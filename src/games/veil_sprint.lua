-- The Veil: Auto Sprint. The game sprints on a double-tap of W (SprintActive; walk 20 -> 31,
-- then SuperSprintActive 43 after ~4 s). Setting those values yourself does nothing (the game
-- owns them), so this does what a player does: when you press W, it adds a quick release +
-- re-press (verified timing: W down, 0.04 s, W up, 0.06 s gap, W down) so the game sees a
-- double tap. The re-press is "held" until your real W comes up. If sprint drops while you're
-- still holding W (attacking, stopping, stamina), it re-triggers.

local Players = game:GetService("Players")
local UIS     = game:GetService("UserInputService")
local VIM     = game:GetService("VirtualInputManager")

local log = require("core.log")

local LP = Players.LocalPlayer
local W = Enum.KeyCode.W

local Sprint = {}
local CFG = { enabled = false }
local conns = {}
local injectingUntil = 0
local lastTrigger = 0

local function sprintValue()
    local c = LP.Character
    if not c then return nil end
    for _, d in ipairs(c:GetDescendants()) do
        if d.Name == "SprintActive" and d:IsA("ValueBase") then return d end
    end
    return nil
end

local function isSprinting()
    local v = sprintValue()
    return v ~= nil and v.Value == true
end

-- fake release + re-press right after your real press -> the game sees a double tap
local function doubleTap()
    local t = os.clock()
    if t - lastTrigger < 0.35 then return end
    lastTrigger = t
    injectingUntil = t + 0.3
    task.spawn(function()
        task.wait(0.04)
        if not UIS:IsKeyDown(W) then return end          -- you already let go
        pcall(function() VIM:SendKeyEvent(false, W, false, game) end)
        task.wait(0.06)
        pcall(function() VIM:SendKeyEvent(true, W, false, game) end)
    end)
end

function Sprint.start()
    Sprint.stop()
    conns[#conns + 1] = UIS.InputBegan:Connect(function(input, gp)
        if not CFG.enabled or gp or input.KeyCode ~= W then return end
        if os.clock() < injectingUntil then return end   -- our own re-press
        if UIS:GetFocusedTextBox() then return end
        if not isSprinting() then doubleTap() end
    end)
    -- sprint dropped while W is still held -> trigger it again
    task.spawn(function()
        while CFG.enabled do
            task.wait(0.25)
            if UIS:IsKeyDown(W) and not UIS:GetFocusedTextBox() and not isSprinting()
               and os.clock() - lastTrigger > 0.6 then
                -- re-create a double tap from the held key: release, press, release, press
                lastTrigger = os.clock()
                injectingUntil = os.clock() + 0.4
                pcall(function()
                    VIM:SendKeyEvent(false, W, false, game); task.wait(0.03)
                    VIM:SendKeyEvent(true, W, false, game);  task.wait(0.04)
                    VIM:SendKeyEvent(false, W, false, game); task.wait(0.06)
                    VIM:SendKeyEvent(true, W, false, game)
                end)
            end
        end
    end)
    log.info("[AutoSprint] on")
end

function Sprint.stop()
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)
end

function Sprint.feature()
    return {
        id          = "veil.auto_sprint",
        name        = "Auto Sprint",
        description = "Sprints for you: the game sprints on a double-tap of W, so when you press W this adds the second tap (~0.1 s later) for you. If sprint drops while you're still holding W (attacking, stopping), it starts it again.",
        default     = false,
        onToggle    = function(v)
            CFG.enabled = v and true or false
            if CFG.enabled then Sprint.start() else Sprint.stop() end
        end,
    }
end

return Sprint
