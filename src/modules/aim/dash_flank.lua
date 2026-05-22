-- Dash Flank: detect the local player's FORWARD dash and curve it AROUND the
-- Target Select target to their side / back -- hugging close -- so the follow-up
-- lands where a front block won't help.
--
-- DETECTION is self-learning (no manual setup, no remote logging): a velocity
-- burst bootstraps it, and the first few dashes auto-grab the game's OWN dash
-- signal -- a "dash"-named/valued character Attribute and/or the dash Animation
-- that co-occurs -- then it reads those directly (precise + instant). Falls back
-- to the velocity heuristic on games that expose neither.
--
-- Around, not through (oval): steers velocity along a tangent that wraps the
-- target, hugging tight at the flank and looser in front, settling on the back.
-- Always yaw-faces the target during the dash (even if it can't reach the
-- flank). Adheres to Target Select (state.target only). Uninterruptable:
-- Rotation Lock + shiftlock yield to isDashing().

local state = require("modules.aim.state")

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")

local DashFlank = {}
local LP = Players.LocalPlayer

local cfg = {
    mode        = "back",
    minRadius   = 3,
    frontExtra  = 4,
    hugStrength = 0.6,
    spikeAccel  = 250,   -- studs/s^2 forward burst => bootstrap dash (also used to auto-learn)
    dashFloor   = 24,    -- min speed to count (studs/s)
    maxDashSpeed = 140,  -- ABOVE this it's a FLING, not a dash -- never redirect it
    dashWindow  = 0.4,   -- how long a detected dash stays "active" (s)
    forwardDot  = 0.5,   -- velocity must align with facing this much
    steer       = 1.0,
    rotateBody  = true,
}

local s = { enabled = false, bound = false, conns = {}, dashing = false, wasActive = false }

-- self-learned dash signal (persists across respawns within a session)
local det = {
    attr = nil,            -- auto-found character attribute that flags a dash
    learnedAnim = nil,     -- auto-found dash animation id
    animCounts = {},       -- anim id -> times it co-occurred with a velocity dash
    lastAnim = nil, lastAnimT = 0,
    animDashUntil = 0,     -- end of the dash-anim window (= its real Length)
    animStopConn = nil,    -- ends the anim window exactly when the dash anim Stops
    velDashing = false,    -- currently in a velocity-detected dash
    velPeak = 0,           -- peak speed of the current velocity dash (for decay-end)
    velDashUntil = 0,      -- hard safety cap for a velocity dash
    prevHs = math.huge,
    animConn = nil,
    attrConn = nil,        -- watches AttributeChanged to grab the dash flag instantly
}

local BAD_STATES = {
    [Enum.HumanoidStateType.Physics]          = true,
    [Enum.HumanoidStateType.FallingDown]      = true,
    [Enum.HumanoidStateType.Ragdoll]          = true,
    [Enum.HumanoidStateType.Seated]           = true,
    [Enum.HumanoidStateType.PlatformStanding] = true,
}

local function rootOf(c) return c and c:FindFirstChild("HumanoidRootPart") end
local function humOf(c)  return c and c:FindFirstChildOfClass("Humanoid") end
local function myChar()  return LP.Character end
local function flat(v)   return Vector3.new(v.X, 0, v.Z) end

-- ADHERE to Target Select: only ever the target it picked.
local function targetRoot()
    if not state.target then return nil end
    local c = (state.target_type == "player") and state.target.Character or state.target
    return rootOf(c)
end

-- Re-scan attributes / re-bind the animation listener for a (re)spawned char.
-- Keeps anything already learned -- this just refreshes per-character hooks.
local function hookChar(char)
    if det.animConn then det.animConn:Disconnect(); det.animConn = nil end
    det.prevHs = math.huge
    local hum = humOf(char)
    if hum then
        det.animConn = hum.AnimationPlayed:Connect(function(t)
            local a = t.Animation
            if not (a and a.AnimationId ~= "") then return end
            det.lastAnim, det.lastAnimT = a.AnimationId, os.clock()
            if det.learnedAnim and a.AnimationId == det.learnedAnim then
                -- end with the animation itself, not a fixed timer
                local len = t.Length
                det.animDashUntil = os.clock() + ((len and len > 0.05) and len or cfg.dashWindow)
                if det.animStopConn then det.animStopConn:Disconnect() end
                det.animStopConn = t.Stopped:Connect(function()
                    det.animDashUntil = 0   -- dash anim ended -> dash is over now
                end)
            end
        end)
    end
end

-- Steering direction that arcs AROUND the target and hugs close in an oval.
local function steerDir(myRoot, tRoot)
    local ePos = flat(tRoot.Position)
    local mPos = flat(myRoot.Position)
    local toMe = mPos - ePos
    local dist = toMe.Magnitude
    if dist < 0.01 then return nil end
    local radial = toMe / dist
    local eLookV = flat(tRoot.CFrame.LookVector)
    local eLook  = (eLookV.Magnitude > 0.01) and eLookV.Unit or radial

    local goalDir
    if cfg.mode == "back" then
        goalDir = eLook * -1
    else
        local eRight = Vector3.new(eLook.Z, 0, -eLook.X)
        goalDir = eRight * ((radial:Dot(eRight) >= 0) and 1 or -1)
    end

    local tangent = Vector3.new(-radial.Z, 0, radial.X)
    if tangent:Dot(goalDir) < 0 then tangent = tangent * -1 end

    local amInFront = radial:Dot(eLook)
    local hug = cfg.minRadius + math.max(0, amInFront) * cfg.frontExtra
    local radialBias = radial * ((dist > hug) and -cfg.hugStrength or cfg.hugStrength)

    local aligned = radial:Dot(goalDir)
    local tangentScale = math.clamp(1 - aligned, 0, 1)   -- fade orbit -> settle on the back
    local dir = tangent * tangentScale + radialBias
    return (dir.Magnitude > 0.01) and dir.Unit or nil
end

local function stopDash()
    s.dashing = false
    det.velDashing = false
    if s.wasActive then
        local hum = humOf(myChar())
        if hum then hum.AutoRotate = true end
        s.wasActive = false
    end
end

-- True if the game currently flags us as dashing, via the best signal we have.
-- Also auto-learns the attribute/animation the first few velocity-dashes.
local function dashingNow(char, root, hs, fdot, dt)
    local now = os.clock()
    local dashing = false

    -- learned dash ANIMATION window (the game's own dash signal)
    if det.learnedAnim and now < det.animDashUntil then dashing = true end

    -- Once we've learned the dash animation, ignore velocity entirely -- a fling
    -- never plays the dash anim, so it can't be mistaken for a dash.
    if det.learnedAnim then return dashing end

    -- 3. velocity burst -- internal fallback + teacher only. Starts on a forward
    --    burst and ENDS when the burst decays (speed back below half its peak),
    --    so the dash ends with the actual movement, not a fixed timer.
    local accel = (hs - det.prevHs) / math.max(dt or (1 / 60), 1 / 240)
    det.prevHs = hs
    if not det.velDashing then
        if accel >= cfg.spikeAccel and hs >= cfg.dashFloor and fdot >= cfg.forwardDot then
            det.velDashing   = true
            det.velPeak      = hs
            det.velDashUntil = now + 1.5   -- hard safety cap only
            -- teach ourselves the dash ANIMATION from this confirmed dash
            if not det.learnedAnim and det.lastAnim and (now - det.lastAnimT) < 0.25 then
                det.animCounts[det.lastAnim] = (det.animCounts[det.lastAnim] or 0) + 1
                if det.animCounts[det.lastAnim] >= 3 then det.learnedAnim = det.lastAnim end
            end
        end
    else
        det.velPeak = math.max(det.velPeak, hs)
        if hs < det.velPeak * 0.5 or hs < cfg.dashFloor
           or fdot < cfg.forwardDot or now > det.velDashUntil then
            det.velDashing = false
        end
    end
    if det.velDashing then dashing = true end

    return dashing
end

local function step(dt)
    if not s.enabled then det.prevHs = math.huge; return stopDash() end
    local char = myChar(); local root = rootOf(char); local hum = humOf(char)
    if not (root and hum) or hum.Health <= 0 then det.prevHs = math.huge; return stopDash() end
    if hum.PlatformStand or BAD_STATES[hum:GetState()] then det.prevHs = math.huge; return stopDash() end
    if state.isWeldedToOther(char) then det.prevHs = math.huge; return stopDash() end

    local vel  = root.AssemblyLinearVelocity
    local hv   = flat(vel)
    local hs   = hv.Magnitude
    local look = flat(root.CFrame.LookVector)
    local fdot = (hs > 0.01 and look.Magnitude > 0.01) and hv.Unit:Dot(look.Unit) or 0

    -- only flank a FORWARD dash with a target
    if not (dashingNow(char, root, hs, fdot, dt) and fdot >= cfg.forwardDot) then return stopDash() end
    local tRoot = targetRoot()
    if not tRoot then return stopDash() end
    s.dashing = true

    -- ALWAYS face the target while dashing (rotate as if on the flank even if we can't reach it)
    if cfg.rotateBody then
        hum.AutoRotate = false
        s.wasActive = true
        local fd = flat(tRoot.Position - root.Position)
        if fd.Magnitude > 0.01 then
            local cf = CFrame.lookAt(root.Position, root.Position + fd)
            local _, y = cf:ToEulerAnglesYXZ()
            if y == y then  -- NaN guard
                root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, y, 0)
            end
        end
    end

    -- steer the dash around to the flank -- but NEVER redirect fling-speed
    -- velocity (that would cancel the fling); detection + facing still ran.
    local dir = (hs <= cfg.maxDashSpeed) and steerDir(root, tRoot) or nil
    if dir then
        local blended = hv:Lerp(dir * hs, cfg.steer)
        if blended.X == blended.X and blended.Z == blended.Z and blended.Magnitude < 1e4 then
            root.AssemblyLinearVelocity = Vector3.new(blended.X, vel.Y, blended.Z)
        end
    end
end

function DashFlank.setEnabled(v)   s.enabled = v and true or false; if not v then stopDash() end end
function DashFlank.setMode(m)       cfg.mode = (m == "side") and "side" or "back" end
function DashFlank.setMinRadius(v)  cfg.minRadius = tonumber(v) or cfg.minRadius end
function DashFlank.setSpike(v)      cfg.spikeAccel = tonumber(v) or cfg.spikeAccel end
function DashFlank.setSteer(v)      cfg.steer = math.clamp(tonumber(v) or cfg.steer, 0, 1) end
function DashFlank.setRotate(v)     cfg.rotateBody = v and true or false end

function DashFlank.isDashing() return s.dashing end

function DashFlank.init()
    if s.bound then return end
    if LP.Character then hookChar(LP.Character) end
    s.conns[#s.conns + 1] = LP.CharacterAdded:Connect(hookChar)
    s.conns[#s.conns + 1] = RunService.Heartbeat:Connect(function(dt) step(dt) end)
    s.bound = true
end

function DashFlank.destroy()
    for _, c in ipairs(s.conns) do pcall(function() c:Disconnect() end) end
    if det.animConn     then pcall(function() det.animConn:Disconnect() end);     det.animConn = nil end
    if det.attrConn     then pcall(function() det.attrConn:Disconnect() end);     det.attrConn = nil end
    if det.animStopConn then pcall(function() det.animStopConn:Disconnect() end); det.animStopConn = nil end
    s.conns = {}
    s.bound = false
    stopDash()
end

return DashFlank
