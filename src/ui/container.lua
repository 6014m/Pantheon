-- Draggable category window. Holds feature rows. Wurst-style — stacks left-to-right
-- by default; user can drag them anywhere.
-- Real hexagon corner accents (rendered via ui/hex) at each corner of the box.

local theme = require("ui.theme")
local hex   = require("ui.hex")

local UIS = game:GetService("UserInputService")

local Container = {}
Container.__index = Container

local nextIndex = 0

-- 14x12 ≈ regular hex proportions (12/14 ≈ 0.857; ideal is 0.866).
local CORNER_HEX_W = 14
local CORNER_HEX_H = 12

local function placeCornerHex(parent, position, color)
    local h = hex.build(parent, CORNER_HEX_W, CORNER_HEX_H, color, 5)
    h.AnchorPoint = Vector2.new(0.5, 0.5)
    h.Position    = position
end

local function addCornerHexes(parent, color)
    placeCornerHex(parent, UDim2.new(0, 0, 0, 0), color) -- TL
    placeCornerHex(parent, UDim2.new(1, 0, 0, 0), color) -- TR
    placeCornerHex(parent, UDim2.new(0, 0, 1, 0), color) -- BL
    placeCornerHex(parent, UDim2.new(1, 0, 1, 0), color) -- BR
end

function Container.new(parent, name)
    local self = setmetatable({}, Container)

    local idx = nextIndex
    nextIndex = nextIndex + 1
    local x = 16 + idx * (theme.containerWidth + theme.containerGap)

    local root = Instance.new("Frame")
    root.Name = "Container_" .. name
    root.Size = UDim2.new(0, theme.containerWidth, 0, 28)
    root.AutomaticSize = Enum.AutomaticSize.Y
    root.Position = UDim2.fromOffset(x, 16)
    root.BackgroundColor3 = theme.bg
    root.BorderSizePixel = 0
    root.Parent = parent

    local stroke = Instance.new("UIStroke", root)
    stroke.Color = theme.border
    stroke.Thickness = 1

    -- Header
    local header = Instance.new("TextLabel")
    header.Name = "Header"
    header.Size = UDim2.new(1, 0, 0, 28)
    header.BackgroundColor3 = theme.accent
    header.BorderSizePixel = 0
    header.Text = name
    header.TextColor3 = theme.fg
    header.Font = theme.fontBold
    header.TextSize = 13
    header.Parent = root

    -- Features stack
    local features = Instance.new("Frame")
    features.Name = "Features"
    features.Position = UDim2.fromOffset(0, 28)
    features.Size = UDim2.new(1, 0, 0, 0)
    features.AutomaticSize = Enum.AutomaticSize.Y
    features.BackgroundTransparency = 1
    features.Parent = root

    local list = Instance.new("UIListLayout", features)
    list.SortOrder = Enum.SortOrder.LayoutOrder
    list.Padding = UDim.new(0, 1)

    -- Real hexagon corner accents (drawn last so they sit on top of stroke + header)
    addCornerHexes(root, theme.accent)

    -- Drag on header
    do
        local dragging, dragStart, startPos = false, nil, nil
        header.InputBegan:Connect(function(input)
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
