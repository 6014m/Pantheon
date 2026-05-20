-- Feature row: [name] [ON/OFF indicator] [cog].
-- Cog click expands an inline settings panel below the row. The panel always
-- starts with a keybind setter; per-feature options follow.
--
-- Declarative API:
--   feature.declare({
--     id           = "aim.lockon",            -- stable id for keybind persistence
--     name         = "Lock-On",
--     default      = false,                   -- initial on/off
--     defaultKey   = Enum.KeyCode.E,          -- default keybind (nil = unbound)
--     onToggle     = function(enabled) end,   -- called on on/off flips
--     onKey        = function() end,          -- called when hotkey pressed (default: flip toggle)
--     onKeyRelease = function() end,          -- called when hotkey released
--     settings     = { { type = "toggle"/"slider"/"button", ... }, ... },
--   })
-- Returns { root = Frame, id = ..., setEnabled = fn, getEnabled = fn }

local theme      = require("ui.theme")
local keybinds   = require("core.keybinds")
local components = require("ui.components")

local Feature = {}

local nextId = 0

function Feature.declare(def)
    nextId = nextId + 1
    local id = def.id or ("feature_" .. nextId)

    local root = Instance.new("Frame")
    root.Name = "Feature_" .. id
    root.Size = UDim2.new(1, 0, 0, theme.featureHeight)
    root.AutomaticSize = Enum.AutomaticSize.Y
    root.BackgroundTransparency = 1

    -- Row
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, theme.featureHeight)
    row.BackgroundColor3 = theme.bgAlt
    row.BorderSizePixel = 0
    row.Parent = root

    local nameLabel = Instance.new("TextLabel")
    nameLabel.Position = UDim2.fromOffset(8, 0)
    nameLabel.Size = UDim2.new(1, -84, 1, 0)
    nameLabel.BackgroundTransparency = 1
    nameLabel.Text = def.name or "Feature"
    nameLabel.TextColor3 = theme.fgDim
    nameLabel.Font = theme.font
    nameLabel.TextSize = 13
    nameLabel.TextXAlignment = Enum.TextXAlignment.Left
    nameLabel.Parent = row

    local indicator = Instance.new("TextButton")
    indicator.Position = UDim2.new(1, -76, 0.5, -10)
    indicator.Size = UDim2.fromOffset(40, 20)
    indicator.BackgroundColor3 = theme.off
    indicator.AutoButtonColor = false
    indicator.Text = "OFF"
    indicator.TextColor3 = theme.fg
    indicator.Font = theme.fontBold
    indicator.TextSize = 10
    indicator.Parent = row
    Instance.new("UICorner", indicator).CornerRadius = UDim.new(0, 3)

    local cog = Instance.new("TextButton")
    cog.Position = UDim2.new(1, -28, 0.5, -10)
    cog.Size = UDim2.fromOffset(20, 20)
    cog.BackgroundColor3 = theme.bgDark
    cog.AutoButtonColor = false
    cog.Text = "\u{2699}"
    cog.TextColor3 = theme.fgDim
    cog.Font = theme.font
    cog.TextSize = 14
    cog.Parent = row
    Instance.new("UICorner", cog).CornerRadius = UDim.new(0, 3)

    -- Settings panel
    local panel = Instance.new("Frame")
    panel.Position = UDim2.fromOffset(0, theme.featureHeight)
    panel.Size = UDim2.new(1, 0, 0, 0)
    panel.AutomaticSize = Enum.AutomaticSize.Y
    panel.BackgroundColor3 = theme.bgDark
    panel.BorderSizePixel = 0
    panel.Visible = false
    panel.Parent = root

    local panelPad = Instance.new("UIPadding", panel)
    panelPad.PaddingTop    = UDim.new(0, 4)
    panelPad.PaddingBottom = UDim.new(0, 4)
    panelPad.PaddingLeft   = UDim.new(0, 6)
    panelPad.PaddingRight  = UDim.new(0, 6)

    local panelList = Instance.new("UIListLayout", panel)
    panelList.Padding   = UDim.new(0, 4)
    panelList.SortOrder = Enum.SortOrder.LayoutOrder

    -- Toggle state
    local enabled = def.default == true

    local function applyToggle()
        indicator.BackgroundColor3 = enabled and theme.on or theme.off
        indicator.Text = enabled and "ON" or "OFF"
        nameLabel.TextColor3 = enabled and theme.fg or theme.fgDim
        if def.onToggle then
            local ok, err = pcall(def.onToggle, enabled)
            if not ok then warn("[Pantheon] feature onToggle error:", err) end
        end
    end

    local function setEnabled(v)
        v = v and true or false
        if enabled ~= v then
            enabled = v
            applyToggle()
        end
    end

    local function toggleEnabled()
        setEnabled(not enabled)
    end

    indicator.MouseButton1Click:Connect(toggleEnabled)

    -- Cog: expand/collapse
    local panelOpen = false
    cog.MouseButton1Click:Connect(function()
        panelOpen = not panelOpen
        panel.Visible = panelOpen
        cog.BackgroundColor3 = panelOpen and theme.accent or theme.bgDark
    end)

    -- Keybind dispatch
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

    -- Settings panel: keybind setter first
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
            if opt.type == "toggle" then
                components.Toggle(panel, {
                    text     = opt.name,
                    default  = opt.default,
                    onChange = opt.onChange,
                })
            elseif opt.type == "slider" then
                components.Slider(panel, {
                    text     = opt.name,
                    min      = opt.min,
                    max      = opt.max,
                    step     = opt.step,
                    default  = opt.default,
                    onChange = opt.onChange,
                })
            elseif opt.type == "button" then
                components.Button(panel, {
                    text    = opt.name,
                    onClick = opt.onClick,
                })
            end
        end
    end

    applyToggle()

    return {
        root       = root,
        id         = id,
        setEnabled = setEnabled,
        getEnabled = function() return enabled end,
    }
end

return Feature
