-- Stacked corner toasts. Stateless caller API.

local env   = require("core.env")
local theme = require("ui.theme")

local notify = {}
local container

local function ensureContainer()
    if container and container.Parent then return container end
    local sg = Instance.new("ScreenGui")
    sg.Name = "PantheonNotify"
    sg.IgnoreGuiInset = true
    sg.ResetOnSpawn = false
    sg.Parent = env.guiParent()
    env.protectGui(sg)

    local f = Instance.new("Frame")
    f.AnchorPoint = Vector2.new(1, 1)
    f.Position = UDim2.new(1, -16, 1, -16)
    f.Size = UDim2.new(0, 300, 1, -32)
    f.BackgroundTransparency = 1
    f.Parent = sg

    local list = Instance.new("UIListLayout", f)
    list.VerticalAlignment = Enum.VerticalAlignment.Bottom
    list.SortOrder = Enum.SortOrder.LayoutOrder
    list.Padding = UDim.new(0, 6)

    container = f
    return f
end

local function toast(text, duration, color)
    duration = duration or 3
    local parent = ensureContainer()

    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(1, 0, 0, 0)
    frame.AutomaticSize = Enum.AutomaticSize.Y
    frame.BackgroundColor3 = theme.bgAlt
    frame.BorderSizePixel = 0
    frame.Parent = parent
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 6)

    local accent = Instance.new("Frame")
    accent.Size = UDim2.new(0, 3, 1, 0)
    accent.BackgroundColor3 = color or theme.accent
    accent.BorderSizePixel = 0
    accent.Parent = frame

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, -20, 0, 0)
    label.Position = UDim2.fromOffset(12, 0)
    label.AutomaticSize = Enum.AutomaticSize.Y
    label.BackgroundTransparency = 1
    label.Text = text or ""
    label.TextColor3 = theme.fg
    label.Font = theme.font
    label.TextSize = 13
    label.TextWrapped = true
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = frame

    local pad = Instance.new("UIPadding", frame)
    pad.PaddingTop = UDim.new(0, 8)
    pad.PaddingBottom = UDim.new(0, 8)

    task.delay(duration, function()
        if frame and frame.Parent then frame:Destroy() end
    end)
end

function notify.info(text, duration)    toast(text, duration, theme.accent)  end
function notify.success(text, duration) toast(text, duration, theme.success) end
function notify.warn(text, duration)    toast(text, duration, theme.danger)  end

notify.toast = toast

function notify.destroy()
    if container and container.Parent then
        local sg = container:FindFirstAncestorWhichIsA("ScreenGui")
        if sg then pcall(function() sg:Destroy() end) end
    end
    container = nil
end

return notify
