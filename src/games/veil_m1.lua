-- The Veil: M1 Continuation. Holding left click swings for as long as you hold it -- until the
-- game ragdolls or stuns you. It forgets the button was down, so when you get back up nothing
-- swings even though your finger never left the mouse (user 2026-10-01: "when the game
-- ragdolls u they forget u were holding m1 and thus ur m1's immediately stop going through").
--
-- This remembers it for the game: your REAL button state is tracked, and the moment you can
-- attack again (ragdoll / stun over; you can't M1 while ragdolled) the hold is started again
-- with a fresh press. It's only ever let go when YOU let go: your real release goes to the
-- game as normal, and if you let go while you were down nothing is pressed at all.
--
-- "Can't attack" = your character's Ragdolled attribute, a StunUntil that hasn't run out
-- (server time), PlatformStand, or a Ragdoll / FallingDown / Physics humanoid state.
--
-- Auto Weave's jump M1 guard lets go of the button for the game too (so a held swing can't
-- lock the jump); it calls M1.resume() when the guard ends, so the hold comes back by itself.

local Players    = game:GetService("Players")
local UIS        = game:GetService("UserInputService")
local VIM        = game:GetService("VirtualInputManager")
local RunService = game:GetService("RunService")
local Workspace  = game:GetService("Workspace")

local log = require("core.log")

local LP = Players.LocalPlayer
local MB1 = Enum.UserInputType.MouseButton1

local M1 = {}
local CFG = { enabled = false, delay = 0.1 }
local conns = {}
local running = false
local realHeld = false        -- is YOUR finger on the left button
local fakeDowns, fakeUps = 0, 0
local fakeAt = 0              -- when an injected click was last announced; stale counts are dropped
local wasBlocked = false
local lastResume = 0

local DOWN_STATES = {
    [Enum.HumanoidStateType.Ragdoll]     = true,
    [Enum.HumanoidStateType.FallingDown] = true,
    [Enum.HumanoidStateType.Physics]     = true,
}

-- Injected clicks (ours, and Auto Weave's guard release) fire the same input events as real
-- ones: each is announced here first and skipped by the tracker. A count can go stale (an "up"
-- sent while the button was already up fires nothing) and would then eat your REAL event, so
-- counts older than 0.3 s are forgotten.
function M1.noteFake(isDown)
    fakeAt = os.clock()
    if isDown then fakeDowns += 1 else fakeUps += 1 end
end

local function fakeEvent(isDown)
    if os.clock() - fakeAt > 0.3 then fakeDowns, fakeUps = 0, 0 end
    if isDown and fakeDowns > 0 then fakeDowns -= 1; return true end
    if not isDown and fakeUps > 0 then fakeUps -= 1; return true end
    return false
end

local function send(down)
    M1.noteFake(down)
    local p = UIS:GetMouseLocation()
    pcall(function() VIM:SendMouseButtonEvent(p.X, p.Y, 0, down, game, 0) end)
end

-- true while the game won't let you attack
local function blocked()
    local c = LP.Character
    local hum = c and c:FindFirstChildOfClass("Humanoid")
    if not (c and hum) or hum.Health <= 0 then return true end
    if c:GetAttribute("Ragdolled") == true then return true end
    local su = c:GetAttribute("StunUntil")
    if type(su) == "number" then
        local ok, sn = pcall(function() return Workspace:GetServerTimeNow() end)
        if ok and su > sn then return true end
    end
    if hum.PlatformStand then return true end
    return DOWN_STATES[hum:GetState()] == true
end
M1.isBlocked = blocked   -- shared with Auto Swing: same "can't attack right now" answer

-- Start the hold again: a release then a press, so the game sees a brand new click that is
-- still down. Nothing happens unless you're really holding the button and can attack.
function M1.resume(reason)
    if not (running and CFG.enabled and realHeld) then return false end
    if UIS:GetFocusedTextBox() or blocked() then return false end
    local t = os.clock()
    if t - lastResume < 0.2 then return false end
    lastResume = t
    send(false)
    send(true)
    log.info("[M1 Continuation] hold restarted (" .. tostring(reason or "?") .. ")")
    return true
end

function M1.start()
    M1.stop()
    running = true
    realHeld = UIS:IsMouseButtonPressed(MB1)
    fakeDowns, fakeUps = 0, 0
    wasBlocked = blocked()
    conns[#conns + 1] = UIS.InputBegan:Connect(function(input)
        if input.UserInputType ~= MB1 or fakeEvent(true) then return end
        realHeld = true
    end)
    conns[#conns + 1] = UIS.InputEnded:Connect(function(input)
        if input.UserInputType ~= MB1 or fakeEvent(false) then return end
        realHeld = false
    end)
    -- alt-tabbing away eats the release: never keep a hold going you can't see
    conns[#conns + 1] = UIS.WindowFocusReleased:Connect(function() realHeld = false end)
    conns[#conns + 1] = RunService.Heartbeat:Connect(function()
        local b = blocked()
        if wasBlocked and not b and realHeld then
            task.delay(CFG.delay, function() M1.resume("back on your feet") end)
        end
        wasBlocked = b
    end)
    log.info("[M1 Continuation] on")
end

function M1.stop()
    running = false
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)
    -- never leave the button held for the game when you aren't holding it
    if not realHeld and UIS:IsMouseButtonPressed(MB1) then
        local p = UIS:GetMouseLocation()
        pcall(function() VIM:SendMouseButtonEvent(p.X, p.Y, 0, false, game, 0) end)
    end
end

function M1.feature()
    return {
        id          = "veil.m1_continuation",
        name        = "M1 Continuation",
        description = "Keeps your held left click going through knock-downs. When the game ragdolls or stuns you it forgets you were holding M1, so your swings stop even though you never let go. This remembers that you're holding it and, the moment you can attack again, starts the hold again for you. It only stops when you let go yourself; if you let go while you were down, nothing is pressed. Also brings the hold back after Auto Weave blocks your clicks for a jump. Delay = how long after getting up the hold restarts (raise it if the first swing after a knock-down doesn't come out).",
        default     = false,
        onToggle    = function(v)
            CFG.enabled = v and true or false
            if CFG.enabled then M1.start() else M1.stop() end
        end,
        settings = {
            { type = "slider", name = "Delay after getting up (s)", key = "delay", min = 0, max = 0.5, step = 0.01,
              default = 0.1, onChange = function(v) CFG.delay = v end },
        },
    }
end

return M1
