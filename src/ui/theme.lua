-- Pantheon visual theme. Adjust here, all components inherit.

local theme = {
    accent   = Color3.fromRGB(85, 130, 255),
    bg       = Color3.fromRGB(20, 20, 22),
    bgAlt    = Color3.fromRGB(28, 28, 32),
    bgDark   = Color3.fromRGB(15, 15, 17),

    fg       = Color3.fromRGB(230, 230, 235),
    fgDim    = Color3.fromRGB(150, 150, 160),
    border   = Color3.fromRGB(45, 45, 50),

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
    featureHeight  = 30,
    rowHeight      = 30,
    cornerRadius   = UDim.new(0, 0),
    padding        = 6,
}

return theme
