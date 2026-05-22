-- Dash Flank: detect the local player's FORWARD dash and steer it to the
-- target's side / back so the follow-up lands where a front block won't help.
--
-- Mechanism (game-agnostic): a dash shows up as a sudden horizontal velocity
-- spike aligned with our facing. While that's happening we
--   (a) redirect the horizontal velocity toward a flank point beside/behind the
--       target, PRESERVING the dash's speed -- so an impulse dash is curved, not
--       just re-faced (rotation alone can't redirect existing momentum), and
--   (b) yaw the body to face the target so the attack cone catches their flank.
-- It ONLY acts during the dash window (the velocity spike); normal walking,
-- sprinting, and non-forward dashes are left untouched.

local state = require("modules.aim.state")

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")

local DashFlank = {}
local LP = Players.LocalPlayer

local cfg = {
    mode       = "back", -- "back" or "side"
    range      = 45,     -- only flank a target within this many studs
    backOffset = 4,      -- studs behind the target to aim
    sideOffset = 6,      -- studs to the side (wrap distance)
    dashMult   = 2.2,    -- horizontal speed >= WalkSpeed*dashMult counts as a dash
    dashMin    = 36,     -- ...but never treat below this as a dash (studs/s)
    forwardDot = 0.5,    -- velocity must align with facing this much (=> forward dash)
    steer      = 1.0,    -- 0..1: how hard to redirect the dash velocity each frame
    rotateBody = true,   -- also turn to face the target
}

local s = { enabled = false, bound = false, conns = {}, dashing = false }

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

-- the point we want the dash to carry us to
local function flankPoint(myRoot, tRoot)
    local ePos  = tRoot.Position
    local eLookV = flat(tRoot.CFrame.LookVector)
    local eLook  = (eLookV.Magnitude > 0.01) and eLookV.Unit or Vector3.new(0, 0, -1)
    local eRight = Vector3.new(eLook.Z, 0, -eLook.X)        -- the target's right, flattened
    local toMe   = flat(myRoot.Position - ePos)
    local sideSign = (toMe:Dot(eRight) >= 0) and 1 or -1    -- wrap via the side we're already on
    if cfg.mode == "back" then
        -- rear quarter: behind them, biased toward our side so we curve around, not into, them
        return ePos - eLook * cfg.backOffset + eRight * (sideSign * cfg.sideOffset * 0.5)
    end
    return ePos + eRight * (sideSign * cfg.sideOffset)
end

local function step()
    if not s.enabled then s.dashing = false; return end
    local char = myChar(); local root = rootOf(char); local hum = humOf(char)
    if not (root and hum) or hum.Health <= 0 then s.dashing = false; return end

    local vel  = root.AssemblyLinearVelocity
    local hv   = flat(vel)
    local hs   = hv.Magnitude
    local look = flat(root.CFrame.LookVector)
    local threshold = math.max(hum.WalkSpeed * cfg.dashMult, cfg.dashMin)
    local fdot = (hs > 0.01 and look.Magnitude > 0.01) and hv.Unit:Dot(look.Unit) or 0

    -- gate: only a fast, forward-aligned movement counts as a forward dash
    if hs < threshold or fdot < cfg.forwardDot then s.dashing = false; return end

    local tRoot = targetRoot()
    if not tRoot then s.dashing = false; return end
    s.dashing = true

    local fp  = flankPoint(root, tRoot)
    local dir = flat(fp - root.Position)
    if dir.Magnitude < 0.01 then return end
    dir = dir.Unit

    -- redirect the dash: keep its horizontal speed, point it at the flank
    local desired = dir * hs
    local blended = hv:Lerp(desired, cfg.steer)
    root.AssemblyLinearVelocity = Vector3.new(blended.X, vel.Y, blended.Z)

    -- face the target so the strike lands on their side/back
    if cfg.rotateBody then
        local fd = flat(tRoot.Position - root.Position)
        if fd.Magnitude > 0.01 then
            local cf = CFrame.lookAt(root.Position, root.Position + fd)
            local _, y = cf:ToEulerAnglesYXZ()
            root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, y, 0)
        end
    end
end

function DashFlank.setEnabled(v) s.enabled = v and true or false; if not v then s.dashing = false end end
function DashFlank.setMode(m)     cfg.mode = (m == "side") and "side" or "back" end
function DashFlank.setRange(v)    cfg.range = tonumber(v) or cfg.range end
function DashFlank.setDashMult(v) cfg.dashMult = tonumber(v) or cfg.dashMult end
function DashFlank.setSteer(v)    cfg.steer = math.clamp(tonumber(v) or cfg.steer, 0, 1) end
function DashFlank.setRotate(v)   cfg.rotateBody = v and true or false end

-- True while we're actively steering a forward dash (handy for other modules).
function DashFlank.isDashing() return s.dashing end

function DashFlank.init()
    if s.bound then return end
    -- Heartbeat: set velocity after the frame's physics so it carries into the
    -- next step -- the reliable point for velocity redirection.
    s.conns[#s.conns + 1] = RunService.Heartbeat:Connect(step)
    s.bound = true
end

function DashFlank.destroy()
    for _, c in ipairs(s.conns) do pcall(function() c:Disconnect() end) end
    s.conns = {}
    s.bound = false
    s.dashing = false
end

return DashFlank
