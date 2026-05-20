-- Pantheon root UI. Hosts a ScreenGui that contains a `Containers` parent (for
-- draggable category windows) plus a floating "P" open/close button.
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

local function buildOpenButton(sg)
    local btn = Instance.new("TextButton")
    btn.Name = "PantheonOpenButton"
    btn.Size = UDim2.fromOffset(40, 40)
    btn.Position = UDim2.new(0, 16, 1, -56)
    btn.BackgroundColor3 = theme.accent
    btn.BorderSizePixel = 0
    btn.Text = "P"
    btn.TextColor3 = theme.fg
    btn.Font = theme.fontBold
    btn.TextSize = 18
    btn.AutoButtonColor = false
    btn.Parent = sg
    Instance.new("UICorner", btn).CornerRadius = UDim.new(1, 0)
    Instance.new("UIStroke", btn).Color = theme.border

    -- Draggable + click-to-toggle (click only fires if not dragged)
    local dragging, dragStart, startPos = false, nil, nil
    local moved = false
    btn.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
           or input.UserInputType == Enum.UserInputType.Touch then
            dragging  = true
            dragStart = input.Position
            startPos  = btn.Position
            moved     = false
        end
    end)
    UIS.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement
           or input.UserInputType == Enum.UserInputType.Touch then
            local delta = input.Position - dragStart
            if delta.Magnitude > 4 then moved = true end
            btn.Position = UDim2.new(
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

    return btn
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
    s.openBtn   = buildOpenButton(sg)

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
