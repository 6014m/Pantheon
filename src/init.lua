-- Pantheon entry point. Boots persist + keybinds + window, registers modules,
-- and stashes a shutdown handle on the executor's global env so a second
-- loadstring() of Pantheon tears down the previous instance before starting
-- fresh (no duplicate GUIs, stacked input listeners, or hook layering).

local log      = require("core.log")
local env      = require("core.env")
local persist  = require("core.persist")
local keybinds   = require("core.keybinds")
local window     = require("ui.window")
local container  = require("ui.container")
local notify     = require("ui.notify")
local components = require("ui.components")
local registry   = require("games.registry")

local genv = (env.getgenv and env.getgenv()) or _G

-- Tear down any previously-loaded Pantheon instance. Uses getgenv() (not _G)
-- because Wave/Synapse-style executors share getgenv across loadstring calls;
-- _G is the Roblox-sandbox-local table and would forget across reloads.
if genv.Pantheon and type(genv.Pantheon.shutdown) == "function" then
    log.info("replacing previously loaded Pantheon instance")
    local ok, err = pcall(genv.Pantheon.shutdown)
    if not ok then log.warn("previous shutdown errored: " .. tostring(err)) end
end
genv.Pantheon = {}

log.info("booting on executor: " .. tostring(env.executor))

persist.init()
keybinds.init()
window.init()

-- The single navigator menu: built first so it's the left-most panel and stays
-- visible. Every container created after this starts hidden and is opened/closed
-- from the navigator (Wurst-style) instead of all menus showing at once.
local nav = container.buildNavigator(window.parent(), "Menu")
container.startHidden = true

-- Universal modules
local aim = require("modules.aim.init")
aim.register()

local friendlies = require("modules.friendlies")
friendlies.register()

local tech = require("modules.tech.init")
tech.register()

local system = require("modules.system")
system.register()

local aesthetic = require("modules.aesthetic")
aesthetic.register()

-- Per-game modules self-register on require; pull them in so registry.current()
-- can find one for this PlaceId. (Requiring in a non-matching game just adds to
-- the registry table; its .register() only runs if the PlaceId matches.)
require("games.jjs")

-- Per-game module (if registered for this PlaceId)
local gameMod = registry.current()
if gameMod and gameMod.register then
    log.info("game module found for PlaceId " .. tostring(game.PlaceId))
    local ok, err = pcall(gameMod.register)
    if not ok then log.err("game module register failed: " .. tostring(err)) end
else
    log.info("no game module for PlaceId " .. tostring(game.PlaceId))
end

-- Every module (and any per-game one) has now created its containers; fill the
-- navigator with a toggle row per menu. They start closed -- click a row to open.
nav.populate()

-- Expose the teardown so a future re-execute can call it.
-- Order matters: aim first (it stops render binds and unhooks the UIS
-- __newindex, so leftover input events from the about-to-die UI don't reach
-- already-torn-down state), then UI, then keybinds, then persist flush.
genv.Pantheon.shutdown = function()
    -- Per-game module FIRST, while aim/shiftlock are still alive, so it can undo
    -- state it set on register (e.g. JJS force-enables shiftlock PAIR mode).
    -- Without this the game module's register() re-ran on every teleport (Auto
    -- Re-Execute) with no matching teardown.
    pcall(function() if gameMod and gameMod.destroy then gameMod.destroy() end end)
    pcall(function() if aim.destroy      then aim.destroy()      end end)
    pcall(function() if friendlies.destroy then friendlies.destroy() end end)
    pcall(function() if tech.destroy     then tech.destroy()     end end)
    pcall(function() if system.destroy   then system.destroy()   end end)
    pcall(function() if aesthetic.destroy then aesthetic.destroy() end end)
    pcall(function() if window.destroy     then window.destroy()     end end)
    pcall(function() if components.destroy then components.destroy() end end)
    pcall(function() if notify.destroy     then notify.destroy()     end end)
    pcall(function() if keybinds.destroy then keybinds.destroy() end end)
    pcall(function() if persist.flush    then persist.flush()    end end)
end

local buildTag = rawget(_G, "PANTHEON_BUILD") or "?"
notify.success("Pantheon loaded (" .. tostring(buildTag) .. "). Press RightCtrl to toggle UI.")

return true
