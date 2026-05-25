-- Target Select: picks and holds a target, triggers Highlight. Lock-On and
-- Rotation Lock read state.target to know who to aim at. Owns the toggle/hold
-- hotkey (default X).

local state     = require("modules.aim.state")
local targeting = require("modules.aim.targeting")
local highlight = require("modules.aim.highlight")

local RunService = game:GetService("RunService")

local TargetSelect = {}

local s = {
    holdMode   = false,
    holdActive = false,
    heartConn  = nil,
    lastStep   = 0,
}

-- Target validity + highlight/swap-target recompute run on a throttle, not every
-- frame. getBestTarget() loops every player (and raycasts per player when the
-- visibility check is on) -- doing that 240x/s in a crowded server is the main
-- source of the "choppy sometimes" hitching. 30 Hz keeps the health bar and
-- target-release responsive while cutting the scan rate ~8x. The actual aim
-- (lockon camera + rotation_lock body) stays per-frame and is untouched.
local STEP_INTERVAL = 1 / 30

local function releaseTarget()
    state.setTarget(nil, nil)
    s.holdActive = false
    highlight.update(nil, nil)
end

local function engageTarget()
    local t = targeting.getBestTarget()
    if not t then return false end
    state.setTarget(t, "player")
    return true
end

function TargetSelect.swapTarget()
    if not state.swap_enabled then return end
    if not state.target_select_enabled or not state.target then return end
    local next_ = targeting.getBestTarget(state.target)
    if next_ then state.setTarget(next_, "player") end
end

local function step()
    if not state.target_select_enabled then return end
    if not state.target then return end

    local now = os.clock()
    if now - s.lastStep < STEP_INTERVAL then return end
    s.lastStep = now

    local t = state.target
    if state.target_type == "player" then
        local char = t and t.Character
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        if not hum or hum.Health <= 0 or not char.Parent or state.isFriendly(t) then
            releaseTarget()
            return
        end
    elseif state.target_type == "npc" then
        local hum = t and t:FindFirstChildOfClass("Humanoid")
        if not hum or hum.Health <= 0 or not t.Parent then
            releaseTarget()
            return
        end
    end

    highlight.update(t, function(exclude) return targeting.getBestTarget(exclude) end)
end

function TargetSelect.hotkeyPress()
    if not state.target_select_enabled then return end
    if s.holdMode then
        if not state.target then engageTarget() end
        s.holdActive = true
    else
        if state.target then releaseTarget() else engageTarget() end
    end
end

function TargetSelect.hotkeyRelease()
    if s.holdMode and s.holdActive and state.target then
        releaseTarget()
    end
end

function TargetSelect.setHoldMode(v)
    s.holdMode = v and true or false
end

function TargetSelect.setEnabled(v)
    state.target_select_enabled = v and true or false
    if not v then releaseTarget() end
end

function TargetSelect.init()
    s.heartConn = RunService.Heartbeat:Connect(step)
end

function TargetSelect.destroy()
    if s.heartConn then s.heartConn:Disconnect(); s.heartConn = nil end
end

return TargetSelect
