-- Pantheon entry point. Wires the runtime together and registers modules.

local log      = require("core.log")
local env      = require("core.env")
local window   = require("ui.window")
local notify   = require("ui.notify")
local registry = require("games.registry")

log.info("booting on executor:", env.executor)

local w = window.new("Pantheon")

-- Universal modules
do
    local aim = require("modules.aim.init")
    aim.register(w)
end

-- Per-game module (if registered for this PlaceId)
local gameMod = registry.current()
if gameMod and gameMod.register then
    log.info("game module found for PlaceId", game.PlaceId)
    local ok, err = pcall(gameMod.register, w)
    if not ok then log.err("game module register failed:", err) end
else
    log.info("no game module for PlaceId", game.PlaceId)
end

notify.success("Pantheon loaded.")

return w
