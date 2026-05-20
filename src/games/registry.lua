-- Per-game module registry. Keys are tostring(PlaceId).
-- A game module is just a table with a .register(window) function.

local games = {}
local registry = {}

function registry.register(placeId, mod)
    games[tostring(placeId)] = mod
end

function registry.current()
    return games[tostring(game.PlaceId)]
end

function registry.all()
    return games
end

return registry
