-- Dash Flank: detect the local player's FORWARD dash and curve it AROUND the
-- Target Select target to their side / back -- hugging as close as possible --
-- so the follow-up lands where a front block won't help.
--
-- Dash detection: a dash is a sudden FORWARD velocity BURST, so we trigger on a
-- forward-aligned acceleration spike (NOT a WalkSpeed multiple), then keep
-- steering for a short window. Works regardless of the game's walk/sprint speed.
--
-- Around, not through (oval, not circle): we steer the horizontal velocity along
-- a tangent that wraps around the target, with a soft pull toward a hug distance
-- that is TIGHT at the flank and looser while still in front -- that asymmetry
-- makes an oval, gives room to swing around, and avoids a rigid circle. We never
-- point at the target's center.
--
-- Rotate regardless: we ALWAYS yaw to face the target during the dash, even if
-- it can't physically reach a flank point -- so we rotate "as if" on the flank.
--
-- Adheres to Target Select (state.target only) and is uninterruptable: Rotation
-- Lock + shiftlock yield to it (via isDashing(), wired in init).

local state = require("modules.aim.state")

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")

local DashFlank = {}
local LP = Players.LocalPlayer

local cfg = {
    mode        = "back", -- "back" or "side"
    minRadius   = 3,      -- studs: how tight we hug at the flank (as close as possible, no collide)
    frontExtra  = 4,      -- extra hug while still in front => OVAL (tight flank, room up front)
    hugStrength = 0.6,    -- soft pull toward the (dynamic) hug distance; tangent stays dominant
    spikeAccel  = 250,    -- studs/s^2: a forward burst this sharp = a dash (NOT walkspeed-based)
    dashFloor   = 24,     -- ...and it must actually reach at least this speed (studs/s)
    dashWindow  = 0.4,    -- keep steering up to this long after the burst (s)
    forwardDot  = 0.5,    -- velocity must align with facing this much (=> forward dash)
    steer       = 1.0,    -- 0..1: how hard to redirect the dash velocity each frame
    rotateBody  = true,   -- yaw to face the target
}

local s = { enabled = false, bound = false, conns = {}, dashing = false,
            wasActive = false, prevHs = math.huge, dashUntil = 0 }

local function rootOf(c) return c and c:FindFirstChild("HumanoidRootPart") end
local function humOf(c)  return c and c:FindFirstChildOfClass("Humanoid") end
local function myChar()  return LP.Character end
local function flat(v)   return Vector3.new(v.X, 0, v.Z) end

-- physics states where touching velocity/CFrame is unsafe (can crash the client)
local BAD_STATES = {
    [Enum.HumanoidStateType.Physics]          = true,
    [Enum.HumanoidStateType.FallingDown]      = true,
    [Enum.HumanoidStateType.Ragdoll]          = true,
    [Enum.HumanoidStateType.Seated]           = true,
    [Enum.HumanoidStateType.PlatformStanding] = true,
}

-- ADHERE to Target Select: only ever the target it picked. No nearest fallback.
local function targetRoot()
    if not state.target then return nil end
    local c = (state.target_type == "player") and state.target.Character or state.target
    return rootOf(c)
end

-- Steering direction that arcs AROUND the target and hugs close in an oval --
-- never points at their center.
local function steerDir(myRoot, tRoot)
    local ePos = flat(tRoot.Position)
    local mPos = flat(myRoot.Position)
    local toMe = mPos - ePos
    local dist = toMe.Magnitude
    if dist < 0.01 then return nil end
    local radial = toMe / dist                                   -- enemy -> me
    local eLookV = flat(tRoot.CFrame.LookVector)
    local eLook  = (eLookV.Magnitude > 0.01) and eLookV.Unit or radial

    local goalDir
    if cfg.mode == "back" then
        goalDir = eLook * -1
    else
        local eRight = Vector3.new(eLook.Z, 0, -eLook.X)
        goalDir = eRight * ((radial:Dot(eRight) >= 0) and 1 or -1)
    end

    -- tangent (perpendicular to radial) toward the goal => go around, not through
    local tangent = Vector3.new(-radial.Z, 0, radial.X)
    if tangent:Dot(goalDir) < 0 then tangent = tangent * -1 end

    -- OVAL hug: tight at the flank, looser while still in front (room to swing in)
    local amInFront = radial:Dot(eLook)                          -- +1 front, -1 back
    local hug = cfg.minRadius + math.max(0, amInFront) * cfg.frontExtra
    local radialBias = radial * ((dist > hug) and -cfg.hugStrength or cfg.hugStrength)

    -- Fade the orbit as we reach the goal bearing so we SETTLE on the back
    -- (the primary focus) instead of orbiting straight past it to the far side.
    -- aligned = 1 directly on the bearing -> no tangent (hug there); behind/front
    -- -> full tangent to keep wrapping around toward the back.
    local aligned = radial:Dot(goalDir)
    local tangentScale = math.clamp(1 - aligned, 0, 1)
    local dir = tangent * tangentScale + radialBias
    return (dir.Magnitude > 0.01) and dir.Unit or nil
end

local function stopDash()
    s.dashing = false
    if s.wasActive then
        local hum = humOf(myChar())
        if hum then hum.AutoRotate = true end
        s.wasActive = false
    end
end

local function step(dt)
    if not s.enabled then s.prevHs = math.huge; return stopDash() end
    local char = myChar(); local root = rootOf(char); local hum = humOf(char)
    if not (root and hum) or hum.Health <= 0 then s.prevHs = math.huge; return stopDash() end

    -- safety: never steer while ragdolled / knocked / platform-standing or while
    -- welded to another character (grab) -- writing velocity/CFrame to a complex
    -- or two-character assembly can destabilise physics and crash the client.
    if hum.PlatformStand or BAD_STATES[hum:GetState()] then s.prevHs = math.huge; return stopDash() end
    if state.isWeldedToOther(char) then s.prevHs = math.huge; return stopDash() end

    local vel  = root.AssemblyLinearVelocity
    local hv   = flat(vel)
    local hs   = hv.Magnitude
    local look = flat(root.CFrame.LookVector)
    local fdot = (hs > 0.01 and look.Magnitude > 0.01) and hv.Unit:Dot(look.Unit) or 0
    local accel = (hs - s.prevHs) / math.max(dt or (1 / 60), 1 / 240)
    s.prevHs = hs
    local now = os.clock()

    -- forward-burst dash detection (no WalkSpeed): rising-edge spike, then hold
    if not s.dashing then
        if accel >= cfg.spikeAccel and hs >= cfg.dashFloor and fdot >= cfg.forwardDot then
            s.dashing   = true
            s.dashUntil = now + cfg.dashWindow
        else
            return stopDash()
        end
    elseif now > s.dashUntil or hs < cfg.dashFloor or fdot < cfg.forwardDot then
        return stopDash()
    end

    local tRoot = targetRoot()
    if not tRoot then return stopDash() end

    -- ALWAYS face the target while dashing -- even if we can't reach the flank,
    -- we rotate as if we were on it, so the strike still aims at them.
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

    -- steer the dash around to the flank (best-effort; facing already handled)
    local dir = steerDir(root, tRoot)
    if dir then
        local blended = hv:Lerp(dir * hs, cfg.steer)
        -- NaN / absurd-magnitude guard before writing to the physics solver
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

-- True while actively steering a forward dash; Rotation Lock + shiftlock yield to this.
function DashFlank.isDashing() return s.dashing end

function DashFlank.init()
    if s.bound then return end
    -- Heartbeat: lands LAST in the frame so our velocity/facing override earlier rotators.
    s.conns[#s.conns + 1] = RunService.Heartbeat:Connect(function(dt) step(dt) end)
    s.bound = true
end

function DashFlank.destroy()
    for _, c in ipairs(s.conns) do pcall(function() c:Disconnect() end) end
    s.conns = {}
    s.bound = false
    stopDash()
end

return DashFlank
