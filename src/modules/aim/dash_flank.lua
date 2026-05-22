-- Dash Flank: when you FORWARD-DASH at the Target Select target, curve the dash
-- around to their side/back. Built for battleground games in general.
--
-- DETECTION is INPUT-based, not physics-based. You bind your game's dash key
-- (default Q); pressing it WHILE MOVING FORWARD is the dash. This is reliable
-- and game-agnostic -- flings, sprints, knockback and launch moves never press
-- the dash key, so they can't be mistaken for a dash (that was the whole problem
-- with the velocity heuristic). If no dash key is bound it falls back to a
-- velocity spike for keyless-dash games.
--
-- While dashing it steers velocity AROUND the target (oval hug, settles on the
-- back), always yaw-faces the target, never redirects fling-speed velocity, and
-- Rotation Lock + shiftlock yield to it (via isDashing()).

local state    = require("modules.aim.state")
local keybinds = require("core.keybinds")

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS        = game:GetService("UserInputService")

local DashFlank = {}
local LP = Players.LocalPlayer
local DASH_KEY_ID = "aim.dash_flank.key"

local cfg = {
    mode         = "back",
    minRadius    = 3,     -- hug distance at the flank
    frontExtra   = 4,     -- extra hug while in front (=> oval)
    hugStrength  = 0.6,
    dashLength   = 0.45,  -- how long a dash lasts (s) = the flank window after the key press
    fwdDot       = 0.35,  -- move direction must align with camera-forward this much (=> forward dash)
    maxDashSpeed = 140,   -- never REDIRECT velocity above this (fling safety)
    steer        = 1.0,
    rotateBody   = true,
    -- velocity-auto fallback (used only when NO dash key is bound):
    spikeAccel   = 250,
    dashFloor    = 20,
}

local s   = { enabled = false, bound = false, conns = {}, dashing = false, wasActive = false }
local det = { active = false, until_ = 0, prevHs = math.huge }

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

-- ADHERE to Target Select.
local function targetRoot()
    if not state.target then return nil end
    local c = (state.target_type == "player") and state.target.Character or state.target
    return rootOf(c)
end

-- Fired by our OWN InputBegan (gpe NOT filtered, since the dash key is one the
-- game also uses). Opens the dash window only for an actual forward dash.
local function onDashKey()
    if not s.enabled then return end
    local char = myChar(); local hum = humOf(char); local cam = workspace.CurrentCamera
    if not (hum and cam) then return end
    if hum.Health <= 0 or hum.PlatformStand or BAD_STATES[hum:GetState()] then return end
    local md = flat(hum.MoveDirection)
    if md.Magnitude < 0.1 then return end                  -- standing still => not a forward dash
    local fwd = flat(cam.CFrame.LookVector)
    if fwd.Magnitude < 0.01 or md.Unit:Dot(fwd.Unit) < cfg.fwdDot then return end  -- not forward
    det.active = true
    det.until_ = os.clock() + cfg.dashLength
end

-- Arc AROUND the target, hug close in an oval, settle on the back.
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
    local tangentScale = math.clamp(1 - aligned, 0, 1)     -- fade orbit -> settle on the back
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
    if not s.enabled then det.active = false; return stopDash() end
    local char = myChar(); local root = rootOf(char); local hum = humOf(char)
    if not (root and hum) or hum.Health <= 0 then det.active = false; return stopDash() end
    if hum.PlatformStand or BAD_STATES[hum:GetState()] then det.active = false; return stopDash() end
    if state.isWeldedToOther(char) then det.active = false; return stopDash() end

    local vel  = root.AssemblyLinearVelocity
    local hv   = flat(vel)
    local hs   = hv.Magnitude
    local look = flat(root.CFrame.LookVector)
    local fdot = (hs > 0.01 and look.Magnitude > 0.01) and hv.Unit:Dot(look.Unit) or 0
    local now  = os.clock()

    local key = keybinds.get(DASH_KEY_ID)
    local dashing
    if key and key ~= Enum.KeyCode.Unknown then
        -- KEY-BASED: onDashKey opened the window; it lasts dashLength
        if det.active and now > det.until_ then det.active = false end
        dashing = det.active
    else
        -- VELOCITY-AUTO fallback (no dash key bound)
        local accel = (hs - det.prevHs) / math.max(dt or (1 / 60), 1 / 240)
        det.prevHs = hs
        if not det.active then
            if accel >= cfg.spikeAccel and hs >= cfg.dashFloor and fdot >= cfg.fwdDot then
                det.active = true; det.until_ = now + cfg.dashLength
            end
        elseif now > det.until_ then
            det.active = false
        end
        dashing = det.active
    end

    if not dashing then return stopDash() end
    local tRoot = targetRoot()
    if not tRoot then return stopDash() end
    s.dashing = true

    -- always face the target while dashing
    if cfg.rotateBody then
        hum.AutoRotate = false
        s.wasActive = true
        local fd = flat(tRoot.Position - root.Position)
        if fd.Magnitude > 0.01 then
            local cf = CFrame.lookAt(root.Position, root.Position + fd)
            local _, y = cf:ToEulerAnglesYXZ()
            if y == y then
                root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, y, 0)
            end
        end
    end

    -- steer the dash around the flank -- never redirect fling-speed velocity
    local dir = (hs <= cfg.maxDashSpeed) and steerDir(root, tRoot) or nil
    if dir then
        local blended = hv:Lerp(dir * hs, cfg.steer)
        if blended.X == blended.X and blended.Z == blended.Z and blended.Magnitude < 1e4 then
            root.AssemblyLinearVelocity = Vector3.new(blended.X, vel.Y, blended.Z)
        end
    end
end

function DashFlank.setEnabled(v)    s.enabled = v and true or false; if not v then det.active = false; stopDash() end end
function DashFlank.setMode(m)        cfg.mode = (m == "side") and "side" or "back" end
function DashFlank.setMinRadius(v)   cfg.minRadius = tonumber(v) or cfg.minRadius end
function DashFlank.setDashLength(v)  cfg.dashLength = tonumber(v) or cfg.dashLength end
function DashFlank.setSteer(v)       cfg.steer = math.clamp(tonumber(v) or cfg.steer, 0, 1) end
function DashFlank.setRotate(v)      cfg.rotateBody = v and true or false end

function DashFlank.isDashing() return s.dashing end

function DashFlank.init()
    if s.bound then return end
    -- Own InputBegan listener: do NOT filter gameProcessed, because the dash key
    -- is one the game itself consumes (Pantheon's keybind dispatcher drops gpe).
    s.conns[#s.conns + 1] = UIS.InputBegan:Connect(function(input)
        local k = keybinds.get(DASH_KEY_ID)
        if k and k ~= Enum.KeyCode.Unknown and input.KeyCode == k then onDashKey() end
    end)
    s.conns[#s.conns + 1] = RunService.Heartbeat:Connect(function(dt) step(dt) end)
    s.bound = true
end

function DashFlank.destroy()
    for _, c in ipairs(s.conns) do pcall(function() c:Disconnect() end) end
    s.conns = {}
    s.bound = false
    det.active = false
    stopDash()
end

return DashFlank
