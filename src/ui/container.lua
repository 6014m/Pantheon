-- Draggable category container. Real chamfered (60-degree) corners at all four
-- corners — the container outline itself is hex-angled, not a rectangle with
-- hex decorations stuck on.
--
-- Layout (vertical stack via UIListLayout):
--    /=========\        <- top chamfered region (accent, header)
--   /           \
--  |---HEADER---|       <- flat header section (accent)
--  |            |       <- body (theme.bg)
--  |  features  |
--  |            |
--   \          /        <- bottom chamfered region (theme.bg)
--    \========/
--
-- The chamfer is built from `CHAMFER_Y` 1-pixel-tall horizontal strips whose
-- width tapers along a 60-degree slope (chamferX = chamferY / sqrt(3)).

local theme = require("ui.theme")

local UIS = game:GetService("UserInputService")

local Container = {}
Container.__index = Container

local nextIndex = 0

local W           = nil  -- set per-instance from theme.containerWidth
local CHAMFER_Y   = 16
local CHAMFER_X   = 9    -- 16 / sqrt(3) rounded; gives a 60-degree slope
local HEADER_FLAT = 16   -- height of the flat (non-chamfered) part of the header

local function buildChamferRegion(parent, totalW, chamferY, chamferX, color, mirror)
    -- mirror=false : narrow at top, full width at bottom (top of container)
    -- mirror=true  : full width at top, narrow at bottom (bottom of container)
    for y = 0, chamferY - 1 do
        local pct = (y + 0.5) / chamferY   -- 0..1 down the chamfer region
        if mirror then pct = 1 - pct end
        local stripW = math.floor(totalW - 2 * chamferX * (1 - pct) + 0.5)
        local strip = Instance.new("Frame")
        strip.Size = UDim2.fromOffset(stripW, 2)  -- 2px tall = 1px overlap with neighbour
        strip.Position = UDim2.fromOffset(totalW * 0.5, y)
        strip.AnchorPoint = Vector2.new(0.5, 0)
        strip.BackgroundColor3 = color
        strip.BorderSizePixel = 0
        strip.Parent = parent
    end
end

function Container.new(parent, name)
    local self = setmetatable({}, Container)

    local idx = nextIndex
    nextIndex = nextIndex + 1
    local containerW = theme.containerWidth
    local x = 16 + idx * (containerW + theme.containerGap)

    local HEADER_H = CHAMFER_Y + HEADER_FLAT
    local BOTTOM_H = CHAMFER_Y

    local root = Instance.new("Frame")
    root.Name = "Container_" .. name
    root.Size = UDim2.new(0, containerW, 0, HEADER_H + BOTTOM_H)
    root.AutomaticSize = Enum.AutomaticSize.Y
    root.Position = UDim2.fromOffset(x, 16)
    root.BackgroundTransparency = 1
    root.Parent = parent

    local rootList = Instance.new("UIListLayout", root)
    rootList.FillDirection = Enum.FillDirection.Vertical
    rootList.SortOrder = Enum.SortOrder.LayoutOrder

    -- ============= TOP: chamfered header (accent) =============
    local header = Instance.new("Frame")
    header.Name = "Header"
    header.Size = UDim2.new(1, 0, 0, HEADER_H)
    header.BackgroundTransparency = 1
    header.LayoutOrder = 1
    header.Parent = root

    -- Chamfered strip stack (y=0 narrow -> y=CHAMFER_Y full width)
    buildChamferRegion(header, containerW, CHAMFER_Y, CHAMFER_X, theme.accent, false)

    -- Flat part of the header that sits just under the chamfer
    local headerFlat = Instance.new("Frame")
    headerFlat.Size = UDim2.new(1, 0, 0, HEADER_FLAT)
    headerFlat.Position = UDim2.fromOffset(0, CHAMFER_Y)
    headerFlat.BackgroundColor3 = theme.accent
    headerFlat.BorderSizePixel = 0
    headerFlat.Parent = header

    -- Category text (centered over the whole header)
    local headerText = Instance.new("TextLabel")
    headerText.Size = UDim2.fromScale(1, 1)
    headerText.BackgroundTransparency = 1
    headerText.Text = name
    headerText.TextColor3 = theme.fg
    headerText.Font = theme.fontBold
    headerText.TextSize = 13
    headerText.ZIndex = 5
    headerText.Parent = header

    -- Drag handle (entire header is the drag target)
    local dragHandle = Instance.new("TextButton")
    dragHandle.Size = UDim2.fromScale(1, 1)
    dragHandle.BackgroundTransparency = 1
    dragHandle.Text = ""
    dragHandle.AutoButtonColor = false
    dragHandle.ZIndex = 8
    dragHandle.Parent = header

    -- ============= MIDDLE: body (dark, holds features) =============
    local body = Instance.new("Frame")
    body.Name = "Body"
    body.Size = UDim2.new(1, 0, 0, 0)
    body.AutomaticSize = Enum.AutomaticSize.Y
    body.BackgroundColor3 = theme.bg
    body.BorderSizePixel = 0
    body.LayoutOrder = 2
    body.Parent = root

    local features = Instance.new("Frame")
    features.Name = "Features"
    features.Size = UDim2.new(1, 0, 0, 0)
    features.AutomaticSize = Enum.AutomaticSize.Y
    features.BackgroundTransparency = 1
    features.Parent = body

    local featuresList = Instance.new("UIListLayout", features)
    featuresList.SortOrder = Enum.SortOrder.LayoutOrder
    featuresList.Padding = UDim.new(0, 1)

    -- ============= BOTTOM: chamfered region (dark, mirror of top) =============
    local bottom = Instance.new("Frame")
    bottom.Name = "Bottom"
    bottom.Size = UDim2.new(1, 0, 0, BOTTOM_H)
    bottom.BackgroundTransparency = 1
    bottom.LayoutOrder = 3
    bottom.Parent = root

    buildChamferRegion(bottom, containerW, CHAMFER_Y, CHAMFER_X, theme.bg, true)

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
