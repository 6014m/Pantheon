-- Draggable category window. Holds feature rows. Wurst-style — stacks left-to-right
-- by default; user can drag them anywhere. Sharp angular corners + L-bracket accents
-- at each corner for a HUD/sci-fi look.

local theme = require("ui.theme")

local UIS = game:GetService("UserInputService")

local Container = {}
Container.__index = Container

local nextIndex = 0

local function bracketPiece(parent, size, position, anchor, color)
    local f = Instance.new("Frame")
    f.Size = size
    f.Position = position
    f.AnchorPoint = anchor
    f.BackgroundColor3 = color
    f.BorderSizePixel = 0
    f.ZIndex = 5
    f.Parent = parent
end

local function addBracket(parent, position, anchor, color)
    local SIZE, THICK = 8, 2
    bracketPiece(parent, UDim2.fromOffset(SIZE, THICK), position, anchor, color)
    bracketPiece(parent, UDim2.fromOffset(THICK, SIZE), position, anchor, color)
end

local function addCornerBrackets(parent, color)
    addBracket(parent, UDim2.new(0, 0, 0, 0), Vector2.new(0, 0), color)
    addBracket(parent, UDim2.new(1, 0, 0, 0), Vector2.new(1, 0), color)
    addBracket(parent, UDim2.new(0, 0, 1, 0), Vector2.new(0, 1), color)
    addBracket(parent, UDim2.new(1, 0, 1, 0), Vector2.new(1, 1), color)
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

    -- Corner brackets (drawn last so they sit on top of header + stroke)
    addCornerBrackets(root, theme.accent)

    -- Drag on header
    do
        local dragging, dragStart, startPos = false, nil, nil
        header.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
               or input.UserInputType == Enum.UserInputType.Touch then
                dragging = true
                dragStart = input.Position
                startPos = root.Position
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
