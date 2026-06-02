-- Pantheon root UI. Hosts a ScreenGui that contains a `Containers` parent
-- (for draggable category windows) plus a floating hexagonal open/close button.
-- Master hotkey (default RightControl) toggles visibility.
--
-- Show/hide animation:
--   * The "P" button spins 360 degrees clockwise on show, counterclockwise on
--     hide. Anchor is centered so the spin happens in place.
--   * Each container slides in from off-screen left to its captured original
--     position with a STAGGER_DELAY between consecutive containers, so they
--     appear one after another, not all at once. Hide reverses the motion.

local env       = require("core.env")
local theme     = require("ui.theme")
local hex       = require("ui.hex")
local keybinds  = require("core.keybinds")
local container = require("ui.container")
local persist   = require("core.persist")

local UIS          = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Window = {}

local TWEEN_DURATION = 0.35
local STAGGER_DELAY  = 0.20
local OFF_SCREEN_X   = -400
local SPIN_DURATION  = 0.55

local s = {
    screenGui = nil,
    container = nil,
    openBtn   = nil,
    visible   = true,
    masterKey = Enum.KeyCode.RightControl,
    dragConns = {},   -- global UIS connections for the "P" button drag; cleared on destroy
}

-- [container Frame] = { x = origX, y = origY } captured the first time we see
-- a container in its on-screen position. Used so we can slide it back home.
local origPositions = {}

local function captureOrig(c)
    if origPositions[c] then return origPositions[c] end
    local p = { x = c.Position.X.Offset, y = c.Position.Y.Offset }
    origPositions[c] = p
    return p
end

local function animateContainers(showing)
    -- Only the OPEN (visible) containers participate, so the stagger reflects
    -- what's actually on screen instead of assuming every menu is open (which
    -- made the slide crawl when most menus were closed).
    local list = {}
    for _, c in ipairs(s.container:GetChildren()) do
        if c:IsA("GuiObject") and c.Visible then
            table.insert(list, c)
        end
    end

    -- On hide, capture each container's CURRENT spot as its home so it slides
    -- back exactly there on the next show (honoring user drags + auto-slots).
    if not showing then
        for _, c in ipairs(list) do
            origPositions[c] = { x = c.Position.X.Offset, y = c.Position.Y.Offset }
        end
    end

    local function homeX(c)
        local h = origPositions[c]
        return h and h.x or c.Position.X.Offset
    end
    table.sort(list, function(a, b) return homeX(a) < homeX(b) end)

    for i, c in ipairs(list) do
        local home = origPositions[c] or { x = c.Position.X.Offset, y = c.Position.Y.Offset }
        origPositions[c] = home
        local targetX = showing and home.x or OFF_SCREEN_X

        -- Pre-position off-screen before the show tween so the user doesn't
        -- see it teleport visually first.
        if showing then
            c.Position = UDim2.fromOffset(OFF_SCREEN_X, home.y)
        end

        task.delay((i - 1) * STAGGER_DELAY, function()
            local info = TweenInfo.new(
                TWEEN_DURATION,
                Enum.EasingStyle.Quad,
                showing and Enum.EasingDirection.Out or Enum.EasingDirection.In
            )
            TweenService:Create(c, info, {
                Position = UDim2.fromOffset(targetX, home.y),
            }):Play()
        end)
    end
end

local function spinButton(clockwise)
    if not s.openBtn then return end
    local delta = clockwise and 360 or -360
    TweenService:Create(s.openBtn,
        TweenInfo.new(SPIN_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        { Rotation = s.openBtn.Rotation + delta }
    ):Play()
end

local function buildHexButton(sg)
    local host = Instance.new("Frame")
    host.Name = "PantheonOpenButton"
    host.Size = UDim2.fromOffset(46, 40)
    -- AnchorPoint centered so Rotation spins in place. Position adjusted so
    -- the visible location matches the previous top-left placement.
    host.AnchorPoint = Vector2.new(0.5, 0.5)
    host.Position = UDim2.new(0, 39, 1, -36)
    host.BackgroundTransparency = 1
    host.ZIndex = 10
    host.Parent = sg

    if theme.panelTexture and theme.panelTexture ~= "" then
        -- Same carbon-fiber treatment as the panels, over the accent base.
        hex.build(host, 46, 40, theme.headerBand, 10, {
            image        = theme.panelTexture,
            src          = theme.panelTextureSrc or 128,
            transparency = theme.panelTextureTransparency,
            tint         = theme.panelTextureTint,
        })
    else
        hex.build(host, 46, 40, theme.headerBand, 10)
    end

    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    label.Text = "P"
    label.TextColor3 = theme.headerBand      -- match the hex button it sits on
    label.Font = theme.fontBold
    label.TextSize = 18
    label.ZIndex = 12
    label.Parent = host

    -- Border so the same-colored "P" stays visible against its hex fill.
    local labelStroke = Instance.new("UIStroke")
    labelStroke.Thickness = theme.logoStrokeThickness or 1.5
    labelStroke.Color     = theme.logoStroke or theme.fg
    labelStroke.Parent    = label

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.fromScale(1, 1)
    btn.BackgroundTransparency = 1
    btn.Text = ""
    btn.AutoButtonColor = false
    btn.ZIndex = 13
    btn.Parent = host

    -- Drag + click-to-toggle (click only fires if not dragged)
    local dragging, dragStart, startPos = false, nil, nil
    local moved = false
    btn.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
           or input.UserInputType == Enum.UserInputType.Touch then
            dragging  = true
            dragStart = input.Position
            startPos  = host.Position
            moved     = false
        end
    end)
    s.dragConns[#s.dragConns + 1] = UIS.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement
           or input.UserInputType == Enum.UserInputType.Touch then
            local delta = input.Position - dragStart
            if delta.Magnitude > 4 then moved = true end
            local g = theme.gridSize or 16
            -- Snap the DELTA so the grid starts where the button was grabbed.
            local nx = startPos.X.Offset + math.floor(delta.X / g + 0.5) * g
            local ny = startPos.Y.Offset + math.floor(delta.Y / g + 0.5) * g
            -- Clamp on-screen (centered anchor; Y is bottom-anchored so offsets
            -- are negative-up).
            local pSz   = host.Parent.AbsoluteSize
            local hw, hh = host.AbsoluteSize.X / 2, host.AbsoluteSize.Y / 2
            nx = math.clamp(nx, hw, math.max(hw, pSz.X - hw))
            ny = math.clamp(ny, hh - pSz.Y, -hh)
            host.Position = UDim2.new(startPos.X.Scale, nx, startPos.Y.Scale, ny)
        end
    end)
    s.dragConns[#s.dragConns + 1] = UIS.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
           or input.UserInputType == Enum.UserInputType.Touch then
            if dragging and not moved then Window.toggle() end
            dragging = false
        end
    end)

    return host
end

function Window.init()
    if s.screenGui then return end

    -- One-time: drop legacy saved panel positions so panels re-home to the new
    -- below-topbar / grid-aligned defaults. Guarded so it runs once per game.
    if not persist.get("ui.posReset_v1", false) then
        persist.clearPrefix("ui.pos.")
        persist.set("ui.posReset_v1", true)
    end

    local sg = Instance.new("ScreenGui")
    sg.Name = "PantheonGui"
    sg.IgnoreGuiInset = true
    sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    sg.ResetOnSpawn = false
    sg.Parent = env.guiParent()
    env.protectGui(sg)

    local containerHost = Instance.new("Frame")
    containerHost.Name = "Containers"
    containerHost.Size = UDim2.fromScale(1, 1)
    containerHost.BackgroundTransparency = 1
    containerHost.Parent = sg

    s.screenGui = sg
    s.container = containerHost
    s.openBtn   = buildHexButton(sg)

    keybinds.set("ui.master_toggle", s.masterKey, Window.toggle)
end

function Window.toggle()
    Window.setVisible(not s.visible)
end

function Window.setVisible(v)
    if s.visible == v then return end
    s.visible = v
    -- Keep the parent visible during animations; children move off-screen
    -- via Position rather than via Visible flips, so the slide tween is
    -- actually seen.
    if s.container then s.container.Visible = true end
    animateContainers(v)
    spinButton(v)
end

function Window.isVisible()
    return s.visible
end

function Window.parent()
    return s.container
end

function Window.setMasterKey(key)
    s.masterKey = key
    keybinds.set("ui.master_toggle", key, Window.toggle)
end

function Window.destroy()
    -- Disconnect the "P" button's global UIS drag handlers and every container's
    -- (both live on the global service, so destroying the GUI doesn't sever them).
    for _, c in ipairs(s.dragConns) do pcall(function() c:Disconnect() end) end
    s.dragConns = {}
    pcall(function() container.cleanup() end)

    if s.screenGui then
        pcall(function() s.screenGui:Destroy() end)
    end
    s.screenGui, s.container, s.openBtn = nil, nil, nil
    -- origPositions keys hold references to GuiObjects that just died; reset
    -- so a fresh Window.init() doesn't try to slide-animate stale frames.
    origPositions = {}
end

return Window
