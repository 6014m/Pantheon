-- UI primitives: Section, Label, Button, Toggle, Slider.

local theme = require("ui.theme")

local UIS = game:GetService("UserInputService")

local components = {}

local function baseRow(parent, height)
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, 0, 0, height or theme.rowHeight)
    f.BackgroundColor3 = theme.bgAlt
    f.BorderSizePixel = 0
    f.Parent = parent
    Instance.new("UICorner", f).CornerRadius = UDim.new(0, 4)
    return f
end

function components.Section(parent, text)
    local f = Instance.new("TextLabel")
    f.Size = UDim2.new(1, 0, 0, 22)
    f.BackgroundTransparency = 1
    f.Text = string.upper(text or "")
    f.TextColor3 = theme.fgDim
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
    label.TextSize = 13
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = f

    local switch = Instance.new("TextButton")
    switch.Size = UDim2.fromOffset(36, 20)
    switch.Position = UDim2.new(1, -46, 0.5, -10)
    switch.AutoButtonColor = false
    switch.Text = ""
    switch.Parent = f
    Instance.new("UICorner", switch).CornerRadius = UDim.new(1, 0)

    local knob = Instance.new("Frame")
    knob.Size = UDim2.fromOffset(16, 16)
    knob.BackgroundColor3 = theme.fg
    knob.BorderSizePixel = 0
    knob.Parent = switch
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

    local function apply()
        switch.BackgroundColor3 = state and theme.accent or theme.bgDark
        knob.Position = state and UDim2.new(1, -18, 0.5, -8) or UDim2.fromOffset(2, 2)
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
    return api
end

function components.Slider(parent, opts)
    opts = opts or {}
    local min   = opts.min or 0
    local max   = opts.max or 100
    local step  = opts.step or 1
    local value = opts.default or min

    local f = baseRow(parent, 46)

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, -20, 0, 20)
    label.Position = UDim2.fromOffset(10, 4)
    label.BackgroundTransparency = 1
    label.Font = theme.font
    label.TextSize = 13
    label.TextColor3 = theme.fg
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Text = string.format("%s: %s", opts.text or "Slider", tostring(value))
    label.Parent = f

    local track = Instance.new("Frame")
    track.Size = UDim2.new(1, -20, 0, 6)
    track.Position = UDim2.fromOffset(10, 30)
    track.BackgroundColor3 = theme.bgDark
    track.BorderSizePixel = 0
    track.Parent = f
    Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)

    local fill = Instance.new("Frame")
    fill.BackgroundColor3 = theme.accent
    fill.BorderSizePixel = 0
    fill.Size = UDim2.new((value - min) / (max - min), 0, 1, 0)
    fill.Parent = track
    Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)

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
    UIS.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement
           or input.UserInputType == Enum.UserInputType.Touch then
            setFromX(input.Position.X)
        end
    end)
    UIS.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
           or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)

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

return components
