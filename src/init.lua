-- Pantheon entry point. Boots persist + keybinds + window, registers modules,
-- and stashes a shutdown handle on the executor's global env so a second
-- loadstring() of Pantheon tears down the previous instance before starting
-- fresh (no duplicate GUIs, stacked input listeners, or hook layering).

local log      = require("core.log")
local env      = require("core.env")
local persist  = require("core.persist")
local keybinds = require("core.keybinds")
local window   = require("ui.window")
local notify   = require("ui.notify")
local registry = require("games.registry")

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

-- Universal modules
local aim = require("modules.aim.init")
aim.register()

-- Per-game module (if registered for this PlaceId)
local gameMod = registry.current()
if gameMod and gameMod.register then
    log.info("game module found for PlaceId " .. tostring(game.PlaceId))
    local ok, err = pcall(gameMod.register)
    if not ok then log.err("game module register failed: " .. tostring(err)) end
else
    log.info("no game module for PlaceId " .. tostring(game.PlaceId))
end

-- Expose the teardown so a future re-execute can call it.
-- Order matters: aim first (it stops render binds and unhooks the UIS
-- __newindex, so leftover input events from the about-to-die UI don't reach
-- already-torn-down state), then UI, then keybinds, then persist flush.
genv.Pantheon.shutdown = function()
    pcall(function() if aim.destroy      then aim.destroy()      end end)
    pcall(function() if window.destroy   then window.destroy()   end end)
    pcall(function() if notify.destroy   then notify.destroy()   end end)
    pcall(function() if keybinds.destroy then keybinds.destroy() end end)
    pcall(function() if persist.flush    then persist.flush()    end end)
end

notify.success("Pantheon loaded. Press RightCtrl to toggle UI.")

return true
