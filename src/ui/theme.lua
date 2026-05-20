-- Pantheon visual theme. Adjust here, all components inherit.

local theme = {
    accent  = Color3.fromRGB(85, 130, 255),
    bg      = Color3.fromRGB(20, 20, 22),
    bgAlt   = Color3.fromRGB(28, 28, 32),
    bgDark  = Color3.fromRGB(15, 15, 17),
    fg      = Color3.fromRGB(230, 230, 235),
    fgDim   = Color3.fromRGB(150, 150, 160),
    border  = Color3.fromRGB(45, 45, 50),
    success = Color3.fromRGB(95, 200, 130),
    danger  = Color3.fromRGB(220, 90, 90),

    font     = Enum.Font.GothamMedium,
    fontBold = Enum.Font.GothamBold,
    fontMono = Enum.Font.Code,

    windowSize    = UDim2.fromOffset(560, 380),
    sidebarWidth  = 140,
    rowHeight     = 32,
    cornerRadius  = UDim.new(0, 6),
    padding       = 8,
}

return theme
