-- Addon-facing API.
--
-- Every addon script is run with a global `Pantheon` (this module's .Pantheon
-- table) -- the same idea as Infinite Yield handing addons its command API. An
-- addon's ONLY required call is:
--
--     local addon = Pantheon.register({
--         name        = "My Addon",
--         description = "what it does",
--         scope       = "universal",        -- or a PlaceId/GameId number, a list
--                                           --   of them, or "char:CharacterName"
--         setup = function(ctx)
--             -- Runs ONLY when the addon is ACTIVE (enabled in the Addons menu
--             -- AND its scope matches the current game). Build the addon's UI
--             -- and start its logic here -- nothing game-specific should run at
--             -- file top level, so a disabled / wrong-game addon stays inert.
--             local m = ctx:menu()                       -- a navigator menu (its own panel)
--             m:toggle("Cool Thing", { default = false, description = "..." }, function(on) ... end)
--             m:button("Do It", function() ... end)
--             m:slider("Speed", { min = 0, max = 100, default = 50 }, function(v) ... end)
--             m:keybind("Trigger", { default = "G" }, function() ... end)
--             ctx:connect(game:GetService("RunService").Heartbeat, function(dt) ... end)  -- auto-disconnected
--             ctx:onUnload(function() ... end)           -- runs when toggled off / reloaded / on re-execute
--         end,
--     })
--
-- Everything built through `ctx` (menus, features, keybinds, connections) is
-- tracked so the Addons manager can fully tear the addon down when you toggle it
-- off, reload it, or re-execute Pantheon -- no leaks, no orphan menus.
--
-- Power users can also reach the raw building blocks on the Pantheon table
-- (Pantheon.feature, .components, .container, .notify, .persist, .keybinds, ...).

local feature    = require("ui.feature")
local container  = require("ui.container")
local components = require("ui.components")
local window     = require("ui.window")
local notify     = require("ui.notify")
local keybinds   = require("core.keybinds")
local persist    = require("core.persist")
local log        = require("core.log")

local API = {}

-- Defs registered during the current file's load pass. init.lua sets the current
-- file, runs the chunk (which calls Pantheon.register), then takes the list.
local registered  = {}
local currentFile = nil

function API.setCurrentFile(name) currentFile = name end
function API.takeRegistered()
    local out = registered
    registered = {}
    return out
end

local function toKeyCode(k)
    if k == nil then return nil end
    if typeof(k) == "EnumItem" then return k end
    local ok, kc = pcall(function() return Enum.KeyCode[tostring(k)] end)
    return (ok and kc) or nil
end

-- ===== per-addon context =====
-- Built at ACTIVATION (enabled + scope match). Tracks everything the addon makes
-- so :destroy() (called by the manager) reverses all of it.
function API.makeContext(def)
    local ctx = { name = def.name, id = def.id, scope = def.scope }
    local pfx = "addon." .. def.id .. "."

    local menus     = {}   -- container objects the addon created
    local conns     = {}   -- tracked signal connections
    local keyIds    = {}   -- keybind ids to clear (feature master keys + ctx keybinds)
    local unloadCbs = {}

    -- per-addon persistence, namespaced so two addons can't clash (per-game store)
    ctx.persist = {
        get = function(k, d) return persist.get(pfx .. k, d) end,
        set = function(k, v) persist.set(pfx .. k, v) end,
    }
    function ctx:notify(msg, dur) pcall(notify.info, "[" .. def.name .. "] " .. tostring(msg), dur or 4) end
    function ctx:log(msg) log.info("[addon:" .. def.id .. "] " .. tostring(msg)) end

    -- Connect a signal and have it auto-disconnected on teardown.
    function ctx:connect(signal, fn)
        local ok, c = pcall(function() return signal:Connect(fn) end)
        if ok and c then conns[#conns + 1] = c; return c end
        return nil
    end
    function ctx:onUnload(fn) if type(fn) == "function" then unloadCbs[#unloadCbs + 1] = fn end end

    -- A menu = a navigator container this addon owns. Items wrap feature/components.
    function ctx:menu(title)
        local box = container.new(window.parent(), title or def.name)
        menus[#menus + 1] = box
        local menu = { container = box }

        -- Full feature row (toggle + optional settings array: sliders / keybinds /
        -- buttons / dropdowns inside its cog panel). The power API.
        function menu:feature(fdef)
            fdef = fdef or {}
            fdef.id = fdef.id or (pfx .. persist.slug(fdef.name or "feature"))
            keyIds[#keyIds + 1] = fdef.id   -- so unload clears its master keybind
            local h = feature.declare(fdef)
            box:add(h.root)
            return h
        end
        function menu:toggle(name, opts, cb)
            opts = opts or {}
            return self:feature({
                name = name, description = opts.description,
                default = opts.default, onToggle = cb,
                defaultKey = toKeyCode(opts.key),
                settings = opts.settings,
            })
        end
        function menu:button(name, cb)
            local f = components.Button(box.features, { text = name, onClick = cb })
            box:add(f); return f
        end
        function menu:label(text)   local f = components.Label(box.features, text);   box:add(f); return f end
        function menu:section(text) local f = components.Section(box.features, text); box:add(f); return f end
        function menu:slider(name, opts, cb)
            opts = opts or {}
            local skey = persist.slug(name)
            local h = components.Slider(box.features, {
                text = name, min = opts.min, max = opts.max, step = opts.step,
                default = ctx.persist.get(skey, opts.default),
                onChange = function(v) ctx.persist.set(skey, v); if cb then cb(v) end end,
            })
            box:add(h.frame); return h
        end
        function menu:dropdown(name, opts, cb)
            opts = opts or {}
            local skey = persist.slug(name)
            local h = components.Dropdown(box.features, {
                label = name, options = opts.options,
                default = ctx.persist.get(skey, opts.default),
                onChange = function(v) ctx.persist.set(skey, v); if cb then cb(v) end end,
            })
            box:add(h.frame); return h
        end
        function menu:textbox(name, opts, cb)
            opts = opts or {}
            local skey = persist.slug(name)
            local h = components.TextBox(box.features, {
                label = name, placeholder = opts.placeholder,
                default = ctx.persist.get(skey, opts.default),
                onChange = function(v) ctx.persist.set(skey, v); if cb then cb(v) end end,
            })
            box:add(h.frame); return h
        end
        function menu:keybind(name, opts, onPress, onRelease)
            opts = opts or {}
            local kid   = pfx .. "key." .. persist.slug(name)
            keyIds[#keyIds + 1] = kid
            local saved = persist.stringToKey(persist.get(kid .. ".bind"))
            local eff   = saved or toKeyCode(opts.default)
            if eff and eff ~= Enum.KeyCode.Unknown then keybinds.set(kid, eff, onPress, onRelease) end
            local h = components.KeybindSetter(box.features, {
                label = name, default = eff,
                onChange = function(k)
                    keybinds.set(kid, k, onPress, onRelease)
                    persist.set(kid .. ".bind", persist.keyToString(k))
                end,
            })
            box:add(h.frame); return h
        end
        return menu
    end

    -- Full teardown: run unload callbacks, drop connections, clear keybinds,
    -- destroy menus. Safe to call once; the manager calls it on disable/reload/exit.
    function ctx._destroy()
        for _, fn in ipairs(unloadCbs) do pcall(fn) end
        for _, c in ipairs(conns)     do pcall(function() c:Disconnect() end) end
        for _, id in ipairs(keyIds)   do pcall(function() keybinds.clear(id) end) end
        for _, box in ipairs(menus)   do pcall(function() box:destroy() end) end
        menus, conns, keyIds, unloadCbs = {}, {}, {}, {}
    end

    return ctx
end

-- ===== the global `Pantheon` table handed to every addon =====
API.Pantheon = {
    register = function(def)
        if type(def) ~= "table" then
            log.warn("[addons] Pantheon.register expects a table"); return
        end
        if type(def.setup) ~= "function" then
            log.warn("[addons] addon '" .. tostring(def.name) .. "' has no setup(ctx) function")
        end
        def.file = currentFile
        registered[#registered + 1] = def
        return def
    end,

    -- raw building blocks for power users (the high-level ctx:menu API covers most)
    feature    = feature,
    components = components,
    container  = container,
    window     = window,
    notify     = notify,
    keybinds   = keybinds,
    persist    = persist,
    log        = log,
    getService = function(n) return game:GetService(n) end,
}

return API
