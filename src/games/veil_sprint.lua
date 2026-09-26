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
local fakeAt = 0              -- when we last injected; stale counts are dropped (see fakeEvent)
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

-- Is this W event one of ours? Injected events are counted, but a count can go stale (a
-- key-up sent while the key was already up fires nothing), and a stale count would eat your
-- REAL release and keep W "held" forever -- so counts older than 0.3 s are forgotten.
local function fakeEvent(isDown)
    if os.clock() - fakeAt > 0.3 then fakeDowns, fakeUps = 0, 0 end
    if isDown and fakeDowns > 0 then fakeDowns -= 1; return true end
    if not isDown and fakeUps > 0 then fakeUps -= 1; return true end
    return false
end

local function send(down)
    fakeAt = os.clock()
    if down then fakeDowns += 1 else fakeUps += 1 end
    pcall(function() VIM:SendKeyEvent(down, W, false, game) end)
end

-- The double tap: release + re-press in ONE go, no waits in between. With a gap, letting go
-- of W inside it was invisible to the game (the key was already "up"), so the re-press
-- stayed down forever. Back-to-back, your real release can only land before (-> we don't
-- press) or after (-> it releases the re-press normally).
local function burst(taps)
    if not (realHeld and UIS:IsKeyDown(W)) then return end
    for _ = 1, taps do
        send(false)
        send(true)
    end
end

local function doubleTap()
    local t = os.clock()
    if t - lastTrigger < 0.35 then return end
    lastTrigger = t
    task.delay(0.04, function() burst(1) end)
end

function Sprint.start()
    Sprint.stop()
    running = true
    realHeld = UIS:IsKeyDown(W)
    fakeDowns, fakeUps = 0, 0
    conns[#conns + 1] = UIS.InputBegan:Connect(function(input, gp)
        if input.KeyCode ~= W or fakeEvent(true) then return end
        realHeld = true
        if not CFG.enabled or gp or UIS:GetFocusedTextBox() then return end
        if not isSprinting() then doubleTap() end
    end)
    conns[#conns + 1] = UIS.InputEnded:Connect(function(input)
        if input.KeyCode ~= W or fakeEvent(false) then return end
        realHeld = false
    end)
    task.spawn(function()
        while running do
            task.wait(0.15)
            -- safety net: the game thinks W is down but you aren't holding it -> let go
            if not realHeld and UIS:IsKeyDown(W) then send(false) end
            -- sprint dropped while you're still holding W -> double tap again
            if realHeld and not UIS:GetFocusedTextBox() and not isSprinting()
               and os.clock() - lastTrigger > 0.6 then
                lastTrigger = os.clock()
                burst(2)
            end
        end
    end)
    log.info("[AutoSprint] on")
end

function Sprint.stop()
    running = false
    if not realHeld and UIS:IsKeyDown(W) then       -- never leave W held when turned off
        pcall(function() VIM:SendKeyEvent(false, W, false, game) end)
    end
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
