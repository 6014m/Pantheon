-- Draggable category container, rendered using the user's uploaded chamfered
-- panel image (rbxassetid://77797049442743). The image is a 64x64 PNG with
-- 24px chamfered corners (transparent), white center, used as a 9-slice via
-- ScaleType.Slice + SliceCenter so the chamfer angle stays clean at any
-- container aspect ratio.
--
-- The header is a hexagonal ImageLabel (height = 2*CHAMFER so the top and
-- bottom chamfers meet in the middle = a 6-sided shape). The body is a
-- chamfered rectangle ImageLabel that grows with feature count. They line
-- up at the seam because both use the same 24px chamfer.

local theme = require("ui.theme")

local UIS = game:GetService("UserInputService")

local Container = {}
Container.__index = Container

local nextIndex = 0

local IMAGE_ID     = "rbxassetid://77797049442743"
local CHAMFER      = 24
local SLICE_CENTER = Rect.new(CHAMFER, CHAMFER, 64 - CHAMFER, 64 - CHAMFER)
local HEADER_H     = CHAMFER * 2   -- = 48; makes the header a clean hexagon

function Container.new(parent, name)
    local self = setmetatable({}, Container)

    local idx = nextIndex
    nextIndex = nextIndex + 1
    local containerW = theme.containerWidth
    local x = 16 + idx * (containerW + theme.containerGap)

    local root = Instance.new("Frame")
    root.Name = "Container_" .. name
    root.Size = UDim2.new(0, containerW, 0, HEADER_H)
    root.AutomaticSize = Enum.AutomaticSize.Y
    root.Position = UDim2.fromOffset(x, 16)
    root.BackgroundTransparency = 1
    root.Parent = parent

    local rootList = Instance.new("UIListLayout", root)
    rootList.FillDirection = Enum.FillDirection.Vertical
    rootList.SortOrder = Enum.SortOrder.LayoutOrder

    -- Header: hexagonal chamfered shape in accent color
    local header = Instance.new("ImageLabel")
    header.Name = "Header"
    header.Size = UDim2.new(1, 0, 0, HEADER_H)
    header.BackgroundTransparency = 1
    header.Image = IMAGE_ID
    header.ImageColor3 = theme.accent
    header.ScaleType = Enum.ScaleType.Slice
    header.SliceCenter = SLICE_CENTER
    header.LayoutOrder = 1
    header.Parent = root

    local headerText = Instance.new("TextLabel")
    headerText.Size = UDim2.fromScale(1, 1)
    headerText.BackgroundTransparency = 1
    headerText.Text = name
    headerText.TextColor3 = theme.fg
    headerText.Font = theme.fontBold
    headerText.TextSize = 13
    headerText.ZIndex = 5
    headerText.Parent = header

    local dragHandle = Instance.new("TextButton")
    dragHandle.Size = UDim2.fromScale(1, 1)
    dragHandle.BackgroundTransparency = 1
    dragHandle.Text = ""
    dragHandle.AutoButtonColor = false
    dragHandle.ZIndex = 8
    dragHandle.Parent = header

    -- Body: chamfered rectangle in body color, grows with features
    local body = Instance.new("ImageLabel")
    body.Name = "Body"
    body.Size = UDim2.new(1, 0, 0, 0)
    body.AutomaticSize = Enum.AutomaticSize.Y
    body.BackgroundTransparency = 1
    body.Image = IMAGE_ID
    body.ImageColor3 = theme.bg
    body.ScaleType = Enum.ScaleType.Slice
    body.SliceCenter = SLICE_CENTER
    body.LayoutOrder = 2
    body.Parent = root

    -- Inset features so they don't render outside the chamfered region.
    local bodyPad = Instance.new("UIPadding", body)
    bodyPad.PaddingTop    = UDim.new(0, CHAMFER + 4)
    bodyPad.PaddingBottom = UDim.new(0, CHAMFER + 4)
    bodyPad.PaddingLeft   = UDim.new(0, 8)
    bodyPad.PaddingRight  = UDim.new(0, 8)

    local features = Instance.new("Frame")
    features.Name = "Features"
    features.Size = UDim2.new(1, 0, 0, 0)
    features.AutomaticSize = Enum.AutomaticSize.Y
    features.BackgroundTransparency = 1
    features.Parent = body

    local featuresList = Instance.new("UIListLayout", features)
    featuresList.SortOrder = Enum.SortOrder.LayoutOrder
    featuresList.Padding = UDim.new(0, 1)

    -- Drag
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
