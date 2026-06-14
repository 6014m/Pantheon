-- Addons: drop-in user/community scripts that extend Pantheon WITHOUT editing its
-- code -- the same spirit as Infinite Yield's addons.
--
-- An addon is a .lua file in the executor's `Pantheon/addons` folder. On boot we
-- run each enabled file with a global `Pantheon` API (see modules/addons/api.lua);
-- the file calls `Pantheon.register{ name, scope, setup }`. An addon's setup() runs
-- only when it's ENABLED (toggle in this menu) AND its `scope` matches the current
-- game -- so a game-specific addon's feature menu "just shows up" in that game and
-- stays out of every other one, no code edits needed.
--
-- This "Addons" panel is the manager: install an addon from a URL, toggle each one
-- on/off (which builds or tears down its menus), reload the folder, or delete one.
-- Each enabled+matching addon gets its OWN navigator menu (built by its setup()).

local window     = require("ui.window")
local container  = require("ui.container")
local components = require("ui.components")
local notify     = require("ui.notify")
local persist    = require("core.persist")
local log        = require("core.log")
local env        = require("core.env")
local theme      = require("ui.theme")
local registry   = require("games.registry")
local api        = require("modules.addons.api")

local module = {}

local FOLDER       = "Pantheon/addons"
local ENABLED_KEY  = "addons.enabled"   -- cross-game (global) map { [fileId] = bool }

-- fileId -> { id, file, path, defs = { def, ... }, ctxs = { ctx, ... }, active, err }
local entries   = {}
local box                       -- the "Addons" manager container
local listFrame                 -- holder the installed-addon rows rebuild into
local rebuildList               -- forward decl (manager row builder)

-- ---- helpers ----

local function fsReady()
    return env.listfiles and env.readfile and env.isfile and env.writefile and env.makefolder
end

local function ensureFolder()
    if not env.makefolder or not env.isfolder then return end
    if not env.isfolder("Pantheon")      then pcall(env.makefolder, "Pantheon")      end
    if not env.isfolder(FOLDER)          then pcall(env.makefolder, FOLDER)          end
end

-- basename of a path, minus the .lua extension. listfiles returns "/"- or "\\"-
-- separated paths depending on the executor; handle both.
local function fileIdOf(path)
    return tostring(path):match("([^/\\]+)%.lua$")
end

local function enabledMap() return persist.getGlobal(ENABLED_KEY, {}) or {} end
local function isEnabled(id)
    local v = enabledMap()[id]
    if v == nil then return true end   -- a freshly-installed addon defaults ON
    return v and true or false
end
local function setEnabledFlag(id, v)
    local m = enabledMap()
    m[id] = v and true or false
    persist.setGlobal(ENABLED_KEY, m)
end

-- Does an addon's scope apply to the current game? Mirrors games.registry /
-- tech engine scope semantics: nil/"universal" always; a PlaceId/GameId number
-- (or a list of them); or "char:<name>" via the game module's detectCharacter().
local function scopeMatches(scope)
    if scope == nil or scope == "universal" then return true end
    if scope == game.PlaceId or scope == game.GameId then return true end
    if type(scope) == "table" then
        for _, s in ipairs(scope) do
            if s == game.PlaceId or s == game.GameId then return true end
        end
        return false
    end
    if type(scope) == "string" then
        local want = scope:match("^char:(.+)$")
        if want then
            local mod = registry.current()
            local fn  = mod and mod.detectCharacter
            if type(fn) == "function" then
                local ok, name = pcall(fn)
                return (ok and name == want) or false
            end
        end
    end
    return false
end

local function scopeLabel(scope)
    if scope == nil or scope == "universal" then return "universal" end
    if scopeMatches(scope) then return "this game" end
    return "other game"
end

-- ---- load / activate ----

-- Run an addon FILE's chunk (which calls Pantheon.register). Returns the list of
-- defs it registered, each tagged with the file's id + path. Errors are captured.
local function loadFile(id, path)
    local ok, src = pcall(env.readfile, path)
    if not ok or not src then return nil, "read failed" end
    local chunk, cerr = loadstring(src, "=[PantheonAddon:" .. id .. "]")
    if not chunk then return nil, "compile: " .. tostring(cerr) end
    -- Inject the Pantheon global into the chunk's environment (and pass it as a
    -- vararg too, so `local Pantheon = ...` works as well as the global).
    local fenv = setmetatable({ Pantheon = api.Pantheon }, { __index = getfenv() })
    pcall(setfenv, chunk, fenv)
    api.setCurrentFile(id)
    local rok, rerr = pcall(chunk, api.Pantheon)
    api.setCurrentFile(nil)
    if not rok then return nil, "run: " .. tostring(rerr) end
    local defs = api.takeRegistered()
    for i, d in ipairs(defs) do
        d.id   = (#defs == 1) and id or (id .. "#" .. i)
        d.file = id
        d.path = path
    end
    return defs
end

-- Build the ctx + run setup() for every def in an entry whose scope matches now.
local function activate(entry)
    if entry.active then return end
    entry.ctxs = {}
    for _, def in ipairs(entry.defs or {}) do
        if type(def.setup) == "function" and scopeMatches(def.scope) then
            local ctx = api.makeContext(def)
            local ok, err = pcall(def.setup, ctx)
            if not ok then
                log.warn("[addons] '" .. tostring(def.name) .. "' setup error: " .. tostring(err))
                pcall(ctx._destroy)
            else
                entry.ctxs[#entry.ctxs + 1] = ctx
            end
        end
    end
    entry.active = true
end

local function deactivate(entry)
    for _, ctx in ipairs(entry.ctxs or {}) do pcall(ctx._destroy) end
    entry.ctxs   = {}
    entry.active = false
end

-- Load (chunk-run) an enabled file and activate its matching defs. No-op if the
-- file is disabled (we keep a bare entry so the manager still lists it).
local function loadEntry(id, path)
    local entry = entries[id] or { id = id, path = path, defs = {}, ctxs = {} }
    entry.path = path
    entries[id] = entry
    if not isEnabled(id) then entry.defs = {}; entry.err = nil; return entry end
    local defs, err = loadFile(id, path)
    if not defs then
        entry.defs = {}; entry.err = err
        log.warn("[addons] failed to load '" .. id .. "': " .. tostring(err))
        return entry
    end
    entry.defs = defs; entry.err = nil
    activate(entry)
    return entry
end

-- Discover every .lua in the addons folder and load the enabled ones.
local function discover()
    if not fsReady() then return end
    ensureFolder()
    local ok, files = pcall(env.listfiles, FOLDER)
    if not ok or type(files) ~= "table" then return end
    for _, path in ipairs(files) do
        local id = fileIdOf(path)
        if id then loadEntry(id, path) end
    end
end

-- ---- runtime ops (toggle / reload / install / delete) ----

local function refreshUI()
    if rebuildList then rebuildList() end
    container.refreshNavigator()
end

local function toggleAddon(id, on)
    setEnabledFlag(id, on)
    local entry = entries[id]
    if not entry then refreshUI(); return end
    if on then
        loadEntry(id, entry.path)        -- (re)load chunk + activate
    else
        deactivate(entry)
        entry.defs = {}                  -- forget defs; a re-enable re-runs the chunk
    end
    refreshUI()
end

local function reloadAll()
    for _, entry in pairs(entries) do deactivate(entry) end
    entries = {}
    discover()
    refreshUI()
    pcall(notify.info, "Addons reloaded", 3)
end

-- sanitize a desired filename to a safe, extensionless id
local function safeName(name)
    name = tostring(name or ""):gsub("%.lua$", "")
    name = name:gsub("[^%w%-_ ]", ""):gsub("%s+", "_")
    if name == "" then name = "addon_" .. tostring(#(entries) + 1) end
    return name
end

local function installFromUrl(url, name)
    if not fsReady() then pcall(notify.warn, "Filesystem APIs unavailable in this executor"); return end
    url = tostring(url or "")
    if url == "" then pcall(notify.warn, "Paste an addon URL first"); return end
    -- derive a name from the URL if none was typed
    if not name or name == "" then name = fileIdOf(url) or url:match("([^/]+)$") or "addon" end
    local id   = safeName(name)
    local okF, src = pcall(env.HttpGet, url)
    if not okF or not src or #src == 0 then pcall(notify.warn, "Download failed"); return end
    ensureFolder()
    local path = FOLDER .. "/" .. id .. ".lua"
    local okW = pcall(env.writefile, path, src)
    if not okW then pcall(notify.warn, "Could not write addon file"); return end
    setEnabledFlag(id, true)
    loadEntry(id, path)
    refreshUI()
    pcall(notify.success, "Installed addon: " .. id, 4)
end

local function deleteAddon(id)
    local entry = entries[id]
    if entry then deactivate(entry) end
    if entry and entry.path and env.delfile then pcall(env.delfile, entry.path) end
    entries[id] = nil
    local m = enabledMap(); m[id] = nil; persist.setGlobal(ENABLED_KEY, m)
    refreshUI()
end

-- ---- manager UI ----

local function buildRow(parent, entry)
    local id   = entry.id
    local def  = (entry.defs and entry.defs[1]) or nil
    local name = (def and def.name) or id
    local on   = isEnabled(id)

    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, 0, 0, 26)
    f.BackgroundColor3 = theme.bgAlt
    f.BorderSizePixel = 0
    f.Parent = parent

    local nameLbl = Instance.new("TextLabel")
    nameLbl.Size = UDim2.new(1, -150, 1, 0)
    nameLbl.Position = UDim2.fromOffset(8, 0)
    nameLbl.BackgroundTransparency = 1
    nameLbl.Text = entry.err and (name .. "  (error)") or name
    nameLbl.TextColor3 = on and theme.fg or theme.fgDim
    nameLbl.Font = theme.font; nameLbl.TextSize = 12
    nameLbl.TextXAlignment = Enum.TextXAlignment.Left
    nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
    nameLbl.Parent = f

    -- scope tag (greyed when the addon isn't applicable to this game)
    local tag = Instance.new("TextLabel")
    tag.Size = UDim2.fromOffset(72, 16); tag.Position = UDim2.new(1, -120, 0.5, -8)
    tag.BackgroundTransparency = 1
    tag.Text = def and scopeLabel(def.scope) or (entry.err and "load failed" or (on and "" or "disabled"))
    tag.TextColor3 = theme.fgDim; tag.Font = theme.font; tag.TextSize = 10
    tag.TextXAlignment = Enum.TextXAlignment.Right
    tag.Parent = f

    local toggle = Instance.new("TextButton")
    toggle.Size = UDim2.fromOffset(38, 18); toggle.Position = UDim2.new(1, -44, 0.5, -9)
    toggle.AutoButtonColor = false
    toggle.BackgroundColor3 = on and theme.on or theme.off
    toggle.TextColor3 = theme.fg; toggle.Font = theme.fontBold; toggle.TextSize = 10
    toggle.Text = on and "ON" or "OFF"
    toggle.Parent = f
    toggle.MouseButton1Click:Connect(function() toggleAddon(id, not isEnabled(id)) end)

    local del = Instance.new("TextButton")
    del.Size = UDim2.fromOffset(18, 18); del.Position = UDim2.new(1, -64, 0.5, -9)
    del.BackgroundColor3 = theme.danger; del.AutoButtonColor = false
    del.TextColor3 = theme.fg; del.Font = theme.fontBold; del.TextSize = 10
    del.Text = "X"
    del.Parent = f
    del.MouseButton1Click:Connect(function() deleteAddon(id) end)

    return f
end

function module.register()
    box = container.new(window.parent(), "Addons")

    local holder = Instance.new("Frame")
    holder.Size = UDim2.new(1, 0, 0, 0)
    holder.AutomaticSize = Enum.AutomaticSize.Y
    holder.BackgroundTransparency = 1
    local hl = Instance.new("UIListLayout", holder)
    hl.SortOrder = Enum.SortOrder.LayoutOrder
    hl.Padding = UDim.new(0, 2)

    local ord = 0
    local function place(inst) ord = ord + 1; inst.LayoutOrder = ord; inst.Parent = holder; return inst end

    if not fsReady() then
        place(components.Label(holder, "Filesystem APIs unavailable -- addons need an executor with listfiles/readfile."))
    else
        place(components.Section(holder, "Install"))
        local urlBox  = components.TextBox(holder, { label = "URL", placeholder = "raw .lua URL" })
        place(urlBox.frame)
        local nameBox = components.TextBox(holder, { label = "Name", placeholder = "optional file name" })
        place(nameBox.frame)
        place(components.Button(holder, { text = "Install from URL", onClick = function()
            installFromUrl(urlBox:Get(), nameBox:Get())
            urlBox:Set(""); nameBox:Set("")
        end }))
        place(components.Button(holder, { text = "Reload addons", onClick = reloadAll }))
        place(components.Label(holder, "Drop .lua files in:  " .. FOLDER))
        place(components.Section(holder, "Installed"))
    end

    listFrame = Instance.new("Frame")
    listFrame.Size = UDim2.new(1, 0, 0, 0)
    listFrame.AutomaticSize = Enum.AutomaticSize.Y
    listFrame.BackgroundTransparency = 1
    listFrame.Parent = holder
    listFrame.LayoutOrder = 999
    local ll = Instance.new("UIListLayout", listFrame)
    ll.SortOrder = Enum.SortOrder.LayoutOrder
    ll.Padding = UDim.new(0, 1)

    rebuildList = function()
        for _, c in ipairs(listFrame:GetChildren()) do
            if not c:IsA("UIListLayout") then c:Destroy() end
        end
        local ids = {}
        for id in pairs(entries) do ids[#ids + 1] = id end
        table.sort(ids)
        local n = 0
        for _, id in ipairs(ids) do
            local r = buildRow(listFrame, entries[id]); n = n + 1; r.LayoutOrder = n
        end
        if n == 0 then
            local empty = components.Label(listFrame, "No addons installed.")
            empty.LayoutOrder = 1
        end
    end

    box:add(holder)

    -- discover + load + activate BEFORE init.lua calls nav.populate() so every
    -- addon's menu (and this manager) is listed in the navigator from boot.
    discover()
    rebuildList()

    local count = 0
    for _ in pairs(entries) do count = count + 1 end
    log.info("Addons registered (" .. count .. " found)")
end

function module.destroy()
    -- Tear down every active addon (disconnect its connections + clear keybinds +
    -- destroy its menus) so a re-execute doesn't leak them. The manager container
    -- itself is destroyed by window.destroy() with the rest of the GUI.
    for _, entry in pairs(entries) do pcall(deactivate, entry) end
    entries     = {}
    box         = nil
    listFrame   = nil
    rebuildList = nil
end

return module
