-- Auto Obby: set a final destination, and it PLANS the whole chain of jumps up
-- front (start -> platform -> platform -> ... -> goal), then executes them one by
-- one. Planning fixed, validated landing spots is far more stable than deciding
-- every frame. The planned jumps are drawn as dots so you can see the route.
--
-- Two hard-won rules baked in:
--   * MOVEMENT: drive HumanoidRootPart velocity each frame (Wave can't disable the
--     default controls, so Humanoid:Move/MoveTo alone get zeroed). On the ground we
--     still use MoveTo for the walk animation; in the air we MUST keep horizontal
--     velocity toward the landing or the jump drops straight into the gap.
--   * RAYCASTS: RespectCanCollide isn't honored on Wave, so rayCollide() casts
--     THROUGH non-collidable parts (invisible zone walls) to the real surface.

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
    speedMult   = 1.0,
    goal        = nil,
    plan        = nil,   -- { Vector3 landing points ..., goal }
    planIndex   = 1,
    targetPoint = nil,   -- world point the mover steers toward (current mini-dest / landing)
    busy        = false,
    lastJump    = 0,
    lastStuck   = 0,
    stallSince  = 0,
    ctrlLoop    = nil,
    moveConn    = nil,
    markConn    = nil,
    clickConn   = nil,
    mouse       = nil,
    ctrlOn      = true,
    controls    = nil,
}

local GOAL_RADIUS = 5
local ARRIVE      = 4      -- within this (horizontal) of a mini-dest = advance
local JUMP_CD     = 0.3
local STEP_HEIGHT = 2.5
local EDGE        = 2.0    -- gap detected this far ahead -> jump

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

-- ---- helpers -----------------------------------------------------------------
local function rig()
    local c = LP.Character
    if not c then return nil end
    return c, c:FindFirstChild("HumanoidRootPart"), c:FindFirstChildOfClass("Humanoid")
end
local function flat(v) return Vector3.new(v.X, 0, v.Z) end
local function rotateY(v, rad)
    local c, sn = math.cos(rad), math.sin(rad)
    return Vector3.new(v.X * c - v.Z * sn, 0, v.X * sn + v.Z * c)
end
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
-- can a jump clear dx horizontally to a point dy above (dy<0=below)? uses the same
-- effective speed the air-control carries at (WalkSpeed*Speed%).
local function reachable(hum, dx, dy)
    local g = Workspace.Gravity
    local v = jumpVelocity(hum)
    local peak = (v * v) / (2 * g)
    if dy > peak then return false end
    local disc = v * v - 2 * g * dy
    if disc < 0 then return false end
    local tLand = (v + math.sqrt(disc)) / g
    return dx <= hum.WalkSpeed * s.speedMult * tLand * s.reachPct
end

local rp = RaycastParams.new()
rp.FilterType = Enum.RaycastFilterType.Exclude
rp.IgnoreWater = true
pcall(function() rp.RespectCanCollide = true end)
local rpIgnore = {}
-- raycast that passes THROUGH non-collidable parts to the first collidable surface
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
local function solidTop(rc, footY, jh)
    return rc and rc.Normal.Y > 0.6 and rc.Instance.CanCollide ~= false
        and not isDamage(rc.Instance) and (not footY or (rc.Position.Y - footY) <= (jh or 99) + 2)
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

-- ---- body rotation (camera free) ---------------------------------------------
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

-- ---- the planner: build the chain of jumps to the goal -----------------------
-- From the current platform, repeatedly find the next platform ACROSS A GAP toward
-- the goal that the character can actually reach, until close to the goal. Returns
-- a list of landing positions (the mini-destinations), ending on the goal.
local PLAN_ANGLES = { 0, 16, -16, 33, -33, 52, -52 }
local function planChain(startPos, hum, goal)
    local g    = Workspace.Gravity
    local jh   = jumpHeight(hum)
    local maxD = (2 * jumpVelocity(hum) * hum.WalkSpeed * s.speedMult / g) * s.reachPct
    local chain, cur = {}, startPos
    local goalFlat = flat(goal)
    for _ = 1, 30 do
        if (flat(cur) - goalFlat).Magnitude <= maxD then chain[#chain + 1] = goal; break end
        local curG  = groundUnder(cur, 60)
        local footY = curG and curG.Position.Y or cur.Y
        local heading = goalFlat - flat(cur)
        if heading.Magnitude < 1 then break end
        heading = heading.Unit
        -- pick the next platform-after-a-gap with the most progress toward the goal
        local best, bestProg
        for _, deg in ipairs(PLAN_ANGLES) do
            local dir, sawGap, dist = rotateY(heading, math.rad(deg)).Unit, false, 2
            while dist <= maxD + 3 do
                local p  = cur + dir * dist
                local rc = rayCollide(Vector3.new(p.X, footY + jh + 6, p.Z), Vector3.new(0, -(jh + 6 + 90), 0))
                if solidTop(rc, footY, jh) then
                    if sawGap then   -- first solid ground after a gap = next platform
                        if reachable(hum, dist, rc.Position.Y - footY) then
                            local prog = (goalFlat - flat(cur)).Magnitude - (goalFlat - flat(rc.Position)).Magnitude
                            if prog > 1 and (not bestProg or prog > bestProg) then best, bestProg = rc.Position, prog end
                        end
                        break
                    end
                else
                    sawGap = true
                end
                dist = dist + 1.5
            end
        end
        if not best then break end
        chain[#chain + 1] = best
        -- the NEXT jump is taken from this platform's FAR edge (we walk across it
        -- first), so measure the next reach from there, not from the landing.
        local eh = goalFlat - flat(best)
        eh = (eh.Magnitude > 1) and eh.Unit or heading
        local edge, ed = best, 1
        while ed <= 50 do
            local p  = best + eh * ed
            local rc = rayCollide(Vector3.new(p.X, best.Y + 3, p.Z), Vector3.new(0, -12, 0))
            if not solidTop(rc, best.Y) then break end
            edge = rc.Position; ed = ed + 1
        end
        cur = edge
    end
    return chain
end

-- ---- jump execution (Tween arc) ----------------------------------------------
local function tweenJumpTo(hum, hrp, targetHrp)
    s.busy = true
    local g = Workspace.Gravity
    local v = jumpVelocity(hum)
    local start = hrp.Position
    local dy = targetHrp.Y - start.Y
    local horiz = flat(targetHrp - start)
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
    if hrp and hrp.Parent then
        local snap = groundUnder(Vector3.new(targetHrp.X, targetHrp.Y + 3, targetHrp.Z), 14)
        local p = (snap and solidTop(snap)) and Vector3.new(targetHrp.X, snap.Position.Y + (start.Y - groundUnder(start, 14).Position.Y), targetHrp.Z) or targetHrp
        hrp.CFrame = CFrame.lookAt(p, p + dir)
        hrp.AssemblyLinearVelocity = ZERO
    end
    pcall(function() hum:ChangeState(Enum.HumanoidStateType.Landed) end)
    s.busy = false
    s.lastJump = os.clock()
end

-- ---- per-frame mover ---------------------------------------------------------
local function applyMovement()
    if not s.active or s.busy then return end
    local tp = s.targetPoint
    if not tp then return end                       -- idle: don't touch manual control
    local _, hrp, hum = rig()
    if not (hrp and hum) then return end
    local d = flat(tp - hrp.Position)
    if d.Magnitude < 0.4 then return end
    d = d.Unit
    faceDir(hrp, hum, d)
    local v = hrp.AssemblyLinearVelocity
    local want = hum.WalkSpeed * s.speedMult
    if want <= 0 then want = 16 end
    if GROUNDED[hum:GetState()] then
        hum:MoveTo(hrp.Position + d * 8)            -- natural walk
        local horiz = math.sqrt(v.X * v.X + v.Z * v.Z)
        if horiz < want * 0.3 then
            if s.stallSince == 0 then s.stallSince = os.clock() end
            if os.clock() - s.stallSince > 0.3 then
                hrp.AssemblyLinearVelocity = Vector3.new(d.X * want, v.Y, d.Z * want)
            end
        else s.stallSince = 0 end
    else
        -- airborne: carry horizontal toward the landing so the jump crosses the gap
        s.stallSince = 0
        hrp.AssemblyLinearVelocity = Vector3.new(d.X * want, v.Y, d.Z * want)
        hum:MoveTo(hrp.Position + d * 8)
    end
end

-- ---- the executor: walk/jump along the planned chain -------------------------
local function stepNav()
    local _, hrp, hum = rig()
    if not (hrp and hum) or hum.Health <= 0 then
        s.targetPoint, s.plan = nil, nil; setControls(true); releaseRot(hum); return
    end
    if not s.goal then
        s.targetPoint, s.plan, s.stallSince = nil, nil, 0; setControls(true); releaseRot(hum); return
    end
    setControls(false)
    if s.busy then return end

    if not s.plan then
        s.plan = planChain(hrp.Position, hum, s.goal)
        s.planIndex = 1
        if #s.plan == 0 then s.plan = { s.goal } end
        notify.info(("Auto Obby: planned %d hops"):format(#s.plan))
    end

    if not GROUNDED[hum:GetState()] then return end   -- airborne: mover steers to the mini-dest

    -- advance past any mini-destinations we've reached
    local tgt = s.plan[s.planIndex]
    while tgt and flat(tgt - hrp.Position).Magnitude < ARRIVE do
        s.planIndex = s.planIndex + 1
        tgt = s.plan[s.planIndex]
    end
    if not tgt then
        if flat(s.goal - hrp.Position).Magnitude <= GOAL_RADIUS then
            s.goal, s.targetPoint, s.plan = nil, nil, nil
            setControls(true); releaseRot(hum); notify.success("Auto Obby: reached the goal"); return
        end
        s.plan = nil; return   -- exhausted but short of the goal -> replan
    end
    s.targetPoint = tgt

    -- jump when ground actually ends just ahead toward the mini-dest; the mover air-
    -- controls across to the planned landing (a fixed, validated platform point).
    local now = os.clock()
    if now - s.lastJump > JUMP_CD then
        local gr = groundUnder(hrp.Position, 14)
        local md = gr and flat(tgt - hrp.Position) or nil
        if gr and md.Magnitude > 0.5 then
            md = md.Unit
            local footY = gr.Position.Y
            local a  = hrp.Position + md * EDGE
            local ag = rayCollide(Vector3.new(a.X, footY + STEP_HEIGHT, a.Z), Vector3.new(0, -(STEP_HEIGHT + 5), 0))
            if not solidTop(ag, footY, jumpHeight(hum)) then   -- gap right ahead -> jump
                if s.mode == "Tween" then
                    tweenJumpTo(hum, hrp, Vector3.new(tgt.X, tgt.Y + (hrp.Position.Y - footY), tgt.Z))
                else
                    hum.Jump = true; s.lastJump = now
                end
            end
        end
    end
end

local function startControl()
    if s.ctrlLoop then return end
    s.ctrlLoop = task.spawn(function()
        while s.active do
            local ok, err = pcall(stepNav)
            if not ok then log.warn("autoobby nav: " .. tostring(err)) end
            task.wait(0.06)
        end
        s.ctrlLoop = nil
    end)
end

-- ---- markers (2D projected; nothing in workspace) ----------------------------
local mk = { gui = nil, preview = nil, placed = nil, label = nil, dots = {} }
local function ensureMarkers()
    if mk.gui and mk.gui.Parent then return end
    local sg = Instance.new("ScreenGui")
    sg.Name = "_" .. tostring(math.random(100000, 999999))
    sg.ResetOnSpawn = false; sg.IgnoreGuiInset = false; sg.DisplayOrder = 50
    sg.Parent = env.guiParent(); env.protectGui(sg)

    -- planned-hop dots (a pool we position each frame)
    mk.dots = {}
    for i = 1, 28 do
        local dt = Instance.new("Frame")
        dt.Size = UDim2.fromOffset(8, 8); dt.AnchorPoint = Vector2.new(0.5, 0.5)
        dt.BackgroundColor3 = Color3.fromRGB(120, 220, 255); dt.BackgroundTransparency = 0.15
        dt.BorderSizePixel = 0; dt.Visible = false; dt.Parent = sg
        Instance.new("UICorner", dt).CornerRadius = UDim.new(1, 0)
        mk.dots[i] = dt
    end

    local pv = Instance.new("Frame")
    pv.Size = UDim2.fromOffset(26, 26); pv.AnchorPoint = Vector2.new(0.5, 0.5)
    pv.BackgroundTransparency = 1; pv.Visible = false; pv.Parent = sg
    Instance.new("UICorner", pv).CornerRadius = UDim.new(1, 0)
    local pvs = Instance.new("UIStroke", pv); pvs.Color = Color3.fromRGB(120, 220, 255); pvs.Thickness = 2; pvs.Transparency = 0.1

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
local function project(cam, world, frame)
    local vp = cam:WorldToViewportPoint(world)
    if vp.Z > 0 then frame.Visible = true; frame.Position = UDim2.fromOffset(vp.X, vp.Y); return true end
    frame.Visible = false; return false
end
local function updateMarkers()
    local cam = Workspace.CurrentCamera
    if not (cam and mk.gui) then return end
    local cw = cursorWorld()
    if cw then project(cam, cw, mk.preview) else mk.preview.Visible = false end
    if s.goal then
        if project(cam, s.goal, mk.placed) then
            local _, hrp = rig()
            if hrp then mk.label.Text = ("GOAL  %d"):format(math.floor(flat(s.goal - hrp.Position).Magnitude)) end
        end
    else mk.placed.Visible = false end
    -- planned hops
    for i, dt in ipairs(mk.dots) do
        local pt = s.plan and s.plan[i]
        if pt then dt.Visible = (i >= (s.planIndex or 1)) and project(cam, pt, dt) else dt.Visible = false end
    end
end
local function hideMarkers()
    if mk.preview then mk.preview.Visible = false end
    if mk.placed  then mk.placed.Visible  = false end
    for _, dt in ipairs(mk.dots) do dt.Visible = false end
end
local function destroyMarkers()
    if mk.gui then pcall(function() mk.gui:Destroy() end) end
    mk.gui, mk.preview, mk.placed, mk.label, mk.dots = nil, nil, nil, nil, {}
end

-- ---- click to set the final destination --------------------------------------
local function onInput(input, gpe)
    if gpe then return end
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
    local cw = cursorWorld()
    if cw then s.goal, s.plan = cw, nil; notify.info("Auto Obby: destination set") end
end

-- ---- lifecycle ---------------------------------------------------------------
local function setActive(v)
    v = v and true or false
    if s.active == v then return end
    s.active = v
    if v then
        s.mouse = s.mouse or LP:GetMouse()
        pcall(function() s.mouse.TargetFilter = LP.Character end)
        s.targetPoint, s.plan = nil, nil
        ensureMarkers()
        if not s.clickConn then s.clickConn = UserInputService.InputBegan:Connect(onInput) end
        if not s.markConn  then s.markConn  = RunService.RenderStepped:Connect(updateMarkers) end
        if not s.moveConn  then s.moveConn  = RunService.Heartbeat:Connect(applyMovement) end
        startControl()
        notify.success("Auto Obby ON -- click a final destination")
    else
        s.goal, s.targetPoint, s.plan = nil, nil, nil
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
        description = "Set a final destination and it auto-completes the obby to it. Engage with the keybind, a preview reticle follows your cursor, click a spot to set the GOAL -- it then PLANS the whole chain of jumps up front (drawn as blue dots) and executes them one platform at a time, only making jumps your character can actually make and avoiding damage / kill blocks. Drives the body by velocity so it works under the executor, carries horizontal speed through each jump so it clears the gap (doesn't drop in), rotates to face travel, and ignores non-collidable parts. Legit = real jumps; Tween = a scripted arc (drives your position -- a strict anticheat may flag it). It leaves your own movement alone when idle, and clears everything when off. Speed % tunes how far it jumps; re-plan by clicking a new spot.",
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
    s.goal, s.targetPoint, s.plan = nil, nil, nil
end

AutoObby._diag = { isDamage = isDamage, jumpVelocity = jumpVelocity, jumpHeight = jumpHeight,
                   reachable = reachable, rayCollide = rayCollide, planChain = planChain }

return AutoObby
