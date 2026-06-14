-- Draggable category container as a single unified chamfered shape.
--
-- One ImageLabel renders the whole outline (using the uploaded chamfered_panel
-- asset as a 9-slice). A UIGradient on the ImageLabel provides the accent
-- header-color to body-color vertical transition with a sharp boundary at
-- HEADER_H pixels from the top. The gradient's color-stop position is in
-- normalized 0..1 space, so when AutomaticSize grows the container as
-- features are added, we update the gradient stops to keep the seam at the
-- same absolute pixel height.

local theme   = require("ui.theme")
local persist = require("core.persist")

local UIS        = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

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

-- Auto-placement: opened containers without a user-saved position pack into
-- slots immediately to the right of the navigator (slot 0 = nearest). Closing
-- one frees its slot. navRef points at the navigator so the slots follow it
-- even if the user drags it.
local slots  = {}
local navRef = nil

local function posKey(name)  return "ui.pos."  .. persist.slug(name) end
local function openKey(name) return "ui.open." .. persist.slug(name) end

-- Default Y for auto-placed containers: the Roblox topbar height + a margin.
-- The ScreenGui uses IgnoreGuiInset, so without this offset panels spawn UNDER
-- the topbar in games that show it. The bottom-anchored P button is unaffected.
local function baseTopY()
    local ok, inset = pcall(function() return GuiService:GetGuiInset() end)
    return ((ok and inset and inset.Y) or 36) + 16
end

-- Quantize a position to the drag-snap grid so panels snap to a grid instead
-- of free pixel drag.
local function snap(v)
    local g = theme.gridSize or 16
    return math.floor(v / g + 0.5) * g
end

local IMAGE_ID     = "rbxassetid://77797049442743"
local CHAMFER      = 24
local SLICE_CENTER = Rect.new(CHAMFER, CHAMFER, 64 - CHAMFER, 64 - CHAMFER)
local HEADER_H     = 36                                  -- accent-colored band height in pixels

function Container.new(parent, name)
    local self = setmetatable({}, Container)
    self._dragConns = {}   -- this container's global-UIS drag handlers (also see Container:destroy)

    local idx = nextIndex
    nextIndex = nextIndex + 1
    local containerW = theme.containerWidth
    local x = 16 + idx * (containerW + theme.containerGap)

    local container = Instance.new("ImageLabel")
    container.Name = "Container_" .. name
    container.Size = UDim2.new(0, containerW, 0, HEADER_H + CHAMFER + 4)
    container.AutomaticSize = Enum.AutomaticSize.Y
    container.Position = UDim2.fromOffset(x, baseTopY())
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

    local lastGradPct = -1
    local function updateGradient()
        local h = container.AbsoluteSize.Y
        if h <= 0 then return end
        local pct = math.clamp(HEADER_H / h, 0.001, 0.999)
        -- The seam sits at `pct` of the height; skip rebuilding the 4-stop
        -- ColorSequence when a size change doesn't move it visibly (AbsoluteSize
        -- fires repeatedly as feature/cog panels expand and collapse).
        if math.abs(pct - lastGradPct) < 0.002 then return end
        lastGradPct = pct
        gradient.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0,                                 theme.headerBand),
            ColorSequenceKeypoint.new(pct,                               theme.headerBand),
            ColorSequenceKeypoint.new(math.min(pct + 0.005, 1),          theme.bg),
            ColorSequenceKeypoint.new(1,                                 theme.bg),
        })
    end
    updateGradient()
    container:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateGradient)

    -- Carbon-fiber texture over the panel so the near-black bodies stay distinct
    -- from each other and the world. Tiled, behind content (ZIndex 0), rounded
    -- so the rectangular tile doesn't poke past the chamfered edge. Skipped
    -- entirely when no texture asset is configured (theme.panelTexture == "").
    if theme.panelTexture and theme.panelTexture ~= "" then
        local carbon = Instance.new("ImageLabel")
        carbon.Name = "CarbonTexture"
        carbon.BackgroundTransparency = 1
        carbon.Image = theme.panelTexture
        carbon.ScaleType = Enum.ScaleType.Tile
        carbon.TileSize = UDim2.fromOffset(theme.panelTextureTile or 96, theme.panelTextureTile or 96)
        carbon.ImageColor3 = theme.panelTextureTint or Color3.new(1, 1, 1)
        carbon.ImageTransparency = theme.panelTextureTransparency or 0.85
        -- Cover the full panel, countering the container's UIPadding (like headerHost).
        carbon.Size = UDim2.new(1, 12, 1, HEADER_H + CHAMFER + 4)
        carbon.Position = UDim2.fromOffset(-6, -HEADER_H)
        carbon.ZIndex = 0
        carbon.Parent = container
        local cc = Instance.new("UICorner", carbon)
        cc.CornerRadius = UDim.new(0, CHAMFER)
    end

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
    local features = Instance.new("ScrollingFrame")
    features.Name = "Features"
    features.Size = UDim2.new(1, 0, 0, 0)                  -- height set by fitFeatures()
    features.AutomaticCanvasSize = Enum.AutomaticSize.Y    -- canvas tracks content
    features.CanvasSize = UDim2.new(0, 0, 0, 0)
    features.BackgroundTransparency = 1
    features.BorderSizePixel = 0
    features.ScrollingDirection = Enum.ScrollingDirection.Y
    features.ScrollBarThickness = 4
    features.ScrollBarImageColor3 = theme.accent
    features.Parent = container

    local featuresList = Instance.new("UIListLayout", features)
    featuresList.SortOrder = Enum.SortOrder.LayoutOrder
    featuresList.Padding = UDim.new(0, 1)

    -- Body height = content height, capped to the viewport so a tall panel scrolls
    -- instead of running off-screen. (AutomaticSize on a ScrollingFrame fights
    -- AutomaticCanvasSize and never actually scrolls -- size from the layout's
    -- content height instead, and only enable scrolling once it overflows.)
    local vph = (workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize.Y) or 720
    local capH = math.max(160, vph - baseTopY() - 90)
    local function fitFeatures()
        local h = featuresList.AbsoluteContentSize.Y
        features.Size = UDim2.new(1, 0, 0, math.min(h, capH))
        features.ScrollingEnabled = h > capH
    end
    featuresList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(fitFeatures)
    fitFeatures()

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
        local moveConn = UIS.InputChanged:Connect(function(input)
            if not dragging then return end
            if input.UserInputType == Enum.UserInputType.MouseMovement
               or input.UserInputType == Enum.UserInputType.Touch then
                local delta = input.Position - dragStart
                -- Snap the DELTA so the grid starts where the panel was grabbed.
                local nx = startPos.X.Offset + snap(delta.X)
                local ny = startPos.Y.Offset + snap(delta.Y)
                -- Clamp so the panel can't be dragged off-screen.
                local pSz = container.Parent.AbsoluteSize
                local sSz = container.AbsoluteSize
                nx = math.clamp(nx, 0, math.max(0, pSz.X - sSz.X))
                ny = math.clamp(ny, 0, math.max(0, pSz.Y - sSz.Y))
                container.Position = UDim2.new(startPos.X.Scale, nx, startPos.Y.Scale, ny)
            end
        end)
        local endConn = UIS.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
               or input.UserInputType == Enum.UserInputType.Touch then
                if dragging then
                    dragging = false
                    -- A real drag (not just a click) pins this container: save
                    -- the spot so it reopens here, and free its auto-slot.
                    local p = container.Position
                    if startPos and (p.X.Offset ~= startPos.X.Offset
                                     or p.Y.Offset ~= startPos.Y.Offset) then
                        self.userMoved = true
                        self:_freeSlot()
                        persist.set(posKey(name), { x = p.X.Offset, y = p.Y.Offset })
                    end
                end
            end
        end)
        -- Track on both the global list (Container.cleanup disconnects all at
        -- re-execute) and this container (Container:destroy disconnects just its
        -- own when a single addon menu is torn down).
        dragConns[#dragConns + 1] = moveConn
        dragConns[#dragConns + 1] = endConn
        self._dragConns[#self._dragConns + 1] = moveConn
        self._dragConns[#self._dragConns + 1] = endConn
    end

    self.root     = container
    self.features = features
    self.name     = name
    self._count   = 0

    -- Restore a user-dragged position if we saved one before; otherwise the
    -- navigator auto-places us next to it on open.
    local sp = persist.get(posKey(name))
    if type(sp) == "table" and tonumber(sp.x) and tonumber(sp.y) then
        self.userMoved = true
        container.Position = UDim2.fromOffset(tonumber(sp.x), tonumber(sp.y))
    end

    -- Start hidden when the navigator is driving visibility; it flips us on.
    self.visible = not Container.startHidden
    container.Visible = self.visible
    instances[#instances + 1] = self

    return self
end

function Container:isVisible()
    return self.visible ~= false
end

-- Place an auto-positioned (not user-moved) container in the first free slot to
-- the right of the navigator. No-op if the user dragged it (honor the saved
-- spot) or it already holds a slot.
function Container:_placeIfNeeded()
    if self.userMoved or self.slot ~= nil then return end
    local k = 0
    while slots[k] ~= nil do k = k + 1 end
    slots[k] = self
    self.slot = k
    local w, gap = theme.containerWidth, theme.containerGap
    local baseX, baseY = 16 + w + gap, baseTopY()
    if navRef and navRef.root then
        baseX = navRef.root.Position.X.Offset + w + gap
        baseY = navRef.root.Position.Y.Offset
    end
    self.root.Position = UDim2.fromOffset(baseX + k * (w + gap), baseY)
end

function Container:_freeSlot()
    if self.slot ~= nil then slots[self.slot] = nil; self.slot = nil end
end

function Container:setVisible(v)
    v = v and true or false
    self.visible = v
    self.root.Visible = v
    if v then self:_placeIfNeeded() else self:_freeSlot() end
    persist.set(openKey(self.name), v)
    if self._onVis then self._onVis(v) end
end

function Container.list()
    return instances
end

-- Tear down a SINGLE container (used when an addon menu is toggled off / the
-- addon is disabled or reloaded). Disconnects this container's own global drag
-- handlers, drops it from the instances list (so a navigator refresh won't relist
-- it), frees its auto-slot, and destroys the GUI. Container.cleanup() remains the
-- nuke-everything path used at re-execute.
function Container:destroy()
    if self._dragConns then
        for _, c in ipairs(self._dragConns) do pcall(function() c:Disconnect() end) end
        self._dragConns = {}
    end
    self:_freeSlot()
    for i, c in ipairs(instances) do if c == self then table.remove(instances, i); break end end
    if self.root then pcall(function() self.root:Destroy() end); self.root = nil end
    self.visible = false
end

-- Re-run the navigator's row build (it clears + rebuilds), so containers created
-- or destroyed AFTER the initial nav.populate() (e.g. addons installed/toggled at
-- runtime) appear/disappear in the menu list.
function Container.refreshNavigator()
    if navRef and navRef.populate then navRef.populate() end
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
    navRef = nav

    function nav.populate()
        -- Clear existing rows first so this doubles as a refresh (addons created
        -- or removed after boot re-run it via Container.refreshNavigator).
        for _, ch in ipairs(nav.features:GetChildren()) do
            if not ch:IsA("UIListLayout") then ch:Destroy() end
        end
        nav._count = 0
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
                -- Restore the saved open/closed state (default closed) so the
                -- user's layout comes back on reload.
                c:setVisible(persist.get(openKey(c.name), false) == true)
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
    slots     = {}
    navRef    = nil
    Container.startHidden = false
end

return Container
