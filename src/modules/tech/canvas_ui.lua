-- Scratch-style block canvas. Replaces the flat chip list inside the Tech
-- Builder. Blocks are absolutely positioned, draggable, and snap-to-connect
-- via their top-notch / bottom-tab connectors -- the same mental model as
-- Scratch's stack blocks. The chain order (hat -> next -> next -> ...) is the
-- tech's action sequence; disconnected blocks are saved in Y order so a
-- block floated off the chain doesn't silently vanish.
--
-- Public API:
--   Canvas.new(parent, opts)  -- opts = { onChange = fn, getPaletteColor, getLabel }
--   c:addBlock(type, params, x, y) -> block      -- spawn a block at canvas-local x,y
--   c:loadActions(actions)                       -- rebuild canvas from action array
--   c:toActions() -> { ... }                     -- read canvas back to action array
--   c:clear()                                    -- destroy all blocks
--   c.changed -- Signal fired when the canvas state changes
--
-- Limitations of V1 (V2 plans):
--   * Nested slots (C-blocks for AND / during / hold-release pair) are NOT
--     drawn as slot containers yet -- they snap into the linear chain like
--     any other block. The engine still consumes them (during/hold/release
--     act as sentinels in the chain; AND has branches[] that we treat as a
--     single-step block for V1, encoding the branches via a side-pane editor
--     that doesn't ship in V1).
--   * No trash zone -- delete is per-block via a tiny X button.

local UIS        = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Players    = game:GetService("Players")

local theme   = require("ui.theme")
local Signal  = require("core.signal")
local feature = require("ui.feature")
local scanner = require("modules.tech.scanner")

local Canvas = {}
Canvas.__index = Canvas

-- ---- visual constants ----
local BLOCK_W       = 200
local BLOCK_H       = 36
local TAB_W         = 20
local TAB_INSET_X   = 22       -- where the top-notch / bottom-tab sits (X offset from block left)
local SNAP_RADIUS   = 22       -- distance to snap when block's top meets another's bottom
local CANVAS_MIN_H  = 320      -- min height of the canvas frame; auto-grows when blocks drop below
local HAT_LABEL_COL = Color3.fromRGB(40, 30, 0)

local CATEGORY = {
    look = "motion", rotate = "motion",
    wait = "control", during = "control", ["return"] = "control",
    hold = "control", release = "control", ["and"] = "control",
    within = "sense",
    feature = "action", key = "action", usebtn = "action",
}
local CAT_COLOR = {
    motion  = Color3.fromRGB(76, 151, 255),
    control = Color3.fromRGB(255, 171, 25),
    sense   = Color3.fromRGB(92, 177, 214),
    action  = Color3.fromRGB(159, 110, 220),
    event   = Color3.fromRGB(255, 191, 0),
}
local STEP_LABEL = {
    look = "Look", rotate = "Rotate", wait = "Wait", during = "During",
    within = "Within", ["return"] = "Return", feature = "Use", key = "Press",
    hold = "Hold", release = "Release", usebtn = "Use Move", ["and"] = "AND",
}
local YAW_PRESETS = { 180, 135, 90, 45, 0, -45, -90, -135, -180 }
local function nextYaw(cur)
    for i, v in ipairs(YAW_PRESETS) do if v == cur then return YAW_PRESETS[(i % #YAW_PRESETS) + 1] end end
    return YAW_PRESETS[1]
end
local function catOf(t) return CATEGORY[t] or "action" end
local function colorOf(t) return CAT_COLOR[catOf(t)] end

-- ---- small helpers ----
local function corner(o, r) local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r or 6); c.Parent = o; return c end
local function stroke(o, col, t) local s = Instance.new("UIStroke"); s.Color = col or theme.border; s.Thickness = t or 1; s.Parent = o; return s end
local function lerpCol(c, k) return Color3.fromRGB(math.floor(c.R * 255 * k), math.floor(c.G * 255 * k), math.floor(c.B * 255 * k)) end

-- mouse position in CANVAS-LOCAL coordinates (subtract canvas absolute origin)
local function canvasLocal(canvas, gx, gy)
    local origin = canvas.frame.AbsolutePosition
    return gx - origin.X, gy - origin.Y
end

-- ---- block param rendering ----
-- Each block type knows how to render its inline param controls onto the
-- block frame, and how to read changes back into block.params. Kept inline
-- here (rather than a big STEP_PARAMS table) so the canvas module is self-
-- contained and the chip layout can evolve without affecting the rest of the
-- builder.
local renderParams
do
    local function valArea(blk)
        local val = Instance.new("Frame")
        val.Size = UDim2.new(1, -118, 1, -10)
        val.Position = UDim2.new(0, 92, 0, 5)
        val.BackgroundColor3 = theme.bgDark
        val.BorderSizePixel = 0
        val.Parent = blk.frame
        corner(val, 6)
        return val
    end
    local function valBtn(blk, text, onClick)
        local v = valArea(blk)
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(1, 0, 1, 0); b.BackgroundTransparency = 1; b.AutoButtonColor = false
        b.Text = text; b.TextColor3 = theme.fg; b.Font = theme.font; b.TextSize = 12; b.Parent = v
        if onClick then b.MouseButton1Click:Connect(onClick) end
        return b
    end
    local function valTextbox(blk, text, onCommit)
        local v = valArea(blk)
        local tb = Instance.new("TextBox")
        tb.Size = UDim2.new(1, 0, 1, 0); tb.BackgroundTransparency = 1
        tb.Text = text; tb.TextColor3 = theme.fg; tb.Font = theme.font; tb.TextSize = 12
        tb.ClearTextOnFocus = false; tb.Parent = v
        tb.FocusLost:Connect(function() onCommit(tb.Text); tb.Text = onCommit(tb.Text, true) or tb.Text end)
        return tb
    end

    renderParams = function(blk)
        local t, p = blk.type, blk.params
        if t == "look" or t == "rotate" then
            valBtn(blk, tostring(p.x or 0) .. "\u{00B0}", function()
                p.x = nextYaw(p.x or 0)
                blk.canvas:_refreshBlockText(blk)
            end)
        elseif t == "wait" then
            valTextbox(blk, tostring(p.seconds or 0.5), function(s, isRead)
                local n = tonumber((tostring(s):gsub("[^%d%.]", "")))
                if n and not isRead then p.seconds = math.clamp(n, 0, 60) end
                return tostring(p.seconds or 0.5)
            end)
        elseif t == "within" then
            valTextbox(blk, tostring(p.studs or 5), function(s, isRead)
                local n = tonumber((tostring(s):gsub("[^%d%.]", "")))
                if n and not isRead then p.studs = math.clamp(n, 0, 500) end
                return tostring(p.studs or 5)
            end)
        elseif t == "during" or t == "return" then
            valBtn(blk, t == "during" and "holds prev step for next wait" or "re-face target")
        elseif t == "key" or t == "hold" or t == "release" then
            local b = valBtn(blk, p.key and ("key: " .. p.key) or "(click, press a key)")
            b.MouseButton1Click:Connect(function()
                b.Text = "press a key..."
                local conn
                conn = UIS.InputBegan:Connect(function(input)
                    if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
                    if input.KeyCode == Enum.KeyCode.Unknown then return end
                    if input.KeyCode ~= Enum.KeyCode.Escape then
                        p.key = (tostring(input.KeyCode):gsub("Enum.KeyCode.", ""))
                    end
                    b.Text = p.key and ("key: " .. p.key) or "(click, press a key)"
                    conn:Disconnect()
                end)
            end)
        elseif t == "feature" then
            local function featName(id)
                for _, f in ipairs(feature.all()) do if f.id == id then return f.name or f.id end end
                return id or "(none)"
            end
            local b = valBtn(blk, featName(p.feature))
            b.MouseButton1Click:Connect(function()
                local feats = feature.all()
                table.sort(feats, function(a, b) return (a.name or a.id) < (b.name or b.id) end)
                if #feats > 0 then
                    local idx = 0
                    for k, ft in ipairs(feats) do if ft.id == p.feature then idx = k end end
                    p.feature = feats[(idx % #feats) + 1].id
                    b.Text = featName(p.feature)
                end
            end)
        elseif t == "usebtn" then
            local res = scanner.cached() or scanner.scan()
            local moveset = res.buttons or {}
            if not p.move and #moveset > 0 then p.move = moveset[1].name end
            local function label()
                if #moveset == 0 then return "(no moves - Dump GUI)" end
                for _, b in ipairs(moveset) do if b.name == p.move then return (b.text ~= "" and b.text) or b.name end end
                return "(pick)"
            end
            local b = valBtn(blk, label())
            b.MouseButton1Click:Connect(function()
                if #moveset == 0 then return end
                local idx = 0
                for k, bb in ipairs(moveset) do if bb.name == p.move then idx = k end end
                p.move = moveset[(idx % #moveset) + 1].name
                b.Text = label()
            end)
        elseif t == "and" then
            -- V1: AND is a leaf-looking block with placeholder text. Branch
            -- editing is the V2 nested-slot job.
            valBtn(blk, "AND -- branches (V2)")
        end
    end
end

-- ============ Canvas ============
function Canvas.new(parent, opts)
    local self = setmetatable({}, Canvas)
    opts = opts or {}
    self.onChange = opts.onChange

    self.frame = Instance.new("Frame")
    self.frame.Size = UDim2.new(1, 0, 0, CANVAS_MIN_H)
    self.frame.BackgroundColor3 = theme.bgDark
    self.frame.BorderSizePixel = 0
    self.frame.Parent = parent
    self.frame.ClipsDescendants = false   -- let blocks visually overflow downward; we grow height instead
    corner(self.frame, 8)
    stroke(self.frame, theme.border)

    self.blocks = {}   -- list of blocks, in insertion order
    self.changed = Signal.new()
    self._uid = 0
    return self
end

function Canvas:_nextId() self._uid = self._uid + 1; return "blk_" .. self._uid end

function Canvas:_refreshBlockText(blk)
    if blk.lbl then
        blk.lbl.Text = (STEP_LABEL[blk.type] or blk.type)
    end
end

function Canvas:_fireChanged()
    self.changed:Fire()
    if self.onChange then pcall(self.onChange) end
end

-- Grow the canvas frame's height to cover the lowest block (+ padding) so
-- a tall stack stays visible without needing scroll inside the canvas.
function Canvas:_resizeToContent()
    local maxY = CANVAS_MIN_H
    for _, b in ipairs(self.blocks) do
        local by = b.frame.Position.Y.Offset + b.frame.Size.Y.Offset + 12
        if by > maxY then maxY = by end
    end
    self.frame.Size = UDim2.new(1, 0, 0, maxY)
end

-- Walk the chain rooted at `head` (head.prev == nil) and stack blocks
-- vertically so they butt up against each other -- used after a snap and
-- when dragging a chain root around.
function Canvas:_layoutChain(head)
    local cur = head
    local x = cur.frame.Position.X.Offset
    local y = cur.frame.Position.Y.Offset
    while cur do
        cur.frame.Position = UDim2.fromOffset(x, y)
        y = y + cur.frame.Size.Y.Offset
        cur = cur.next
    end
end

-- Find the head of `blk`'s chain (walk .prev to the topmost block).
local function chainHead(blk)
    while blk.prev do blk = blk.prev end
    return blk
end

-- Remove block from its current chain (if any) -- used at drag start so the
-- block can be repositioned freely without dragging its old neighbors along.
function Canvas:_detach(blk)
    if blk.prev then
        blk.prev.next = nil
        blk.prev = nil
    end
end

-- Try to snap `blk` to another block's bottom. Looks for any block whose
-- bottom-tab is within SNAP_RADIUS of `blk`'s top-notch, AND whose .next
-- slot is open. On success, rewires the chain and lays out the joined
-- chain so it stacks cleanly.
function Canvas:_trySnap(blk)
    if blk.prev then return end   -- already chained somewhere
    local myTopX = blk.frame.Position.X.Offset + TAB_INSET_X
    local myTopY = blk.frame.Position.Y.Offset
    for _, other in ipairs(self.blocks) do
        if other ~= blk and not other.next then
            -- block can't snap onto its own descendant (would create a loop)
            local descendant = false
            local cur = blk
            while cur do if cur == other then descendant = true; break end; cur = cur.next end
            if not descendant then
                local oBotX = other.frame.Position.X.Offset + TAB_INSET_X
                local oBotY = other.frame.Position.Y.Offset + other.frame.Size.Y.Offset
                local dx, dy = math.abs(myTopX - oBotX), math.abs(myTopY - oBotY)
                if dx < SNAP_RADIUS and dy < SNAP_RADIUS then
                    blk.frame.Position = UDim2.fromOffset(other.frame.Position.X.Offset, oBotY)
                    other.next = blk; blk.prev = other
                    self:_layoutChain(chainHead(blk))
                    return true
                end
            end
        end
    end
    return false
end

-- Drag wiring: hold MB1 on a block -> drag freely (chain follows); release
-- -> try to snap to a nearby block's bottom. We detach the block from its
-- previous chain on drag start so it lifts cleanly out of the stack.
function Canvas:_wireDrag(blk)
    local moveConn, endConn, dragging
    blk.frame.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
        dragging = {
            startMouse = UIS:GetMouseLocation(),
            startPos = blk.frame.Position,
        }
        self:_detach(blk)
        blk.frame.ZIndex = 100   -- float above siblings while dragging
        local cur = blk.next; while cur do cur.frame.ZIndex = 100; cur = cur.next end
    end)
    moveConn = UIS.InputChanged:Connect(function(input)
        if not dragging or input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
        local mm = UIS:GetMouseLocation()
        local dx = mm.X - dragging.startMouse.X
        local dy = mm.Y - dragging.startMouse.Y
        blk.frame.Position = UDim2.fromOffset(
            dragging.startPos.X.Offset + dx,
            dragging.startPos.Y.Offset + dy
        )
        self:_layoutChain(blk)
    end)
    endConn = UIS.InputEnded:Connect(function(input)
        if not dragging or input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
        dragging = nil
        self:_trySnap(blk)
        blk.frame.ZIndex = 2
        local cur = blk.next; while cur do cur.frame.ZIndex = 2; cur = cur.next end
        self:_resizeToContent()
    self:_fireChanged()
    end)
    blk._dragConns = { moveConn, endConn }
end

function Canvas:_destroyBlock(blk)
    if blk.prev then blk.prev.next = nil end
    if blk.next then blk.next.prev = nil end
    if blk._dragConns then
        for _, c in ipairs(blk._dragConns) do pcall(function() c:Disconnect() end) end
    end
    blk.frame:Destroy()
    for i, b in ipairs(self.blocks) do if b == blk then table.remove(self.blocks, i); break end end
    self:_resizeToContent()
    self:_fireChanged()
end

-- Render the visual block (rounded fill, label, decorative top notch + bottom
-- tab, X button to delete). Inline param controls are added by renderParams.
function Canvas:_renderBlock(blk)
    local f = blk.frame
    f.BackgroundColor3 = colorOf(blk.type)
    corner(f, 10)
    stroke(f, lerpCol(colorOf(blk.type), 0.55), 1)

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(0, 78, 1, 0); lbl.Position = UDim2.fromOffset(10, 0)
    lbl.BackgroundTransparency = 1; lbl.Text = STEP_LABEL[blk.type] or blk.type
    lbl.TextColor3 = theme.fg; lbl.Font = theme.fontBold; lbl.TextSize = 13
    lbl.TextXAlignment = Enum.TextXAlignment.Left; lbl.Parent = f
    blk.lbl = lbl

    -- bottom tab decoration (visual connector cue)
    local tab = Instance.new("Frame")
    tab.Size = UDim2.fromOffset(TAB_W, 3); tab.Position = UDim2.new(0, TAB_INSET_X, 1, 0)
    tab.BackgroundColor3 = colorOf(blk.type); tab.BorderSizePixel = 0; tab.Parent = f

    -- delete button (top-right corner)
    local del = Instance.new("TextButton")
    del.Size = UDim2.fromOffset(18, 18); del.Position = UDim2.new(1, -22, 0, 4)
    del.BackgroundColor3 = theme.danger; del.AutoButtonColor = false
    del.TextColor3 = theme.fg; del.Font = theme.fontBold; del.TextSize = 11; del.Text = "X"
    del.Parent = f; corner(del, 4)
    del.MouseButton1Click:Connect(function() self:_destroyBlock(blk) end)

    renderParams(blk)
end

function Canvas:addBlock(blockType, params, x, y)
    local f = Instance.new("Frame")
    f.Size = UDim2.fromOffset(BLOCK_W, BLOCK_H)
    f.Position = UDim2.fromOffset(x or 12, y or (#self.blocks * (BLOCK_H + 4) + 12))
    f.BackgroundColor3 = colorOf(blockType); f.BorderSizePixel = 0
    f.ZIndex = 2; f.Parent = self.frame

    local blk = {
        id = self:_nextId(), type = blockType, params = params or {},
        frame = f, next = nil, prev = nil, canvas = self,
    }
    self.blocks[#self.blocks + 1] = blk
    self:_renderBlock(blk)
    self:_wireDrag(blk)
    -- try auto-snap to last block's bottom if visually close enough -- so
    -- click-to-add from a palette button still produces a stack on the
    -- canvas (V1 keeps the palette tap path even with drag enabled).
    self:_trySnap(blk)
    self:_resizeToContent()
    self:_fireChanged()
    return blk
end

function Canvas:clear()
    for _, b in ipairs(self.blocks) do
        if b._dragConns then for _, c in ipairs(b._dragConns) do pcall(function() c:Disconnect() end) end end
        b.frame:Destroy()
    end
    self.blocks = {}
end

-- Read canvas state -> linear action array. Strategy: find chain heads (no
-- .prev), walk each chain head -> next -> ... to produce a list per chain,
-- then concat all chains in order of their head's Y position (so the
-- top-most chain is the "main" sequence, with disconnected blocks tacked on
-- in Y order). Includes block.params verbatim.
function Canvas:toActions()
    local heads = {}
    for _, b in ipairs(self.blocks) do if not b.prev then heads[#heads + 1] = b end end
    table.sort(heads, function(a, b)
        return a.frame.Position.Y.Offset < b.frame.Position.Y.Offset
    end)
    local out = {}
    for _, h in ipairs(heads) do
        local cur = h
        while cur do
            local a = { type = cur.type }
            for k, v in pairs(cur.params or {}) do a[k] = v end
            out[#out + 1] = a
            cur = cur.next
        end
    end
    return out
end

-- Hydrate canvas from a saved action array -- place blocks vertically and
-- chain them. Anything that came in chained stays chained on load (so a
-- saved tech opens visually identical to a Scratch stack).
function Canvas:loadActions(actions)
    self:clear()
    local y = 12
    local prev
    for _, a in ipairs(actions or {}) do
        local params = {}
        for k, v in pairs(a) do if k ~= "type" then params[k] = v end end
        local blk = self:addBlock(a.type, params, 12, y)
        -- _trySnap on add will chain with last block; if it didn't snap
        -- (unlikely on identical x), manually wire it
        if prev and not blk.prev then prev.next = blk; blk.prev = prev end
        y = y + BLOCK_H + 4
        prev = blk
    end
    if prev then self:_layoutChain(chainHead(prev)) end
end

return Canvas
