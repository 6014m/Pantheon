-- Pantheon root UI. Hosts a ScreenGui that contains a `Containers` parent
-- (for draggable category windows) plus a floating hexagonal open/close button.
-- Master hotkey (default RightControl) toggles visibility.

local env      = require("core.env")
local theme    = require("ui.theme")
local hex      = require("ui.hex")
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

-- Flat-top regular hexagon (46x40, very close to the 2/sqrt(3) ratio).
local function buildHexButton(sg)
    local host = Instance.new("Frame")
    host.Name = "PantheonOpenButton"
    host.Size = UDim2.fromOffset(46, 40)
    host.Position = UDim2.new(0, 16, 1, -56)
    host.BackgroundTransparency = 1
    host.ZIndex = 10
    host.Parent = sg

    -- The hex itself
    hex.build(host, 46, 40, theme.accent, 10)

    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    label.Text = "P"
    label.TextColor3 = theme.fg
    label.Font = theme.fontBold
    label.TextSize = 18
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
