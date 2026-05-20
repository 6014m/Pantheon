-- Draggable category window. Wurst-style stack-left-to-right default; user can
-- drag them anywhere via the hex tab on top.
--
-- Visual layout:
--    /-----------\         <- hex tab (drag handle, accent-colored)
--   /   Category  \
--  /---------------\
--  |               |       <- body (theme.bg, holds features)
--  |  feature row  |
--  |  feature row  |
--  |               |
--  *---------------*       <- hex corner accents at bottom

local theme = require("ui.theme")
local hex   = require("ui.hex")

local UIS = game:GetService("UserInputService")

local Container = {}
Container.__index = Container

local nextIndex = 0

local CORNER_HEX_W, CORNER_HEX_H = 14, 12

local function placeCornerHex(parent, position, color)
    local h = hex.build(parent, CORNER_HEX_W, CORNER_HEX_H, color, 5)
    h.AnchorPoint = Vector2.new(0.5, 0.5)
    h.Position    = position
end

local function addBottomCornerHexes(parent, color)
    -- Top corners are visually replaced by the hex tab on the parent root.
    placeCornerHex(parent, UDim2.new(0, 0, 1, 0), color)
    placeCornerHex(parent, UDim2.new(1, 0, 1, 0), color)
end

function Container.new(parent, name)
    local self = setmetatable({}, Container)

    local idx = nextIndex
    nextIndex = nextIndex + 1
    local x = 16 + idx * (theme.containerWidth + theme.containerGap)

    local TAB_W, TAB_H = 130, 32
    local TAB_OVERLAP = 6  -- tab dips into body for visual continuity

    local root = Instance.new("Frame")
    root.Name = "Container_" .. name
    root.Size = UDim2.new(0, theme.containerWidth, 0, TAB_H)
    root.AutomaticSize = Enum.AutomaticSize.Y
    root.Position = UDim2.fromOffset(x, 16)
    root.BackgroundTransparency = 1
    root.Parent = parent

    -- Body (rectangular, holds features + bottom corner hexes)
    local body = Instance.new("Frame")
    body.Name = "Body"
    body.Size = UDim2.new(1, 0, 0, 0)
    body.AutomaticSize = Enum.AutomaticSize.Y
    body.Position = UDim2.fromOffset(0, TAB_H - TAB_OVERLAP)
    body.BackgroundColor3 = theme.bg
    body.BorderSizePixel = 0
    body.ZIndex = 1
    body.Parent = root

    local stroke = Instance.new("UIStroke", body)
    stroke.Color = theme.border
    stroke.Thickness = 1

    -- Features stack (starts below the tab overlap so content isn't hidden)
    local features = Instance.new("Frame")
    features.Name = "Features"
    features.Size = UDim2.new(1, 0, 0, 0)
    features.AutomaticSize = Enum.AutomaticSize.Y
    features.Position = UDim2.fromOffset(0, TAB_OVERLAP + 2)
    features.BackgroundTransparency = 1
    features.ZIndex = 2
    features.Parent = body

    local list = Instance.new("UIListLayout", features)
    list.SortOrder = Enum.SortOrder.LayoutOrder
    list.Padding = UDim.new(0, 1)

    addBottomCornerHexes(body, theme.accent)

    -- Hex tab (header) on top, centered, ZIndex above body
    local tab = Instance.new("Frame")
    tab.Name = "Tab"
    tab.Size = UDim2.fromOffset(TAB_W, TAB_H)
    tab.Position = UDim2.new(0.5, 0, 0, 0)
    tab.AnchorPoint = Vector2.new(0.5, 0)
    tab.BackgroundTransparency = 1
    tab.ZIndex = 5
    tab.Parent = root

    hex.build(tab, TAB_W, TAB_H, theme.accent, 5)

    local tabText = Instance.new("TextLabel")
    tabText.Size = UDim2.fromScale(1, 1)
    tabText.BackgroundTransparency = 1
    tabText.Text = name
    tabText.TextColor3 = theme.fg
    tabText.Font = theme.fontBold
    tabText.TextSize = 13
    tabText.ZIndex = 7
    tabText.Parent = tab

    -- Drag handle (transparent click area covering the tab)
    local dragHandle = Instance.new("TextButton")
    dragHandle.Size = UDim2.fromScale(1, 1)
    dragHandle.BackgroundTransparency = 1
    dragHandle.Text = ""
    dragHandle.AutoButtonColor = false
    dragHandle.ZIndex = 8
    dragHandle.Parent = tab

    do
        local dragging, dragStart, startPos = false, nil, nil
        dragHandle.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
               or input.UserInputType == Enum.UserInputType.Touch then
                dragging  = true
                dragStart = input.Position
                startPos  = root.Position
            end
        end)
        UIS.InputChanged:Connect(function(input)
            if not dragging then return end
            if input.UserInputType == Enum.UserInputType.MouseMovement
               or input.UserInputType == Enum.UserInputType.Touch then
                local delta = input.Position - dragStart
                root.Position = UDim2.new(
                    startPos.X.Scale, startPos.X.Offset + delta.X,
                    startPos.Y.Scale, startPos.Y.Offset + delta.Y
                )
            end
        end)
        UIS.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
               or input.UserInputType == Enum.UserInputType.Touch then
                dragging = false
            end
        end)
    end

    self.root     = root
    self.features = features
    self.name     = name
    self._count   = 0

    return self
end

function Container:add(featureRoot)
    self._count = self._count + 1
    featureRoot.LayoutOrder = self._count
    featureRoot.Parent = self.features
    return self
end

return Container
