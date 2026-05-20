-- Draggable category container.
--
-- Visual: header bends OUTWARD at the top (chamfered top corners), then
-- contorts into a square body below. No second inward chamfer at the
-- header-body seam.
--
-- Implementation:
--   * Header is an ImageLabel using the uploaded chamfered_panel image
--     (rbxassetid://77797049442743) tinted accent. The image has chamfers on
--     ALL four corners, so we lay a solid accent-colored strip across the
--     bottom 24px to hide the bottom chamfer -- net visual is "chamfered
--     top, flat rectangular bottom."
--   * Body is just a plain Frame with theme.bg and a 1px UIStroke. Square
--     corners, full width, grows with the feature stack.

local theme = require("ui.theme")

local UIS = game:GetService("UserInputService")

local Container = {}
Container.__index = Container

local nextIndex = 0

local IMAGE_ID     = "rbxassetid://77797049442743"
local CHAMFER      = 24
local SLICE_CENTER = Rect.new(CHAMFER, CHAMFER, 64 - CHAMFER, 64 - CHAMFER)
local HEADER_H     = 48                                  -- 2 * CHAMFER

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

    -- Header: chamfered ImageLabel
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

    -- Hide the IMAGE's bottom chamfer so the header bottom reads as a flat
    -- rectangle that feeds directly into the body. Accent-colored strip
    -- covers the bottom 24px (the chamfered-corner row of the 9-slice).
    local bottomCover = Instance.new("Frame")
    bottomCover.Name = "BottomCover"
    bottomCover.Size = UDim2.new(1, 0, 0, CHAMFER)
    bottomCover.Position = UDim2.new(0, 0, 1, -CHAMFER)
    bottomCover.BackgroundColor3 = theme.accent
    bottomCover.BorderSizePixel = 0
    bottomCover.ZIndex = 2
    bottomCover.Parent = header

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

    -- Body: plain square panel
    local body = Instance.new("Frame")
    body.Name = "Body"
    body.Size = UDim2.new(1, 0, 0, 0)
    body.AutomaticSize = Enum.AutomaticSize.Y
    body.BackgroundColor3 = theme.bg
    body.BorderSizePixel = 0
    body.LayoutOrder = 2
    body.Parent = root

    local stroke = Instance.new("UIStroke", body)
    stroke.Color = theme.border
    stroke.Thickness = 1

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
