-- Main lock-on driver. Owns the hotkey, the toggle/hold state machine, and the
-- per-frame target-validity loop. Writes to the shared aim state; lockon+ and
-- highlight react.

local state     = require("modules.aim.state")
local targeting = require("modules.aim.targeting")
local highlight = require("modules.aim.highlight")

local UserInputService = game:GetService("UserInputService")
local RunService       = game:GetService("RunService")

local LockOn = {}

local self_state = {
    hotkey       = Enum.KeyCode.E,
    holdMode     = false,
    runConn      = nil,
    inputConn    = nil,
    inputEndConn = nil,
}

local function releaseLock()
    state.setLocked(false)
    state.lockon_held = false
    state.setTarget(nil, nil)
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

local function onInputBegan(input, gpe)
    if gpe then return end
    if not state.lockon_enabled then return end
    if input.KeyCode ~= self_state.hotkey then return end

    if self_state.holdMode then
        engageLock()
    else
        if state.lockon_locked then releaseLock() else engageLock() end
    end
end

local function onInputEnded(input)
    if input.KeyCode ~= self_state.hotkey then return end
    if self_state.holdMode and state.lockon_locked then
        releaseLock()
    end
end

function LockOn.setHotkey(key)
    self_state.hotkey = key
end

function LockOn.setHoldMode(v)
    self_state.holdMode = v and true or false
end

function LockOn.setEnabled(v)
    state.lockon_enabled = v and true or false
    if not v then releaseLock() end
end

function LockOn.init()
    self_state.inputConn    = UserInputService.InputBegan:Connect(onInputBegan)
    self_state.inputEndConn = UserInputService.InputEnded:Connect(onInputEnded)
    self_state.runConn      = RunService.Heartbeat:Connect(step)
end

function LockOn.destroy()
    if self_state.inputConn    then self_state.inputConn:Disconnect()    end
    if self_state.inputEndConn then self_state.inputEndConn:Disconnect() end
    if self_state.runConn      then self_state.runConn:Disconnect()      end
end

return LockOn
