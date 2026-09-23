-- Dodge or Die (PlaceId 131794278839305) integration.
--
-- Wraps Ball Reaction 1.8.9 -- a third-party predictive auto-dodge, vendored
-- verbatim in games/dodgeordie_ballreaction.lua (MIT, pinned to upstream
-- 710136b). Pantheon's row is a start/stop switch; Ball Reaction brings its own
-- Fluent panel, which is where its ~40 knobs live (margin, horizon, orient,
-- jump, lava, lasers, the replay debugger...).
--
-- Two things worth knowing before flipping it on:
--
--   * ORIENT MODE rotates your character to aim a dodge. The game's dodges are
--     Q/E/R = Left/Right/Forward RELATIVE TO FACING, so only three world
--     directions exist without it. Orient generates 16 world angles and, for
--     each, picks whichever dodge key is off cooldown, sets AutoRotate=false and
--     hard-writes HumanoidRootPart.CFrame so that key's direction lands on the
--     angle it wants -- re-asserted every frame for 0.14s, then AutoRotate is
--     restored. That snap is the single most visible thing this script does.
--     It is ON by default upstream; Ball Reaction's own panel turns it off,
--     which falls back to plain camera-relative Q/E/R.
--
--   * It reads YOUR keybinds from Player.Keybinds.PC.DodgeLeft/DodgeRight/
--     DodgeFront, and reads dodge cooldowns off the game's own
--     PlayerGui.PCControlsUI overlay rather than guessing -- so rebinds and
--     cooldown state are both handled without configuration.
--
-- Teardown: the factory returns { Destroy, Stats, SelfTest }. Destroy()
-- disconnects everything, unbinds its render step, releases held keys, restores
-- AutoRotate and destroys its Fluent UI, so a Pantheon re-execute or a toggle
-- OFF leaves nothing behind.

local registry  = require("games.registry")
local window    = require("ui.window")
local container = require("ui.container")
local feature   = require("ui.feature")
local notify    = require("ui.notify")
local log       = require("core.log")

local DOD_IDS = { 131794278839305 }

local DodgeOrDie = {}

local handle   -- { Destroy, Stats, SelfTest } while running, nil while stopped

local function stop()
    if not handle then return end
    local h = handle
    handle = nil
    local ok, err = pcall(h.Destroy)
    if not ok then log.warn("Ball Reaction teardown errored: " .. tostring(err)) end
end

local function start()
    if handle then return true end
    -- The whole bundle is one chunk, so the payload is compiled at load either
    -- way; what the bundle's lazy require() buys is that its body is never
    -- ENTERED (no services grabbed, no GUI built) until someone flips this on.
    local ok, factory = pcall(require, "games.dodgeordie_ballreaction")
    if not ok then
        log.err("Ball Reaction module failed to load: " .. tostring(factory))
        notify.warn("Ball Reaction failed to load (see console).")
        return false
    end
    local started, result = pcall(factory)
    if not started then
        log.err("Ball Reaction failed to start: " .. tostring(result))
        notify.warn("Ball Reaction failed to start (see console).")
        return false
    end
    if type(result) ~= "table" or type(result.Destroy) ~= "function" then
        log.err("Ball Reaction returned no teardown handle")
        notify.warn("Ball Reaction started but cannot be stopped -- reload Pantheon.")
        return false
    end
    handle = result
    return true
end

function DodgeOrDie.register()
    log.info("Dodge or Die module REGISTER on PlaceId=" .. tostring(game.PlaceId))

    local box = container.new(window.parent(), "Dodge or Die")
    box:add(feature.declare({
        id          = "dod.ball_reaction",
        name        = "Ball Reaction (auto dodge)",
        description = "Third-party predictive auto-dodge (Ball Reaction 1.8.9 by projectsMy123-hub, MIT, vendored at commit 710136b). Simulates every ball's trajectory -- including wall bounces and homing -- scores 16 world directions against ALL of them at once, and dodges into the safest gap. Learns each ball's homing strength, acceleration, turn rate and reaction delay live, and widens its safety margin when its own predictions stop matching. A separate 60Hz safety check runs independently of the planner and can cancel a dash mid-flight. Turning this ON opens Ball Reaction's own Fluent panel, which holds all of its settings; RightShift opens its menu and replay debugger, F8 stops its auto dodge. Heads up: its Orient mode rotates your character (AutoRotate off plus a hard CFrame write for 0.14s) to aim dodges at angles Q/E/R cannot reach on their own -- that snap is very visible. Turn Orient off in its panel for plain camera-relative dodges.",
        default     = false,
        onToggle    = function(v)
            if v then
                if start() then notify.success("Ball Reaction loaded -- see its own panel for settings.") end
            else
                stop()
                notify.info("Ball Reaction unloaded.")
            end
        end,
        settings = {
            { type = "button", name = "Print stats to console", onClick = function()
                if not handle or type(handle.Stats) ~= "function" then
                    log.info("Ball Reaction is not running.")
                    return
                end
                local ok, s = pcall(handle.Stats)
                if not ok or type(s) ~= "table" then
                    log.warn("Ball Reaction stats failed: " .. tostring(s))
                    return
                end
                -- The rotation trick is the part most worth watching: if oriented
                -- dashes climb but verified ones do not, the CFrame write is not
                -- taking and it is silently dodging into nothing.
                log.info(string.format("Ball Reaction %s | auto=%s status=%s",
                    tostring(s.version), tostring(s.auto), tostring(s.status)))
                log.info(string.format("  threats=%d (targeted=%d) nearest=%.1f clearance=%.2f confidence=%.2f",
                    s.balls or 0, s.targeted or 0, s.nearest or 0,
                    s.clearance or 0, s.predictionConfidence or 0))
                log.info(string.format("  dashes: oriented=%d verified=%d UNCONFIRMED=%d | orient=%s",
                    s.orientedDashes or 0, s.verifiedDashes or 0,
                    s.unconfirmedDashes or 0, tostring(s.orient)))
                log.info(string.format("  planner=%dHz p95=%.1fms | collisionPreds=%d bouncePreds=%d emergencyReplans=%d",
                    s.plannerHz or 0, s.p95PlanningMs or 0, s.collisionPredictions or 0,
                    s.bouncePredictions or 0, s.emergencyReplans or 0))
            end },
            { type = "button", name = "Run its self-test", onClick = function()
                if not handle or type(handle.SelfTest) ~= "function" then
                    log.info("Ball Reaction is not running.")
                    return
                end
                local ok, result = pcall(handle.SelfTest)
                if not ok then log.warn("self-test errored: " .. tostring(result)); return end
                local passed, failed = 0, {}
                if type(result) == "table" then
                    for name, value in pairs(result) do
                        if value == true then passed = passed + 1 else table.insert(failed, name) end
                    end
                end
                log.info(string.format("Ball Reaction self-test: %d passed, %d failed", passed, #failed))
                for _, name in ipairs(failed) do log.warn("  FAILED: " .. tostring(name)) end
            end },
        },
    }).root)

    log.info("Dodge or Die module registered -- Ball Reaction available (starts on toggle)")
end

-- init.lua's shutdown calls this on re-execute / Auto Re-Execute / unload.
function DodgeOrDie.destroy()
    stop()
end

registry.register(DOD_IDS, DodgeOrDie)

return DodgeOrDie
