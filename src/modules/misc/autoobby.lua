-- Auto Obby: navigates the local character to a goal you click, using Roblox's
-- PathfindingService for routing and driving the body with direct velocity so it
-- actually moves on an executor.
--
-- Two lessons this is built around (they're why naive versions don't work):
--  1) MOVEMENT: Humanoid:Move is zeroed every frame by the default control script,
--     and Wave often can't disable controls -- so we set HumanoidRootPart velocity
--     directly each frame (horizontal at WalkSpeed, vertical kept for gravity/jumps).
--  2) RAYCASTS: RaycastParams.RespectCanCollide isn't honored on Wave, so we cast
--     THROUGH non-collidable parts (invisible zone walls) by hand to the first solid
--     surface -- used for footing checks and the fallback's gap detection.
--
-- Flow: engage with the keybind -> a preview reticle tracks your cursor -> click to
-- drop a goal -> PathfindingService routes there (walking the waypoints, jumping at
-- Jump waypoints) and recomputes as you go. If no path is found it heads straight at
-- the goal and auto-jumps gaps. Modes: Legit (real jump) / Tween (gravity arc).

local feature = require("ui.feature")
local notify  = require("ui.notify")
local log     = require("core.log")
local env     = require("core.env")

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Pathfinder       = game:GetService("PathfindingService")
local Workspace        = workspace

local AutoObby = {}
local LP = Players.LocalPlayer
local ZERO = Vector3.new(0, 0, 0)

local s = {
    active      = false,
    mode        = "Legit",
    avoidDamage = true,
    speedMult   = 1.0,    -- WalkSpeed multiplier for the drive (1 = exact walk speed)
    goal        = nil,
    targetPoint = nil,    -- the world point the mover steers toward (a waypoint / goal)
    busy        = false,  -- mid tween arc
    lastJump    = 0,
    lastStuck   = 0,
    stallSince  = 0,      -- when MoveTo stopped producing motion (-> velocity fallback)
    waypoints   = nil,
    wpIndex     = 1,
    pathStamp   = 0,
    ctrlLoop    = nil,
    moveConn    = nil,
    markConn    = nil,
    clickConn   = nil,
    mouse       = nil,
    ctrlOn      = true,
    controls    = nil,
}

local GOAL_RADIUS = 5
local WP_REACH    = 3.5     -- within this of a waypoint = advance to the next
local JUMP_CD     = 0.3
local RECOMPUTE   = 1.0     -- re-run pathfinding at most this often (s)
local STEP_HEIGHT = 2.5

local GROUNDED = {
    [Enum.HumanoidStateType.Running]          = true,
    [Enum.HumanoidStateType.RunningNoPhysics] = true,
    [Enum.HumanoidStateType.Landed]           = true,
    [Enum.HumanoidStateType.GettingUp]        = true,
}

-- ---- damage heuristic --------------------------------------------------------
local DAMAGE_NAMES = {
    "kill", "lava", "damage", "spike", "death", "hazard", "trap",
    "acid", "poison", "laser", "saw", "void", "danger", "hurt", "deadly",
}
local DAMAGE_MATERIALS = { [Enum.Material.CrackedLava] = true }
local function isDamage(part)
    if not s.avoidDamage or not part then return false end
    local inst = part
    for _ = 1, 3 do
        if not inst or inst == Workspace then break end
        local n = inst.Name:lower()
        for _, pat in ipairs(DAMAGE_NAMES) do
            if n:find(pat, 1, true) then return true end
        end
        inst = inst.Parent
    end
    if part:IsA("BasePart") then
        if DAMAGE_MATERIALS[part.Material] then return true end
        local ok, c = pcall(function() return part.Color end)
        if ok and c and c.R > 0.62 and c.G < 0.32 and c.B < 0.32 then return true end
    end
    return false
end

-- ---- character + physics -----------------------------------------------------
local function rig()
    local c = LP.Character
    if not c then return nil end
    return c, c:FindFirstChild("HumanoidRootPart"), c:FindFirstChildOfClass("Humanoid")
end
local function flat(v) return Vector3.new(v.X, 0, v.Z) end
local function jumpVelocity(hum)
    local g = Workspace.Gravity
    if hum.UseJumpPower then return hum.JumpPower end
    return math.sqrt(2 * g * math.max(hum.JumpHeight, 0))
end
local function jumpHeight(hum)
    local g = Workspace.Gravity
    if hum.UseJumpPower then return (hum.JumpPower * hum.JumpPower) / (2 * g) end
    return hum.JumpHeight
end

-- ---- raycast that ignores non-collidable parts -------------------------------
local rp = RaycastParams.new()
rp.FilterType = Enum.RaycastFilterType.Exclude
rp.IgnoreWater = true
pcall(function() rp.RespectCanCollide = true end)
local rpIgnore = {}
local function rayCollide(origin, dir)
    rpIgnore[1] = LP.Character
    for i = #rpIgnore, 2, -1 do rpIgnore[i] = nil end
    rp.FilterDescendantsInstances = rpIgnore
    local mag = dir.Magnitude
    if mag < 1e-4 then return nil end
    local unit, o, remaining = dir / mag, origin, mag
    for _ = 1, 8 do
        local rc = Workspace:Raycast(o, unit * remaining, rp)
        if not rc then return nil end
        if rc.Instance.CanCollide ~= false then return rc end
        rpIgnore[#rpIgnore + 1] = rc.Instance
        rp.FilterDescendantsInstances = rpIgnore
        remaining = remaining - (rc.Position - o).Magnitude - 0.05
        if remaining <= 0 then return nil end
        o = rc.Position + unit * 0.05
    end
    return nil
end
local function groundUnder(pos, depth)
    return rayCollide(pos + Vector3.new(0, 2.5, 0), Vector3.new(0, -(depth or 80), 0))
end

-- ---- default-controls toggle -------------------------------------------------
local function getControls()
    if s.controls ~= nil then return s.controls end
    s.controls = false
    pcall(function()
        local ps = LP:FindFirstChild("PlayerScripts") or LP:WaitForChild("PlayerScripts", 2)
        local pm = ps and (ps:FindFirstChild("PlayerModule") or ps:WaitForChild("PlayerModule", 2))
        if pm then s.controls = require(pm):GetControls() end
    end)
    return s.controls
end
local function setControls(on)
    if s.ctrlOn == on then return end
    s.ctrlOn = on
    local c = getControls()
    if c then pcall(function() if on then c:Enable() else c:Disable() end end) end
end

-- ---- body rotation (camera stays free) ---------------------------------------
local rot = { att = nil, align = nil, owned = false }
local function faceDir(hrp, hum, dir)
    dir = flat(dir)
    if dir.Magnitude < 1e-3 then return end
    if not (rot.att and rot.att.Parent) then
        rot.att = Instance.new("Attachment"); rot.att.Name = "PantheonObbyAtt"; rot.att.Parent = hrp
    end
    if not (rot.align and rot.align.Parent) then
        rot.align = Instance.new("AlignOrientation")
        rot.align.Name = "PantheonObbyAlign"; rot.align.Mode = Enum.OrientationAlignmentMode.OneAttachment
        rot.align.Attachment0 = rot.att; rot.align.RigidityEnabled = true
        rot.align.Responsiveness = 200; rot.align.MaxTorque = math.huge; rot.align.Parent = hrp
    end
    rot.align.Enabled = true
    rot.align.CFrame = CFrame.lookAt(Vector3.zero, dir.Unit)
    if hum then hum.AutoRotate = false end
    rot.owned = true
end
local function releaseRot(hum)
    if rot.align then rot.align.Enabled = false end
    if rot.owned and hum then pcall(function() hum.AutoRotate = true end) end
    rot.owned = false
end
local function destroyRot()
    if rot.align then pcall(function() rot.align:Destroy() end); rot.align = nil end
    if rot.att   then pcall(function() rot.att:Destroy()   end); rot.att   = nil end
    rot.owned = false
end

-- ---- per-frame mover ---------------------------------------------------------
-- Prefer Humanoid:MoveTo -- that's REAL walking (animation, acceleration, correct
-- speed) and works when the default controls can be disabled. If it isn't actually
-- moving us (executor couldn't disable controls), fall back to a direct velocity
-- kick after a brief stall so it still works on locked-down clients. When there's
-- NO target we touch nothing, so your own movement is never affected.
local function applyMovement()
    if not s.active or s.busy then return end
    local tp = s.targetPoint
    if not tp then return end                       -- idle: leave manual control alone
    local _, hrp, hum = rig()
    if not (hrp and hum) then return end
    local d = flat(tp - hrp.Position)
    if d.Magnitude < 0.5 then return end
    d = d.Unit
    hum:MoveTo(hrp.Position + d * 8)                -- natural walk toward the target
    faceDir(hrp, hum, d)
    -- fallback only if MoveTo produced no motion for a moment (controls not disabled)
    local hv = hrp.AssemblyLinearVelocity
    local horiz = math.sqrt(hv.X * hv.X + hv.Z * hv.Z)
    local want = hum.WalkSpeed * s.speedMult
    if want > 0 and horiz < want * 0.3 then
        if s.stallSince == 0 then s.stallSince = os.clock() end
        if os.clock() - s.stallSince > 0.3 then
            hrp.AssemblyLinearVelocity = Vector3.new(d.X * want, hv.Y, d.Z * want)
        end
    else
        s.stallSince = 0
    end
end

-- ---- tween jump (gravity arc to a point) -------------------------------------
local function tweenJumpTo(hum, hrp, targetPos)
    s.busy = true
    local g = Workspace.Gravity
    local v = jumpVelocity(hum)
    local start = hrp.Position
    local dy = targetPos.Y - start.Y
    local horiz = flat(targetPos - start)
    local dx = horiz.Magnitude
    local dir = (dx > 0.01) and (horiz / dx) or flat(hrp.CFrame.LookVector).Unit
    local disc = v * v - 2 * g * dy
    if disc < 0 then s.busy = false; return end
    local T = (v + math.sqrt(disc)) / g
    if T <= 0 then s.busy = false; return end
    local hs = dx / T
    if rot.align then rot.align.Enabled = false end
    pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
    local t = 0
    while t < T and s.active do
        if not (hrp and hrp.Parent) then s.busy = false; return end
        local dt = RunService.Heartbeat:Wait()
        t = math.min(t + dt, T)
        local y = v * t - 0.5 * g * t * t
        local pos = start + dir * (hs * t) + Vector3.new(0, y, 0)
        hrp.CFrame = CFrame.lookAt(pos, pos + dir)
        hrp.AssemblyLinearVelocity = dir * hs + Vector3.new(0, v - g * t, 0)
    end
    if hrp and hrp.Parent then    -- snap onto real ground, never phase through
        local snap = groundUnder(Vector3.new(targetPos.X, targetPos.Y + 3, targetPos.Z), 14)
        local fy = snap and (snap.Position.Y + (start.Y - (groundUnder(start, 14) or snap).Position.Y)) or targetPos.Y
        if snap then fy = snap.Position.Y + 3 end
        local p = Vector3.new(targetPos.X, fy, targetPos.Z)
        hrp.CFrame = CFrame.lookAt(p, p + dir)
        hrp.AssemblyLinearVelocity = ZERO
    end
    pcall(function() hum:ChangeState(Enum.HumanoidStateType.Landed) end)
    s.busy = false
    s.lastJump = os.clock()
end

-- ---- pathfinding -------------------------------------------------------------
local function computePath(fromPos, goalPos, hum)
    local path = Pathfinder:CreatePath({
        AgentRadius     = 2,
        AgentHeight     = 5,
        AgentCanJump    = true,
        AgentJumpHeight = math.max(jumpHeight(hum), 5),
        AgentMaxSlope   = 70,
        WaypointSpacing = 4,
        Costs           = { CrackedLava = math.huge, Water = math.huge },
    })
    local ok = pcall(function() path:ComputeAsync(fromPos, goalPos) end)
    if ok and path.Status == Enum.PathStatus.Success then
        return path:GetWaypoints()
    end
    return nil
end

-- fallback when there's no path: head straight at the goal, jump if a gap is right
-- ahead (collidable-ground check via rayCollide)
local function autoJumpGap(hrp, hum, now)
    if not GROUNDED[hum:GetState()] or now - s.lastJump < JUMP_CD then return end
    local dir = flat(s.goal - hrp.Position)
    if dir.Magnitude < 0.5 then return end
    dir = dir.Unit
    local gr = groundUnder(hrp.Position, 14)
    local footY = gr and gr.Position.Y or hrp.Position.Y
    local p = hrp.Position + dir * 2.5
    local g = rayCollide(Vector3.new(p.X, footY + STEP_HEIGHT + 0.5, p.Z),
                         Vector3.new(0, -(2 * STEP_HEIGHT + 0.5), 0))
    local ok = g and g.Normal.Y > 0.6 and g.Instance.CanCollide ~= false and not isDamage(g.Instance)
    if not ok then hum.Jump = true; s.lastJump = now end
end

-- one navigation step (run from the control loop; may yield in ComputeAsync/tween)
local function stepNav()
    local _, hrp, hum = rig()
    if not (hrp and hum) or hum.Health <= 0 then
        s.targetPoint = nil; s.waypoints = nil; setControls(true); releaseRot(hum); return
    end
    if not s.goal then
        s.targetPoint, s.waypoints, s.stallSince = nil, nil, 0
        setControls(true); releaseRot(hum); return
    end
    if flat(s.goal - hrp.Position).Magnitude <= GOAL_RADIUS then
        s.goal, s.targetPoint, s.waypoints, s.stallSince = nil, nil, nil, 0
        setControls(true); releaseRot(hum)
        notify.success("Auto Obby: reached the goal"); return
    end
    setControls(false)
    if s.busy then return end

    local now = os.clock()
    if not s.waypoints or s.wpIndex > #s.waypoints or (now - s.pathStamp) > RECOMPUTE then
        local wps = computePath(hrp.Position, s.goal, hum)
        s.pathStamp = now
        if wps and #wps >= 2 then s.waypoints, s.wpIndex = wps, 2
        else s.waypoints = nil end
    end

    if s.waypoints then
        local wp = s.waypoints[s.wpIndex]
        while wp and flat(wp.Position - hrp.Position).Magnitude < WP_REACH do
            s.wpIndex = s.wpIndex + 1
            wp = s.waypoints[s.wpIndex]
        end
        if wp then
            s.targetPoint = wp.Position
            if wp.Action == Enum.PathWaypointAction.Jump and GROUNDED[hum:GetState()]
               and now - s.lastJump > JUMP_CD then
                if s.mode == "Tween" then
                    local nxt = s.waypoints[s.wpIndex + 1]
                    tweenJumpTo(hum, hrp, nxt and nxt.Position or wp.Position)
                else
                    hum.Jump = true; s.lastJump = now
                end
            end
        else
            s.targetPoint = nil   -- exhausted; recompute next tick
        end
    else
        -- no path: drive straight at the goal and auto-jump gaps
        s.targetPoint = s.goal
        autoJumpGap(hrp, hum, now)
        if now - s.lastStuck > 4 then
            s.lastStuck = now
            notify.warn("Auto Obby: no path found -- heading straight; pick a closer goal if it stalls")
        end
    end
end

local function startControl()
    if s.ctrlLoop then return end
    s.ctrlLoop = task.spawn(function()
        while s.active do
            local ok, err = pcall(stepNav)
            if not ok then log.warn("autoobby nav: " .. tostring(err)) end
            task.wait(0.07)
        end
        s.ctrlLoop = nil
    end)
end

-- ---- markers (2D projected; nothing in workspace) ----------------------------
local mk = { gui = nil, preview = nil, placed = nil, label = nil }
local function ensureMarkers()
    if mk.gui and mk.gui.Parent then return end
    local sg = Instance.new("ScreenGui")
    sg.Name = "_" .. tostring(math.random(100000, 999999))
    sg.ResetOnSpawn = false; sg.IgnoreGuiInset = false; sg.DisplayOrder = 50
    sg.Parent = env.guiParent(); env.protectGui(sg)

    local pv = Instance.new("Frame")
    pv.Size = UDim2.fromOffset(26, 26); pv.AnchorPoint = Vector2.new(0.5, 0.5)
    pv.BackgroundTransparency = 1; pv.Visible = false; pv.Parent = sg
    Instance.new("UICorner", pv).CornerRadius = UDim.new(1, 0)
    local pvs = Instance.new("UIStroke", pv); pvs.Color = Color3.fromRGB(120, 220, 255); pvs.Thickness = 2; pvs.Transparency = 0.1
    local dot = Instance.new("Frame", pv)
    dot.Size = UDim2.fromOffset(4, 4); dot.AnchorPoint = Vector2.new(0.5, 0.5); dot.Position = UDim2.fromScale(0.5, 0.5)
    dot.BackgroundColor3 = Color3.fromRGB(120, 220, 255); dot.BorderSizePixel = 0
    Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)

    local pl = Instance.new("Frame")
    pl.Size = UDim2.fromOffset(18, 18); pl.AnchorPoint = Vector2.new(0.5, 0.5); pl.Rotation = 45
    pl.BackgroundColor3 = Color3.fromRGB(87, 242, 135); pl.BorderSizePixel = 0; pl.Visible = false; pl.Parent = sg
    local pls = Instance.new("UIStroke", pl); pls.Color = Color3.fromRGB(255, 255, 255); pls.Thickness = 1.5
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.fromOffset(120, 16); lbl.AnchorPoint = Vector2.new(0.5, 1); lbl.Position = UDim2.fromOffset(0, -16)
    lbl.BackgroundTransparency = 1; lbl.Font = Enum.Font.GothamBold; lbl.TextSize = 12
    lbl.TextColor3 = Color3.fromRGB(87, 242, 135); lbl.TextStrokeTransparency = 0.4; lbl.Text = "GOAL"; lbl.Rotation = -45
    lbl.Parent = pl

    mk.gui, mk.preview, mk.placed, mk.label = sg, pv, pl, lbl
end
local function cursorWorld()
    local m = s.mouse
    if m and m.Target and m.Target.Parent then return m.Hit.Position end
    return nil
end
local function updateMarkers()
    local cam = Workspace.CurrentCamera
    if not (cam and mk.gui) then return end
    local cw = cursorWorld()
    if cw then
        local vp = cam:WorldToViewportPoint(cw)
        if vp.Z > 0 then mk.preview.Visible = true; mk.preview.Position = UDim2.fromOffset(vp.X, vp.Y)
        else mk.preview.Visible = false end
    else mk.preview.Visible = false end
    if s.goal then
        local vp = cam:WorldToViewportPoint(s.goal)
        if vp.Z > 0 then
            mk.placed.Visible = true; mk.placed.Position = UDim2.fromOffset(vp.X, vp.Y)
            local _, hrp = rig()
            if hrp then mk.label.Text = ("GOAL  %d"):format(math.floor(flat(s.goal - hrp.Position).Magnitude)) end
        else mk.placed.Visible = false end
    else mk.placed.Visible = false end
end
local function hideMarkers()
    if mk.preview then mk.preview.Visible = false end
    if mk.placed  then mk.placed.Visible  = false end
end
local function destroyMarkers()
    if mk.gui then pcall(function() mk.gui:Destroy() end) end
    mk.gui, mk.preview, mk.placed, mk.label = nil, nil, nil, nil
end

-- ---- click to set goal -------------------------------------------------------
local function onInput(input, gpe)
    if gpe then return end
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
    local cw = cursorWorld()
    if cw then s.goal, s.waypoints = cw, nil; notify.info("Auto Obby: goal set") end
end

-- ---- lifecycle ---------------------------------------------------------------
local function setActive(v)
    v = v and true or false
    if s.active == v then return end
    s.active = v
    if v then
        s.mouse = s.mouse or LP:GetMouse()
        pcall(function() s.mouse.TargetFilter = LP.Character end)
        s.targetPoint, s.waypoints = nil, nil
        ensureMarkers()
        if not s.clickConn then s.clickConn = UserInputService.InputBegan:Connect(onInput) end
        if not s.markConn  then s.markConn  = RunService.RenderStepped:Connect(updateMarkers) end
        if not s.moveConn  then s.moveConn  = RunService.Heartbeat:Connect(applyMovement) end
        startControl()
        notify.success("Auto Obby ON -- click a spot to set a goal")
    else
        s.goal, s.targetPoint, s.waypoints = nil, nil, nil
        for _, k in ipairs({ "clickConn", "markConn", "moveConn" }) do
            if s[k] then s[k]:Disconnect(); s[k] = nil end
        end
        hideMarkers()
        local _, _, hum = rig()
        releaseRot(hum); setControls(true)
        if hum then pcall(function() hum:Move(ZERO, false) end) end
    end
end

function AutoObby.register(box)
    box:add(feature.declare({
        id          = "misc.autoobby",
        name        = "Auto Obby",
        description = "Pathfinds the local character to a goal you click. Engage with the keybind, a preview reticle follows your cursor, click a spot to drop a GOAL marker, and it routes there with Roblox PathfindingService -- walking, jumping the gaps, recomputing as it goes, and routing around obstacles (so it naturally takes angled / sideways routes). Drives the body via direct velocity so it actually moves under an executor, ignores non-collidable parts (invisible zone walls), and avoids lava + detected kill blocks. If no path is found it heads straight at the goal and auto-jumps gaps. Legit = real jumps; Tween = a gravity-accurate jump arc (drives your position -- a strict client anticheat may flag it). Turning it off clears the goal + markers and hands movement back.",
        default     = false,
        defaultKey  = Enum.KeyCode.G,
        onToggle    = setActive,
        settings    = {
            { type = "dropdown", name = "Mode", key = "mode", options = { "Legit", "Tween" }, default = "Legit",
              onChange = function(v) s.mode = v end },
            { type = "toggle", name = "Avoid damage blocks", key = "avoid", default = true,
              onChange = function(v) s.avoidDamage = v end },
            { type = "slider", name = "Speed %", key = "speed", min = 50, max = 200, step = 10, default = 100,
              onChange = function(v) s.speedMult = (v or 100) / 100 end },
        },
    }).root)
    log.info("Auto Obby feature registered")
end

function AutoObby.destroy()
    s.active = false
    for _, k in ipairs({ "clickConn", "markConn", "moveConn" }) do
        if s[k] then pcall(function() s[k]:Disconnect() end); s[k] = nil end
    end
    local _, _, hum = rig()
    releaseRot(hum); destroyRot(); destroyMarkers(); setControls(true)
    s.goal, s.targetPoint, s.waypoints = nil, nil, nil
end

-- pure-ish helpers for the offline mock test
AutoObby._diag = { isDamage = isDamage, jumpVelocity = jumpVelocity, jumpHeight = jumpHeight,
                   computePath = computePath, rayCollide = rayCollide }

return AutoObby
