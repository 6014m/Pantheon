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
    rim      = Color3.fromRGB(122, 129, 139),  -- milled edge around the chamfer
    band     = Color3.fromRGB(52, 56, 62),     -- header bar
    plate    = Color3.fromRGB(26, 28, 32),     -- faceplate body
    faceTop  = Color3.fromRGB(46, 50, 56),     -- row face, lit edge
    faceBot  = Color3.fromRGB(32, 35, 39),     -- row face, shadowed edge
    keyTop   = Color3.fromRGB(70, 75, 83),     -- raised keycap
    keyBot   = Color3.fromRGB(42, 45, 51),
    wellTop  = Color3.fromRGB(13, 14, 16),     -- recessed well (shadowed at top)
    wellBot  = Color3.fromRGB(26, 28, 32),
    bolt     = Color3.fromRGB(118, 125, 135),  -- hex bolt head
    boltDk   = Color3.fromRGB(38, 41, 46),
    etch     = Color3.fromRGB(158, 164, 174),
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

-- ---- hooks ----------------------------------------------------------------

-- Repaint the shared theme for the hardware skin. Runs once, at skin load,
-- BEFORE any UI is constructed (every ui/* module reads theme.* at build time,
-- not at require time), so there is nothing to refresh afterwards.
function hw.applyTheme(t)
    -- The container's chamfered 9-slice is already tinted by a headerBand -> bg
    -- gradient with a sharp seam at the header height. That IS a faceplate with
    -- a header bar, so the hardware skin repaints those two stops in metal and
    -- keeps the silhouette Pantheon has always had.
    t.headerBand = C.band
    t.bg         = C.plate
    t.bgAlt      = C.faceBot
    t.bgDark     = C.wellTop
    t.accent     = Color3.fromRGB(142, 150, 162)   -- brushed steel
    t.border     = Color3.fromRGB(12, 13, 15)
    t.fg         = Color3.fromRGB(228, 232, 240)
    t.fgDim      = Color3.fromRGB(140, 146, 156)
    t.logoStroke = Color3.fromRGB(228, 232, 240)
    -- Rows become keycaps; a key needs a little more height to read as one.
    t.featureHeight = 32
    t.rowHeight     = 32
end

-- Keep the carbon tile: on a metal plate it reads as the surface grain, and it
-- is what gives the "P" hexagon its texture too.
function hw.usePanelTexture() return true end

-- Machine the panel. Deliberately does NOT add a full-bleed background child:
-- the container is AutomaticSize.Y, and a child sized to the whole panel is
-- exactly what stretched every menu to the bottom of the screen the first time
-- round. The 9-slice the container already draws IS the plate (applyTheme
-- repainted its gradient) -- all this adds is the milled rim plus the hardware
-- bolted across the header bar, parented into headerHost, whose extent is fixed.
function hw.panel(container, headerHost, headerH, chamferH)
    -- UIStroke on an ImageLabel follows the image alpha, so the rim traces the
    -- chamfered outline instead of boxing it in.
    stroke(container, C.rim, 0.45, 1)

    -- Top highlight along the bar, then the groove + lit lip that separates the
    -- bar from the plate.
    local function line(y, color, tr, z)
        local f = Instance.new("Frame")
        f.Size = UDim2.new(1, 0, 0, 1)
        f.Position = UDim2.new(0, 0, 0, y)
        f.BackgroundColor3 = color
        f.BackgroundTransparency = tr
        f.BorderSizePixel = 0
        f.ZIndex = z or 3
        f.Parent = headerHost
        return f
    end
    line(1,           WHITE, 0.82)
    line(headerH - 1, BLACK, 0.25)
    line(headerH,     WHITE, 0.88)

    -- Hex bolt heads holding the bar down: hexagons, because that is the shape
    -- this hub is built out of -- and because a real bolt head is one.
    local function bolt(position)
        local b = hex.build(headerHost, 11, 10, C.bolt, 6, nil, C.boltDk)
        b.Name = "Bolt"
        b.AnchorPoint = Vector2.new(0.5, 0.5)
        b.Position = position
        local core = hex.build(b, 5, 4, C.boltDk, 7)
        core.Name = "BoltCore"
        core.AnchorPoint = Vector2.new(0.5, 0.5)
        core.Position = UDim2.fromScale(0.5, 0.5)
        return b
    end
    bolt(UDim2.new(0, 13, 0.5, 0))
    bolt(UDim2.new(1, -13, 0.5, 0))
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

-- Feature-row indicator / "i" / cog. These stay HEXAGONS -- they are the hub's
-- signature shape. What the skin adds is depth: a black hexagon one pixel low
-- behind the face makes the key stand proud of the plate, and the face itself
-- is shaded top-lit instead of filled flat. Turning it on drops the face onto
-- its shadow, the way a key that is pressed in sits.
-- opts.latching adds the lamp + backlight (the ON/OFF switch); momentary keys
-- (cog, info) just light their face while active.
function hw.hexKey(host, hexHost, label, opts)
    opts = opts or {}
    local w = (host.Size and host.Size.X.Offset) or 22
    local h = (host.Size and host.Size.Y.Offset) or 18

    -- Behind the face hexagon, which feature.lua built at ZIndex 2.
    local shadow = hex.build(host, w, h, BLACK, 1)
    shadow.Name = "HexShadow"
    shadow.Position = UDim2.fromOffset(0, 1)

    local lamp
    if opts.latching then
        -- A hex lamp, not a round LED: same reason as the bolts.
        lamp = hex.build(host, 6, 5, opts.onColor or theme.on, 6)
        lamp.Name = "Lamp"
        lamp.AnchorPoint = Vector2.new(0, 0.5)
        lamp.Position = UDim2.new(0, 3, 0.5, 0)
        lamp.Visible = false
    end

    label.ZIndex = 5
    local labelHome = label.Position
    local hexHome   = hexHost.Position

    return {
        set = function(on)
            if on then
                -- A lit key glows THROUGH the cap, so the face shades toward the
                -- lamp color rather than being painted over in it.
                local lit = opts.onColor or theme.accent
                hex.setShade(hexHost, lit:Lerp(BLACK, 0.35), lit:Lerp(BLACK, 0.62))
                hexHost.Position = hexHome + UDim2.fromOffset(0, 1)
                label.Position   = labelHome + UDim2.fromOffset(0, 1)
                label.TextColor3 = lit:Lerp(WHITE, 0.55)
                shadow.Visible   = false
                if lamp then lamp.Visible = true end
            else
                hex.setShade(hexHost, C.keyTop, C.keyBot)
                hexHost.Position = hexHome
                label.Position   = labelHome
                label.TextColor3 = opts.latching and theme.fgDim or theme.fg
                shadow.Visible   = true
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

-- The floating "P" opener stays the hexagon it has always been. It just gains a
-- shadow hex underneath and a shaded, top-lit face, so it reads as a physical
-- key sitting on the screen rather than a flat badge.
function hw.logo(host, hexHost, label)
    local w = (host.Size and host.Size.X.Offset) or 46
    local h = (host.Size and host.Size.Y.Offset) or 40

    local shadow = hex.build(host, w, h, BLACK, 9)
    shadow.Name = "HexShadow"
    shadow.Position = UDim2.fromOffset(0, 2)

    hex.setShade(hexHost, C.keyTop, C.keyBot)
    label.TextColor3 = C.etch
    return hexHost
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
function skin.panel(c, hdr, hh, ch)           return active.panel(c, hdr, hh, ch) end
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
