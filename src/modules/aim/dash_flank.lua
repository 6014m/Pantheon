-- Dash Flank: detect the local player's FORWARD dash and curve it AROUND the
-- target to their side / back -- never straight through them -- so the
-- follow-up lands where a front block won't help.
--
-- "Around, not through": while dashing we steer the horizontal velocity along a
-- tangent that orbits the target at a set radius, biased toward the rear (or
-- side). The path arcs around the enemy instead of driving into their center;
-- only once we've reached the flank bearing do we home onto the exact point. We
-- preserve the dash's speed (so an impulse dash is curved, not just re-faced)
-- and yaw to face the target so the strike connects.
--
-- Priority over Rotation Lock / shiftlock: while a flank dash is in progress,
-- both yield (wired via isDashing() in init) so they can't snap the body back
-- to the enemy's front and interrupt the maneuver.

local state = require("modules.aim.state")

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")

local DashFlank = {}
local LP = Players.LocalPlayer

local cfg = {
    mode         = "back", -- "back" or "side"
    range        = 45,     -- only flank a target within this many studs
    orbitRadius  = 6,      -- studs: how far off the target we arc (close, no collide)
    radialWeight = 0.7,    -- converge-on-radius pull vs going tangential (0..1-ish)
    dashMult     = 2.2,    -- horizontal speed >= WalkSpeed*dashMult counts as a dash
    dashMin      = 36,     -- ...but never treat below this as a dash (studs/s)
    forwardDot   = 0.5,    -- velocity must align with facing this much (=> forward dash)
    steer        = 1.0,    -- 0..1: how hard to redirect the dash velocity each frame
    rotateBody   = true,   -- also turn to face the target
}

local s = { enabled = false, bound = false, conns = {}, dashing = false, wasActive = false }

local function rootOf(c) return c and c:FindFirstChild("HumanoidRootPart") end
local function humOf(c)  return c and c:FindFirstChildOfClass("Humanoid") end
local function myChar()  return LP.Character end
local function flat(v)   return Vector3.new(v.X, 0, v.Z) end

-- prefer Target Select's pick; otherwise the nearest player within range
local function targetRoot()
    if state.target then
        local c = (state.target_type == "player") and state.target.Character or state.target
        local r = rootOf(c)
        if r then return r end
    end
    local myRoot = rootOf(myChar()); if not myRoot then return nil end
    local best, bd
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP and p.Character then
            local r = rootOf(p.Character)
            if r then
                local d = (r.Position - myRoot.Position).Magnitude
                if d <= cfg.range and (not bd or d < bd) then best, bd = r, d end
            end
        end
    end
    return best
end

-- Steering direction that ARCS AROUND the target toward the flank bearing and
-- never points straight at their center (so we go around players, not through).
local function steerDir(myRoot, tRoot)
    local ePos = flat(tRoot.Position)
    local mPos = flat(myRoot.Position)
    local toMe = mPos - ePos
    local dist = toMe.Magnitude
    if dist < 0.01 then return nil end
    local radial = toMe / dist                                   -- enemy -> me
    local eLookV = flat(tRoot.CFrame.LookVector)
    local eLook  = (eLookV.Magnitude > 0.01) and eLookV.Unit or radial

    -- where (as a bearing from the enemy) we want to end up
    local goalDir
    if cfg.mode == "back" then
        goalDir = eLook * -1                                     -- behind them
    else
        local eRight = Vector3.new(eLook.Z, 0, -eLook.X)
        goalDir = eRight * ((radial:Dot(eRight) >= 0) and 1 or -1)  -- nearer side
    end

    local R = cfg.orbitRadius
    local aligned = radial:Dot(goalDir)                          -- 1 => at the flank bearing
    if aligned > 0.8 then
        -- on the flank: home onto the exact point at radius R behind/beside them
        local d = (ePos + goalDir * R) - mPos
        return (d.Magnitude > 0.01) and d.Unit or nil
    end

    -- otherwise circle around: tangent (perpendicular to radial) toward the goal,
    -- plus a CLAMPED radial pull so we converge on radius R without aiming at center
    local tangent = Vector3.new(-radial.Z, 0, radial.X)
    if tangent:Dot(goalDir) < 0 then tangent = tangent * -1 end
    local radialErr = math.clamp((R - dist) / R, -1, 1)         -- clamp so tangent dominates
    local dir = tangent + radial * (radialErr * cfg.radialWeight)
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

local function step()
    if not s.enabled then return stopDash() end
    local char = myChar(); local root = rootOf(char); local hum = humOf(char)
    if not (root and hum) or hum.Health <= 0 then return stopDash() end

    local vel  = root.AssemblyLinearVelocity
    local hv   = flat(vel)
    local hs   = hv.Magnitude
    local look = flat(root.CFrame.LookVector)
    local threshold = math.max(hum.WalkSpeed * cfg.dashMult, cfg.dashMin)
    local fdot = (hs > 0.01 and look.Magnitude > 0.01) and hv.Unit:Dot(look.Unit) or 0

    -- only a fast, forward-aligned movement counts as a forward dash
    if hs < threshold or fdot < cfg.forwardDot then return stopDash() end

    local tRoot = targetRoot()
    if not tRoot then return stopDash() end
    s.dashing = true

    local dir = steerDir(root, tRoot)
    if not dir then return end

    -- redirect the dash AROUND the target, keeping its horizontal speed
    local blended = hv:Lerp(dir * hs, cfg.steer)
    root.AssemblyLinearVelocity = Vector3.new(blended.X, vel.Y, blended.Z)

    -- face the target so the strike lands on their flank
    if cfg.rotateBody then
        hum.AutoRotate = false
        s.wasActive = true
        local fd = flat(tRoot.Position - root.Position)
        if fd.Magnitude > 0.01 then
            local cf = CFrame.lookAt(root.Position, root.Position + fd)
            local _, y = cf:ToEulerAnglesYXZ()
            root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, y, 0)
        end
    end
end

function DashFlank.setEnabled(v) s.enabled = v and true or false; if not v then stopDash() end end
function DashFlank.setMode(m)     cfg.mode = (m == "side") and "side" or "back" end
function DashFlank.setRange(v)    cfg.range = tonumber(v) or cfg.range end
function DashFlank.setDashMult(v) cfg.dashMult = tonumber(v) or cfg.dashMult end
function DashFlank.setSteer(v)    cfg.steer = math.clamp(tonumber(v) or cfg.steer, 0, 1) end
function DashFlank.setRotate(v)   cfg.rotateBody = v and true or false end

-- True while we're actively steering a forward dash. Rotation Lock and shiftlock
-- read this and yield so neither can interrupt the flank.
function DashFlank.isDashing() return s.dashing end

function DashFlank.init()
    if s.bound then return end
    -- Heartbeat: set velocity after the frame's physics so it carries into the
    -- next step, and lands LAST in the frame so it overrides earlier rotators.
    s.conns[#s.conns + 1] = RunService.Heartbeat:Connect(step)
    s.bound = true
end

function DashFlank.destroy()
    for _, c in ipairs(s.conns) do pcall(function() c:Disconnect() end) end
    s.conns = {}
    s.bound = false
    stopDash()
end

return DashFlank
