-- Draggable category container as a single unified chamfered shape.
--
-- One ImageLabel renders the whole outline (using the uploaded chamfered_panel
-- asset as a 9-slice). A UIGradient on the ImageLabel provides the accent
-- header-color to body-color vertical transition with a sharp boundary at
-- HEADER_H pixels from the top. The gradient's color-stop position is in
-- normalized 0..1 space, so when AutomaticSize grows the container as
-- features are added, we update the gradient stops to keep the seam at the
-- same absolute pixel height.

local theme = require("ui.theme")

local UIS = game:GetService("UserInputService")

local Container = {}
Container.__index = Container

local nextIndex = 0

-- Drag handlers are connected to the GLOBAL UserInputService (mouse moves
-- happen outside the small drag handle), so destroying the container's GUI
-- does NOT sever them. We track them here and disconnect on teardown --
-- otherwise every Auto Re-Execute (teleport) leaks one pair per container
-- that keeps firing on every mouse move forever.
local dragConns = {}

-- Every live container, in creation order. The navigator lists these so the
-- user can open/close each menu (Wurst-style) instead of all showing at once.
local instances = {}

-- When true, newly-created containers start hidden -- the navigator toggles
-- them on. The navigator itself is built with this still false so it stays
-- visible. Reset on cleanup so a re-execute starts fresh.
Container.startHidden = false

local IMAGE_ID     = "rbxassetid://77797049442743"
local CHAMFER      = 24
local SLICE_CENTER = Rect.new(CHAMFER, CHAMFER, 64 - CHAMFER, 64 - CHAMFER)
local HEADER_H     = 36                                  -- accent-colored band height in pixels

function Container.new(parent, name)
    local self = setmetatable({}, Container)

    local idx = nextIndex
    nextIndex = nextIndex + 1
    local containerW = theme.containerWidth
    local x = 16 + idx * (containerW + theme.containerGap)

    local container = Instance.new("ImageLabel")
    container.Name = "Container_" .. name
    container.Size = UDim2.new(0, containerW, 0, HEADER_H + CHAMFER + 4)
    container.AutomaticSize = Enum.AutomaticSize.Y
    container.Position = UDim2.fromOffset(x, 16)
    container.BackgroundTransparency = 1
    container.Image = IMAGE_ID
    container.ImageColor3 = Color3.new(1, 1, 1)          -- white so the UIGradient tints freely
    container.ScaleType = Enum.ScaleType.Slice
    container.SliceCenter = SLICE_CENTER
    container.Parent = parent

    -- Reserve space at the bottom so feature rows don't sit on top of the
    -- chamfered bottom corners. PaddingTop = HEADER_H so the Features
    -- frame (UIListLayout-stacked, sitting at the top of the padded area)
    -- starts right after the accent header band.
    local pad = Instance.new("UIPadding", container)
    pad.PaddingTop    = UDim.new(0, HEADER_H)
    pad.PaddingBottom = UDim.new(0, CHAMFER + 4)
    pad.PaddingLeft   = UDim.new(0, 6)
    pad.PaddingRight  = UDim.new(0, 6)

    -- Accent (header band) -> body color, sharp seam at HEADER_H pixels from
    -- the top. UIGradient stops are normalized so we recompute on size changes.
    local gradient = Instance.new("UIGradient")
    gradient.Rotation = 90                                -- top -> bottom
    gradient.Parent = container

    local function updateGradient()
        local h = container.AbsoluteSize.Y
        if h <= 0 then return end
        local pct = math.clamp(HEADER_H / h, 0.001, 0.999)
        gradient.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0,                                 theme.accent),
            ColorSequenceKeypoint.new(pct,                               theme.accent),
            ColorSequenceKeypoint.new(math.min(pct + 0.005, 1),          theme.bg),
            ColorSequenceKeypoint.new(1,                                 theme.bg),
        })
    end
    updateGradient()
    container:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateGradient)

    -- Header text sits over the accent band. Positioned in the unpadded
    -- top region (0 .. HEADER_H) so it doesn't get shoved by UIPadding.
    local headerText = Instance.new("TextLabel")
    headerText.Name = "HeaderText"
    headerText.Size = UDim2.new(1, 0, 0, HEADER_H)
    headerText.Position = UDim2.fromOffset(0, 0)
    headerText.AnchorPoint = Vector2.new(0, 0)
    headerText.BackgroundTransparency = 1
    headerText.Text = name
    headerText.TextColor3 = theme.fg
    headerText.Font = theme.fontBold
    headerText.TextSize = 13
    headerText.TextXAlignment = Enum.TextXAlignment.Center
    headerText.TextYAlignment = Enum.TextYAlignment.Center
    headerText.ZIndex = 5
    -- IMPORTANT: UIPadding shifts ALL children by default. Parent the header
    -- text under a child Frame that bypasses the padding by anchoring outside
    -- the padded area.
    local headerHost = Instance.new("Frame")
    headerHost.Size = UDim2.new(1, 12, 0, HEADER_H)        -- +12 to undo the -6 left + -6 right padding
    headerHost.Position = UDim2.fromOffset(-6, -HEADER_H)   -- undo PaddingLeft (-6) and PaddingTop (-HEADER_H)
    headerHost.BackgroundTransparency = 1
    headerHost.ZIndex = 4
    headerHost.Parent = container
    headerText.Parent = headerHost

    local dragHandle = Instance.new("TextButton")
    dragHandle.Size = UDim2.fromScale(1, 1)
    dragHandle.BackgroundTransparency = 1
    dragHandle.Text = ""
    dragHandle.AutoButtonColor = false
    dragHandle.ZIndex = 8
    dragHandle.Parent = headerHost

    -- Features: stacked inside the padded body area. UIListLayout owns the
    -- height; AutomaticSize on the container propagates up.
    local features = Instance.new("Frame")
    features.Name = "Features"
    features.Size = UDim2.new(1, 0, 0, 0)
    features.AutomaticSize = Enum.AutomaticSize.Y
    features.BackgroundTransparency = 1
    features.Parent = container

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
                startPos  = container.Position
            end
        end)
        dragConns[#dragConns + 1] = UIS.InputChanged:Connect(function(input)
            if not dragging then return end
            if input.UserInputType == Enum.UserInputType.MouseMovement
               or input.UserInputType == Enum.UserInputType.Touch then
                local delta = input.Position - dragStart
                container.Position = UDim2.new(
                    startPos.X.Scale, startPos.X.Offset + delta.X,
                    startPos.Y.Scale, startPos.Y.Offset + delta.Y
                )
            end
        end)
        dragConns[#dragConns + 1] = UIS.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
               or input.UserInputType == Enum.UserInputType.Touch then
                dragging = false
            end
        end)
    end

    self.root     = container
    self.features = features
    self.name     = name
    self._count   = 0

    -- Start hidden when the navigator is driving visibility; it flips us on.
    self.visible = not Container.startHidden
    container.Visible = self.visible
    instances[#instances + 1] = self

    return self
end

function Container:isVisible()
    return self.visible ~= false
end

function Container:setVisible(v)
    v = v and true or false
    self.visible = v
    self.root.Visible = v
    if self._onVis then self._onVis(v) end
end

function Container.list()
    return instances
end

function Container:add(featureRoot)
    self._count = self._count + 1
    featureRoot.LayoutOrder = self._count
    featureRoot.Parent = self.features
    return self
end

-- The single "menu" that opens/closes every other container (Wurst-style).
-- Build it BEFORE the feature containers (so it's leftmost + stays visible),
-- then call nav.populate() AFTER all modules register so it lists every menu.
function Container.buildNavigator(parent, title)
    local nav = Container.new(parent, title or "Pantheon")
    nav.isNav = true

    function nav.populate()
        for _, c in ipairs(instances) do
            if c ~= nav and not c.isNav then
                local row = Instance.new("TextButton")
                row.Name = "Nav_" .. tostring(c.name)
                row.Size = UDim2.new(1, 0, 0, 26)
                row.BackgroundColor3 = theme.bgAlt
                row.AutoButtonColor = true
                row.BorderSizePixel = 0
                row.Font = theme.font
                row.TextSize = 12
                row.TextColor3 = theme.fg
                row.TextXAlignment = Enum.TextXAlignment.Left
                row.Text = "  " .. tostring(c.name)

                local pill = Instance.new("TextLabel")
                pill.Size = UDim2.fromOffset(42, 16)
                pill.Position = UDim2.new(1, -46, 0.5, -8)
                pill.BorderSizePixel = 0
                pill.Font = theme.fontBold
                pill.TextSize = 10
                pill.TextColor3 = theme.fg
                pill.Parent = row

                local function refresh()
                    local on = c:isVisible()
                    pill.Text = on and "ON" or "OFF"
                    pill.BackgroundColor3 = on and theme.on or theme.off
                end
                c._onVis = refresh
                row.MouseButton1Click:Connect(function()
                    c:setVisible(not c:isVisible())
                end)
                refresh()
                nav:add(row)
            end
        end
    end

    return nav
end

-- Disconnect every container's global drag handlers. Called from Window.destroy()
-- (the UI teardown entry point) so re-execute doesn't stack listeners. Also reset
-- nextIndex so a fresh boot lays containers out from the left again.
function Container.cleanup()
    for _, c in ipairs(dragConns) do pcall(function() c:Disconnect() end) end
    dragConns = {}
    nextIndex = 0
    instances = {}
    Container.startHidden = false
end

return Container
