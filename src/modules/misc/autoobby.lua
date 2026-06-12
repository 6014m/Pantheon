-- Auto Obby: auto-completes an obstacle course toward a goal you place.
--
-- Engage with the feature keybind (or the toggle): a PREVIEW reticle tracks
-- whatever your cursor points at -- click to drop a GOAL marker there. The bot
-- WALKS to the goal on continuous ground and only JUMPS when it has to (a real
-- gap, or a ledge taller than a step), and it will jump SIDEWAYS / at an angle
-- when that reaches a platform a straight jump can't, or to go AROUND a damage
-- block. It only ever attempts jumps the local character could physically make.
--
-- Movement: Roblox's default control script zeroes Humanoid.MoveDirection every
-- frame when you aren't pressing keys, which would cancel our walking. So while a
-- goal is active we DISABLE the PlayerModule controls and drive movement each
-- frame ourselves; controls are handed back the instant there's no goal, you
-- arrive, or you turn it off (you're never left unable to move).
--
-- Robustness: non-collidable parts (invisible zone/trigger walls) are ignored for
-- footing AND obstruction (RespectCanCollide + CanCollide check); it never noclips
-- (physics walk; jumps blocked by a wall in their path are rejected; the tween arc
-- re-snaps onto real ground so it can't end up through the floor); it steers around
-- walls; it rotates the body to face travel via AlignOrientation (camera stays free).
--
-- Modes: Legit = real Humanoid jump + air control over the gap. Tween = drives the
-- root along a gravity-accurate projectile arc (looks legit; per-frame CFrame drive
-- can trip strict client ACs -- use Legit there). Both gated by the same physics.

local feature = require("ui.feature")
local notify  = require("ui.notify")
local log     = require("core.log")
local env     = require("core.env")

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace        = workspace

local AutoObby = {}
local LP = Players.LocalPlayer
local ZERO = Vector3.new(0, 0, 0)

local s = {
    active      = false,
    mode        = "Legit",
    avoidDamage = true,
    reachPct    = 0.85,
    hopDelay    = 0.12,
    goal        = nil,
    moveDir     = ZERO,    -- intended walk/air direction, applied every frame
    airTarget   = nil,     -- where a legit jump is air-controlling toward
    busy        = false,   -- mid tween arc (the arc drives the root, mover stands off)
    lastJump    = 0,
    ctrlOn      = true,    -- whether the default controls are currently enabled
    controls    = nil,     -- PlayerModule controls (false = looked up, unavailable)
    ctrlLoop    = nil,
    moveConn    = nil,     -- per-frame movement/facing
    markConn    = nil,     -- per-frame marker projection
    clickConn   = nil,
    mouse       = nil,
}

local STEP_HEIGHT = 2.5   -- ledges up to this we walk up (auto-step); above -> jump
local LOOKAHEAD   = 4.5   -- studs ahead we probe for a body-height wall
local EDGE_LOOK   = 2.0   -- how close to a gap edge before we stop walking and jump
local GOAL_RADIUS = 5     -- within this (horizontal) of the goal = arrived
local JUMP_CD     = 0.25  -- min seconds between jump triggers

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

local function jumpVelocity(hum)
    local g = Workspace.Gravity
    if hum.UseJumpPower then return hum.JumpPower end
    return math.sqrt(2 * g * math.max(hum.JumpHeight, 0))
end

local function reachable(hum, dx, dy)
    local g = Workspace.Gravity
    local v = jumpVelocity(hum)
    local peak = (v * v) / (2 * g)
    if dy > peak then return false end
    local disc = v * v - 2 * g * dy
    if disc < 0 then return false end
    local tLand = (v + math.sqrt(disc)) / g
    return dx <= hum.WalkSpeed * tLand * s.reachPct
end

local rp = RaycastParams.new()
rp.FilterType = Enum.RaycastFilterType.Exclude
rp.IgnoreWater = true
pcall(function() rp.RespectCanCollide = true end)   -- ignore non-collidable parts
local rpIgnore = {}
local function params(extra)
    rpIgnore[1] = LP.Character
    rpIgnore[2] = extra
    rp.FilterDescendantsInstances = rpIgnore
    return rp
end

local function flat(v) return Vector3.new(v.X, 0, v.Z) end
local function rotateY(v, rad)
    local c, sn = math.cos(rad), math.sin(rad)
    return Vector3.new(v.X * c - v.Z * sn, 0, v.X * sn + v.Z * c)
end

local function groundUnder(pos, depth)
    return Workspace:Raycast(pos + Vector3.new(0, 2.5, 0), Vector3.new(0, -(depth or 80), 0), params())
end
local function standable(rc)
    return rc and rc.Instance and rc.Instance.CanCollide ~= false
        and rc.Normal.Y > 0.6 and not isDamage(rc.Instance)
end

-- ---- default-controls toggle (so our movement isn't overridden) --------------
local function getControls()
    if s.controls ~= nil then return s.controls end
    s.controls = false
    pcall(function()
        local ps = LP:FindFirstChild("PlayerScripts")
        local pm = ps and ps:FindFirstChild("PlayerModule")
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
local function ensureAlign(hrp)
    if not (rot.att and rot.att.Parent) then
        rot.att = Instance.new("Attachment"); rot.att.Name = "PantheonObbyAtt"; rot.att.Parent = hrp
    end
    if not (rot.align and rot.align.Parent) then
        rot.align = Instance.new("AlignOrientation")
        rot.align.Name = "PantheonObbyAlign"
        rot.align.Mode = Enum.OrientationAlignmentMode.OneAttachment
        rot.align.Attachment0 = rot.att
        rot.align.RigidityEnabled = true
        rot.align.Responsiveness = 200
        rot.align.MaxTorque = math.huge
        rot.align.Parent = hrp
    end
end
local function faceDir(hrp, hum, dir)
    dir = flat(dir)
    if dir.Magnitude < 1e-3 then return end
    ensureAlign(hrp)
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

-- ---- find a jump landing (incl. sideways) ------------------------------------
-- Wide fan so it can angle around damage blocks / reach off-line platforms.
local ANGLES = { 0, 12, -12, 25, -25, 40, -40, 55, -55, 70, -70 }
local function findLanding(fromPos, startGroundY, standOffset, heading, hum, goal)
    local g = Workspace.Gravity
    local v = jumpVelocity(hum)
    local peak     = (v * v) / (2 * g)
    local maxReach = hum.WalkSpeed * (2 * v / g)
    local fromFlat = flat(fromPos)
    local goalFlat = goal and flat(goal) or nil
    local goalDist = goalFlat and (goalFlat - fromFlat).Magnitude or nil

    local best, bestScore
    for _, deg in ipairs(ANGLES) do
        local dir = rotateY(heading, math.rad(deg)).Unit
        for i = 1, 7 do
            local dist = math.max(4, (i / 7) * maxReach)
            local col  = fromPos + dir * dist
            local top  = col + Vector3.new(0, peak + 6, 0)
            local rc   = Workspace:Raycast(top, Vector3.new(0, -(peak + 6 + 60), 0), params())
            if standable(rc) then
                local land = rc.Position
                local dx   = (flat(land) - fromFlat).Magnitude
                local dyP  = land.Y - startGroundY
                if dx >= 4 and reachable(hum, dx, dyP) then
                    local fwd = (flat(land) - fromFlat).Unit:Dot(heading)
                    if fwd > 0 then
                        -- prefer getting closer to the goal; the dot term keeps it
                        -- from wandering too wide unless a detour is the only way.
                        local score = goalDist
                            and (goalDist - (goalFlat - flat(land)).Magnitude) + fwd * 0.5
                            or  (flat(land) - fromFlat):Dot(heading)
                        if score > 0.3 and (not bestScore or score > bestScore) then
                            best = { hrpPos = land + Vector3.new(0, standOffset, 0), inst = rc.Instance, groundY = land.Y }
                            bestScore = score
                        end
                    end
                end
            end
        end
    end
    return best
end

-- straight-line collidable obstruction between root and a landing (no noclip)
local function pathClear(fromHrp, toHrp, destInst)
    local dir = toHrp - fromHrp
    if dir.Magnitude < 0.1 then return true end
    return Workspace:Raycast(fromHrp, dir * 0.9, params(destInst)) == nil
end

-- ---- movement decision -------------------------------------------------------
local GROUNDED = {
    [Enum.HumanoidStateType.Running]          = true,
    [Enum.HumanoidStateType.RunningNoPhysics] = true,
    [Enum.HumanoidStateType.Landed]           = true,
    [Enum.HumanoidStateType.GettingUp]        = true,
}

-- continuous safe ground for the next EDGE_LOOK studs (walk up to the gap edge)
local function walkClear(hrp, footY, dir)
    for i = 1, 2 do
        local p = hrp.Position + dir * (EDGE_LOOK * i / 2)
        local b = Workspace:Raycast(Vector3.new(p.X, footY + STEP_HEIGHT + 0.5, p.Z),
                                    Vector3.new(0, -(2 * STEP_HEIGHT + 0.5), 0), params())
        if not standable(b) then return false end
    end
    return true
end

-- "walk", "jump"+landing, "wall", or "stuck"
local function decideMove(hrp, hum, footY, heading)
    local wall = Workspace:Raycast(hrp.Position, heading * LOOKAHEAD, params())
    if not wall and walkClear(hrp, footY, heading) then
        return "walk"
    end
    local land = findLanding(hrp.Position, footY, hrp.Position.Y - footY, heading, hum, s.goal)
    if land and pathClear(hrp.Position, land.hrpPos, land.inst) then
        return "jump", land
    end
    if wall or land then return "wall" end
    return "stuck"
end

local function steerAround(hrp, footY, heading)
    for _, deg in ipairs({ 25, -25, 50, -50, 80, -80 }) do
        local d = rotateY(heading, math.rad(deg)).Unit
        local wall = Workspace:Raycast(hrp.Position, d * (LOOKAHEAD + 1), params())
        local probe = hrp.Position + d * LOOKAHEAD
        local band  = Workspace:Raycast(Vector3.new(probe.X, footY + STEP_HEIGHT + 0.5, probe.Z),
                                        Vector3.new(0, -(2 * STEP_HEIGHT + 0.5), 0), params())
        if standable(band) and not wall then return d end
    end
    return ZERO
end

-- ---- jump execution (tween) --------------------------------------------------
local function tweenJump(hum, hrp, land, standOffset)
    s.busy = true
    local g = Workspace.Gravity
    local v = jumpVelocity(hum)
    local start = hrp.Position
    local target = land.hrpPos
    local dy = target.Y - start.Y
    local horiz = flat(target - start)
    local dx = horiz.Magnitude
    local dir = (dx > 0.01) and (horiz / dx) or flat(hrp.CFrame.LookVector).Unit
    local disc = v * v - 2 * g * dy
    if disc < 0 then s.busy = false; return end
    local T = (v + math.sqrt(disc)) / g
    if T <= 0 then s.busy = false; return end
    local hs = dx / T

    if rot.align then rot.align.Enabled = false end   -- the arc CFrame owns orientation
    pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
    local t = 0
    while t < T and s.active do
        if not (hrp and hrp.Parent) then s.busy = false; return end
        local dt = RunService.Heartbeat:Wait()
        t = math.min(t + dt, T)
        local y   = v * t - 0.5 * g * t * t
        local pos = start + dir * (hs * t) + Vector3.new(0, y, 0)
        hrp.CFrame = CFrame.lookAt(pos, pos + dir)
        hrp.AssemblyLinearVelocity = dir * hs + Vector3.new(0, v - g * t, 0)
    end
    if hrp and hrp.Parent then   -- land on the TRUE ground (re-raycast) -- never phase in
        local snap = groundUnder(Vector3.new(target.X, target.Y + 2, target.Z), 12)
        local fy = (snap and standable(snap)) and (snap.Position.Y + standOffset) or target.Y
        local p = Vector3.new(target.X, fy, target.Z)
        hrp.CFrame = CFrame.lookAt(p, p + dir)
        hrp.AssemblyLinearVelocity = ZERO
    end
    pcall(function() hum:ChangeState(Enum.HumanoidStateType.Landed) end)
    s.busy = false
    s.lastJump = os.clock()
end

-- ---- per-frame movement applier ----------------------------------------------
-- Runs every frame: with the default controls off, this is what actually walks
-- the body. Skipped during a tween arc (that drives the root directly).
local function applyMovement()
    if not s.active or s.busy then return end
    local _, hrp, hum = rig()
    if not (hrp and hum) then return end
    local d = s.moveDir or ZERO
    hum:Move(d, false)
    if d.Magnitude > 0.01 then faceDir(hrp, hum, d) else releaseRot(hum) end
end

-- ---- decision loop -----------------------------------------------------------
-- returns true if it triggered a jump (so the loop pauses briefly)
local function controlTick()
    local _, hrp, hum = rig()
    if not (hrp and hum) or hum.Health <= 0 then
        s.moveDir, s.airTarget = ZERO, nil; setControls(true); releaseRot(hum); return false
    end

    if not s.goal then                          -- idle: hand controls back, don't drive
        s.moveDir, s.airTarget = ZERO, nil; setControls(true); return false
    end
    if flat(s.goal - hrp.Position).Magnitude <= GOAL_RADIUS then
        s.goal, s.moveDir, s.airTarget = nil, ZERO, nil
        setControls(true)
        notify.success("Auto Obby: reached the goal")
        return false
    end

    setControls(false)                          -- a goal is active -> we drive

    if not GROUNDED[hum:GetState()] then         -- airborne (legit jump): steer toward the landing
        local aim = s.airTarget or s.goal
        local d = flat(aim - hrp.Position)
        if d.Magnitude > 0.5 then s.moveDir = d.Unit end
        return false
    end
    s.airTarget = nil
    if s.busy then return false end

    local gr = groundUnder(hrp.Position, 14)
    if not gr then return false end
    local footY = gr.Position.Y
    local standOffset = hrp.Position.Y - footY
    local goalDir = flat(s.goal - hrp.Position).Unit

    local action, land = decideMove(hrp, hum, footY, goalDir)
    if action == "walk" then
        s.moveDir = goalDir
        return false
    elseif action == "jump" then
        if os.clock() - s.lastJump < JUMP_CD then return false end
        local jumpDir = flat(land.hrpPos - hrp.Position)
        jumpDir = (jumpDir.Magnitude > 0.01) and jumpDir.Unit or goalDir   -- may be sideways
        if s.mode == "Tween" then
            s.moveDir = ZERO
            tweenJump(hum, hrp, land, standOffset)
        else
            s.airTarget = land.hrpPos
            s.moveDir = jumpDir
            hum.Jump = true
            s.lastJump = os.clock()
        end
        return true
    elseif action == "wall" then
        s.moveDir = steerAround(hrp, footY, goalDir)
        return false
    else
        s.moveDir = ZERO
        return false
    end
end

local function startControl()
    if s.ctrlLoop then return end
    s.ctrlLoop = task.spawn(function()
        while s.active do
            local jumped
            local ok, err = pcall(function() jumped = controlTick() end)
            if not ok then log.warn("autoobby tick: " .. tostring(err)) end
            task.wait(jumped and s.hopDelay or 0.06)
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
    sg.ResetOnSpawn = false
    sg.IgnoreGuiInset = false
    sg.DisplayOrder = 50
    sg.Parent = env.guiParent()
    env.protectGui(sg)

    local pv = Instance.new("Frame")
    pv.Size = UDim2.fromOffset(26, 26); pv.AnchorPoint = Vector2.new(0.5, 0.5)
    pv.BackgroundTransparency = 1; pv.Visible = false; pv.Parent = sg
    local pvc = Instance.new("UICorner", pv); pvc.CornerRadius = UDim.new(1, 0)
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
    if cw then s.goal = cw; notify.info("Auto Obby: goal set") end
end

-- ---- lifecycle ---------------------------------------------------------------
local function setActive(v)
    v = v and true or false
    if s.active == v then return end
    s.active = v
    if v then
        s.mouse = s.mouse or LP:GetMouse()
        pcall(function() s.mouse.TargetFilter = LP.Character end)
        s.moveDir, s.airTarget = ZERO, nil
        ensureMarkers()
        if not s.clickConn then s.clickConn = UserInputService.InputBegan:Connect(onInput) end
        if not s.markConn  then s.markConn  = RunService.RenderStepped:Connect(updateMarkers) end
        if not s.moveConn  then s.moveConn  = RunService.Heartbeat:Connect(applyMovement) end
        startControl()
        notify.success("Auto Obby ON -- click a spot to set a goal")
    else
        s.goal, s.airTarget, s.moveDir = nil, nil, ZERO
        if s.clickConn then s.clickConn:Disconnect(); s.clickConn = nil end
        if s.markConn  then s.markConn:Disconnect();  s.markConn  = nil end
        if s.moveConn  then s.moveConn:Disconnect();  s.moveConn  = nil end
        hideMarkers()
        local _, _, hum = rig()
        releaseRot(hum)
        setControls(true)                       -- ALWAYS hand the controls back
        if hum then pcall(function() hum:Move(ZERO, false) end) end
    end
end

function AutoObby.register(box)
    box:add(feature.declare({
        id          = "misc.autoobby",
        name        = "Auto Obby",
        description = "Auto-completes obstacle courses. Engage with the keybind, then a preview reticle follows your cursor -- click a spot to drop a GOAL marker and it heads there on its own. It WALKS on continuous ground and only JUMPS at real gaps / tall ledges (and will jump sideways to reach off-line platforms or go around damage blocks), only attempting jumps your character can actually make, rotating the body to face travel (camera stays put). While a goal is active it takes over movement (the default controls are disabled and handed back when you arrive or turn it off). Ignores non-collidable parts (invisible zone walls), won't noclip through walls, avoids damage / kill blocks. Legit = real jump + air control; Tween = a gravity-accurate jump arc (looks legit, but drives your position -- a strict client anticheat may flag it). Turning it off clears the goal + markers.",
        default     = false,
        defaultKey  = Enum.KeyCode.G,
        onToggle    = setActive,
        settings    = {
            { type = "dropdown", name = "Mode", key = "mode", options = { "Legit", "Tween" }, default = "Legit",
              onChange = function(v) s.mode = v end },
            { type = "toggle", name = "Avoid damage blocks", key = "avoid", default = true,
              onChange = function(v) s.avoidDamage = v end },
            { type = "slider", name = "Reach safety %", key = "reach", min = 50, max = 100, step = 5, default = 85,
              onChange = function(v) s.reachPct = (v or 85) / 100 end },
            { type = "slider", name = "Jump pause (s)", key = "delay", min = 0, max = 0.6, step = 0.05, default = 0.12,
              onChange = function(v) s.hopDelay = v or 0.12 end },
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
    releaseRot(hum)
    destroyRot()
    destroyMarkers()
    setControls(true)
    s.goal, s.airTarget, s.moveDir = nil, nil, ZERO
end

-- pure helpers for the offline mock test; no side effects
AutoObby._diag = { reachable = reachable, isDamage = isDamage, jumpVelocity = jumpVelocity,
                   findLanding = findLanding, decideMove = decideMove, pathClear = pathClear }

return AutoObby
