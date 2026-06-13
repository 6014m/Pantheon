-- Fake Tab: reproduces the PvP effect of alt-tabbing ("tabbing") without the
-- downside. When you really alt-tab, Roblox throttles the client to ~0 FPS, your
-- character stops replicating movement, and to everyone else you're frozen in
-- place (and you stop eating knockback / combos). The useful half of that is the
-- freeze-in-place desync; the painful half is that YOU can't see at 0 FPS. This
-- gives you the freeze without the blackout -- camera / vision / aim stay live.
--
-- Mechanism: anchor the HEAD. In an R6/R15 rig every part is rigidly joined
-- (Motor6D) up to the head, so anchoring the head pins the whole assembly in
-- place. It's the head specifically that gives the clean tab-freeze in the games
-- this is used in -- anchoring the HumanoidRootPart tends to disturb the Humanoid
-- (it's the assembly root) / get noticed, whereas the head doesn't. The anchored
-- state replicates (we own our character), so others see us frozen and external
-- forces can't shove us.
--
-- A light Heartbeat keeps it anchored: it re-anchors the new head after a respawn
-- and re-asserts if the game unanchors us. It deliberately does NOT yield, so it
-- sidesteps Wave's "task.wait in a respawn signal may not resume" quirk
-- ([[feedback_executor_signal_taskwait]]). Anchored=true is still a property tell
-- -- this makes no anti-cheat-safety claims ([[feedback_adonis_detection]]).

local RunService = game:GetService("RunService")
local Players    = game:GetService("Players")
local LP         = Players.LocalPlayer

local feature = require("ui.feature")
local log     = require("core.log")
local notify  = require("ui.notify")

local FakeTab = {}

local enabled  = false
local anchored = nil   -- the BasePart we currently hold anchored (so we restore exactly it)
local hbConn   = nil   -- the Heartbeat maintainer (live only while enabled)

-- The part we freeze: Head first (the tab-freeze part), else fall back to the
-- root / any BasePart so the feature still does something on an odd rig.
local function freezePart(char)
    if not char then return nil end
    return char:FindFirstChild("Head")
        or char:FindFirstChild("HumanoidRootPart")
        or char:FindFirstChild("Torso")
        or char:FindFirstChild("UpperTorso")
        or char:FindFirstChildWhichIsA("BasePart")
end

local function release()
    if anchored then pcall(function() anchored.Anchored = false end); anchored = nil end
end

-- Keep the head anchored. Picks up a NEW body after a respawn (the old anchored
-- head died with the old character) and re-asserts if something unanchored us --
-- all without yielding, so the Wave signal/taskwait quirk can't strand it.
local function tick()
    if not enabled then return end
    local char = LP.Character
    local part = freezePart(char)
    if not part then return end
    if anchored ~= part then                 -- first anchor, or a fresh body after respawn
        if anchored then pcall(function() anchored.Anchored = false end) end
        anchored = part
    end
    if not part.Anchored then pcall(function() part.Anchored = true end) end
    -- stop the walk animation from moonwalking in place while we're pinned
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then pcall(function() hum:Move(Vector3.zero, false) end) end
end

local function setActive(v)
    v = v and true or false
    if enabled == v then return end

    if v then
        if not LP.Character then
            notify.warn("Fake Tab: no character to freeze")
            return   -- leave disabled; toggling again once spawned works
        end
        enabled = true
        if not hbConn then hbConn = RunService.Heartbeat:Connect(tick) end
        tick()   -- anchor immediately; the Heartbeat maintains it from here
        notify.success("Fake Tab ON -- frozen (head anchored), FPS untouched")
    else
        enabled = false
        if hbConn then pcall(function() hbConn:Disconnect() end); hbConn = nil end
        release()
        notify.info("Fake Tab OFF -- thawed")
    end
end

function FakeTab.register(box)
    box:add(feature.declare({
        id          = "misc.faketab",
        name        = "Fake Tab",
        description = "Reproduces alt-tab \"tabbing\": freezes your character in place by anchoring your head -- the whole rig is rigidly joined to it, so you lock up and stop replicating movement (others see you stuck still and you stop taking knockback / combos) -- but WITHOUT dropping your own FPS to zero, so you keep full vision, camera and aim. Survives respawns while it's on. Bind a key below to flick it on/off like real alt-tabbing. You can't move while frozen -- toggle off to resume.",
        default     = false,
        onToggle    = setActive,
    }).root)

    log.info("Fake Tab feature registered")
end

function FakeTab.destroy()
    enabled = false
    if hbConn then pcall(function() hbConn:Disconnect() end); hbConn = nil end
    release()
end

return FakeTab
