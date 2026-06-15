-- Pantheon dev loader.
-- Fetches each src/*.lua live with a cache-bust query, assembles the same
-- require shim the bundle uses, and boots from src/init.lua.
-- For releases, users should load dist/main.lua instead.

local REPO_RAW = "https://raw.githubusercontent.com/6014m/Pantheon/main/"

local _MODULES, _LOADED = {}, {}

local function require_(name)
    if _LOADED[name] ~= nil then return _LOADED[name] end
    local m = _MODULES[name]
    if not m then error("[Pantheon] module not found: " .. tostring(name)) end
    _LOADED[name] = true
    local r = m()
    _LOADED[name] = (r == nil) and true or r
    return _LOADED[name]
end

local function fetch(rel)
    return game:HttpGet(REPO_RAW .. "src/" .. rel .. "?v=" .. tostring(tick()), true)
end

local function loadModule(name, rel)
    local src = fetch(rel)
    local chunk, err = loadstring(src, "=[Pantheon:" .. name .. "]")
    if not chunk then
        error("[Pantheon] compile failed for " .. name .. ": " .. tostring(err))
    end
    local penv = setmetatable({ require = require_ }, { __index = getfenv() })
    setfenv(chunk, penv)
    _MODULES[name] = chunk
end

-- Keep in sync with BUILD_ORDER in tools/build.py
local files = {
    { "core.env",                  "core/env.lua" },
    { "core.signal",               "core/signal.lua" },
    { "core.log",                  "core/log.lua" },
    { "core.persist",              "core/persist.lua" },
    { "core.keybinds",             "core/keybinds.lua" },
    { "ui.theme",                  "ui/theme.lua" },
    { "ui.hex",                    "ui/hex.lua" },
    { "ui.components",             "ui/components.lua" },
    { "ui.window",                 "ui/window.lua" },
    { "ui.container",              "ui/container.lua" },
    { "ui.feature",                "ui/feature.lua" },
    { "ui.notify",                 "ui/notify.lua" },
    { "games.registry",            "games/registry.lua" },
    { "modules.aim.state",         "modules/aim/state.lua" },
    { "modules.aim.targeting",     "modules/aim/targeting.lua" },
    { "modules.aim.highlight",     "modules/aim/highlight.lua" },
    { "modules.aim.shiftlock",     "modules/aim/shiftlock.lua" },
    { "modules.aim.rotation_lock", "modules/aim/rotation_lock.lua" },
    { "modules.aim.lockon",        "modules/aim/lockon.lua" },
    { "modules.aim.target_select", "modules/aim/target_select.lua" },
    { "modules.aim.init",          "modules/aim/init.lua" },
    { "modules.tech.engine",       "modules/tech/engine.lua" },
    { "modules.tech.scanner",      "modules/tech/scanner.lua" },
    { "modules.tech.dumper",       "modules/tech/dumper.lua" },
    { "modules.tech.canvas_ui",    "modules/tech/canvas_ui.lua" },
    { "modules.tech.builder_ui",   "modules/tech/builder_ui.lua" },
    { "modules.tech.init",         "modules/tech/init.lua" },
    { "modules.system",            "modules/system.lua" },
    { "modules.aesthetic",         "modules/aesthetic.lua" },
    { "modules.misc.faketab",      "modules/misc/faketab.lua" },
    { "modules.misc.freecam",      "modules/misc/freecam.lua" },
    { "modules.misc.init",         "modules/misc/init.lua" },
    { "modules.addons.api",        "modules/addons/api.lua" },
    { "modules.addons.init",       "modules/addons/init.lua" },
    { "games.jjs",                 "games/jjs.lua" },
    { "games.evilplate",           "games/evilplate.lua" },
    { "init",                      "init.lua" },
}

for _, e in ipairs(files) do loadModule(e[1], e[2]) end

return require_("init")
