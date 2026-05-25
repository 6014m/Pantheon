-- Per-game module registry. Keys are tostring(id), where id is either a PlaceId
-- or a GameId (universe id). A game module is a table with a .register() function.
--
-- Matching by GameId is the robust option: a game can have many PlaceIds (lobby,
-- combat, VIP servers) that all share ONE GameId, so registering under the GameId
-- catches every place. registry.current() checks both game.PlaceId and game.GameId.

local games = {}
local registry = {}

-- ids may be a single id or a list of ids (place ids and/or the game id).
function registry.register(ids, mod)
    if type(ids) == "table" then
        for _, id in ipairs(ids) do games[tostring(id)] = mod end
    else
        games[tostring(ids)] = mod
    end
end

function registry.current()
    return games[tostring(game.PlaceId)] or games[tostring(game.GameId)]
end

function registry.all()
    return games
end

return registry
