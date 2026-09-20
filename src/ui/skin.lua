-- Optional UI skins.
--
-- A skin is a DECORATION LAYER, not a second UI. Every ui/* module builds the
-- same instance tree it always did, then hands the pieces it just made to a
-- hook in here. For the default skin ("flat") every hook is a no-op, so the hub
-- looks and behaves exactly as before. "hardware" uses those hooks to make one
-- moulded faceplate with the controls sunk into it.
--
-- WHAT MAKES IT READ AS EMBEDDED (the first two attempts got this wrong):
--
--   1. VALUE RANGE. Depth is lighting, and lighting needs somewhere to happen.
--      A near-black plate with near-black controls has nowhere: a highlight and
--      a shadow both clip to "dark" and the panel stays a flat slab. So the
--      plate is a real mid grey -- RGB(60,63,70), which is exactly the grey
--      Pantheon's header band has always been, so the hub still looks like
--      itself. The cutouts go down to 13 and the caps up to 96. THAT range is
--      what a 1px white lip and a 1px black shadow need to be visible at all.
--
--   2. THE PLATE HAS TO SHOW BETWEEN THINGS. A control cut into a plate only
--      reads that way if you can see the plate around it. Hence theme.rowGap:
--      the gap between rows shows plate, not void.
--
--   3. THE PLATE IS CONTINUOUS; ONLY CONTROLS ARE SUNK INTO IT. A feature row
--      is not a card -- it is a stretch of plate, divided from the next by a
--      hairline seam cut into the surface. What gets a socket is the hardware:
--      the hex keys, the buttons, the rockers, the faders, the readouts. Give
--      every ROW a socket too and you are back to a stack of trays, which is
--      what the second attempt looked like. One surface, things set into it.
--
-- The active skin is chosen ONCE at load (Pantheon menu -> cog -> UI Skin) and
-- lives in the cross-game global store, so it follows you into every game.
-- Switching is a reload, not a live re-style: the hooks run during construction
-- and what they add can't be un-drawn cleanly.
--
-- Roblox notes that shape the code below:
--   * The ScreenGui is ZIndexBehavior.Sibling, so a decoration parented under a
--     low-ZIndex host stays under everything the host is under, whatever ZIndex
--     it uses internally. That's what lets a cap sit at ZIndex 0 inside a row
--     and still layer its own lip and foot above itself.
--   * A GuiObject can hold only ONE UIGradient.
--   * Decoration Frames must NEVER be parented to something with a UIListLayout
--     (they'd become list items) or a UIPadding (they'd be inset by it). Those
--     get stroke() treatment instead.
--   * A container is AutomaticSize.Y. The panel hook must not give it a child
--     sized to the whole panel -- that feeds its own growth and stretches every
--     menu to the bottom of the screen. Panel furniture goes in the header
--     host, whose extent is fixed. mocktest_skin.py guards this.

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
function flat.tray() end
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
-- hardware: one moulded faceplate with the controls sunk into it.
-- ---------------------------------------------------------------------------

local hw = {}

-- The material. Read these as a lighting model, not a colour scheme: plate is
-- the surface, slot is what you see where the surface is cut through, cap is a
-- piece of the surface standing back up inside the cut.
local C = {
    plate    = Color3.fromRGB(60, 63, 70),     -- faceplate (Pantheon's own grey)
    plateLit = Color3.fromRGB(88, 93, 102),    -- plate where the light lands
    plateDim = Color3.fromRGB(41, 44, 50),     -- plate falling into shadow
    band     = Color3.fromRGB(86, 91, 100),    -- header rail, the top face
    bandDim  = Color3.fromRGB(62, 66, 74),
    slot     = Color3.fromRGB(13, 14, 16),     -- a cut through the plate
    capTop   = Color3.fromRGB(104, 110, 121),  -- key cap, lit edge
    capBot   = Color3.fromRGB(68, 72, 80),     -- key cap, shadowed edge
    bolt     = Color3.fromRGB(186, 193, 204),  -- hex bolt head
    boltDk   = Color3.fromRGB(44, 47, 53),
    rim      = Color3.fromRGB(138, 145, 156),  -- milled edge around the chamfer
    etch     = Color3.fromRGB(180, 186, 196),  -- lettering cut into the metal
    legend   = Color3.fromRGB(26, 28, 33),     -- lettering printed ON a key cap
}

-- Lip / shadow strengths. These are the whole illusion, so they are named once
-- here rather than sprinkled as literals down the file.
local LIP_T   = 0.42   -- lit top edge of a cap
local FOOT_T  = 0.38   -- shadowed bottom edge of a cap
local SHADE_T = 0.30   -- shadow the plate casts into the top of a cut

local function corner(inst, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 2)
    c.Parent = inst
    return c
end

-- A UIGradient MULTIPLIES the object's BackgroundColor3 -- it does not replace
-- it. Gradient grey over background grey therefore squares down to near-black,
-- which is exactly what made the first hardware skins look like unlit slabs.
-- So the base goes white and the gradient supplies the colour outright, the
-- same trick container.lua already uses on its 9-slice ("white so the UIGradient
-- tints freely"). Pass multiply = true when the multiply IS the point -- the
-- navigator lamps shade their own ON/OFF colour that way.
local function gradient(inst, top, bottom, rotation, multiply)
    if not multiply then inst.BackgroundColor3 = WHITE end
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

local function line(parent, name, pos, size, color, transparency, z)
    local f = Instance.new("Frame")
    f.Name = name
    f.Position = pos
    f.Size = size
    f.BackgroundColor3 = color
    f.BackgroundTransparency = transparency
    f.BorderSizePixel = 0
    f.ZIndex = z or 1
    f.Parent = parent
    return f
end

-- Cut `frame` into the plate, and stand a cap back up inside the cut.
--
-- The frame itself becomes the socket (slot-dark, so a dark ring shows all the
-- way round it). The cap is inset inside that, gradient-lit, with a bright lip
-- along its top edge and a shadow under its bottom edge; a separate shadow sits
-- in the socket above the cap, as if cast by the plate edge over it.
--
-- NEVER call this on a frame carrying a UIListLayout (cap/lip would become list
-- items) or a UIPadding (they'd be inset by it). Those take readout() instead.
local function socket(frame, opts)
    opts = opts or {}
    local inset  = opts.inset or 3
    local radius = opts.radius or 3
    local top    = opts.top or C.capTop
    local bottom = opts.bottom or C.capBot

    frame.BackgroundColor3 = C.slot
    frame.BackgroundTransparency = 0
    corner(frame, radius)

    -- Shadow cast into the cut, above the cap. Drawn on the socket, not on the
    -- cap, so it stays put when the cap drops.
    line(frame, "SocketShade", UDim2.fromOffset(0, 0),
         UDim2.new(1, 0, 0, inset), BLACK, SHADE_T, 1)

    local cap = Instance.new("Frame")
    cap.Name = "Cap"
    cap.Size = UDim2.new(1, -inset * 2, 1, -inset * 2)
    cap.Position = UDim2.fromOffset(inset, inset)
    cap.BackgroundColor3 = top
    cap.BorderSizePixel = 0
    cap.ZIndex = 0
    cap.Parent = frame
    corner(cap, math.max(1, radius - 1))
    local grad = gradient(cap, top, bottom)

    local lip  = line(cap, "Lip",  UDim2.fromOffset(0, 0),
                      UDim2.new(1, 0, 0, 1), WHITE, LIP_T, 1)
    local foot = line(cap, "Foot", UDim2.new(0, 0, 1, -1),
                      UDim2.new(1, 0, 0, 1), BLACK, FOOT_T, 1)

    local capHome = cap.Position
    local pressed, litColor = false, nil

    local api = {}
    api.cap = cap

    local function repaint()
        if litColor then
            grad.Color = ColorSequence.new(
                litColor:Lerp(BLACK, pressed and 0.22 or 0.3),
                litColor:Lerp(BLACK, pressed and 0.5 or 0.58))
        elseif pressed then
            grad.Color = ColorSequence.new(bottom, bottom:Lerp(BLACK, 0.25))
        else
            grad.Color = ColorSequence.new(top, bottom)
        end
    end

    -- Pressed: the cap drops the rest of the way into its socket, and its lit
    -- lip goes out because nothing is catching the light up there any more.
    function api.setPressed(on)
        on = on and true or false
        if pressed == on then return end
        pressed = on
        cap.Position = on and (capHome + UDim2.fromOffset(0, 1)) or capHome
        lip.BackgroundTransparency  = on and 0.9  or LIP_T
        foot.BackgroundTransparency = on and 0.25 or FOOT_T
        repaint()
    end

    -- Backlight a latched control: the cap glows from within rather than being
    -- repainted, so it still reads as the same piece of plastic.
    function api.setLit(color)
        litColor = color
        repaint()
    end

    return api
end

-- ---- hooks ----------------------------------------------------------------

-- Repaint the shared theme. Runs once, at skin load, BEFORE any UI is built
-- (every ui/* module reads theme.* while constructing, not at require time),
-- so this lands in time and never needs a second pass.
function hw.applyTheme(t)
    -- The container's chamfered 9-slice is already tinted by a headerBand -> bg
    -- gradient with a sharp seam at the header height. That IS a faceplate with
    -- a rail across the top, so the skin just repaints those two stops and
    -- keeps the silhouette Pantheon has always had.
    t.headerBand = C.band
    t.bg         = C.plate
    t.bgAlt      = C.plate     -- rows are cut FROM the plate: same material
    t.bgDark     = C.slot
    t.border     = C.slot
    -- Still Pantheon's monochrome silver, pushed brighter so it holds its own
    -- against a lit grey plate instead of sinking into it.
    t.accent     = Color3.fromRGB(170, 177, 189)
    t.fg         = Color3.fromRGB(240, 243, 248)
    t.fgDim      = Color3.fromRGB(176, 182, 192)
    t.logoStroke = Color3.fromRGB(20, 21, 24)
    -- The carbon weave is the plate's grain. At the flat skin's 0.82 it is
    -- invisible on a lit surface, so bring it up until you can feel it.
    t.panelTextureTransparency = 0.55
    t.panelTextureTile         = 72
    -- A cap needs height to read as one, and the gap between rows is where the
    -- plate shows through -- without it the sockets fuse into one dark band.
    t.featureHeight = 32
    t.rowHeight     = 32
    t.rowGap        = 0
end

-- The carbon tile is the plate's grain, and it is what gives the "P" hex its
-- texture too.
function hw.usePanelTexture() return true end

-- Machine the panel.
--
-- Deliberately adds NO child sized to the whole panel: the container is
-- AutomaticSize.Y and such a child is what stretched every menu to the bottom
-- of the screen the first time round. The 9-slice the container already draws
-- IS the plate (applyTheme repainted its gradient); this adds the milled rim
-- and the hardware across the header rail, parented into headerHost, whose
-- extent is fixed.
function hw.panel(container, headerHost, headerH, chamferH)
    -- UIStroke on an ImageLabel follows the image alpha, so the rim traces the
    -- chamfered outline instead of boxing it in.
    stroke(container, C.rim, 0.55, 1)

    local W = UDim2.new(1, 0, 0, 1)
    -- Light along the top edge of the rail, then the groove and its lit lip
    -- where the rail meets the plate.
    line(headerHost, "RailLight", UDim2.fromOffset(0, 0),           W, WHITE, 0.55, 3)
    line(headerHost, "Groove",    UDim2.fromOffset(0, headerH - 2), W, BLACK, 0.25, 3)
    line(headerHost, "GrooveLip", UDim2.fromOffset(0, headerH - 1), W, WHITE, 0.72, 3)

    -- Hex bolt heads holding the rail down: hexagons, because that is the shape
    -- this hub is built out of -- and because a real bolt head is one.
    local function bolt(position)
        local b = hex.build(headerHost, 13, 12, C.bolt, 6, nil, C.boltDk)
        b.Name = "Bolt"
        b.AnchorPoint = Vector2.new(0.5, 0.5)
        b.Position = position
        local core = hex.build(b, 6, 5, C.boltDk, 7)
        core.Name = "BoltCore"
        core.AnchorPoint = Vector2.new(0.5, 0.5)
        core.Position = UDim2.fromScale(0.5, 0.5)
        return b
    end
    bolt(UDim2.new(0, 13, 0.5, 0))
    bolt(UDim2.new(1, -13, 0.5, 0))
end

-- A key cut into the plate: the thing you press.
--   opts.legend  a TextLabel/TextButton whose text is printed ON the cap. A key
--                cap is lighter than the plate, so its legend has to go DARK --
--                the hub's white-on-grey body text vanishes on one.
--   opts.tint    colour the cap (the keybind row's unbind key stays red).
--   opts.radius  corner rounding.
function hw.key(frame, opts)
    opts = opts or {}
    -- AutoButtonColor tints BackgroundColor3 on hover, which would flood the
    -- socket. setPressed is the feedback on a physical key anyway.
    if frame:IsA("TextButton") or frame:IsA("ImageButton") then
        frame.AutoButtonColor = false
    end
    local top, bottom = C.capTop, C.capBot
    if opts.tint then
        top, bottom = opts.tint:Lerp(WHITE, 0.2), opts.tint:Lerp(BLACK, 0.3)
    end
    local sock = socket(frame, { radius = opts.radius, top = top, bottom = bottom })
    local legend = opts.legend
    if legend == frame and (frame:IsA("TextButton") or frame:IsA("TextBox")) then
        -- The cap is a CHILD of the button, and in Roblox a child always draws
        -- above its parent -- including over the parent's own text. A button
        -- that letters itself (a navigator row, a dropdown option, the unbind
        -- key) would have its label swallowed by its own cap, so the lettering
        -- moves to a label that sits above the cap instead.
        local l = Instance.new("TextLabel")
        l.Name = "Legend"
        l.BackgroundTransparency = 1
        l.Size = UDim2.fromScale(1, 1)
        l.Text = frame.Text
        l.Font = frame.Font
        l.TextSize = frame.TextSize
        l.TextXAlignment = frame.TextXAlignment
        l.TextYAlignment = frame.TextYAlignment
        l.ZIndex = 2
        l.Parent = frame
        frame.Text = ""
        legend = l
    end
    if legend then
        -- A tinted cap is dark enough to keep light lettering; a bare one isn't.
        legend.TextColor3 = opts.tint and theme.fg or C.legend
    end
    return sock
end

-- A bare recess: the channel something rides in, with no cap standing in it.
function hw.well(frame, radius)
    frame.BackgroundColor3 = C.slot
    corner(frame, radius or 2)
    line(frame, "WellShade", UDim2.fromOffset(0, 0),
         UDim2.new(1, 0, 0, 1), BLACK, 0.2, 2)
    line(frame, "WellLip", UDim2.new(0, 0, 1, -1),
         UDim2.new(1, 0, 0, 1), WHITE, 0.82, 2)
end

-- A row that HOSTS controls rather than being one. It IS the plate: fully
-- transparent, so the panel surface runs straight through it, with a hairline
-- seam cut across the bottom to divide it from the row below. Anything sunk
-- into it (a hex key, a rocker, a fader) supplies the depth.
function hw.face(frame, radius)
    frame.BackgroundTransparency = 1
    line(frame, "Seam",    UDim2.new(0, 0, 1, -2), UDim2.new(1, 0, 0, 1), BLACK, 0.55, 1)
    line(frame, "SeamLip", UDim2.new(0, 0, 1, -1), UDim2.new(1, 0, 0, 1), WHITE, 0.86, 1)
    return nil
end

-- A compartment opened in the plate: the settings tray and the description
-- panel. Floor is plate in shadow (still the same material, just deeper in),
-- with the cut edge shading the top. Stroke-based, because these carry
-- UIPadding and a UIListLayout and child frames would be shoved or stacked.
function hw.tray(frame)
    frame.BackgroundColor3 = C.plateDim
    corner(frame, 2)
    stroke(frame, BLACK, 0.25, 1)
end

-- Readouts (keybind field, dropdown value, text box, the settings tray): inset,
-- like a window cut into the plate. Stroke rather than child frames, because
-- these carry UIPadding/UIListLayout and children would be shoved or stacked.
function hw.readout(frame)
    frame.BackgroundColor3 = C.slot
    corner(frame, 2)
    stroke(frame, BLACK, 0.15, 1)
end

-- Lettering cut into the metal: a dark copy one pixel low behind the text. It
-- reads as engraving because the plate under it is finally light enough to
-- contrast with a shadow.
function hw.engrave(label)
    label.TextColor3 = C.etch
    -- The shadow is a sibling, so inside a UIListLayout it becomes a list item
    -- and the heading renders twice (it did -- "TUNING", "TUNING"). There, cut
    -- the letters with a stroke instead, which adds no layout participant.
    local parent = label.Parent
    if parent and parent:FindFirstChildOfClass("UIListLayout") then
        local s = Instance.new("UIStroke")
        s.Color = BLACK
        s.Transparency = 0.45
        s.Thickness = 1
        s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual   -- strokes the glyphs
        s.Parent = label
        return
    end
    local ghost = label:Clone()
    -- Strip anything that would make the shadow interactive or recursive.
    for _, ch in ipairs(ghost:GetChildren()) do ch:Destroy() end
    ghost.Name = "Etch"
    ghost.TextColor3 = BLACK
    ghost.TextTransparency = 0.35
    ghost.ZIndex = math.max(1, (label.ZIndex or 1) - 1)
    ghost.Position = label.Position + UDim2.fromOffset(0, 1)
    ghost.Parent = label.Parent
end

-- The settings-tray divider becomes a moulding seam: groove plus lit lip.
function hw.separator(frame)
    frame.Size = UDim2.new(1, 0, 0, 2)
    frame.BackgroundColor3 = BLACK
    frame.BackgroundTransparency = 0.25
    line(frame, "SeamLip", UDim2.fromOffset(0, 1),
         UDim2.new(1, 0, 0, 1), WHITE, 0.8, 1)
end

-- Wire a button so its socket takes the press. `sock` is what key()/face()
-- returned; `shift` is an optional list of GuiObjects (a legend printed on the
-- cap) to ride down with it.
function hw.press(btn, sock, shift)
    if not sock then return end
    local origin = {}
    if shift then
        for _, o in ipairs(shift) do origin[o] = o.Position end
    end

    local function down()
        sock.setPressed(true)
        if shift then
            for _, o in ipairs(shift) do o.Position = origin[o] + UDim2.fromOffset(0, 1) end
        end
    end
    local function up()
        sock.setPressed(false)
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

-- Feature-row indicator / "i" / cog. These stay HEXAGONS -- they are the shape
-- the hub is made of. The socket idea applies unchanged, just hex-shaped: a
-- larger dark hexagon behind is the cut through the plate, and the hexagon
-- feature.lua already built is the cap standing inside it. Latching drops the
-- cap to the bottom of the cut and backlights it, with a hex lamp alongside.
function hw.hexKey(host, hexHost, label, opts)
    opts = opts or {}
    local w = (host.Size and host.Size.X.Offset) or 22
    local h = (host.Size and host.Size.Y.Offset) or 18

    -- The cut: bigger than the cap on every side, and BEHIND it (feature.lua
    -- builds the cap hexagon at ZIndex 2).
    local cut = hex.build(host, w + 5, h + 4, C.slot, 1)
    cut.Name = "HexSocket"
    cut.AnchorPoint = Vector2.new(0.5, 0.5)
    cut.Position = UDim2.fromScale(0.5, 0.5)

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

    local api
    api = {
        set = function(on)
            if on then
                -- A lit key glows THROUGH the cap, so the face shades toward
                -- the lamp colour rather than being painted over in it, and it
                -- sits a pixel deeper in the cut.
                local lit = opts.onColor or theme.accent
                hex.setShade(hexHost, lit:Lerp(BLACK, 0.22), lit:Lerp(BLACK, 0.55))
                hexHost.Position = hexHome + UDim2.fromOffset(0, 1)
                label.Position   = labelHome + UDim2.fromOffset(0, 1)
                label.TextColor3 = lit:Lerp(WHITE, 0.7)
                if lamp then lamp.Visible = true end
            else
                hex.setShade(hexHost, C.capTop, C.capBot)
                hexHost.Position = hexHome
                label.Position   = labelHome
                label.TextColor3 = opts.latching and theme.fgDim or theme.fg
                if lamp then lamp.Visible = false end
            end
            if opts.onText or opts.offText then
                label.Text = on and (opts.onText or "") or (opts.offText or "")
            end
        end,
    }
    -- Paint the off state now. feature.lua drives set() from clicks and from
    -- its own applyToggle, but a momentary key (cog, "i") gets neither until
    -- you press it, and would sit there in the raw slot colour it was built in.
    api.set(false)
    return api
end

-- components.Toggle's sliding switch becomes a rocker: a slot cut in the plate
-- with a paddle riding in it, and a lamp behind that shows when it is on.
function hw.switch(switchBtn, knob)
    switchBtn.BackgroundColor3 = C.slot
    corner(switchBtn, 3)
    line(switchBtn, "SwitchShade", UDim2.fromOffset(0, 0),
         UDim2.new(1, 0, 0, 1), BLACK, 0.2, 2)

    knob.ZIndex = 4
    knob.BackgroundColor3 = C.capTop
    corner(knob, 2)
    gradient(knob, C.capTop, C.capBot)
    line(knob, "KnobLip",  UDim2.fromOffset(0, 0),
         UDim2.new(1, 0, 0, 1), WHITE, LIP_T, 5)
    line(knob, "KnobFoot", UDim2.new(0, 0, 1, -1),
         UDim2.new(1, 0, 0, 1), BLACK, FOOT_T, 5)

    -- Grip ridges, so the paddle reads as something a thumb pushes.
    for i = 0, 2 do
        local ridge = Instance.new("Frame")
        ridge.Name = "Grip"
        ridge.Size = UDim2.new(0, 1, 0, 8)
        ridge.AnchorPoint = Vector2.new(0.5, 0.5)
        ridge.Position = UDim2.new(0.5, (i - 1) * 3, 0.5, 0)
        ridge.BackgroundColor3 = BLACK
        ridge.BackgroundTransparency = 0.55
        ridge.BorderSizePixel = 0
        ridge.ZIndex = 6
        ridge.Parent = knob
    end

    -- The lit end of the slot, revealed as the paddle slides off it.
    local glow = Instance.new("Frame")
    glow.Name = "Glow"
    glow.Size = UDim2.new(1, -4, 1, -4)
    glow.Position = UDim2.fromOffset(2, 2)
    glow.BackgroundColor3 = theme.on
    glow.BackgroundTransparency = 0.45
    glow.BorderSizePixel = 0
    glow.ZIndex = 3
    glow.Visible = false
    glow.Parent = switchBtn
    corner(glow, 2)

    -- ownsColor tells components.Toggle to stop doing its own accent/bgDark
    -- fill: the slot is painted here and a flat fill would kill the gradient.
    return { ownsColor = true, set = function(on) glow.Visible = on and true or false end }
end

-- The slider becomes a fader: a routed channel with a physical cap riding it.
-- The cap tracks the fill frame's width, so components.Slider needs no wiring
-- beyond handing us the two frames.
function hw.slider(track, fill)
    hw.well(track, 2)

    fill.ZIndex = 3
    corner(fill, 2)
    gradient(fill, theme.accent:Lerp(WHITE, 0.2), theme.accent:Lerp(BLACK, 0.35))

    local cap = Instance.new("Frame")
    cap.Name = "FaderCap"
    cap.Size = UDim2.fromOffset(10, 18)
    cap.AnchorPoint = Vector2.new(0.5, 0.5)
    cap.Position = UDim2.new(0, 0, 0.5, 0)
    cap.BackgroundColor3 = C.capTop
    cap.BorderSizePixel = 0
    cap.ZIndex = 6
    cap.Parent = track
    corner(cap, 2)
    gradient(cap, C.capTop, C.capBot)
    line(cap, "CapLip",  UDim2.fromOffset(0, 0),
         UDim2.new(1, 0, 0, 1), WHITE, LIP_T, 7)
    line(cap, "CapFoot", UDim2.new(0, 0, 1, -1),
         UDim2.new(1, 0, 0, 1), BLACK, FOOT_T, 7)
    line(cap, "CapNotch", UDim2.new(0.5, -3, 0.5, 0),
         UDim2.new(0, 6, 0, 1), BLACK, 0.35, 8)

    -- Follow the fill rather than the value: Slider drives fill.Size for both
    -- drags and api:Set, so one signal covers every way the value can move.
    local function follow()
        cap.Position = UDim2.new(fill.Size.X.Scale, fill.Size.X.Offset, 0.5, 0)
    end
    follow()
    fill:GetPropertyChangedSignal("Size"):Connect(follow)

    return { set = follow }
end

-- Navigator pills become lamps sunk into the plate: dark bezel, lit face.
function hw.led(frame)
    corner(frame, 2)
    stroke(frame, BLACK, 0.1, 1)
    local g = gradient(frame, WHITE, BLACK, 90, true)
    g.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.6),
        NumberSequenceKeypoint.new(1, 0.35),
    })
    return { set = function() end }
end

-- The floating "P" opener stays the hexagon it has always been. It is the one
-- control NOT embedded in anything -- it sits on the screen by itself -- so it
-- gets the raised treatment instead: a shadow hex under it, and a shaded,
-- top-lit face.
function hw.logo(host, hexHost, label)
    local w = (host.Size and host.Size.X.Offset) or 46
    local h = (host.Size and host.Size.Y.Offset) or 40

    local shadow = hex.build(host, w, h, BLACK, 9)
    shadow.Name = "HexShadow"
    shadow.Position = UDim2.fromOffset(0, 2)

    hex.setShade(hexHost, C.band, C.bandDim)
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
-- before the first instance exists, so this lands in time.
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
function skin.key(f, o)                       return active.key(f, o) end
function skin.well(f, r)                      return active.well(f, r) end
function skin.face(f, r)                      return active.face(f, r) end
function skin.readout(f)                      return active.readout(f) end
function skin.tray(f)                         return active.tray(f) end
function skin.engrave(l)                      return active.engrave(l) end
function skin.separator(f)                    return active.separator(f) end
function skin.press(b, sock, shift)           return active.press(b, sock, shift) end
function skin.hexKey(host, hexHost, label, o) return active.hexKey(host, hexHost, label, o) end
function skin.switch(sw, knob)                return active.switch(sw, knob) end
function skin.slider(track, fill)             return active.slider(track, fill) end
function skin.led(f)                          return active.led(f) end
function skin.logo(host, hexHost, label)      return active.logo(host, hexHost, label) end

return skin
