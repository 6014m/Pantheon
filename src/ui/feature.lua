-- Feature row: [name] [hex ON/OFF indicator] [hex info] [hex cog].
-- Cog click expands an inline settings panel below the row.
-- "i" click expands a description label below the row (separate from settings).
-- All three buttons are real hex shapes (built via ui/hex).
--
-- Dependency cascading:
-- Each feature.declare({ ... }) can take a `dependencies = { "id", ... }`
-- list. When the feature is enabled, every dependency is auto-enabled first.
-- When the feature is disabled, every other feature that lists it as a
-- dependency is auto-disabled too (so e.g. turning off Target Select turns
-- off Lock-On / Highlight / Swap Target instead of leaving them stuck "on"
-- with no target source).

local theme      = require("ui.theme")
local hex        = require("ui.hex")
local keybinds   = require("core.keybinds")
local components = require("ui.components")

local Feature = {}

local nextId     = 0
local registry   = {} -- [id] = { setEnabled, getEnabled }
local dependents = {} -- [depId] = { dependentId, ... }

local function hexButton(parent, w, h, color, text, font, textSize)
    local host = Instance.new("Frame")
    host.Size = UDim2.fromOffset(w, h)
    host.BackgroundTransparency = 1
    host.Parent = parent

    local hexFrame = hex.build(host, w, h, color, 2)

    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    label.Text = text or ""
    label.TextColor3 = theme.fg
    label.Font = font or theme.font
    label.TextSize = textSize or 12
    label.ZIndex = 5
    label.Parent = host

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.fromScale(1, 1)
    btn.BackgroundTransparency = 1
    btn.Text = ""
    btn.AutoButtonColor = false
    btn.ZIndex = 6
    btn.Parent = host

    return host, hexFrame, label, btn
end

function Feature.declare(def)
    nextId = nextId + 1
    local id = def.id or ("feature_" .. nextId)
    local hasDesc = def.description and #def.description > 0

    -- Register reverse-dep edges so the disable cascade works.
    if def.dependencies then
        for _, depId in ipairs(def.dependencies) do
            dependents[depId] = dependents[depId] or {}
            table.insert(dependents[depId], id)
        end
    end

    local root = Instance.new("Frame")
    root.Name = "Feature_" .. id
    root.Size = UDim2.new(1, 0, 0, 0)
    root.AutomaticSize = Enum.AutomaticSize.Y
    root.BackgroundTransparency = 1

    local rootList = Instance.new("UIListLayout", root)
    rootList.SortOrder = Enum.SortOrder.LayoutOrder

    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, theme.featureHeight)
    row.BackgroundColor3 = theme.bgAlt
    row.BorderSizePixel = 0
    row.LayoutOrder = 1
    row.Parent = root

    local nameLabel = Instance.new("TextLabel")
    nameLabel.Position = UDim2.fromOffset(8, 0)
    nameLabel.Size = UDim2.new(1, hasDesc and -112 or -84, 1, 0)
    nameLabel.BackgroundTransparency = 1
    nameLabel.Text = def.name or "Feature"
    nameLabel.TextColor3 = theme.fgDim
    nameLabel.Font = theme.font
    nameLabel.TextSize = 13
    nameLabel.TextXAlignment = Enum.TextXAlignment.Left
    nameLabel.Parent = row

    local indicatorHost, indicatorHex, indicatorLabel, indicatorBtn =
        hexButton(row, 40, 22, theme.off, "OFF", theme.fontBold, 10)
    indicatorHost.Position = UDim2.new(1, hasDesc and -104 or -76, 0.5, 0)
    indicatorHost.AnchorPoint = Vector2.new(0, 0.5)

    local infoHex, infoBtn
    if hasDesc then
        local _, hx, _, b = hexButton(row, 22, 18, theme.bgDark, "i", theme.fontBold, 12)
        local infoHost = b.Parent
        infoHost.Position = UDim2.new(1, -54, 0.5, 0)
        infoHost.AnchorPoint = Vector2.new(0, 0.5)
        infoHex, infoBtn = hx, b
    end

    local _, cogHex, _, cogBtn =
        hexButton(row, 22, 18, theme.bgDark, "\u{2699}", theme.font, 14)
    local cogHost = cogBtn.Parent
    cogHost.Position = UDim2.new(1, -28, 0.5, 0)
    cogHost.AnchorPoint = Vector2.new(0, 0.5)

    local desc
    if hasDesc then
        desc = Instance.new("TextLabel")
        desc.Size = UDim2.new(1, 0, 0, 0)
        desc.AutomaticSize = Enum.AutomaticSize.Y
        desc.BackgroundColor3 = theme.bgDark
        desc.BorderSizePixel = 0
        desc.Text = def.description
        desc.TextColor3 = theme.fgDim
        desc.Font = theme.font
        desc.TextSize = 11
        desc.TextWrapped = true
        desc.TextXAlignment = Enum.TextXAlignment.Left
        desc.TextYAlignment = Enum.TextYAlignment.Top
        desc.Visible = false
        desc.LayoutOrder = 2
        desc.Parent = root

        local pad = Instance.new("UIPadding", desc)
        pad.PaddingTop    = UDim.new(0, 6)
        pad.PaddingBottom = UDim.new(0, 6)
        pad.PaddingLeft   = UDim.new(0, 8)
        pad.PaddingRight  = UDim.new(0, 8)
    end

    local panel = Instance.new("Frame")
    panel.Size = UDim2.new(1, 0, 0, 0)
    panel.AutomaticSize = Enum.AutomaticSize.Y
    panel.BackgroundColor3 = theme.bgDark
    panel.BorderSizePixel = 0
    panel.Visible = false
    panel.LayoutOrder = 3
    panel.Parent = root

    local panelPad = Instance.new("UIPadding", panel)
    panelPad.PaddingTop    = UDim.new(0, 4)
    panelPad.PaddingBottom = UDim.new(0, 4)
    panelPad.PaddingLeft   = UDim.new(0, 6)
    panelPad.PaddingRight  = UDim.new(0, 6)

    local panelList = Instance.new("UIListLayout", panel)
    panelList.Padding   = UDim.new(0, 4)
    panelList.SortOrder = Enum.SortOrder.LayoutOrder

    local enabled = def.default == true

    local function applyToggle()
        hex.setColor(indicatorHex, enabled and theme.on or theme.off)
        indicatorLabel.Text = enabled and "ON" or "OFF"
        nameLabel.TextColor3 = enabled and theme.fg or theme.fgDim
        if def.onToggle then
            local ok, err = pcall(def.onToggle, enabled)
            if not ok then warn("[Pantheon] feature onToggle error:", err) end
        end
    end

    local function setEnabled(v)
        v = v and true or false
        if enabled == v then return end

        -- Enable cascade: turn on every dependency before turning on us.
        if v and def.dependencies then
            for _, depId in ipairs(def.dependencies) do
                local dep = registry[depId]
                if dep and not dep.getEnabled() then
                    dep.setEnabled(true)
                end
            end
        end

        enabled = v
        applyToggle()

        -- Disable cascade: anyone who lists us as a dependency goes off too.
        if not v and dependents[id] then
            for _, depId in ipairs(dependents[id]) do
                local dep = registry[depId]
                if dep and dep.getEnabled() then
                    dep.setEnabled(false)
                end
            end
        end
    end

    local function toggleEnabled() setEnabled(not enabled) end

    indicatorBtn.MouseButton1Click:Connect(toggleEnabled)

    local panelOpen = false
    cogBtn.MouseButton1Click:Connect(function()
        panelOpen = not panelOpen
        panel.Visible = panelOpen
        hex.setColor(cogHex, panelOpen and theme.accent or theme.bgDark)
    end)

    if infoBtn then
        local descOpen = false
        infoBtn.MouseButton1Click:Connect(function()
            descOpen = not descOpen
            desc.Visible = descOpen
            hex.setColor(infoHex, descOpen and theme.accent or theme.bgDark)
        end)
    end

    local function onPress()
        if def.onKey then
            local ok, err = pcall(def.onKey)
            if not ok then warn("[Pantheon] feature onKey error:", err) end
        else
            toggleEnabled()
        end
    end
    local function onRelease()
        if def.onKeyRelease then
            local ok, err = pcall(def.onKeyRelease)
            if not ok then warn("[Pantheon] feature onKeyRelease error:", err) end
        end
    end

    if def.defaultKey then
        keybinds.set(id, def.defaultKey, onPress, onRelease)
    end

    components.KeybindSetter(panel, {
        label    = "Keybind",
        default  = def.defaultKey,
        onChange = function(newKey)
            keybinds.set(id, newKey, onPress, onRelease)
        end,
    })

    if def.settings and #def.settings > 0 then
        local sep = Instance.new("Frame")
        sep.Size = UDim2.new(1, 0, 0, 1)
        sep.BackgroundColor3 = theme.border
        sep.BorderSizePixel = 0
        sep.Parent = panel

        for _, opt in ipairs(def.settings) do
            if opt.type == "section" then
                components.Section(panel, opt.name)
            elseif opt.type == "toggle" then
                components.Toggle(panel, {
                    text     = opt.name,
                    default  = opt.default,
                    onChange = opt.onChange,
                })
            elseif opt.type == "slider" then
                components.Slider(panel, {
                    text     = opt.name,
                    min      = opt.min, max = opt.max, step = opt.step,
                    default  = opt.default,
                    onChange = opt.onChange,
                })
            elseif opt.type == "button" then
                components.Button(panel, {
                    text    = opt.name,
                    onClick = opt.onClick,
                })
            elseif opt.type == "keybind" then
                if opt.default and opt.id then
                    keybinds.set(opt.id, opt.default, opt.onPress, opt.onRelease)
                end
                components.KeybindSetter(panel, {
                    label    = opt.name or "Key",
                    default  = opt.default,
                    onChange = function(newKey)
                        if opt.id then
                            keybinds.set(opt.id, newKey, opt.onPress, opt.onRelease)
                        end
                    end,
                })
            end
        end
    end

    registry[id] = {
        setEnabled = setEnabled,
        getEnabled = function() return enabled end,
        def        = def,
    }

    applyToggle()

    return {
        root       = root,
        id         = id,
        setEnabled = setEnabled,
        getEnabled = function() return enabled end,
    }
end

return Feature
