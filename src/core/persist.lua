-- Per-game settings persistence. Each Roblox universe (game.GameId) gets its
-- own JSON file at Pantheon/settings/<gameId>.json so toggles, sliders, and
-- keybinds the user changes in one game don't bleed into another. Keying on
-- GameId (the universe) instead of PlaceId means settings follow a game across
-- all its places -- a lobby place and the main place share one config.
-- Mutations are kept in an in-memory cache and flushed to disk on a 0.5s
-- debounce, so dragging a slider doesn't hammer the filesystem.

local env = require("core.env")
local log = require("core.log")

local FOLDER          = "Pantheon"
local SETTINGS_FOLDER = FOLDER .. "/settings"
local SAVE_DELAY      = 0.5

local persist = {}

local cache         = {}
local loaded        = false
local saveScheduled = false

local function gameFile()
    return SETTINGS_FOLDER .. "/" .. tostring(game.GameId) .. ".json"
end

local function ensureFolders()
    if not env.makefolder or not env.isfolder then return end
    if not env.isfolder(FOLDER)          then env.makefolder(FOLDER)          end
    if not env.isfolder(SETTINGS_FOLDER) then env.makefolder(SETTINGS_FOLDER) end
end

local function jsonEncode(t)
    local HttpService = game:GetService("HttpService")
    local ok, s = pcall(HttpService.JSONEncode, HttpService, t)
    return ok and s or "{}"
end

local function jsonDecode(s)
    local HttpService = game:GetService("HttpService")
    local ok, t = pcall(HttpService.JSONDecode, HttpService, s)
    return ok and t or {}
end

function persist.init()
    if loaded then return end
    loaded = true
    if not env.readfile or not env.isfile then
        log.info("persist: filesystem APIs unavailable, persistence disabled")
        return
    end
    local file = gameFile()
    if not env.isfile(file) then
        log.info("persist: no saved settings for GameId " .. tostring(game.GameId))
        return
    end
    local ok, content = pcall(env.readfile, file)
    if ok and content and #content > 0 then
        cache = jsonDecode(content) or {}
        log.info("persist: loaded settings for GameId " .. tostring(game.GameId))
    end
end

function persist.get(key, default)
    if not loaded then persist.init() end
    local v = cache[key]
    if v == nil then return default end
    return v
end

local function writeNow()
    if not env.writefile then return end
    ensureFolders()
    local ok, err = pcall(env.writefile, gameFile(), jsonEncode(cache))
    if not ok then
        log.warn("persist: save failed: " .. tostring(err))
    end
end

function persist.scheduleSave()
    if saveScheduled then return end
    if not env.writefile then return end
    saveScheduled = true
    task.delay(SAVE_DELAY, function()
        saveScheduled = false
        writeNow()
    end)
end

function persist.set(key, value)
    if not loaded then persist.init() end
    if cache[key] == value then return end
    cache[key] = value
    persist.scheduleSave()
end

-- Remove every cached key starting with `prefix` (e.g. "ui.pos." to wipe saved
-- panel positions). Schedules a save if anything changed.
function persist.clearPrefix(prefix)
    if not loaded then persist.init() end
    local changed = false
    for k in pairs(cache) do
        if type(k) == "string" and string.sub(k, 1, #prefix) == prefix then
            cache[k] = nil
            changed = true
        end
    end
    if changed then persist.scheduleSave() end
end

-- Synchronous flush. Called by the shutdown teardown so pending debounced
-- writes aren't lost when the user re-executes Pantheon mid-debounce.
function persist.flush()
    if not loaded then return end
    saveScheduled = false
    writeNow()
end

-- ---- KeyCode <-> string helpers -------------------------------------------
-- Enum.KeyCode values are userdata; HttpService:JSONEncode can't serialize
-- them. We persist the short name ("LeftShift") and rehydrate via
-- Enum.KeyCode[name]. Empty string represents an explicit "unbound" choice;
-- nil means "never saved, use the declared default."

function persist.keyToString(k)
    if not k then return nil end
    if k == Enum.KeyCode.Unknown then return "" end
    return (tostring(k):gsub("Enum.KeyCode.", ""))
end

function persist.stringToKey(s)
    if s == nil then return nil end
    if s == "" then return Enum.KeyCode.Unknown end
    return Enum.KeyCode[s] or Enum.KeyCode.Unknown
end

-- Slug a human-readable setting name so it can be a stable file key. If the
-- user renames a setting we'll lose the old saved value — opt-in workaround
-- is to pass an explicit `key = "..."` field on the setting declaration.

function persist.slug(s)
    if not s or s == "" then return "_" end
    s = string.lower(s)
    s = string.gsub(s, "[^%w]+", "_")
    s = string.gsub(s, "^_+", "")
    s = string.gsub(s, "_+$", "")
    if s == "" then return "_" end
    return s
end

function persist.all() return cache end

return persist
