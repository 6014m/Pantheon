-- Draggable category container. The outline itself is hex-angled at all four
-- corners (60-degree chamfer = hexagon interior angle). The shape is built in
-- two passes:
--   1. Row-stack: stacked horizontal strips whose width tapers along the
--      60-degree slope, drawing the FILL.
--   2. Anti-aliased diagonal overlays: each chamfered edge gets a rotated
--      rectangle laid directly on top of it. Rotated frame edges in Roblox
--      ARE anti-aliased (axis-aligned frame edges are not), so the rotated
--      overlay smooths the stairsteps visible in pass 1.
--
-- Layout (vertical stack via UIListLayout):
--     /===========\        <- top chamfered region (accent, header)
--    /             \
--   |---HEADER------|      <- flat header section (accent)
--   |               |      <- body (theme.bg) with feature rows
--   |               |
--    \             /       <- bottom chamfered region (theme.bg)
--     \===========/

local theme = require("ui.theme")

local UIS = game:GetService("UserInputService")

local Container = {}
Container.__index = Container

local nextIndex = 0

-- Chamfer geometry — these give a 60-degree slope (= regular hex angle).
local CHAMFER_Y   = 24
local CHAMFER_X   = 14            -- = round(CHAMFER_Y / sqrt(3))
local HEADER_FLAT = 16

local function buildChamferRegion(parent, totalW, chamferY, chamferX, color, mirror)
    -- ---------- pass 1: row-stack fill ----------
    for y = 0, chamferY - 1 do
        local pct = (y + 0.5) / chamferY
        if mirror then pct = 1 - pct end
        local stripW = math.floor(totalW - 2 * chamferX * (1 - pct) + 0.5)
        local strip = Instance.new("Frame")
        -- 2px tall = 1px overlap between adjacent strips so the fill has no gaps.
        strip.Size = UDim2.fromOffset(stripW, 2)
        strip.Position = UDim2.fromOffset(totalW * 0.5, y)
        strip.AnchorPoint = Vector2.new(0.5, 0)
        strip.BackgroundColor3 = color
        strip.BorderSizePixel = 0
        strip.Parent = parent
    end

    -- ---------- pass 2: anti-aliased diagonal overlay ----------
    local hyp = math.sqrt(chamferX * chamferX + chamferY * chamferY)
    local angleDeg = math.deg(math.atan2(chamferY, chamferX))  -- ~60.0 for our ratio

    local function placeEdge(midX, midY, rotation)
        local edge = Instance.new("Frame")
        -- A rotated rectangle laid over the diagonal. The long-axis edges of
        -- this rectangle (the diagonals as seen on screen) get the Roblox
        -- rotated-edge anti-aliasing pass, which is what smooths the
        -- row-stack stairsteps below it. The 4px thickness extends ~2px on
        -- each side of the ideal diagonal — enough to cover the stairsteps
        -- and small enough that the tiny intrusion into the cut-corner area
        -- isn't visible.
        edge.Size = UDim2.fromOffset(hyp + 4, 4)
        edge.AnchorPoint = Vector2.new(0.5, 0.5)
        edge.Position = UDim2.fromOffset(midX, midY)
        edge.Rotation = rotation
        edge.BackgroundColor3 = color
        edge.BorderSizePixel = 0
        edge.Parent = parent
    end

    -- Diagonals run from corner to corner of each region. Each diagonal's
    -- screen-space angle is angleDeg or 180-angleDeg depending on which
    -- corner of which region.
    if not mirror then
        -- Top region: narrow up top, full width at bottom.
        --   left edge:  (chamferX, 0) -> (0, chamferY)        -> 180 - angleDeg
        --   right edge: (W-chamferX, 0) -> (W, chamferY)      -> angleDeg
        placeEdge(chamferX / 2,         chamferY / 2, 180 - angleDeg)
        placeEdge(totalW - chamferX / 2, chamferY / 2, angleDeg)
    else
        -- Bottom region: full width up top, narrow at bottom.
        --   left edge:  (0, 0) -> (chamferX, chamferY)        -> angleDeg
        --   right edge: (W, 0) -> (W-chamferX, chamferY)      -> 180 - angleDeg
        placeEdge(chamferX / 2,         chamferY / 2, angleDeg)
        placeEdge(totalW - chamferX / 2, chamferY / 2, 180 - angleDeg)
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

    buildChamferRegion(header, containerW, CHAMFER_Y, CHAMFER_X, theme.accent, false)

    local headerFlat = Instance.new("Frame")
    headerFlat.Size = UDim2.new(1, 0, 0, HEADER_FLAT)
    headerFlat.Position = UDim2.fromOffset(0, CHAMFER_Y)
    headerFlat.BackgroundColor3 = theme.accent
    headerFlat.BorderSizePixel = 0
    headerFlat.Parent = header

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
