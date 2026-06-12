-- Auto Obby: auto-completes an obstacle course toward a goal you place.
--
-- Engage with the feature keybind (or the toggle), then a PREVIEW reticle tracks
-- whatever your cursor points at -- click to drop a GOAL marker there. The bot
-- then heads to the goal on its own: it WALKS on continuous ground and only JUMPS
-- when it actually has to (a real gap, or a ledge taller than a normal step), and
-- it only ever attempts jumps the local character could physically make.
--
-- Caveats handled (this is meant to be robust):
--   * Non-collidable parts (invisible zone/trigger walls, decoration) are ignored
--     for BOTH footing and obstruction -- RaycastParams.RespectCanCollide + a
--     CanCollide re-check. They never count as ground or as a wall.
--   * Never noclips: walking is real physics; a jump is rejected if a collidable
--     wall sits in its straight-line path; the tween arc re-snaps onto real ground
--     on landing so it can't end up inside/through the floor.
--   * Only jumps when necessary (gap / tall ledge), never spam-jumps on flat ground.
--   * Rotates the BODY to face travel (rotation_lock's AlignOrientation) WITHOUT
--     moving the camera; AutoRotate is handed back when idle / off.
--   * Detects + avoids damage / kill blocks (name, lava material, strong-red).
--   * Steers around a wall when the straight line is blocked.
--   * Clears the goal + both markers + body constraint when you turn it off or die.
--
-- Modes: Legit = real Humanoid jump + air control over the gap. Tween = drives the
-- root along a gravity-accurate projectile arc (looks legit). Both are gated by the
-- same physics reachability, so Tween never travels farther/higher than a real jump.
-- Tween drives the root each frame -- a strict client AC can flag it; use Legit there.

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

local s = {
    active      = false,
    mode        = "Legit",
    avoidDamage = true,
    reachPct    = 0.85,   -- fraction of physics-max reach we trust (safety margin)
    hopDelay    = 0.12,   -- pause after a jump before the next decision
    goal        = nil,    -- Vector3 goal (set by clicking)
    airTarget   = nil,    -- Vector3 we're air-controlling toward during a legit jump
    busy        = false,  -- mid tween arc
    lastJump    = 0,
    ctrlLoop    = nil,
    markConn    = nil,
    clickConn   = nil,
    mouse       = nil,
}

local STEP_HEIGHT = 2.5   -- ledges up to this we walk up (Roblox auto-steps); above -> jump
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

-- one reusable params: ignore non-collidable parts (zone walls etc.) + water +
-- our own character. RespectCanCollide is pcall'd in case an old client lacks it;
-- callers also re-check CanCollide defensively.
local rp = RaycastParams.new()
rp.FilterType = Enum.RaycastFilterType.Exclude
rp.IgnoreWater = true
pcall(function() rp.RespectCanCollide = true end)
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

-- ground (collidable) directly under pos
local function groundUnder(pos, depth)
    return Workspace:Raycast(pos + Vector3.new(0, 2.5, 0), Vector3.new(0, -(depth or 80), 0), params())
end
-- a hit counts as standable ground: collidable top surface that isn't a damage block
local function standable(rc)
    return rc and rc.Instance and rc.Instance.CanCollide ~= false
        and rc.Normal.Y > 0.6 and not isDamage(rc.Instance)
end

-- ---- body rotation (rotation_lock style: camera stays free) -------------------
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

-- ---- find a jump landing ------------------------------------------------------
-- Fans downward (collidable) rays ahead toward `heading`, keeping reachable, safe,
-- standable surfaces; scores by progress toward the goal (or raw forward distance).
-- Returns { hrpPos, inst, groundY } or nil.
local ANGLES = { 0, 15, -15, 30, -30, 45, -45 }
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
                        local score = goalDist and (goalDist - (goalFlat - flat(land)).Magnitude)
                                       or (flat(land) - fromFlat):Dot(heading)
                        if score > 0.5 and (not bestScore or score > bestScore) then
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

-- straight-line collidable obstruction between the root and a landing (so we never
-- jump THROUGH a wall). Excludes our character and the destination platform; stops
-- short of the landing so the platform itself doesn't read as a blocker.
local function pathClear(fromHrp, toHrp, destInst)
    local dir = toHrp - fromHrp
    local dist = dir.Magnitude
    if dist < 0.1 then return true end
    return Workspace:Raycast(fromHrp, dir * 0.9, params(destInst)) == nil
end

-- ---- movement decision -------------------------------------------------------
local GROUNDED = {
    [Enum.HumanoidStateType.Running]          = true,
    [Enum.HumanoidStateType.RunningNoPhysics] = true,
    [Enum.HumanoidStateType.Landed]           = true,
    [Enum.HumanoidStateType.GettingUp]        = true,
}

-- ground continuous + walkable-height for the next EDGE_LOOK studs, so we keep
-- walking right up to a gap edge, then jump (not several studs early).
local function walkClear(hrp, footY, dir)
    for i = 1, 2 do
        local p = hrp.Position + dir * (EDGE_LOOK * i / 2)
        local b = Workspace:Raycast(Vector3.new(p.X, footY + STEP_HEIGHT + 0.5, p.Z),
                                    Vector3.new(0, -(2 * STEP_HEIGHT + 0.5), 0), params())
        if not standable(b) then return false end   -- a gap / cliff / damage block in the path
    end
    return true
end

-- "walk" (continuous safe ground just ahead, no wall), "jump"+landing, "wall", or "stuck"
local function decideMove(hrp, hum, footY, heading)
    -- collidable wall at body height in the immediate path? (passes over small steps)
    local wall = Workspace:Raycast(hrp.Position, heading * LOOKAHEAD, params())
    if not wall and walkClear(hrp, footY, heading) then
        return "walk"
    end
    local land = findLanding(hrp.Position, footY, hrp.Position.Y - footY, heading, hum, s.goal)
    if land and pathClear(hrp.Position, land.hrpPos, land.inst) then
        return "jump", land
    end
    if wall or land then return "wall" end   -- blocked straight ahead -> try to steer
    return "stuck"
end

-- pick a sideways heading that's walkable, to round a wall / dead-end
local function steerAround(hrp, footY, heading)
    for _, deg in ipairs({ 25, -25, 50, -50, 80, -80 }) do
        local d = rotateY(heading, math.rad(deg)).Unit
        local wall = Workspace:Raycast(hrp.Position, d * (LOOKAHEAD + 1), params())
        local probe = hrp.Position + d * LOOKAHEAD
        local band  = Workspace:Raycast(Vector3.new(probe.X, footY + STEP_HEIGHT + 0.5, probe.Z),
                                        Vector3.new(0, -(2 * STEP_HEIGHT + 0.5), 0), params())
        if standable(band) and not wall then return d end
    end
    return Vector3.zero
end

-- ---- jump execution ----------------------------------------------------------
-- Tween: drive the root along the SAME projectile a real jump would trace, then
-- re-snap onto the real landing surface so it can never end up inside the floor.
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

    if rot.align then rot.align.Enabled = false end   -- the per-frame CFrame owns orientation now
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
    -- land on the TRUE ground at the target column (re-raycast) so we never phase in
    if hrp and hrp.Parent then
        local snap = groundUnder(Vector3.new(target.X, target.Y + 2, target.Z), 12)
        local fy = (snap and standable(snap)) and (snap.Position.Y + standOffset) or target.Y
        local p = Vector3.new(target.X, fy, target.Z)
        hrp.CFrame = CFrame.lookAt(p, p + dir)
        hrp.AssemblyLinearVelocity = Vector3.zero
    end
    pcall(function() hum:ChangeState(Enum.HumanoidStateType.Landed) end)
    s.busy = false
    s.lastJump = os.clock()
end

-- ---- control loop ------------------------------------------------------------
-- returns true if it triggered a jump this tick (so the loop pauses briefly)
local function controlTick()
    local _, hrp, hum = rig()
    if not (hrp and hum) or hum.Health <= 0 then releaseRot(hum); s.airTarget = nil; return false end

    if not s.goal then                      -- idle: don't move, hand the body back
        hum:Move(Vector3.zero, false); releaseRot(hum); return false
    end
    if flat(s.goal - hrp.Position).Magnitude <= GOAL_RADIUS then
        s.goal = nil; s.airTarget = nil
        hum:Move(Vector3.zero, false); releaseRot(hum)
        notify.success("Auto Obby: reached the goal")
        return false
    end

    local goalDir = flat(s.goal - hrp.Position)
    if goalDir.Magnitude < 1e-3 then return false end
    goalDir = goalDir.Unit

    if not GROUNDED[hum:GetState()] then    -- airborne (legit jump): air-control toward the target
        local aim = s.airTarget or s.goal
        local d = flat(aim - hrp.Position)
        if d.Magnitude > 0.5 then hum:Move(d.Unit, false); faceDir(hrp, hum, d) end
        return false
    end
    s.airTarget = nil
    if s.busy then return false end

    local gr = groundUnder(hrp.Position, 14)
    if not gr then return false end          -- briefly off ground; wait
    local footY = gr.Position.Y
    local standOffset = hrp.Position.Y - footY
    faceDir(hrp, hum, goalDir)

    local action, land = decideMove(hrp, hum, footY, goalDir)
    if action == "walk" then
        hum:Move(goalDir, false)
        return false
    elseif action == "jump" then
        if os.clock() - s.lastJump < JUMP_CD then return false end
        if s.mode == "Tween" then
            tweenJump(hum, hrp, land, standOffset)
        else
            s.airTarget = land.hrpPos
            hum:Move(goalDir, false)
            hum.Jump = true
            s.lastJump = os.clock()
        end
        return true
    elseif action == "wall" then
        local d = steerAround(hrp, footY, goalDir)
        hum:Move(d, false)
        if d.Magnitude > 0 then faceDir(hrp, hum, d) end
        return false
    else
        hum:Move(Vector3.zero, false)
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
            task.wait(jumped and s.hopDelay or 0.05)
        end
        s.ctrlLoop = nil
    end)
end

-- ---- markers (2D, projected; nothing in workspace) ---------------------------
local mk = { gui = nil, preview = nil, placed = nil, label = nil }
local function ensureMarkers()
    if mk.gui and mk.gui.Parent then return end
    local sg = Instance.new("ScreenGui")
    sg.Name = "_" .. tostring(math.random(100000, 999999))   -- randomized (anti-scan, Pantheon convention)
    sg.ResetOnSpawn = false
    sg.IgnoreGuiInset = false                                 -- matches WorldToViewportPoint space
    sg.DisplayOrder = 50
    sg.Parent = env.guiParent()
    env.protectGui(sg)

    -- preview reticle: hollow cyan ring + center dot (where a click WOULD set the goal)
    local pv = Instance.new("Frame")
    pv.Size = UDim2.fromOffset(26, 26)
    pv.AnchorPoint = Vector2.new(0.5, 0.5)
    pv.BackgroundTransparency = 1
    pv.Visible = false
    pv.Parent = sg
    local pvc = Instance.new("UICorner", pv); pvc.CornerRadius = UDim.new(1, 0)
    local pvs = Instance.new("UIStroke", pv); pvs.Color = Color3.fromRGB(120, 220, 255); pvs.Thickness = 2; pvs.Transparency = 0.1
    local dot = Instance.new("Frame", pv)
    dot.Size = UDim2.fromOffset(4, 4); dot.AnchorPoint = Vector2.new(0.5, 0.5); dot.Position = UDim2.fromScale(0.5, 0.5)
    dot.BackgroundColor3 = Color3.fromRGB(120, 220, 255); dot.BorderSizePixel = 0
    Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)

    -- placed goal: solid green diamond + distance label (distinct from the preview)
    local pl = Instance.new("Frame")
    pl.Size = UDim2.fromOffset(18, 18)
    pl.AnchorPoint = Vector2.new(0.5, 0.5)
    pl.Rotation = 45
    pl.BackgroundColor3 = Color3.fromRGB(87, 242, 135)
    pl.BorderSizePixel = 0
    pl.Visible = false
    pl.Parent = sg
    local pls = Instance.new("UIStroke", pl); pls.Color = Color3.fromRGB(255, 255, 255); pls.Thickness = 1.5
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.fromOffset(120, 16)
    lbl.AnchorPoint = Vector2.new(0.5, 1)
    lbl.Position = UDim2.fromOffset(0, -16)
    lbl.BackgroundTransparency = 1
    lbl.Font = Enum.Font.GothamBold
    lbl.TextSize = 12
    lbl.TextColor3 = Color3.fromRGB(87, 242, 135)
    lbl.TextStrokeTransparency = 0.4
    lbl.Text = "GOAL"
    lbl.Rotation = -45                         -- counter the diamond's parent rotation
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
    -- preview at the cursor's world hit
    local cw = cursorWorld()
    if cw then
        local vp = cam:WorldToViewportPoint(cw)
        if vp.Z > 0 then mk.preview.Visible = true; mk.preview.Position = UDim2.fromOffset(vp.X, vp.Y)
        else mk.preview.Visible = false end
    else
        mk.preview.Visible = false
    end
    -- placed goal marker + live distance
    if s.goal then
        local vp = cam:WorldToViewportPoint(s.goal)
        if vp.Z > 0 then
            mk.placed.Visible = true
            mk.placed.Position = UDim2.fromOffset(vp.X, vp.Y)
            local _, hrp = rig()
            if hrp then mk.label.Text = ("GOAL  %d"):format(math.floor(flat(s.goal - hrp.Position).Magnitude)) end
        else
            mk.placed.Visible = false
        end
    else
        mk.placed.Visible = false
    end
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
    if gpe then return end   -- consumed by the Pantheon UI / any GUI
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
    local cw = cursorWorld()
    if cw then
        s.goal = cw
        notify.info("Auto Obby: goal set")
    end
end

-- ---- lifecycle ---------------------------------------------------------------
local function setActive(v)
    v = v and true or false
    if s.active == v then return end
    s.active = v
    if v then
        s.mouse = s.mouse or LP:GetMouse()
        pcall(function() s.mouse.TargetFilter = LP.Character end)
        ensureMarkers()
        if not s.clickConn then s.clickConn = UserInputService.InputBegan:Connect(onInput) end
        if not s.markConn then s.markConn = RunService.RenderStepped:Connect(updateMarkers) end
        startControl()
        notify.success("Auto Obby ON -- click a spot to set a goal")
    else
        -- clear the goal + both markers + body constraint (full reset)
        s.goal, s.airTarget = nil, nil
        if s.clickConn then s.clickConn:Disconnect(); s.clickConn = nil end
        if s.markConn  then s.markConn:Disconnect();  s.markConn  = nil end
        hideMarkers()
        local _, hrp, hum = rig()
        releaseRot(hum)
        if hum then pcall(function() hum:Move(Vector3.zero, false) end) end
    end
end

function AutoObby.register(box)
    box:add(feature.declare({
        id          = "misc.autoobby",
        name        = "Auto Obby",
        description = "Auto-completes obstacle courses. Engage with the keybind, then a preview reticle follows your cursor -- click a spot to drop a GOAL marker and it heads there on its own. It WALKS on continuous ground and only JUMPS at real gaps / tall ledges, only attempting jumps your character can actually make, rotating the body to face travel (no camera movement). Ignores non-collidable parts (invisible zone walls), won't noclip through walls, and avoids damage / kill blocks it detects. Legit mode = real jump + air control; Tween mode = a gravity-accurate jump arc (looks legit, but drives your position -- a strict client anticheat may flag it). Turning it off clears the goal + markers.",
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
    if s.clickConn then pcall(function() s.clickConn:Disconnect() end); s.clickConn = nil end
    if s.markConn  then pcall(function() s.markConn:Disconnect()  end); s.markConn  = nil end
    local _, _, hum = rig()
    releaseRot(hum)
    destroyRot()
    destroyMarkers()
    s.goal, s.airTarget = nil, nil
end

-- pure helpers for the offline mock test (tools/mocktest_autoobby.py); no side effects
AutoObby._diag = { reachable = reachable, isDamage = isDamage, jumpVelocity = jumpVelocity,
                   findLanding = findLanding, decideMove = decideMove, pathClear = pathClear }

return AutoObby
