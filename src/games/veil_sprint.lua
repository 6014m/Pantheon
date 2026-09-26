-- The Veil: Auto Sprint. The game sprints on a double-tap of W (SprintActive; walk 20 -> 31,
-- then SuperSprintActive 43 after ~4 s). Setting those values yourself does nothing (the game
-- owns them), so this does what a player does: when you press W, it adds a quick release +
-- re-press (verified timing: W down, 0.04 s, W up, 0.06 s gap, W down) so the game sees a
-- double tap. If sprint drops while you're still holding W, it re-triggers.
--
-- Your REAL W state is tracked separately from the game's (which includes our fake presses):
-- each injected event is counted and skipped, so a quick tap that lets go mid-sequence can
-- never leave W stuck down (user bug: tap-and-release sprinted forward forever).

local Players = game:GetService("Players")
local UIS     = game:GetService("UserInputService")
local VIM     = game:GetService("VirtualInputManager")

local log = require("core.log")

local LP = Players.LocalPlayer
local W = Enum.KeyCode.W

local Sprint = {}
local CFG = { enabled = false }
local conns = {}
local running = false
local realHeld = false        -- is YOUR finger on W
local fakeDowns, fakeUps = 0, 0
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

local function fakeUp()
    fakeUps += 1
    pcall(function() VIM:SendKeyEvent(false, W, false, game) end)
end

local function fakeDown()
    if not realHeld then return end          -- you already let go: never press W for you
    fakeDowns += 1
    pcall(function() VIM:SendKeyEvent(true, W, false, game) end)
end

-- release + re-press right after your real press -> the game sees a double tap
local function doubleTap()
    local t = os.clock()
    if t - lastTrigger < 0.35 then return end
    lastTrigger = t
    task.spawn(function()
        task.wait(0.04)
        if not realHeld then return end
        fakeUp()
        task.wait(0.06)
        fakeDown()
    end)
end

function Sprint.start()
    Sprint.stop()
    running = true
    realHeld = UIS:IsKeyDown(W)
    conns[#conns + 1] = UIS.InputBegan:Connect(function(input, gp)
        if input.KeyCode ~= W then return end
        if fakeDowns > 0 then fakeDowns -= 1; return end    -- ours
        realHeld = true
        if not CFG.enabled or gp or UIS:GetFocusedTextBox() then return end
        if not isSprinting() then doubleTap() end
    end)
    conns[#conns + 1] = UIS.InputEnded:Connect(function(input)
        if input.KeyCode ~= W then return end
        if fakeUps > 0 then fakeUps -= 1; return end        -- ours
        realHeld = false
    end)
    task.spawn(function()
        while running do
            task.wait(0.2)
            -- safety net: the game thinks W is down but you aren't holding it -> let go
            if not realHeld and UIS:IsKeyDown(W) then
                fakeUps += 1
                pcall(function() VIM:SendKeyEvent(false, W, false, game) end)
            end
            -- sprint dropped while you're still holding W -> double tap again
            if realHeld and not UIS:GetFocusedTextBox() and not isSprinting()
               and os.clock() - lastTrigger > 0.6 then
                lastTrigger = os.clock()
                fakeUp(); task.wait(0.03)
                fakeDown(); task.wait(0.04)
                fakeUp(); task.wait(0.06)
                fakeDown()
            end
        end
    end)
    log.info("[AutoSprint] on")
end

function Sprint.stop()
    running = false
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)
end

function Sprint.feature()
    return {
        id          = "veil.auto_sprint",
        name        = "Auto Sprint",
        description = "Sprints for you: the game sprints on a double-tap of W, so when you press W this adds the second tap (~0.1 s later) for you. If sprint drops while you're still holding W (attacking, stopping), it starts it again. It only ever presses W while your finger is on W.",
        default     = false,
        onToggle    = function(v)
            CFG.enabled = v and true or false
            if CFG.enabled then Sprint.start() else Sprint.stop() end
        end,
    }
end

return Sprint
