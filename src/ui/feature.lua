-- Feature row: [name] [ON/OFF indicator] [i info] [cog].
-- Cog click expands an inline settings panel below the row.
-- "i" click expands a description label below the row (separate from settings).
-- Sharp angular corners throughout.
--
-- Settings types: toggle, slider, button, section.

local theme      = require("ui.theme")
local keybinds   = require("core.keybinds")
local components = require("ui.components")

local Feature = {}

local nextId = 0

function Feature.declare(def)
    nextId = nextId + 1
    local id = def.id or ("feature_" .. nextId)
    local hasDesc = def.description and #def.description > 0

    -- Root uses UIListLayout so row / description / settings panel stack
    -- vertically and only contribute height when Visible = true.
    local root = Instance.new("Frame")
    root.Name = "Feature_" .. id
    root.Size = UDim2.new(1, 0, 0, 0)
    root.AutomaticSize = Enum.AutomaticSize.Y
    root.BackgroundTransparency = 1

    local rootList = Instance.new("UIListLayout", root)
    rootList.SortOrder = Enum.SortOrder.LayoutOrder

    -- Row
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, theme.featureHeight)
    row.BackgroundColor3 = theme.bgAlt
    row.BorderSizePixel = 0
    row.LayoutOrder = 1
    row.Parent = root

    -- Reserve right-side space: indicator(40) + i(20) + cog(20) + gaps = ~108
    local nameLabel = Instance.new("TextLabel")
    nameLabel.Position = UDim2.fromOffset(8, 0)
    nameLabel.Size = UDim2.new(1, hasDesc and -108 or -84, 1, 0)
    nameLabel.BackgroundTransparency = 1
    nameLabel.Text = def.name or "Feature"
    nameLabel.TextColor3 = theme.fgDim
    nameLabel.Font = theme.font
    nameLabel.TextSize = 13
    nameLabel.TextXAlignment = Enum.TextXAlignment.Left
    nameLabel.Parent = row

    local indicator = Instance.new("TextButton")
    indicator.Position = UDim2.new(1, hasDesc and -100 or -76, 0.5, -10)
    indicator.Size = UDim2.fromOffset(40, 20)
    indicator.BackgroundColor3 = theme.off
    indicator.AutoButtonColor = false
    indicator.Text = "OFF"
    indicator.TextColor3 = theme.fg
    indicator.Font = theme.fontBold
    indicator.TextSize = 10
    indicator.Parent = row

    local info -- info "i" button, only if a description was provided
    if hasDesc then
        info = Instance.new("TextButton")
        info.Position = UDim2.new(1, -52, 0.5, -10)
        info.Size = UDim2.fromOffset(20, 20)
        info.BackgroundColor3 = theme.bgDark
        info.AutoButtonColor = false
        info.Text = "i"
        info.TextColor3 = theme.fgDim
        info.Font = theme.fontBold
        info.TextSize = 12
        info.Parent = row
    end

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

    -- Description label (hidden until "i" clicked)
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

    -- Settings panel (hidden until cog clicked)
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

    -- Cog: toggle settings panel
    local panelOpen = false
    cog.MouseButton1Click:Connect(function()
        panelOpen = not panelOpen
        panel.Visible = panelOpen
        cog.BackgroundColor3 = panelOpen and theme.accent or theme.bgDark
    end)

    -- Info: toggle description label
    if info then
        local descOpen = false
        info.MouseButton1Click:Connect(function()
            descOpen = not descOpen
            desc.Visible = descOpen
            info.BackgroundColor3 = descOpen and theme.accent or theme.bgDark
        end)
    end

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

    -- Settings panel content: keybind setter first
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
