-- Optional UI skins.
--
-- A skin is a DECORATION LAYER, not a second UI. Every ui/* module builds the
-- same instance tree it always did, then hands the pieces it just made to a
-- hook in here. For the default skin ("flat") every hook is a no-op, so the
-- hub looks and behaves exactly as before. For "hardware" the hooks draw the
-- extra geometry that makes a panel read as one physical object: a machined
-- faceplate with corner screws, raised keycaps seated in it, recessed wells
-- for the things you read rather than press, backlit latching switches, and
-- real bevels (a light edge where the light hits, a dark edge where it
-- doesn't) on all of it.
--
-- Why decorate instead of fork: the flat path stays byte-identical, and a new
-- component only has to be skinned in ONE place (here) instead of in every
-- module that builds one.
--
-- The active skin is chosen ONCE at load (Pantheon menu -> cog -> UI Skin) and
-- lives in the cross-game global store, so it follows you into every game.
-- Switching is a reload, not a live re-style: the hooks run during
-- construction and what they add can't be un-drawn cleanly.
--
-- Roblox notes that shape the code below:
--   * The ScreenGui is ZIndexBehavior.Sibling, so a decoration parented under a
--     low-ZIndex host stays under everything the host is under, whatever ZIndex
--     it uses internally. That's what lets the panel chassis sit at ZIndex 0
--     and still layer its own screws/vents above its own faceplate.
--   * A GuiObject can hold only ONE UIGradient, so anything needing two passes
--     (brushed streaks AND a top-down light falloff) gets an overlay frame.
--   * Bevel edges are Frames, so they must NEVER be parented to something with
--     a UIListLayout (they'd become list items) or a UIPadding (they'd be
--     inset). Those get stroke()/gradient treatment instead.

local theme   = require("ui.theme")
local hex     = require("ui.hex")
local persist = require("core.persist")

local skin = {}

local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)

-- ---------------------------------------------------------------------------
-- flat: the original look. Every hook is a no-op or forwards to the old call.
-- ---------------------------------------------------------------------------

local flat = {}

function flat.applyTheme() end
function flat.usePanelTexture() return true end
function flat.panel() end
function flat.key() end
function flat.well() end
function flat.face() end
function flat.readout() end
function flat.engrave() end
function flat.separator() end
function flat.press() end
function flat.logo() end

-- ON/OFF-style hex buttons (feature row indicator, the "i" and the cog). The
-- flat skin keeps the hex.setColor + label swap the row used to do inline.
function flat.hexKey(host, hexHost, label, opts)
    opts = opts or {}
    return {
        set = function(on)
            hex.setColor(hexHost, on and opts.onColor or opts.offColor)
            if opts.onText or opts.offText then
                label.Text = on and (opts.onText or "") or (opts.offText or "")
            end
        end,
    }
end

function flat.switch() return { set = function() end } end
function flat.slider() return { set = function() end } end
function flat.led()    return { set = function() end } end

-- ---------------------------------------------------------------------------
-- hardware: a machined faceplate with real controls bolted to it.
-- ---------------------------------------------------------------------------

local hw = {}

-- Faceplate / key / well palette. Kept local (not in theme) because these are
-- lighting values for the bevel maths, not user-facing colors.
local C = {
    bezel    = Color3.fromRGB(10, 11, 13),   -- the chamfered rim around the plate
    faceTop  = Color3.fromRGB(44, 47, 52),   -- faceplate, lit streak
    faceBot  = Color3.fromRGB(28, 30, 34),   -- faceplate, shadowed streak
    bandTop  = Color3.fromRGB(58, 62, 69),   -- header bar, lit edge
    bandBot  = Color3.fromRGB(36, 39, 44),
    keyTop   = Color3.fromRGB(62, 66, 73),   -- raised keycap
    keyBot   = Color3.fromRGB(40, 43, 48),
    wellTop  = Color3.fromRGB(13, 14, 16),   -- recessed well (shadowed at top)
    wellBot  = Color3.fromRGB(26, 28, 32),
    screw    = Color3.fromRGB(96, 101, 110),
    screwDk  = Color3.fromRGB(24, 26, 29),
    etch     = Color3.fromRGB(150, 156, 166),
}

-- Bevel edge transparencies. The lit edge is subtle; the shadow does most of
-- the work of selling depth.
local HI_T, LO_T = 0.70, 0.42

local function corner(inst, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 2)
    c.Parent = inst
    return c
end

local function gradient(inst, top, bottom, rotation)
    local g = Instance.new("UIGradient")
    g.Rotation = rotation or 90
    g.Color = ColorSequence.new(top, bottom)
    g.Parent = inst
    return g
end

local function stroke(inst, color, transparency, thickness)
    local s = Instance.new("UIStroke")
    s.Color = color or BLACK
    s.Transparency = transparency or 0.5
    s.Thickness = thickness or 1
    s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    s.Parent = inst
    return s
end

-- Four edge Frames wrapped in one transparent host, so a control can hold both
-- a raised and a recessed set and flip between them with .Visible instead of
-- rebuilding eight instances on every press.
-- NEVER call this on a frame carrying a UIListLayout or UIPadding (see header).
local function bevel(frame, mode, thickness, z)
    thickness = thickness or 1
    z = z or 3
    local raised = (mode ~= "recessed")

    local host = Instance.new("Frame")
    host.Name = raised and "BevelRaised" or "BevelRecessed"
    host.Size = UDim2.fromScale(1, 1)
    host.BackgroundTransparency = 1
    host.ZIndex = z
    host.Parent = frame

    local hi,  lo  = raised and WHITE or BLACK, raised and BLACK or WHITE
    local hiT, loT = raised and HI_T  or LO_T,  raised and LO_T  or HI_T

    local function edge(pos, size, color, tr)
        local f = Instance.new("Frame")
        f.BackgroundColor3 = color
        f.BackgroundTransparency = tr
        f.BorderSizePixel = 0
        f.Position = pos
        f.Size = size
        f.ZIndex = z
        f.Parent = host
    end
    edge(UDim2.fromOffset(0, 0),         UDim2.new(1, 0, 0, thickness), hi, hiT)
    edge(UDim2.fromOffset(0, 0),         UDim2.new(0, thickness, 1, 0), hi, hiT)
    edge(UDim2.new(0, 0, 1, -thickness), UDim2.new(1, 0, 0, thickness), lo, loT)
    edge(UDim2.new(1, -thickness, 0, 0), UDim2.new(0, thickness, 1, 0), lo, loT)
    return host
end

-- A screw head: bright ring, dark recess, crossed slots. Sized to whatever `d`
-- you pass; used at the faceplate corners.
local function screw(parent, d, position, anchor, z)
    local host = Instance.new("Frame")
    host.Name = "Screw"
    host.Size = UDim2.fromOffset(d, d)
    host.Position = position
    host.AnchorPoint = anchor or Vector2.new(0, 0)
    host.BackgroundColor3 = C.screw
    host.BorderSizePixel = 0
    host.ZIndex = z or 4
    host.Parent = parent
    corner(host, d)                          -- radius >= d/2 rounds to a circle
    gradient(host, C.screw, C.screwDk)
    stroke(host, BLACK, 0.35, 1)

    local function slot(size)
        local f = Instance.new("Frame")
        f.AnchorPoint = Vector2.new(0.5, 0.5)
        f.Position = UDim2.fromScale(0.5, 0.5)
        f.Size = size
        f.BackgroundColor3 = C.screwDk
        f.BackgroundTransparency = 0.15
        f.BorderSizePixel = 0
        f.ZIndex = (z or 4) + 1
        f.Parent = host
    end
    slot(UDim2.new(0.7, 0, 0, 1))
    slot(UDim2.new(0, 1, 0.7, 0))
    return host
end

-- ---- hooks ----------------------------------------------------------------

-- Repaint the shared theme for the hardware skin. Runs once, at skin load,
-- BEFORE any UI is constructed (every ui/* module reads theme.* at build time,
-- not at require time), so there is nothing to refresh afterwards.
function hw.applyTheme(t)
    -- The container's chamfered 9-slice is tinted by a headerBand -> bg
    -- gradient. Hardware draws its own header band on the chassis, so both
    -- stops collapse to the bezel color and the 9-slice becomes a plain rim
    -- around the faceplate.
    t.headerBand = C.bezel
    t.bg         = C.bezel
    t.bgAlt      = C.faceBot
    t.bgDark     = C.wellTop
    t.accent     = Color3.fromRGB(138, 146, 158)   -- brushed steel
    t.border     = Color3.fromRGB(12, 13, 15)
    t.fg         = Color3.fromRGB(226, 230, 238)
    t.fgDim      = Color3.fromRGB(138, 144, 154)
    t.logoStroke = Color3.fromRGB(226, 230, 238)
    -- Feature rows become keycaps; a key needs a little more height to read as
    -- one, and the gap between them is what stops neighbours fusing into a slab.
    t.featureHeight = 32
    t.rowHeight     = 32
end

-- The carbon-fiber tile is the flat skin's way of keeping near-black panels
-- distinct. Hardware has its own faceplate treatment and the two fight, so it
-- tells container.lua to skip the overlay.
function hw.usePanelTexture() return false end

-- The faceplate itself. `container` is the chamfered ImageLabel; it carries a
-- UIPadding (top = headerH, bottom = chamferH + 4, sides = 6) that we counter
-- the same way the carbon overlay does, then inset by INSET so the 9-slice rim
-- shows as a machined bezel around the plate.
function hw.panel(container, headerH, chamferH)
    local INSET = 3

    local chassis = Instance.new("Frame")
    chassis.Name = "Chassis"
    chassis.BackgroundColor3 = C.faceBot
    chassis.BorderSizePixel = 0
    chassis.Size = UDim2.new(1, 12 - INSET * 2, 1, headerH + chamferH + 4 - INSET * 2)
    chassis.Position = UDim2.fromOffset(-6 + INSET, -headerH + INSET)
    chassis.ZIndex = 0
    chassis.Parent = container
    corner(chassis, 16)

    -- Brushed metal: alternating light/dark stops at rotation 0 give vertical
    -- hairline streaks for the price of one instance. (ColorSequence caps at 20
    -- keypoints, hence the 19 below.)
    do
        local stops, n = {}, 18
        for i = 0, n do
            stops[#stops + 1] = ColorSequenceKeypoint.new(
                i / n, (i % 2 == 0) and C.faceTop or C.faceBot)
        end
        local g = Instance.new("UIGradient")
        g.Rotation = 0
        g.Color = ColorSequence.new(stops)
        g.Parent = chassis
    end

    -- Second pass: the top-down light falloff the chassis gradient can't also
    -- carry. Black, faded to nearly nothing at the top.
    local shade = Instance.new("Frame")
    shade.Name = "Shade"
    shade.Size = UDim2.fromScale(1, 1)
    shade.BackgroundColor3 = BLACK
    shade.BorderSizePixel = 0
    shade.ZIndex = 1
    shade.Parent = chassis
    corner(shade, 16)
    do
        local g = Instance.new("UIGradient")
        g.Rotation = 90
        g.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.92),
            NumberSequenceKeypoint.new(1, 0.45),
        })
        g.Parent = shade
    end

    -- Header bar: a raised strip across the top of the plate, seamed off from
    -- the body by a dark groove with a lit lip under it.
    local band = Instance.new("Frame")
    band.Name = "HeaderBand"
    band.Size = UDim2.new(1, 0, 0, headerH - INSET)
    band.BackgroundColor3 = C.bandBot
    band.BorderSizePixel = 0
    band.ZIndex = 2
    band.Parent = chassis
    corner(band, 14)
    gradient(band, C.bandTop, C.bandBot)

    -- band's UICorner rounds its BOTTOM corners too, which would show the
    -- faceplate through them. A square patch over the lower half hides that
    -- without needing a second image.
    local footH = math.floor((headerH - INSET) / 2)
    local bandFoot = Instance.new("Frame")
    bandFoot.Name = "BandFoot"
    bandFoot.Size = UDim2.new(1, 0, 0, footH)
    bandFoot.Position = UDim2.new(0, 0, 1, -footH)
    bandFoot.BackgroundColor3 = C.bandBot
    bandFoot.BorderSizePixel = 0
    bandFoot.ZIndex = 2
    bandFoot.Parent = band

    local groove = Instance.new("Frame")
    groove.Name = "Groove"
    groove.Size = UDim2.new(1, 0, 0, 1)
    groove.Position = UDim2.new(0, 0, 0, headerH - INSET)
    groove.BackgroundColor3 = BLACK
    groove.BackgroundTransparency = 0.25
    groove.BorderSizePixel = 0
    groove.ZIndex = 3
    groove.Parent = chassis

    local lip = Instance.new("Frame")
    lip.Name = "GrooveLip"
    lip.Size = UDim2.new(1, 0, 0, 1)
    lip.Position = UDim2.new(0, 0, 0, headerH - INSET + 1)
    lip.BackgroundColor3 = WHITE
    lip.BackgroundTransparency = 0.86
    lip.BorderSizePixel = 0
    lip.ZIndex = 3
    lip.Parent = chassis

    bevel(chassis, "raised", 1, 4)

    -- Four corner screws holding the plate to the bezel.
    local m, a = 9, Vector2.new(0.5, 0.5)
    screw(chassis, 7, UDim2.fromOffset(m, m),  a, 5)
    screw(chassis, 7, UDim2.new(1, -m, 0, m),  a, 5)
    screw(chassis, 7, UDim2.new(0, m, 1, -m),  a, 5)
    screw(chassis, 7, UDim2.new(1, -m, 1, -m), a, 5)

    -- Vent grille in the dead space below the last row (the container reserves
    -- chamferH + 4 px there for the bottom corners).
    for i = 0, 2 do
        local slat = Instance.new("Frame")
        slat.Name = "Vent"
        slat.Size = UDim2.new(0, 46, 0, 2)
        slat.AnchorPoint = Vector2.new(0.5, 1)
        slat.Position = UDim2.new(0.5, 0, 1, -(8 + i * 5))
        slat.BackgroundColor3 = BLACK
        slat.BackgroundTransparency = 0.45
        slat.BorderSizePixel = 0
        slat.ZIndex = 5
        slat.Parent = chassis
    end

    return chassis
end

-- A raised keycap: the thing you press. Returns both bevel hosts so press()
-- can flip between them.
function hw.key(frame, radius)
    -- AutoButtonColor tints BackgroundColor3 on hover, which washes the keycap
    -- gradient out. press() is the feedback on a physical key anyway.
    if frame:IsA("TextButton") or frame:IsA("ImageButton") then
        frame.AutoButtonColor = false
    end
    frame.BackgroundColor3 = C.keyBot
    gradient(frame, C.keyTop, C.keyBot)
    corner(frame, radius or 3)
    local raised   = bevel(frame, "raised", 1, 3)
    local recessed = bevel(frame, "recessed", 1, 3)
    recessed.Visible = false
    return { raised = raised, recessed = recessed }
end

-- A recessed well: the thing you read, or the channel something rides in.
function hw.well(frame, radius)
    frame.BackgroundColor3 = C.wellTop
    gradient(frame, C.wellTop, C.wellBot)
    corner(frame, radius or 2)
    bevel(frame, "recessed", 1, 3)
end

-- A module face: sits flush with the plate. For rows that HOST controls rather
-- than being a control themselves.
function hw.face(frame, radius)
    frame.BackgroundColor3 = C.faceBot
    gradient(frame, C.faceTop, C.faceBot)
    corner(frame, radius or 3)
    stroke(frame, BLACK, 0.55, 1)
end

-- Readouts (keybind field, dropdown value, text box): inset, like a little
-- window cut into the plate. Stroke rather than bevel frames, because these
-- carry UIPadding and bevel children would be shoved by it.
function hw.readout(frame)
    frame.BackgroundColor3 = C.wellTop
    corner(frame, 2)
    stroke(frame, BLACK, 0.2, 1)
end

-- Etched lettering: a dark copy of the text sitting one pixel low behind it, so
-- the label reads as cut into the metal rather than printed on it.
function hw.engrave(label)
    label.TextColor3 = C.etch
    local ghost = label:Clone()
    -- Strip anything that would make the shadow interactive or recursive.
    for _, ch in ipairs(ghost:GetChildren()) do ch:Destroy() end
    ghost.Name = "Etch"
    ghost.TextColor3 = BLACK
    ghost.TextTransparency = 0.45
    ghost.ZIndex = math.max(1, (label.ZIndex or 1) - 1)
    ghost.Position = label.Position + UDim2.fromOffset(0, 1)
    ghost.Parent = label.Parent
end

-- The settings-panel divider becomes a panel seam: dark groove, lit lip.
function hw.separator(frame)
    frame.Size = UDim2.new(1, 0, 0, 2)
    frame.BackgroundColor3 = BLACK
    frame.BackgroundTransparency = 0.3
    local lip = Instance.new("Frame")
    lip.Name = "SeamLip"
    lip.Size = UDim2.new(1, 0, 0, 1)
    lip.Position = UDim2.new(0, 0, 0, 1)
    lip.BackgroundColor3 = WHITE
    lip.BackgroundTransparency = 0.86
    lip.BorderSizePixel = 0
    lip.Parent = frame
end

-- Wire a button so the thing it sits on physically depresses: the bevel inverts
-- and the label drops a pixel. `caps` is what key() returned; `shift` is an
-- optional list of GuiObjects to nudge down while held.
function hw.press(btn, caps, shift)
    if not caps then return end
    local held = false
    local origin = {}
    if shift then
        for _, o in ipairs(shift) do origin[o] = o.Position end
    end

    local function down()
        if held then return end
        held = true
        caps.raised.Visible   = false
        caps.recessed.Visible = true
        if shift then
            for _, o in ipairs(shift) do o.Position = origin[o] + UDim2.fromOffset(0, 1) end
        end
    end
    local function up()
        if not held then return end
        held = false
        caps.raised.Visible   = true
        caps.recessed.Visible = false
        if shift then
            for _, o in ipairs(shift) do o.Position = origin[o] end
        end
    end

    -- Down/Up plus MouseLeave: a drag that leaves the button never fires Up on
    -- it, and a key stuck down forever is worse than one that pops back early.
    btn.MouseButton1Down:Connect(down)
    btn.MouseButton1Up:Connect(up)
    btn.MouseLeave:Connect(up)
end

-- Feature-row indicator / "i" / cog. The flat skin's hexagons are hidden and
-- replaced by a key in the same footprint, so nothing around them has to move.
-- opts.latching adds the lamp + backlight (the ON/OFF switch); momentary keys
-- (cog, info) just light their face while active.
function hw.hexKey(host, hexHost, label, opts)
    opts = opts or {}
    hexHost.Visible = false

    local face = Instance.new("Frame")
    face.Name = "KeyFace"
    face.Size = UDim2.fromScale(1, 1)
    face.BackgroundColor3 = C.keyBot
    face.BorderSizePixel = 0
    face.ZIndex = 2
    face.Parent = host
    corner(face, 3)
    local g = gradient(face, C.keyTop, C.keyBot)
    local raised   = bevel(face, "raised", 1, 3)
    local recessed = bevel(face, "recessed", 1, 3)
    recessed.Visible = false

    -- Indicator lamp, lit only in the ON state. Sits left of the label inside
    -- the same footprint the hex occupied.
    local lamp
    if opts.latching then
        lamp = Instance.new("Frame")
        lamp.Name = "Lamp"
        lamp.Size = UDim2.fromOffset(4, 4)
        lamp.AnchorPoint = Vector2.new(0, 0.5)
        lamp.Position = UDim2.new(0, 4, 0.5, 0)
        lamp.BackgroundColor3 = opts.onColor or theme.on
        lamp.BorderSizePixel = 0
        lamp.ZIndex = 6
        lamp.Visible = false
        lamp.Parent = host
        corner(lamp, 4)
    end

    label.ZIndex = 5
    local labelHome = label.Position

    return {
        set = function(on)
            if on then
                -- Pressed in and backlit: the cap darkens TOWARD the lamp color,
                -- because a lit key glows through the cap rather than being
                -- painted on top of it.
                local lit = opts.onColor or theme.accent
                g.Color = ColorSequence.new(lit:Lerp(BLACK, 0.55), lit:Lerp(BLACK, 0.75))
                raised.Visible   = false
                recessed.Visible = true
                label.Position   = labelHome + UDim2.fromOffset(0, 1)
                label.TextColor3 = lit:Lerp(WHITE, 0.45)
                if lamp then lamp.Visible = true end
            else
                g.Color = ColorSequence.new(C.keyTop, C.keyBot)
                raised.Visible   = true
                recessed.Visible = false
                label.Position   = labelHome
                label.TextColor3 = opts.latching and theme.fgDim or theme.fg
                if lamp then lamp.Visible = false end
            end
            if opts.onText or opts.offText then
                label.Text = on and (opts.onText or "") or (opts.offText or "")
            end
        end,
    }
end

-- components.Toggle's sliding switch becomes a rocker: a recessed well with a
-- raised paddle riding in it, and a lamp behind it that shows when it's on.
function hw.switch(switchBtn, knob)
    switchBtn.BackgroundColor3 = C.wellTop
    corner(switchBtn, 3)
    gradient(switchBtn, C.wellTop, C.wellBot)
    bevel(switchBtn, "recessed", 1, 2)

    knob.ZIndex = 4
    knob.BackgroundColor3 = C.keyTop
    corner(knob, 2)
    gradient(knob, C.keyTop, C.keyBot)
    bevel(knob, "raised", 1, 5)

    -- Grip ridges, so the paddle reads as something a thumb pushes.
    for i = 0, 2 do
        local ridge = Instance.new("Frame")
        ridge.Name = "Grip"
        ridge.Size = UDim2.new(0, 1, 0, 8)
        ridge.AnchorPoint = Vector2.new(0.5, 0.5)
        ridge.Position = UDim2.new(0.5, (i - 1) * 3, 0.5, 0)
        ridge.BackgroundColor3 = BLACK
        ridge.BackgroundTransparency = 0.6
        ridge.BorderSizePixel = 0
        ridge.ZIndex = 6
        ridge.Parent = knob
    end

    -- The lit half of the well, revealed as the paddle slides off it.
    local glow = Instance.new("Frame")
    glow.Name = "Glow"
    glow.Size = UDim2.new(0, 14, 1, -4)
    glow.Position = UDim2.fromOffset(2, 2)
    glow.BackgroundColor3 = theme.on
    glow.BackgroundTransparency = 0.25
    glow.BorderSizePixel = 0
    glow.ZIndex = 3
    glow.Visible = false
    glow.Parent = switchBtn
    corner(glow, 2)

    -- ownsColor tells components.Toggle to stop doing its own accent/bgDark
    -- fill: the well is painted here and a flat fill would kill the gradient.
    return { ownsColor = true, set = function(on) glow.Visible = on and true or false end }
end

-- The slider becomes a fader: a routed channel with a physical cap riding it.
-- The cap tracks the fill frame's width, so components.Slider needs no wiring
-- beyond handing us the two frames.
function hw.slider(track, fill)
    track.BackgroundColor3 = C.wellTop
    corner(track, 2)
    gradient(track, C.wellTop, C.wellBot)
    bevel(track, "recessed", 1, 2)

    fill.ZIndex = 3
    corner(fill, 2)
    gradient(fill, theme.accent:Lerp(WHITE, 0.25), theme.accent:Lerp(BLACK, 0.3))

    local cap = Instance.new("Frame")
    cap.Name = "FaderCap"
    cap.Size = UDim2.fromOffset(10, 16)
    cap.AnchorPoint = Vector2.new(0.5, 0.5)
    cap.Position = UDim2.new(0, 0, 0.5, 0)
    cap.BackgroundColor3 = C.keyTop
    cap.BorderSizePixel = 0
    cap.ZIndex = 6
    cap.Parent = track
    corner(cap, 2)
    gradient(cap, C.keyTop, C.keyBot)
    bevel(cap, "raised", 1, 7)

    local notch = Instance.new("Frame")
    notch.Name = "CapNotch"
    notch.Size = UDim2.new(0, 6, 0, 1)
    notch.AnchorPoint = Vector2.new(0.5, 0.5)
    notch.Position = UDim2.fromScale(0.5, 0.5)
    notch.BackgroundColor3 = BLACK
    notch.BackgroundTransparency = 0.4
    notch.BorderSizePixel = 0
    notch.ZIndex = 8
    notch.Parent = cap

    -- Follow the fill instead of the value: Slider drives fill.Size for both
    -- drags and api:Set, so one signal covers every way the value can move.
    local function follow()
        cap.Position = UDim2.new(fill.Size.X.Scale, fill.Size.X.Offset, 0.5, 0)
    end
    follow()
    fill:GetPropertyChangedSignal("Size"):Connect(follow)

    return { set = follow }
end

-- Navigator pills become lamps behind a bezel.
function hw.led(frame)
    corner(frame, 2)
    stroke(frame, BLACK, 0.25, 1)
    local g = gradient(frame, WHITE, BLACK)
    g.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.72),
        NumberSequenceKeypoint.new(1, 0.5),
    })
    return { set = function() end }
end

-- The floating "P" opener becomes a chunky round power button in a collar.
function hw.logo(host, hexHost, label)
    hexHost.Visible = false
    local d = math.min(host.Size.X.Offset, host.Size.Y.Offset)

    local collar = Instance.new("Frame")
    collar.Name = "Collar"
    collar.Size = UDim2.fromOffset(d, d)
    collar.AnchorPoint = Vector2.new(0.5, 0.5)
    collar.Position = UDim2.fromScale(0.5, 0.5)
    collar.BackgroundColor3 = C.bezel
    collar.BorderSizePixel = 0
    collar.ZIndex = 10
    collar.Parent = host
    corner(collar, d)
    gradient(collar, C.faceTop, C.bezel)
    stroke(collar, BLACK, 0.2, 1)

    local cap = Instance.new("Frame")
    cap.Name = "Cap"
    cap.Size = UDim2.fromOffset(d - 8, d - 8)
    cap.AnchorPoint = Vector2.new(0.5, 0.5)
    cap.Position = UDim2.fromScale(0.5, 0.5)
    cap.BackgroundColor3 = C.keyBot
    cap.BorderSizePixel = 0
    cap.ZIndex = 11
    cap.Parent = host
    corner(cap, d)
    gradient(cap, C.keyTop, C.keyBot)
    bevel(cap, "raised", 1, 12)

    label.ZIndex = 14
    label.TextColor3 = C.etch
    return cap
end

-- ---------------------------------------------------------------------------
-- Selection + dispatch
-- ---------------------------------------------------------------------------

skin.list = { "Flat", "Hardware" }

local impls = { flat = flat, hardware = hw }

local SAVE_KEY = "ui.skin"

-- Global (cross-game) so the look follows you everywhere, unlike the per-game
-- feature toggles.
local function readSaved()
    -- pcall: a persist without the cross-game store shouldn't be able to stop
    -- the UI from loading -- fall back to the default look instead.
    local ok, v = pcall(persist.getGlobal, SAVE_KEY, "Flat")
    if not ok or type(v) ~= "string" then return "flat" end
    v = string.lower(v)
    return impls[v] and v or "flat"
end

skin.name = readSaved()
local active = impls[skin.name]

-- Repaint the shared theme immediately, at require time: every ui/* module
-- reads theme.* while BUILDING instances, and skin is required by all of them
-- before the first instance exists, so this lands in time and never needs a
-- second pass.
active.applyTheme(theme)

-- Title-case, matching skin.list, for the dropdown.
function skin.current()
    return (skin.name:gsub("^%l", string.upper))
end

function skin.set(name)
    persist.setGlobal(SAVE_KEY, tostring(name))
end

function skin.isHardware() return skin.name == "hardware" end

-- Every hook forwards to the active impl. Declared explicitly (rather than via
-- a metatable) so a typo at a call site is a nil-call error here instead of a
-- silent no-op somewhere out in the UI.
function skin.usePanelTexture()               return active.usePanelTexture() end
function skin.panel(c, hh, ch)                return active.panel(c, hh, ch) end
function skin.key(f, r)                       return active.key(f, r) end
function skin.well(f, r)                      return active.well(f, r) end
function skin.face(f, r)                      return active.face(f, r) end
function skin.readout(f)                      return active.readout(f) end
function skin.engrave(l)                      return active.engrave(l) end
function skin.separator(f)                    return active.separator(f) end
function skin.press(b, caps, shift)           return active.press(b, caps, shift) end
function skin.hexKey(host, hexHost, label, o) return active.hexKey(host, hexHost, label, o) end
function skin.switch(sw, knob)                return active.switch(sw, knob) end
function skin.slider(track, fill)             return active.slider(track, fill) end
function skin.led(f)                          return active.led(f) end
function skin.logo(host, hexHost, label)      return active.logo(host, hexHost, label) end

return skin
