-- Auto Obby: auto-completes an obstacle course. Press the feature's keybind to
-- engage (the master toggle), then click anywhere in the world to set a goal --
-- or just look where you want to go and it heads that way. While engaged it hops
-- platform-to-platform on its own, ONLY making jumps the local character could
-- physically make (so it stays legit-looking and won't attempt the impossible),
-- and it skips blocks it judges to be damage / kill blocks.
--
-- Two movement modes:
--   * Legit -- real Humanoid jump + air control toward the landing spot. The
--     server sees ordinary movement; the body rotates to face the jump (we use
--     the humanoid's own AutoRotate facing).
--   * Tween -- plays a gravity-accurate jump ARC: we drive the root along a
--     projectile trajectory (horizontal at a constant <= WalkSpeed, vertical
--     under workspace.Gravity from the character's real jump velocity), so the
--     rise/fall accelerates exactly like a real jump. Looks like you made the
--     jump legit. NOTE: this drives the root each frame -- a strict client AC
--     can flag it; prefer Legit on AC-heavy games.
--
-- The reachability check (jump physics) gates BOTH modes, so even Tween only
-- ever travels a distance/height the player could really jump.

local feature = require("ui.feature")
local notify  = require("ui.notify")
local log     = require("core.log")

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace        = workspace

local AutoObby = {}

local LP = Players.LocalPlayer

-- live, tunable state (settings push into this via the cog onChange)
local s = {
    active      = false,
    mode        = "Legit",  -- "Legit" | "Tween"
    avoidDamage = true,
    reachPct    = 0.85,     -- fraction of the physics-max reach we trust (safety margin)
    hopDelay    = 0.15,     -- pause between hops (seconds)
    goal        = nil,      -- Vector3 world goal set by clicking (optional)
    loop        = nil,      -- hop-loop thread
    clickConn   = nil,
    mouse       = nil,
}

-- ----- damage-block heuristics -------------------------------------------------
-- Name substrings (checked on the part + 2 ancestors), lava-ish materials, and a
-- strong-red colour -- the usual tells for kill bricks. Tunable via "Avoid
-- damage blocks"; conservative thresholds keep normal platforms from tripping it.
local DAMAGE_NAMES = {
    "kill", "lava", "damage", "spike", "death", "hazard", "trap",
    "acid", "poison", "laser", "saw", "void", "danger", "hurt", "deadly",
}
local DAMAGE_MATERIALS = {
    [Enum.Material.CrackedLava] = true,
}

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

-- ----- character / physics helpers --------------------------------------------
local function rig()
    local c = LP.Character
    if not c then return nil end
    return c, c:FindFirstChild("HumanoidRootPart"), c:FindFirstChildOfClass("Humanoid")
end

-- Initial vertical jump velocity (studs/s), matching the character's real jump.
local function jumpVelocity(hum)
    local g = Workspace.Gravity
    if hum.UseJumpPower then return hum.JumpPower end
    return math.sqrt(2 * g * math.max(hum.JumpHeight, 0))
end

-- Can a jump clear a horizontal gap `dx` to a point `dy` studs above (dy<0=below)?
-- Models the body moving horizontally at WalkSpeed for the whole airtime; the
-- jump can reach the point if it can get that high AND still be over it on the
-- way down within the horizontal reach. `reachPct` is the safety margin.
local function reachable(hum, dx, dy)
    local g = Workspace.Gravity
    local v = jumpVelocity(hum)
    local peak = (v * v) / (2 * g)
    if dy > peak then return false end            -- can't jump that high
    local disc = v * v - 2 * g * dy
    if disc < 0 then return false end
    local tLand = (v + math.sqrt(disc)) / g       -- time to fall back to height dy
    local reach = hum.WalkSpeed * tLand
    return dx <= reach * s.reachPct
end

-- one reusable downward-ray params (excludes our own character)
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
local rayIgnore = {}
local function params()
    rayIgnore[1] = LP.Character
    rayParams.FilterDescendantsInstances = rayIgnore
    return rayParams
end

-- Find the ground directly under `pos` (start a little above so we don't begin
-- inside the floor). Returns the RaycastResult or nil.
local function groundUnder(pos, depth)
    return Workspace:Raycast(pos + Vector3.new(0, 2.5, 0), Vector3.new(0, -(depth or 80), 0), params())
end

-- rotate a horizontal (y=0) vector around the Y axis
local function rotateY(v, rad)
    local c, sn = math.cos(rad), math.sin(rad)
    return Vector3.new(v.X * c - v.Z * sn, 0, v.X * sn + v.Z * c)
end

local function flat(v) return Vector3.new(v.X, 0, v.Z) end

-- Search a fan ahead of `fromPos` (in `heading`) for the best next safe, reachable
-- landing surface. Returns { hrpPos = Vector3, inst = BasePart } or nil.
-- Scores by progress toward the goal if one is set, else raw forward distance, so
-- it favours the farthest reachable platform and crosses gaps in big hops.
local ANGLES = { 0, 15, -15, 30, -30, 45, -45 }
local function findLanding(fromPos, startGroundY, standOffset, heading, hum, goal)
    local g = Workspace.Gravity
    local v = jumpVelocity(hum)
    local peak    = (v * v) / (2 * g)
    local maxReach = hum.WalkSpeed * (2 * v / g)   -- horizontal reach at equal height
    local fromFlat = flat(fromPos)
    local goalFlat = goal and flat(goal) or nil
    local goalDist = goalFlat and (goalFlat - fromFlat).Magnitude or nil

    local best, bestScore
    for _, deg in ipairs(ANGLES) do
        local dir = rotateY(heading, math.rad(deg)).Unit
        for i = 1, 7 do
            local dist = math.max(4, (i / 7) * maxReach)
            local col  = fromPos + dir * dist
            -- cast down through the whole band a jump could reach (peak above to
            -- a good drop below) so we catch higher AND lower platforms.
            local top = col + Vector3.new(0, peak + 6, 0)
            local rc  = Workspace:Raycast(top, Vector3.new(0, -(peak + 6 + 60), 0), params())
            if rc and rc.Instance and rc.Normal.Y > 0.6 then   -- top surface, not a wall
                local land  = rc.Position
                local dx    = (flat(land) - fromFlat).Magnitude
                local dyP   = land.Y - startGroundY            -- platform-to-platform rise
                if dx >= 4 and reachable(hum, dx, dyP) and not isDamage(rc.Instance) then
                    local progress = (flat(land) - fromFlat).Unit:Dot(heading)
                    if progress > 0 then
                        local score
                        if goalDist then
                            score = goalDist - (goalFlat - flat(land)).Magnitude  -- distance cut toward goal
                        else
                            score = (flat(land) - fromFlat):Dot(heading)          -- farthest forward
                        end
                        if score > 0.5 and (not bestScore or score > bestScore) then
                            best, bestScore = { hrpPos = land + Vector3.new(0, standOffset, 0), inst = rc.Instance }, score
                        end
                    end
                end
            end
        end
    end
    return best
end

-- ----- jump execution ----------------------------------------------------------
local GROUNDED = {
    [Enum.HumanoidStateType.Running]          = true,
    [Enum.HumanoidStateType.RunningNoPhysics] = true,
    [Enum.HumanoidStateType.Landed]           = true,
    [Enum.HumanoidStateType.GettingUp]        = true,
}

-- Legit: face + run toward the spot, real jump, keep air-controlling toward it
-- until we land (or time out). Only ever called for a reachable spot.
local function legitJump(hum, hrp, targetHrp)
    local dir = flat(targetHrp - hrp.Position)
    if dir.Magnitude < 0.01 then return end
    dir = dir.Unit
    hum.AutoRotate = true
    hum:Move(dir, false)
    RunService.Heartbeat:Wait()
    hum.Jump = true
    local t0 = os.clock()
    while os.clock() - t0 < 2.5 and s.active do
        local _, h2, hum2 = rig()
        if not (h2 and hum2) then break end
        hum2:Move(flat(targetHrp - h2.Position).Unit, false)
        if os.clock() - t0 > 0.25 and GROUNDED[hum2:GetState()] then break end
        RunService.Heartbeat:Wait()
    end
    local _, h3, hum3 = rig()
    if hum3 then hum3:Move(Vector3.zero, false) end
end

-- Tween: drive the root along the SAME projectile a real jump would follow.
-- Horizontal at a constant speed (<= WalkSpeed because the spot is reachable),
-- vertical = v*t - 0.5*g*t^2 -> the rise eases off and the fall accelerates,
-- exactly like gravity. We set CFrame + AssemblyLinearVelocity each frame so the
-- replicated motion stays self-consistent, then hand control back on landing.
local function tweenJump(hum, hrp, targetHrp)
    local g = Workspace.Gravity
    local v = jumpVelocity(hum)
    local start = hrp.Position
    local dy = targetHrp.Y - start.Y
    local horiz = flat(targetHrp - start)
    local dx = horiz.Magnitude
    local dir = (dx > 0.01) and (horiz / dx) or flat(hrp.CFrame.LookVector).Unit

    local disc = v * v - 2 * g * dy
    if disc < 0 then return end                 -- guarded by reachable(), defensive
    local T = (v + math.sqrt(disc)) / g
    if T <= 0 then return end
    local horizSpeed = dx / T

    hum.AutoRotate = false
    pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
    local t = 0
    while t < T and s.active do
        if not (hrp and hrp.Parent) then return end
        local dt = RunService.Heartbeat:Wait()
        t = math.min(t + dt, T)
        local y   = v * t - 0.5 * g * t * t
        local pos = start + dir * (horizSpeed * t) + Vector3.new(0, y, 0)
        hrp.CFrame = CFrame.lookAt(pos, pos + dir)
        hrp.AssemblyLinearVelocity = dir * horizSpeed + Vector3.new(0, v - g * t, 0)
    end
    -- settle exactly on the platform and hand control back
    if hrp and hrp.Parent then
        hrp.CFrame = CFrame.lookAt(targetHrp, targetHrp + dir)
        hrp.AssemblyLinearVelocity = Vector3.zero
    end
    hum.AutoRotate = true
    pcall(function() hum:ChangeState(Enum.HumanoidStateType.Landed) end)
end

-- ----- hop loop ----------------------------------------------------------------
-- One hop: validate we're grounded, work out the heading (clicked goal or camera
-- forward), find the best next landing, and jump to it.
local function hopOnce()
    local _, hrp, hum = rig()
    if not (hrp and hum) then return "nochar" end
    if hum.Health <= 0 then return "dead" end
    if not GROUNDED[hum:GetState()] then return "air" end

    local gr = groundUnder(hrp.Position, 14)
    if not gr then return "noground" end
    local standOffset = hrp.Position.Y - gr.Position.Y

    -- reached the clicked goal?
    if s.goal and flat(s.goal - hrp.Position).Magnitude < 6 then
        s.goal = nil
        notify.info("Auto Obby: reached goal")
        return "reached"
    end

    local heading
    if s.goal then
        heading = flat(s.goal - hrp.Position)
    else
        local cam = Workspace.CurrentCamera
        heading = flat((cam and cam.CFrame.LookVector) or hrp.CFrame.LookVector)
    end
    if heading.Magnitude < 0.01 then return "noheading" end
    heading = heading.Unit

    local land = findLanding(hrp.Position, gr.Position.Y, standOffset, heading, hum, s.goal)
    if not land then return "stuck" end

    if s.mode == "Tween" then tweenJump(hum, hrp, land.hrpPos)
    else                      legitJump(hum, hrp, land.hrpPos) end
    return "hopped"
end

local function startLoop()
    if s.loop then return end
    s.loop = task.spawn(function()
        local stuckMsg = false
        while s.active do
            local ok, r = pcall(hopOnce)
            if not ok then
                log.warn("autoobby hop error: " .. tostring(r))
                task.wait(0.3)
            elseif r == "hopped" or r == "reached" then
                stuckMsg = false
                task.wait(s.hopDelay)
            elseif r == "stuck" then
                if not stuckMsg then
                    notify.warn("Auto Obby: no safe jump ahead -- look toward the path or click a goal")
                    stuckMsg = true
                end
                task.wait(0.35)
            else
                task.wait(0.2)   -- nochar / dead / air / noground: wait + retry
            end
        end
        s.loop = nil
    end)
end

-- ----- click-to-set-goal -------------------------------------------------------
local function onInput(input, gpe)
    if gpe then return end   -- a click consumed by the Pantheon UI (or any GUI)
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
    local m = s.mouse
    if m and m.Target then
        s.goal = m.Hit.Position
        notify.info("Auto Obby: goal set")
    end
end

local function setActive(v)
    v = v and true or false
    if s.active == v then return end
    s.active = v
    if v then
        s.mouse = s.mouse or LP:GetMouse()
        pcall(function() s.mouse.TargetFilter = LP.Character end)
        if not s.clickConn then
            s.clickConn = UserInputService.InputBegan:Connect(onInput)
        end
        startLoop()
        notify.success("Auto Obby ON -- click a spot to head there, or look where to go")
    else
        s.goal = nil
        if s.clickConn then s.clickConn:Disconnect(); s.clickConn = nil end
        -- hand the body back (Tween may have left AutoRotate off mid-jump)
        local _, _, hum = rig()
        if hum then pcall(function() hum.AutoRotate = true end) end
    end
end

function AutoObby.register(box)
    box:add(feature.declare({
        id          = "misc.autoobby",
        name        = "Auto Obby",
        description = "Auto-completes obstacle courses. Press the keybind to engage, then click anywhere in the world to set a goal -- or just look where you want to go and it heads there. It hops platform-to-platform on its own, ONLY making jumps your character could really make, rotating to face each jump, and skips damage / kill blocks it detects (by name, lava material, or strong-red colour). Legit mode jumps + air-controls like a real player; Tween mode drives a gravity-accurate jump arc that looks legit. Tween drives your position each frame, so a strict client anticheat may flag it -- use Legit there.",
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
            { type = "slider", name = "Hop delay (s)", key = "delay", min = 0, max = 0.6, step = 0.05, default = 0.15,
              onChange = function(v) s.hopDelay = v or 0.15 end },
        },
    }).root)
    log.info("Auto Obby feature registered")
end

-- pure helpers exposed for the offline mock test (tools/mocktest_*). No side
-- effects; not used by the runtime.
AutoObby._diag = { reachable = reachable, isDamage = isDamage, jumpVelocity = jumpVelocity, findLanding = findLanding }

function AutoObby.destroy()
    s.active = false   -- ends the hop loop after its current iteration
    if s.clickConn then pcall(function() s.clickConn:Disconnect() end); s.clickConn = nil end
    local _, _, hum = rig()
    if hum then pcall(function() hum.AutoRotate = true end) end
    s.goal = nil
end

return AutoObby
