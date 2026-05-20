-- Pantheon root UI. Hosts a ScreenGui that contains a `Containers` parent (for
-- draggable category windows) plus a floating hexagonal open/close button.
-- Master hotkey (default RightControl) toggles visibility.

local env      = require("core.env")
local theme    = require("ui.theme")
local keybinds = require("core.keybinds")

local UIS = game:GetService("UserInputService")

local Window = {}

local s = {
    screenGui = nil,
    container = nil,
    openBtn   = nil,
    visible   = true,
    masterKey = Enum.KeyCode.RightControl,
}

local function buildHexButton(sg)
    local host = Instance.new("Frame")
    host.Name = "PantheonOpenButton"
    host.Size = UDim2.fromOffset(46, 50)
    host.Position = UDim2.new(0, 16, 1, -66)
    host.BackgroundTransparency = 1
    host.ZIndex = 10
    host.Parent = sg

    -- 3-frame hex shape: top point + middle rectangle + bottom point.
    -- The rotated squares are anchored so their outer tips sit at the host edges,
    -- and the middle rectangle covers the diamonds' inner halves.
    local top = Instance.new("Frame")
    top.Size = UDim2.fromOffset(35, 35)
    top.AnchorPoint = Vector2.new(0.5, 0)
    top.Position = UDim2.new(0.5, 0, 0, 0)
    top.Rotation = 45
    top.BackgroundColor3 = theme.accent
    top.BorderSizePixel = 0
    top.ZIndex = 10
    top.Parent = host

    local mid = Instance.new("Frame")
    mid.Size = UDim2.new(1, 0, 0, 26)
    mid.Position = UDim2.fromOffset(0, 12)
    mid.BackgroundColor3 = theme.accent
    mid.BorderSizePixel = 0
    mid.ZIndex = 11
    mid.Parent = host

    local bot = Instance.new("Frame")
    bot.Size = UDim2.fromOffset(35, 35)
    bot.AnchorPoint = Vector2.new(0.5, 1)
    bot.Position = UDim2.new(0.5, 0, 1, 0)
    bot.Rotation = 45
    bot.BackgroundColor3 = theme.accent
    bot.BorderSizePixel = 0
    bot.ZIndex = 10
    bot.Parent = host

    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    label.Text = "P"
    label.TextColor3 = theme.fg
    label.Font = theme.fontBold
    label.TextSize = 20
    label.ZIndex = 12
    label.Parent = host

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.fromScale(1, 1)
    btn.BackgroundTransparency = 1
    btn.Text = ""
    btn.AutoButtonColor = false
    btn.ZIndex = 13
    btn.Parent = host

    -- Drag + click-to-toggle (click only fires if not dragged)
    local dragging, dragStart, startPos = false, nil, nil
    local moved = false
    btn.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
           or input.UserInputType == Enum.UserInputType.Touch then
            dragging  = true
            dragStart = input.Position
            startPos  = host.Position
            moved     = false
        end
    end)
    UIS.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement
           or input.UserInputType == Enum.UserInputType.Touch then
            local delta = input.Position - dragStart
            if delta.Magnitude > 4 then moved = true end
            host.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end)
    UIS.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
           or input.UserInputType == Enum.UserInputType.Touch then
            if dragging and not moved then Window.toggle() end
            dragging = false
        end
    end)

    return host
end

function Window.init()
    if s.screenGui then return end

    local sg = Instance.new("ScreenGui")
    sg.Name = "PantheonGui"
    sg.IgnoreGuiInset = true
    sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    sg.ResetOnSpawn = false
    sg.Parent = env.guiParent()
    env.protectGui(sg)

    local containerHost = Instance.new("Frame")
    containerHost.Name = "Containers"
    containerHost.Size = UDim2.fromScale(1, 1)
    containerHost.BackgroundTransparency = 1
    containerHost.Parent = sg

    s.screenGui = sg
    s.container = containerHost
    s.openBtn   = buildHexButton(sg)

    keybinds.set("ui.master_toggle", s.masterKey, Window.toggle)
end

function Window.toggle()
    Window.setVisible(not s.visible)
end

function Window.setVisible(v)
    s.visible = v
    if s.container then s.container.Visible = v end
end

function Window.isVisible()
    return s.visible
end

function Window.parent()
    return s.container
end

function Window.setMasterKey(key)
    s.masterKey = key
    keybinds.set("ui.master_toggle", key, Window.toggle)
end

return Window
