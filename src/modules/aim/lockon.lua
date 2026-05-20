-- Main lock-on driver. Hotkey dispatch comes through core.keybinds (handled by
-- the feature row), so this module only exposes the press/release entry points
-- and runs the per-frame target-validity loop.

local state     = require("modules.aim.state")
local targeting = require("modules.aim.targeting")
local highlight = require("modules.aim.highlight")

local RunService = game:GetService("RunService")

local LockOn = {}

local s = {
    holdMode   = false,
    holdActive = false,
    runConn    = nil,
}

local function releaseLock()
    state.setLocked(false)
    state.lockon_held = false
    state.setTarget(nil, nil)
    s.holdActive = false
    highlight.update(nil, nil)
end

local function engageLock()
    local t = targeting.getBestTarget()
    if not t then return false end
    state.setTarget(t, "player")
    state.setLocked(true)
    state.lockon_held = true
    return true
end

local function step()
    if not state.lockon_enabled or not state.lockon_locked then return end

    local t = state.lockon_target
    if state.lockon_target_type == "player" then
        local char = t and t.Character
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        if not hum or hum.Health <= 0 or not char.Parent or state.isFriendly(t) then
            releaseLock()
            return
        end
    elseif state.lockon_target_type == "npc" then
        local hum = t and t:FindFirstChildOfClass("Humanoid")
        if not hum or hum.Health <= 0 or not t.Parent then
            releaseLock()
            return
        end
    end

    highlight.update(t, function(exclude) return targeting.getBestTarget(exclude) end)
end

-- Called by the central keybind dispatcher on key press.
function LockOn.hotkeyPress()
    if not state.lockon_enabled then return end
    if s.holdMode then
        if not state.lockon_locked then engageLock() end
        s.holdActive = true
    else
        if state.lockon_locked then releaseLock() else engageLock() end
    end
end

-- Called by the central keybind dispatcher on key release.
function LockOn.hotkeyRelease()
    if s.holdMode and s.holdActive and state.lockon_locked then
        releaseLock()
    end
end

function LockOn.setHoldMode(v)
    s.holdMode = v and true or false
end

function LockOn.setEnabled(v)
    state.lockon_enabled = v and true or false
    if not v then releaseLock() end
end

function LockOn.init()
    s.runConn = RunService.Heartbeat:Connect(step)
end

function LockOn.destroy()
    if s.runConn then s.runConn:Disconnect() end
end

return LockOn
