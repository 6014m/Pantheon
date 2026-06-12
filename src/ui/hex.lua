-- Hexagon shape builder. Draws a flat-top regular hexagon as a stack of
-- horizontal rows whose width matches the hex's geometry at that y. Rows are
-- ~2px tall and each overlaps its neighbor by 1px to hide the seam, so the
-- diagonal edges still read smooth while halving the GuiObject count vs the old
-- 1-row-per-pixel build (the hub draws ~3 hexes per feature row, so it adds up).
--
-- Geometry for a flat-top hex inscribed in w x h:
--   * widest at the vertical middle (width = w)
--   * narrowest at the top and bottom edges (width = w/2)
--   * width(y) = w - |y - h/2| * w/h
-- For a regular hexagon, pass h = w * sqrt(3)/2 (~= 0.866w). Stretched
-- proportions still draw cleanly but are no longer "regular."

local hex = {}

function hex.build(parent, w, h, color, zIndex, texture)
    -- texture (optional): { image, src, transparency, tint }. When given, each
    -- row becomes an ImageLabel showing its horizontal band of `image` (assumed
    -- `src` px square) over the base `color`, so the picture fills the hex
    -- silhouette -- used to give the "P" button the same carbon look as panels.
    -- ~2px per row (was ~1px). rowH+1 sizing below keeps a 1px overlap so the
    -- coarser stepping doesn't open gaps on the diagonal edges.
    local rows = math.max(8, math.ceil(h / 2))
    local rowH = h / rows
    local src  = texture and (texture.src or 128) or nil

    local host = Instance.new("Frame")
    host.Size = UDim2.fromOffset(w, h)
    host.BackgroundTransparency = 1
    host.ZIndex = zIndex or 1
    host.Parent = parent

    for i = 0, rows - 1 do
        local yCenter = (i + 0.5) * rowH
        local distFromMid = math.abs(yCenter - h / 2)
        local rowW = w - distFromMid * w / h
        if rowW < 1 then rowW = 1 end

        local row
        if texture then
            -- Sample the sub-rect of the image that lines up with this row so
            -- the whole picture is reconstructed inside the hex outline.
            local left = w / 2 - rowW / 2
            row = Instance.new("ImageLabel")
            row.BackgroundColor3 = color           -- base tints through the texture
            row.Image = texture.image
            row.ScaleType = Enum.ScaleType.Stretch
            row.ImageRectOffset = Vector2.new(left / w * src, (yCenter - rowH / 2) / h * src)
            row.ImageRectSize   = Vector2.new(rowW / w * src, rowH / h * src)
            row.ImageTransparency = texture.transparency or 0
            if texture.tint then row.ImageColor3 = texture.tint end
        else
            row = Instance.new("Frame")
            row.BackgroundColor3 = color
        end
        -- +1 on height so adjacent rows overlap by ~1px, hiding gaps.
        row.Size = UDim2.fromOffset(rowW, rowH + 1)
        row.Position = UDim2.fromOffset(w / 2, yCenter)
        row.AnchorPoint = Vector2.new(0.5, 0.5)
        row.BorderSizePixel = 0
        row.Parent = host
    end

    return host
end

-- Convenience: build a hex AND position it at `position` with `anchor`.
-- Used for placing small hex accents at specific points (container corners etc).
function hex.placed(parent, w, h, color, position, anchor, zIndex)
    local host = hex.build(parent, w, h, color, zIndex)
    host.Position = position
    host.AnchorPoint = anchor or Vector2.new(0, 0)
    return host
end

-- Recolor every row of an existing hex (built by hex.build). Used for
-- elements that need to flip color on a state change (ON/OFF indicators etc).
function hex.setColor(hexHost, color)
    for _, child in ipairs(hexHost:GetChildren()) do
        if child:IsA("Frame") then
            child.BackgroundColor3 = color
        end
    end
end

return hex
