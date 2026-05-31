-- Bot Mode: hands-free auto-combat. While on, it continuously acquires the
-- nearest valid (non-friendly) target and keeps it parked in state.target, so
-- Lock-On (camera) and Rotation Lock (body) -- which both read state.target --
-- track it WITHOUT you holding the Target Select key. Optional Auto-attack fires
-- left-clicks at the locked target on an interval.
--
-- Declared the same way as Shiftlock / Lock-On (a Combat feature with a master
-- toggle + keybind + cog settings). It depends on Lock-On in the feature graph,
-- so enabling Bot Mode turns the whole aim stack on; turn on Rotation Lock in
-- Lock-On's panel too if you want your body to face the target (melee / attack).
--
-- Friendlies (the Friendlies panel) are skipped automatically: acquisition goes
-- through targeting.getBestTarget(), which already filters state.isFriendly.

local state     = require("modules.aim.state")
local targeting = require("modules.aim.targeting")

local RunService          = game:GetService("RunService")
local Workspace           = game:GetService("Workspace")
local VirtualInputManager = game:GetService("VirtualInputManager")

local Bot = {}

local s = {
    enabled        = false,
    heartConn      = nil,
    lastStep       = 0,
    autoAttack     = false,
    attackInterval = 0.4,
    lastAttack     = 0,
    reacquire      = true,   -- pick a fresh target when the current one dies / leaves
}

-- Acquisition runs on a throttle (not every frame): getBestTarget() loops every
-- player, and the actual aim (lockon camera / rotation_lock body) already runs
-- per-frame off state.target, so 15 Hz is plenty to keep a live target parked.
local STEP_INTERVAL = 1 / 15

local function targetValid()
    local t = state.target
    if not t then return false end
    if state.isFriendly(t) then return false end
    if state.target_type == "player" then
        local ch  = t.Character
        local hum = ch and ch:FindFirstChildOfClass("Humanoid")
        return hum ~= nil and hum.Health > 0 and ch.Parent ~= nil
    else
        local hum = t:FindFirstChildOfClass("Humanoid")
        return hum ~= nil and hum.Health > 0 and t.Parent ~= nil
    end
end

local function attackOnce()
    local cam = Workspace.CurrentCamera
    local vp  = cam and cam.ViewportSize
    local x   = (vp and vp.X or 800) * 0.5
    local y   = (vp and vp.Y or 600) * 0.5
    -- Click at screen center (where the locked target sits). pcall'd by caller.
    VirtualInputManager:SendMouseButtonEvent(x, y, 0, true,  game, 0)
    VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 0)
end

local function step()
    if not s.enabled then return end
    local now = os.clock()
    if now - s.lastStep < STEP_INTERVAL then return end
    s.lastStep = now

    if not targetValid() then
        -- Current target gone. Re-acquire the nearest enemy (unless the user
        -- turned re-acquire off, in which case we just drop it and wait).
        if s.reacquire then
            local t = targeting.getBestTarget()
            state.setTarget(t or nil, t and "player" or nil)
        else
            state.setTarget(nil, nil)
        end
    end

    if state.target and s.autoAttack and (now - s.lastAttack) >= s.attackInterval then
        s.lastAttack = now
        pcall(attackOnce)
    end
end

function Bot.setEnabled(v)
    s.enabled = v and true or false
    if not s.enabled then
        -- Release the target we were holding so the camera / body stop tracking
        -- a stale enemy the moment the bot is switched off.
        state.setTarget(nil, nil)
    end
end

function Bot.setAutoAttack(v)     s.autoAttack = v and true or false end
function Bot.setAttackInterval(v) s.attackInterval = math.max(0.05, tonumber(v) or 0.4) end
function Bot.setReacquire(v)      s.reacquire = v and true or false end

function Bot.init()
    if s.heartConn then return end
    s.heartConn = RunService.Heartbeat:Connect(step)
end

function Bot.destroy()
    if s.heartConn then s.heartConn:Disconnect(); s.heartConn = nil end
end

return Bot
