-- Pantheon visual theme. Adjust here, all components inherit.

local theme = {
    -- Discord-black palette (was a blue accent). The blue became a monochrome
    -- silver-gray so header bands / slider fills / the "P" still read against
    -- near-black; panels are kept distinct by the carbon-fiber texture below
    -- rather than by color.
    accent   = Color3.fromRGB(120, 125, 133),
    -- Darker grey just for the draggable container header bands + the "P"
    -- button (kept separate from `accent` so slider/section text stays legible).
    headerBand = Color3.fromRGB(60, 63, 70),
    bg       = Color3.fromRGB(24, 25, 28),
    bgAlt    = Color3.fromRGB(35, 37, 41),
    bgDark   = Color3.fromRGB(15, 16, 18),

    fg       = Color3.fromRGB(230, 230, 235),
    fgDim    = Color3.fromRGB(150, 150, 160),
    border   = Color3.fromRGB(48, 50, 55),

    -- "P" open button: the glyph is drawn in the SAME color as its hex fill
    -- (theme.accent) so it blends, and a stroke keeps it legible. Tweak these
    -- to restyle the logo without touching window.lua.
    logoStroke          = Color3.fromRGB(230, 230, 235),
    logoStrokeThickness = 1.5,

    -- Carbon-fiber texture tiled over container bodies so the near-black panels
    -- don't blend into each other / the world. Upload assets/carbon_fiber.png to
    -- Roblox and put its id in panelTexture; "" disables the overlay entirely.
    panelTexture             = "rbxassetid://83752823743620",
    panelTextureTransparency = 0.82,
    panelTextureTint         = Color3.fromRGB(255, 255, 255),
    panelTextureTile         = 96,
    panelTextureSrc          = 128,   -- carbon_fiber.png native px; used to sample the hex "P" button

    -- Wurst-style ON/OFF state colors
    on       = Color3.fromRGB(60, 222, 60),
    off      = Color3.fromRGB(222, 60, 60),
    success  = Color3.fromRGB(60, 222, 60),
    danger   = Color3.fromRGB(222, 60, 60),

    font     = Enum.Font.GothamMedium,
    fontBold = Enum.Font.GothamBold,
    fontMono = Enum.Font.Code,

    -- Sizes
    containerWidth = 220,
    containerGap   = 12,
    gridSize       = 48,   -- drag-snap grid (px) for containers + the P button
    featureHeight  = 30,
    rowHeight      = 30,
    cornerRadius   = UDim.new(0, 0),
    padding        = 6,

    -- Slide sound: played per panel as it slides on/off screen (master toggle).
    -- Set slideSoundId = "" to disable.
    slideSoundId = "rbxassetid://106626079056148",
    slideVolume  = 0.5,
}

return theme
