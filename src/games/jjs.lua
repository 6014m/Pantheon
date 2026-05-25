-- Jujutsu Shenanigans (PlaceId 17016840407) integration.
--
-- Registered into the game registry; its container only appears when you're
-- actually in JJS -- init.lua calls registry.current().register() gated on
-- game.PlaceId, so this never shows in other games.
--
-- Feature: Nanami "Perfect Special" -- auto-times Salaryman's R special, Ratio
-- Point (NanamiService.RE.RightActivated). Per the JJS wiki, Ratio Point marks a
-- target within 70 STUDS and runs a quick-time event whose timing speeds up as
-- the target's HP drops; this fires the confirm after an HP-scaled delay so it
-- lands on the ratio. Ported from the old lock-on script, which used a wrong
-- 27-stud range -- corrected to the wiki's 70.

local registry  = require("games.registry")
local window    = require("ui.window")
local container = require("ui.container")
local feature   = require("ui.feature")
local state     = require("modules.aim.state")
local targeting = require("modules.aim.targeting")
local shiftlock = require("modules.aim.shiftlock")
local log       = require("core.log")

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- JJS spans multiple places (17016840407 = "Lobby", 9391468976 = experience root)
-- under ONE GameId 3508322461 (grabbed in-game; matches the legacy script's id).
-- registry.current() checks game.GameId, so the GameId entry covers EVERY place /
-- VIP server in one go; the place ids are just extra redundancy.
local JJS_IDS = { 3508322461, 17016840407, 9391468976 }   -- GameId first, then known places

local JJS = {}

local CFG = {
    range    = 70,     -- studs -- wiki: Ratio Point marks a target within 70 studs
    delayHi  = 0.63,   -- s, target >= 80% HP (QTE slower early-fight)
    delayLo  = 0.55,   -- s, target <  80% HP (QTE faster as HP drops)
    hpThresh = 80,     -- % HP threshold between the two timings
}
local enabled = false

local function rootOf(c) return c and c:FindFirstChild("HumanoidRootPart") end

-- Prefer the Target Select / Lock-On target; fall back to the nearest valid
-- target so it still works if you haven't engaged Target Select first.
local function targetChar()
    local t = state.target
    if t then
        return (state.target_type == "npc") and t or t.Character
    end
    local best = targeting.getBestTarget()
    return best and best.Character or nil
end

local function ratioPointPerfect()
    if not enabled then return end
    local tChar = targetChar()
    if not tChar then return end
    local myRoot, tRoot = rootOf(Players.LocalPlayer.Character), rootOf(tChar)
    if not (myRoot and tRoot) then return end
    if (myRoot.Position - tRoot.Position).Magnitude > CFG.range then return end
    local hum = tChar:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    local hpPct = (hum.Health / math.max(hum.MaxHealth, 1)) * 100
    local delay = (hpPct < CFG.hpThresh) and CFG.delayLo or CFG.delayHi
    task.delay(delay, function()
        pcall(function()
            ReplicatedStorage.Knit.Knit.Services.NanamiService.RE.RightActivated:FireServer(tChar)
        end)
    end)
end

function JJS.register()
    -- JJS ships its own shiftlock, which fights Pantheon's. Auto-engage mirror mode
    -- so Pantheon FOLLOWS the game's shiftlock (writes nothing) instead of running a
    -- competing one -- this is the per-game "register the shiftlock with JJS" fix.
    -- Runs at load, BEFORE any shiftlock-enable, so the foreign sweep never kills
    -- the game's shiftlock we want to follow.
    shiftlock.setShiftlockMirror(true)

    local box = container.new(window.parent(), "Jujutsu Shenanigans")
    box:add(feature.declare({
        id          = "jjs.nanami_special",
        name        = "Nanami Perfect Special",
        description = "Auto-times Salaryman's R special, Ratio Point, onto your target. With a target within 70 studs (wiki range), pressing the key fires Ratio Point after an HP-timed delay so the confirm lands on the ratio QTE (the QTE speeds up at lower HP). Uses your Target Select / Lock-On target, else the nearest player.",
        default     = false,
        defaultKey  = Enum.KeyCode.R,
        onToggle    = function(v) enabled = v and true or false end,
        onKey       = function() ratioPointPerfect() end,
    }).root)
    log.info("JJS module registered -- Nanami Perfect Special (Ratio Point, 70-stud range)")
end

registry.register(JJS_IDS, JJS)

return JJS
