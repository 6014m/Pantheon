-- Save/load persistent settings via the executor's filesystem APIs.

local env = require("core.env")
local log = require("core.log")

local FOLDER = "Pantheon"
local FILE   = FOLDER .. "/settings.json"

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

local persist = {}

function persist.load()
    if not env.readfile or not env.isfile then return {} end
    if not env.isfile(FILE) then return {} end
    local ok, content = pcall(env.readfile, FILE)
    if not ok then return {} end
    return jsonDecode(content)
end

function persist.save(data)
    if not env.writefile then return false end
    if env.makefolder and env.isfolder and not env.isfolder(FOLDER) then
        env.makefolder(FOLDER)
    end
    local ok, err = pcall(env.writefile, FILE, jsonEncode(data))
    if not ok then
        log.warn("persist.save failed:", err)
        return false
    end
    return true
end

return persist
