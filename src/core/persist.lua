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
local GLOBAL_FILE     = SETTINGS_FOLDER .. "/global.json"   -- cross-game store (e.g. saved shaders)

local persist = {}

local cache         = {}
local loaded        = false
local saveScheduled = false

local globalCache         = {}
local globalLoaded        = false
local globalSaveScheduled = false

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
-- ---- Global (cross-game) store --------------------------------------------
-- A second store NOT keyed by GameId, for things that should follow the user to
-- every game (e.g. saved shader presets). Same debounced-write model.
local function loadGlobal()
    if globalLoaded then return end
    globalLoaded = true
    if not env.readfile or not env.isfile then return end
    if not env.isfile(GLOBAL_FILE) then return end
    local ok, content = pcall(env.readfile, GLOBAL_FILE)
    if ok and content and #content > 0 then globalCache = jsonDecode(content) or {} end
end

function persist.getGlobal(key, default)
    loadGlobal()
    local v = globalCache[key]
    if v == nil then return default end
    return v
end

local function writeGlobalNow()
    if not env.writefile then return end
    ensureFolders()
    local ok, err = pcall(env.writefile, GLOBAL_FILE, jsonEncode(globalCache))
    if not ok then log.warn("persist: global save failed: " .. tostring(err)) end
end

-- No value-dedup: callers (e.g. shader presets) mutate a table in place and pass
-- the same reference, so an == check would wrongly skip the save.
function persist.setGlobal(key, value)
    loadGlobal()
    globalCache[key] = value
    if not globalSaveScheduled and env.writefile then
        globalSaveScheduled = true
        task.delay(SAVE_DELAY, function() globalSaveScheduled = false; writeGlobalNow() end)
    end
end

function persist.flush()
    saveScheduled = false
    if loaded then writeNow() end
    globalSaveScheduled = false
    if globalLoaded then writeGlobalNow() end
end

-- ---- KeyCode <-> string helpers -------------------------------------------
-- Enum.KeyCode values are userdata; HttpService:JSONEncode can't serialize
-- them. We persist the short name ("LeftShift") and rehydrate via
-- Enum.KeyCode[name]. Empty string represents an explicit "unbound" choice;
-- nil means "never saved, use the declared default."

function persist.keyToString(k)
    if not k then return nil end
    if k == Enum.KeyCode.Unknown then return "" end
    local s = tostring(k)
    -- Mouse-button binds (UserInputType) are tagged so rehydration knows to
    -- look them up in Enum.UserInputType rather than Enum.KeyCode.
    if s:find("Enum.UserInputType.") then
        return "UIT:" .. (s:gsub("Enum.UserInputType.", ""))
    end
    return (s:gsub("Enum.KeyCode.", ""))
end

function persist.stringToKey(s)
    if s == nil then return nil end
    if s == "" then return Enum.KeyCode.Unknown end
    local uit = s:match("^UIT:(.+)$")
    if uit then return Enum.UserInputType[uit] or Enum.KeyCode.Unknown end
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
