-- UI primitives: Section, Label, Button, Toggle, Slider, KeybindSetter.
-- Sharp angular corners — no UICorner anywhere — to match the hex/HUD theme.

local theme = require("ui.theme")

local UIS = game:GetService("UserInputService")

local components = {}

-- Slider drag + KeybindSetter listen-mode need GLOBAL UserInputService
-- connections (a drag/keypress lands outside the row). Destroying the row's
-- GUI does NOT sever those, so we track them here and disconnect on teardown.
-- Without this, every Auto Re-Execute (teleport) stacked ~2 dead InputChanged
-- handlers per slider on UIS, firing on every mouse move forever.
-- NB: named trackConn (not `track`) on purpose -- Slider has a local `track`
-- Frame, and a bare `track` here would be shadowed by it, turning track(...)
-- into "call a Frame value" at runtime.
local conns = {}   -- [conn] = true
local function trackConn(c) conns[c] = true; return c end
local function untrackConn(c) conns[c] = nil end

local function baseRow(parent, height)
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, 0, 0, height or theme.rowHeight)
    f.BackgroundColor3 = theme.bgAlt
    f.BorderSizePixel = 0
    f.Parent = parent
    return f
end

function components.Section(parent, text)
    local f = Instance.new("TextLabel")
    f.Size = UDim2.new(1, 0, 0, 22)
    f.BackgroundTransparency = 1
    f.Text = string.upper(text or "")
    f.TextColor3 = theme.accent
    f.Font = theme.fontBold
    f.TextSize = 11
    f.TextXAlignment = Enum.TextXAlignment.Left
    f.Parent = parent
    return f
end

function components.Label(parent, text)
    local f = Instance.new("TextLabel")
    f.Size = UDim2.new(1, 0, 0, 20)
    f.BackgroundTransparency = 1
    f.Text = text or ""
    f.TextColor3 = theme.fgDim
    f.Font = theme.font
    f.TextSize = 12
    f.TextXAlignment = Enum.TextXAlignment.Left
    f.Parent = parent
    return f
end

function components.Button(parent, opts)
    opts = opts or {}
    local f = baseRow(parent)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.fromScale(1, 1)
    btn.BackgroundTransparency = 1
    btn.Text = opts.text or "Button"
    btn.TextColor3 = theme.fg
    btn.Font = theme.font
    btn.TextSize = 13
    btn.Parent = f
    if opts.onClick then
        btn.MouseButton1Click:Connect(opts.onClick)
    end
    return f
end

function components.Toggle(parent, opts)
    opts = opts or {}
    local state = opts.default == true
    local f = baseRow(parent)

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, -56, 1, 0)
    label.Position = UDim2.fromOffset(10, 0)
    label.BackgroundTransparency = 1
    label.Text = opts.text or "Toggle"
    label.TextColor3 = theme.fg
    label.Font = theme.font
    label.TextSize = 12
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = f

    local switch = Instance.new("TextButton")
    switch.Size = UDim2.fromOffset(36, 18)
    switch.Position = UDim2.new(1, -44, 0.5, -9)
    switch.AutoButtonColor = false
    switch.Text = ""
    switch.Parent = f

    local knob = Instance.new("Frame")
    knob.Size = UDim2.fromOffset(14, 14)
    knob.BackgroundColor3 = theme.fg
    knob.BorderSizePixel = 0
    knob.Parent = switch

    local function apply()
        switch.BackgroundColor3 = state and theme.accent or theme.bgDark
        knob.Position = state and UDim2.new(1, -16, 0.5, -7) or UDim2.fromOffset(2, 2)
    end
    apply()

    switch.MouseButton1Click:Connect(function()
        state = not state
        apply()
        if opts.onChange then opts.onChange(state) end
    end)

    local api = {}
    function api:Set(v)
        v = v and true or false
        if state ~= v then
            state = v
            apply()
            if opts.onChange then opts.onChange(state) end
        end
    end
    function api:Get() return state end
    api.frame = f   -- expose the row so callers (e.g. addon menus) can set LayoutOrder
    return api
end

function components.Slider(parent, opts)
    opts = opts or {}
    local min   = opts.min or 0
    local max   = opts.max or 100
    local step  = opts.step or 1
    local value = opts.default or min

    local f = baseRow(parent, 42)

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, -20, 0, 18)
    label.Position = UDim2.fromOffset(10, 2)
    label.BackgroundTransparency = 1
    label.Font = theme.font
    label.TextSize = 12
    label.TextColor3 = theme.fg
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = string.format("%s: %s", opts.text or "Slider", tostring(value))
    label.Parent = f

    local track = Instance.new("Frame")
    track.Size = UDim2.new(1, -20, 0, 6)
    track.Position = UDim2.fromOffset(10, 26)
    track.BackgroundColor3 = theme.bgDark
    track.BorderSizePixel = 0
    track.Parent = f

    local fill = Instance.new("Frame")
    fill.BackgroundColor3 = theme.accent
    fill.BorderSizePixel = 0
    fill.Size = UDim2.new((value - min) / (max - min), 0, 1, 0)
    fill.Parent = track

    local dragging = false

    local function setFromX(x)
        local relX = math.clamp(x - track.AbsolutePosition.X, 0, track.AbsoluteSize.X)
        local pct = (track.AbsoluteSize.X == 0) and 0 or relX / track.AbsoluteSize.X
        local v = min + pct * (max - min)
        v = math.floor(v / step + 0.5) * step
        v = math.clamp(v, min, max)
        if math.abs(v - value) > 1e-6 then
            value = v
            fill.Size = UDim2.new((v - min) / (max - min), 0, 1, 0)
            label.Text = string.format("%s: %s", opts.text or "Slider", tostring(v))
            if opts.onChange then opts.onChange(v) end
        end
    end

    track.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
           or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            setFromX(input.Position.X)
        end
    end)
    trackConn(UIS.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement
           or input.UserInputType == Enum.UserInputType.Touch then
            setFromX(input.Position.X)
        end
    end))
    trackConn(UIS.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
           or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))

    local api = {}
    function api:Get() return value end
    function api:Set(v)
        v = math.clamp(v, min, max)
        value = v
        fill.Size = UDim2.new((v - min) / (max - min), 0, 1, 0)
        label.Text = string.format("%s: %s", opts.text or "Slider", tostring(v))
        if opts.onChange then opts.onChange(v) end
    end
    return api
end

local function keyDisplayName(k)
    if not k or k == Enum.KeyCode.Unknown then return "<none>" end
    return (tostring(k):gsub("Enum.KeyCode.", ""))
end

function components.KeybindSetter(parent, opts)
    opts = opts or {}
    local current = opts.default or Enum.KeyCode.Unknown
    local listening = false

    local f = baseRow(parent, 28)

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(0.5, -10, 1, 0)
    label.Position = UDim2.fromOffset(10, 0)
    label.BackgroundTransparency = 1
    label.Text = opts.label or "Keybind"
    label.TextColor3 = theme.fg
    label.Font = theme.font
    label.TextSize = 12
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = f

    -- Setter button (click to enter listen mode, then press any key to bind)
    local btn = Instance.new("TextButton")
    btn.Position = UDim2.new(0.5, 4, 0.5, -10)
    btn.Size = UDim2.new(0.5, -38, 0, 20)
    btn.BackgroundColor3 = theme.bgDark
    btn.AutoButtonColor = false
    btn.TextColor3 = theme.fgDim
    btn.Font = theme.fontMono
    btn.TextSize = 11
    btn.Text = keyDisplayName(current)
    btn.Parent = f

    -- Unbind button: clears the keybind in one click
    local unbind = Instance.new("TextButton")
    unbind.Position = UDim2.new(1, -22, 0.5, -10)
    unbind.Size = UDim2.fromOffset(20, 20)
    unbind.BackgroundColor3 = theme.danger
    unbind.AutoButtonColor = false
    unbind.Text = "X"
    unbind.TextColor3 = theme.fg
    unbind.Font = theme.fontBold
    unbind.TextSize = 10
    unbind.Parent = f

    btn.MouseButton1Click:Connect(function()
        if listening then return end
        listening = true
        btn.Text = "<press a key>"
        btn.BackgroundColor3 = theme.accent

        local conn
        conn = trackConn(UIS.InputBegan:Connect(function(input)
            if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
            if input.KeyCode == Enum.KeyCode.Unknown then return end
            local k = input.KeyCode
            if k == Enum.KeyCode.Escape then
                listening = false
                btn.Text = keyDisplayName(current)
                btn.BackgroundColor3 = theme.bgDark
                conn:Disconnect(); untrackConn(conn)
                return
            end
            if k == Enum.KeyCode.Backspace then
                current = Enum.KeyCode.Unknown
                listening = false
                btn.Text = keyDisplayName(current)
                btn.BackgroundColor3 = theme.bgDark
                if opts.onChange then opts.onChange(current) end
                conn:Disconnect(); untrackConn(conn)
                return
            end
            current = k
            listening = false
            btn.Text = keyDisplayName(current)
            btn.BackgroundColor3 = theme.bgDark
            if opts.onChange then opts.onChange(current) end
            conn:Disconnect(); untrackConn(conn)
        end))
    end)

    unbind.MouseButton1Click:Connect(function()
        current = Enum.KeyCode.Unknown
        btn.Text = keyDisplayName(current)
        if opts.onChange then opts.onChange(current) end
    end)

    return {
        get = function() return current end,
        set = function(k)
            current = k
            btn.Text = keyDisplayName(current)
            if opts.onChange then opts.onChange(current) end
        end,
    }
end

-- Dropdown: a header row showing the current value; clicking it expands an
-- inline list of options below (pushes following rows down via the panel's
-- UIListLayout -- no overlay z-fighting). Returns api:Get()/api:Set(v).
function components.Dropdown(parent, opts)
    opts = opts or {}
    local options  = opts.options or {}
    local value    = opts.default or options[1]
    local onChange = opts.onChange

    local root = Instance.new("Frame")
    root.Size = UDim2.new(1, 0, 0, 0)
    root.AutomaticSize = Enum.AutomaticSize.Y
    root.BackgroundTransparency = 1
    root.Parent = parent
    local rl = Instance.new("UIListLayout", root)
    rl.SortOrder = Enum.SortOrder.LayoutOrder
    rl.Padding = UDim.new(0, 2)

    local header = baseRow(root, 28)
    header.LayoutOrder = 1
    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(0.5, -10, 1, 0); label.Position = UDim2.fromOffset(10, 0)
    label.BackgroundTransparency = 1; label.Text = opts.label or "Select"
    label.TextColor3 = theme.fg; label.Font = theme.font; label.TextSize = 12
    label.TextXAlignment = Enum.TextXAlignment.Left; label.Parent = header

    local cur = Instance.new("TextButton")
    cur.Position = UDim2.new(0.5, 4, 0.5, -10); cur.Size = UDim2.new(0.5, -14, 0, 20)
    cur.BackgroundColor3 = theme.bgDark; cur.AutoButtonColor = false
    cur.TextColor3 = theme.fg; cur.Font = theme.font; cur.TextSize = 11
    cur.Text = tostring(value or ""); cur.Parent = header

    local listHost = Instance.new("Frame")
    listHost.Size = UDim2.new(1, 0, 0, 0); listHost.AutomaticSize = Enum.AutomaticSize.Y
    listHost.BackgroundTransparency = 1; listHost.Visible = false; listHost.LayoutOrder = 2
    listHost.Parent = root
    local ll = Instance.new("UIListLayout", listHost)
    ll.SortOrder = Enum.SortOrder.LayoutOrder; ll.Padding = UDim.new(0, 1)

    local optCount = 0
    local function addOption(o)
        optCount = optCount + 1
        local ob = Instance.new("TextButton")
        ob.Size = UDim2.new(1, -20, 0, 22); ob.Position = UDim2.fromOffset(20, 0)
        ob.BackgroundColor3 = theme.bgAlt; ob.AutoButtonColor = true; ob.BorderSizePixel = 0
        ob.TextColor3 = theme.fgDim; ob.Font = theme.font; ob.TextSize = 11
        ob.Text = tostring(o); ob.LayoutOrder = optCount; ob.Parent = listHost
        ob.MouseButton1Click:Connect(function()
            value = o; cur.Text = tostring(o); listHost.Visible = false
            if onChange then onChange(value) end
        end)
    end
    for _, o in ipairs(options) do addOption(o) end

    cur.MouseButton1Click:Connect(function()
        listHost.Visible = not listHost.Visible
    end)

    local api = {}
    function api:Get() return value end
    function api:Set(v)
        value = v; cur.Text = tostring(v or "")
        if onChange then onChange(value) end
    end
    function api:AddOption(o) addOption(o) end   -- append a new option (e.g. a saved custom preset)
    return api
end

-- Text input row: label on the left, a TextBox on the right. onChange fires on
-- focus-lost with the entered text. Used to name custom shader presets.
function components.TextBox(parent, opts)
    opts = opts or {}
    local f = baseRow(parent, 28)

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(0.4, -10, 1, 0); label.Position = UDim2.fromOffset(10, 0)
    label.BackgroundTransparency = 1; label.Text = opts.label or "Name"
    label.TextColor3 = theme.fg; label.Font = theme.font; label.TextSize = 12
    label.TextXAlignment = Enum.TextXAlignment.Left; label.Parent = f

    local box = Instance.new("TextBox")
    box.Position = UDim2.new(0.4, 4, 0.5, -10); box.Size = UDim2.new(0.6, -14, 0, 20)
    box.BackgroundColor3 = theme.bgDark; box.BorderSizePixel = 0
    box.TextColor3 = theme.fg; box.PlaceholderColor3 = theme.fgDim
    box.Font = theme.font; box.TextSize = 11
    box.Text = opts.default or ""; box.PlaceholderText = opts.placeholder or ""
    box.ClearTextOnFocus = false; box.TextXAlignment = Enum.TextXAlignment.Left
    box.Parent = f
    local pad = Instance.new("UIPadding", box); pad.PaddingLeft = UDim.new(0, 6)

    box.FocusLost:Connect(function()
        if opts.onChange then opts.onChange(box.Text) end
    end)

    local api = {}
    function api:Get() return box.Text end
    function api:Set(v) box.Text = v or "" end
    return api
end

-- Disconnect every tracked global-UIS connection (slider drag handlers + any
-- live keybind listen). Called from init.lua's shutdown so a re-execute doesn't
-- stack listeners across teleports.
function components.destroy()
    for c in pairs(conns) do pcall(function() c:Disconnect() end) end
    conns = {}
end

return components
