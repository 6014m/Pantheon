-- Hexagon shape builder. Draws a flat-top regular hexagon as a stack of
-- horizontal rows whose width matches the hex's geometry at that y. With
-- ~1 row per pixel of height, the diagonal edges look smooth.
--
-- Geometry for a flat-top hex inscribed in w x h:
--   * widest at the vertical middle (width = w)
--   * narrowest at the top and bottom edges (width = w/2)
--   * width(y) = w - |y - h/2| * w/h
-- For a regular hexagon, pass h = w * sqrt(3)/2 (~= 0.866w). Stretched
-- proportions still draw cleanly but are no longer "regular."

local hex = {}

function hex.build(parent, w, h, color, zIndex)
    local rows = math.max(8, math.ceil(h))
    local rowH = h / rows

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

        local row = Instance.new("Frame")
        -- +1 on height so adjacent rows overlap by ~1px, hiding gaps.
        row.Size = UDim2.fromOffset(rowW, rowH + 1)
        row.Position = UDim2.fromOffset(w / 2, yCenter)
        row.AnchorPoint = Vector2.new(0.5, 0.5)
        row.BackgroundColor3 = color
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
