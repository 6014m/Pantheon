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

-- Module-level exports (the builder_ui needs these to iterate hat-block
-- types for its palette + detect hats in the saved action stream).
Canvas.HAT_TYPES = nil      -- assigned below once HAT_TYPES exists
Canvas.isHat = nil
Canvas.colorOf = nil
Canvas.STEP_LABEL = nil

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
    hold = "control", release = "control", ["and"] = "control", ["or"] = "control",
    within = "sense",
    feature = "action", key = "action", usebtn = "action",
    -- Hat blocks (event triggers). Each carries the trigger params on its
    -- own .params table; builder_ui detects a hat at the top of a chain at
    -- Save and extracts it into tech.trigger.
    event_key       = "event",
    event_anim      = "event",
    event_target_anim = "event",
    event_move      = "event",
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
    hold = "Hold", release = "Release", usebtn = "Use Move", ["and"] = "AND", ["or"] = "OR",
    event_key         = "When key",
    event_anim        = "When my anim",
    event_target_anim = "When target anim",
    event_move        = "When move",
}
local HAT_TYPES = { "event_key", "event_anim", "event_target_anim", "event_move" }
local function isHat(t) return t == "event_key" or t == "event_anim" or t == "event_target_anim" or t == "event_move" end
local YAW_PRESETS = { 180, 135, 90, 45, 0, -45, -90, -135, -180 }
local function nextYaw(cur)
    for i, v in ipairs(YAW_PRESETS) do if v == cur then return YAW_PRESETS[(i % #YAW_PRESETS) + 1] end end
    return YAW_PRESETS[1]
end
local function catOf(t) return CATEGORY[t] or "action" end
local function colorOf(t) return CAT_COLOR[catOf(t)] end

Canvas.HAT_TYPES = HAT_TYPES
Canvas.isHat = isHat
Canvas.colorOf = colorOf
Canvas.STEP_LABEL = STEP_LABEL

-- ---- small helpers ----
local function corner(o, r) local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r or 6); c.Parent = o; return c end
local function stroke(o, col, t) local s = Instance.new("UIStroke"); s.Color = col or theme.border; s.Thickness = t or 1; s.Parent = o; return s end
local function lerpCol(c, k) return Color3.fromRGB(math.floor(c.R * 255 * k), math.floor(c.G * 255 * k), math.floor(c.B * 255 * k)) end

-- Drag-window flag set briefly after a drag ends so the inner param buttons
-- can swallow the accidental MouseButton1Click that would otherwise fire
-- when MB1Up lands on the (now-moved) value button. Without this, a drag
-- that ends with the cursor still over the value button triggers its
-- onClick -- which for `key`/`hold` blocks blanked the inline label to
-- "press a key...", and for `look`/`rotate`/`feature` cycled the value.
local dragJustEnded = false
local function guardedClick(btn, fn)
    btn.MouseButton1Click:Connect(function(...)
        if dragJustEnded then return end
        fn(...)
    end)
end

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
        if onClick then guardedClick(b, onClick) end
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
            -- left: yaw cycle button. right: a "hold (s)" textbox = how long to
            -- keep this look/rotation before it snaps back (blank/0 = until a
            -- Return / During->Wait / tech end, the old behavior).
            local v = valArea(blk)
            local yawB = Instance.new("TextButton")
            yawB.Size = UDim2.new(0.5, -3, 1, 0); yawB.Position = UDim2.new(0, 0, 0, 0)
            yawB.BackgroundTransparency = 1; yawB.AutoButtonColor = false
            yawB.Text = tostring(p.x or 0) .. "\u{00B0}"
            yawB.TextColor3 = theme.fg; yawB.Font = theme.font; yawB.TextSize = 12; yawB.Parent = v
            guardedClick(yawB, function()
                p.x = nextYaw(p.x or 0); yawB.Text = tostring(p.x or 0) .. "\u{00B0}"
            end)
            local function holdText() return (p.hold and p.hold > 0) and (tostring(p.hold) .. "s") or "" end
            local holdB = Instance.new("TextBox")
            holdB.Size = UDim2.new(0.5, -3, 1, 0); holdB.Position = UDim2.new(0.5, 3, 0, 0)
            holdB.BackgroundColor3 = theme.bgAlt; holdB.BorderSizePixel = 0
            holdB.Text = holdText(); holdB.PlaceholderText = "hold s"
            holdB.PlaceholderColor3 = theme.fgDim
            holdB.TextColor3 = theme.fg; holdB.Font = theme.font; holdB.TextSize = 11
            holdB.ClearTextOnFocus = false; holdB.Parent = v
            corner(holdB, 4)
            holdB.FocusLost:Connect(function()
                local n = tonumber((tostring(holdB.Text):gsub("[^%d%.]", "")))
                if n and n > 0 then p.hold = math.clamp(n, 0, 30) else p.hold = nil end
                holdB.Text = holdText()
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
            guardedClick(b, function()
                -- Disconnect a capture already armed on this block (double-click)
                -- so the previous global UIS connection doesn't leak.
                if blk._keyCaptureConn then blk._keyCaptureConn:Disconnect(); blk._keyCaptureConn = nil end
                b.Text = "press a key..."
                blk._keyCaptureConn = UIS.InputBegan:Connect(function(input)
                    if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
                    if input.KeyCode == Enum.KeyCode.Unknown then return end
                    if input.KeyCode ~= Enum.KeyCode.Escape then
                        p.key = (tostring(input.KeyCode):gsub("Enum.KeyCode.", ""))
                    end
                    b.Text = p.key and ("key: " .. p.key) or "(click, press a key)"
                    if blk._keyCaptureConn then blk._keyCaptureConn:Disconnect(); blk._keyCaptureConn = nil end
                end)
            end)
        elseif t == "feature" then
            local function featName(id)
                for _, f in ipairs(feature.all()) do if f.id == id then return f.name or f.id end end
                return id or "(none)"
            end
            local b = valBtn(blk, featName(p.feature))
            guardedClick(b, function()
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
            -- Click opens the Use Move editor modal (in builder_ui) via the
            -- editUseMoveRequested signal: move dropdown + manual name + key +
            -- fire method. (Was a cycle-only picker -- no manual entry / key.)
            local res = scanner.cached() or scanner.scan()
            local moveset = res.buttons or {}
            if not p.move and #moveset > 0 then p.move = moveset[1].name end
            local function label()
                local base = "(configure move)"
                if p.move and p.move ~= "" then
                    base = p.move
                    for _, b in ipairs(moveset) do if b.name == p.move then base = (b.text ~= "" and b.text) or b.name; break end end
                end
                if p.key and p.key ~= "" then base = base .. " [" .. tostring(p.key) .. "]" end
                return base
            end
            local b = valBtn(blk, label(), function()
                if blk.canvas and blk.canvas.editUseMoveRequested then blk.canvas.editUseMoveRequested:Fire(blk) end
            end)
            blk._refreshUseMoveLabel = function() b.Text = label() end
        elseif t == "and" then
            -- V2: clicking the param button opens a sub-editor modal where
            -- each branch is its own mini canvas. The block itself stays a
            -- single tile in the main chain (so flow stays linear); the
            -- modal handles the nested complexity.
            local function label()
                local n = #(p.branches or {})
                return string.format("[%d branches] - click to edit", n)
            end
            local b = valBtn(blk, label())
            guardedClick(b, function()
                if blk.canvas and blk.canvas.editBranchesRequested then
                    blk.canvas.editBranchesRequested:Fire(blk)
                end
            end)
            blk._refreshAndLabel = function() b.Text = label() end
        elseif t == "or" then
            -- OR block: forks between branches based on which trigger fired.
            -- Like AND, the block is a single tile on the main chain; the
            -- branches (each = a trigger + its action chain) are edited in
            -- a modal opened from the inline summary button.
            local function label()
                local n = math.max(#(p.triggers or {}), #(p.branches or {}))
                if n == 0 then n = 2 end
                return string.format("[%d-way fork] - click to edit", n)
            end
            local b = valBtn(blk, label())
            guardedClick(b, function()
                if blk.canvas and blk.canvas.editBranchesRequested then
                    blk.canvas.editBranchesRequested:Fire(blk)
                end
            end)
            blk._refreshAndLabel = function() b.Text = label() end
        elseif isHat(t) then
            -- Hat blocks (yellow, top of every chain) carry the trigger
            -- params (key / animId / move / etc.). The inline button is a
            -- one-liner summary that opens a modal for full editing -- the
            -- modal lives in builder_ui (renderHatConfig signal) so it has
            -- access to the scanner + Engine anim history without having
            -- to plumb them into the canvas module.
            local function summarize()
                if t == "event_key" then
                    -- p.key is a KeyCode EnumItem (from the hat modal's KeybindSetter);
                    -- "str " .. EnumItem THROWS in Luau, so normalize to a name string.
                    local kn = p.key and (typeof(p.key) == "EnumItem"
                        and (tostring(p.key):gsub("Enum.KeyCode.", "")) or tostring(p.key))
                    return ((kn and kn ~= "") and ("key: " .. kn) or "(no key set)") ..
                           (p.suppress and " [block]" or "") ..
                           ((p.event or "key") == "keyhold" and " [hold]" or "")
                elseif t == "event_anim" then
                    return p.animId and ("anim " .. tostring(p.animId)) or "(no anim set)"
                elseif t == "event_target_anim" then
                    return p.animId and ("target anim " .. tostring(p.animId)) or "(no anim set)"
                elseif t == "event_move" then
                    -- A move trigger fires off its KEY; the name is optional. Show
                    -- whichever is set so a key-only (scanner-less) config reads as
                    -- configured, not "(no move set)".
                    if p.move and p.move ~= "" then return "move: " .. tostring(p.move) end
                    if p.movekey and p.movekey ~= "" then return "key: " .. tostring(p.movekey) end
                    return "(set move/key)"
                end
                return "configure"
            end
            local b = valBtn(blk, summarize())
            guardedClick(b, function()
                if blk.canvas and blk.canvas.editHatRequested then
                    blk.canvas.editHatRequested:Fire(blk)
                end
            end)
            blk._refreshHatLabel = function() b.Text = summarize() end
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
    self.blockClicked = Signal.new()       -- (block) on click without drag
    self.editBranchesRequested = Signal.new() -- (andBlock) when AND's branch-edit button is clicked
    self.editHatRequested      = Signal.new() -- (hatBlock) when a hat's summary button is clicked
    self.editUseMoveRequested  = Signal.new() -- (useBlock) when a Use Move block's button is clicked
    self._uid = 0
    -- (Global trash zone removed -- per-block trash icons are the delete UX
    -- now; see _renderBlock. Drag-onto-trash was unreliable because the
    -- dragged block visually covered the trash zone and the user's cursor
    -- was offset by their click origin.)
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
            moved = false,
        }
        -- defer detach + ZIndex bump until we know it's a real drag (so a
        -- click-without-move can fire :blockClicked cleanly)
    end)
    moveConn = UIS.InputChanged:Connect(function(input)
        if not dragging or input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
        local mm = UIS:GetMouseLocation()
        local dx = mm.X - dragging.startMouse.X
        local dy = mm.Y - dragging.startMouse.Y
        if not dragging.moved and (dx * dx + dy * dy) > 36 then
            dragging.moved = true
            self:_detach(blk)
            blk.frame.ZIndex = 100
            local cur = blk.next; while cur do cur.frame.ZIndex = 100; cur = cur.next end
        end
        if dragging.moved then
            blk.frame.Position = UDim2.fromOffset(
                dragging.startPos.X.Offset + dx,
                dragging.startPos.Y.Offset + dy
            )
            self:_layoutChain(blk)
        end
    end)
    endConn = UIS.InputEnded:Connect(function(input)
        if not dragging or input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
        local moved = dragging.moved
        dragging = nil
        if not moved then
            self.blockClicked:Fire(blk)
            return
        end
        -- drag finish: try-snap then settle. Brief click-guard window
        -- prevents the MB1Up over a value button (now sitting under the
        -- cursor after the drag) from firing its onClick handler -- that
        -- was blanking the label on key blocks and cycling values on
        -- look/rotate/feature blocks. Delete is now per-block via the
        -- trash icon (top-right corner).
        dragJustEnded = true
        task.delay(0.12, function() dragJustEnded = false end)
        self:_trySnap(blk)
        blk.frame.ZIndex = 2
        local cur = blk.next; while cur do cur.frame.ZIndex = 2; cur = cur.next end
        self:_resizeToContent()
        self:_fireChanged()
    end)
    blk._dragConns = { moveConn, endConn }
end

function Canvas:_destroyBlock(blk)
    -- Re-knit prev and next so a middle-block delete keeps the chain
    -- continuous instead of leaving the tail floating where it was.
    local prev, nxt = blk.prev, blk.next
    if prev and nxt then prev.next = nxt; nxt.prev = prev
    elseif prev then prev.next = nil
    elseif nxt then nxt.prev = nil
    end
    if blk._dragConns then
        for _, c in ipairs(blk._dragConns) do pcall(function() c:Disconnect() end) end
    end
    if blk._keyCaptureConn then pcall(function() blk._keyCaptureConn:Disconnect() end); blk._keyCaptureConn = nil end
    blk.frame:Destroy()
    for i, b in ipairs(self.blocks) do if b == blk then table.remove(self.blocks, i); break end end
    -- Tighten layout: chain prev belonged to gets re-laid so the tail
    -- moves up to fill the gap. Free-floating tail (no prev) stays where
    -- it was -- that's a deliberate gap the user can re-snap if desired.
    if prev then self:_layoutChain(chainHead(prev)) end
    self:_resizeToContent()
    self:_fireChanged()
end

-- Explicit teardown: clear all blocks (disconnects drag conns) and destroy
-- the canvas frame. Use from Builder.open/close + the AND branch sub-modal
-- so re-opens don't leak per-block UIS.InputChanged/InputEnded connections.
function Canvas:destroy()
    self:clear()
    if self.frame then pcall(function() self.frame:Destroy() end); self.frame = nil end
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
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    -- Pin label above the rest of the block's children (the val Frame and
    -- the trash icon both render in the same parent; sibling ZIndex ties
    -- can occasionally hide a label in screenshots -- defensive bump).
    lbl.ZIndex = 5
    lbl.Parent = f
    blk.lbl = lbl

    -- bottom tab decoration (visual connector cue)
    local tab = Instance.new("Frame")
    tab.Size = UDim2.fromOffset(TAB_W, 3); tab.Position = UDim2.new(0, TAB_INSET_X, 1, 0)
    tab.BackgroundColor3 = colorOf(blk.type); tab.BorderSizePixel = 0; tab.Parent = f

    -- Per-block trash icon (top-right corner of every block). The global
    -- drag-to-trash zone was removed -- this is the only delete affordance
    -- now and we make it readable: bigger, with a clearer label, higher
    -- ZIndex so it always lands above the inline value button on its left.
    local del = Instance.new("TextButton")
    del.Size = UDim2.fromOffset(22, 22); del.Position = UDim2.new(1, -26, 0, 4)
    del.BackgroundColor3 = theme.danger; del.AutoButtonColor = true
    del.TextColor3 = theme.fg; del.Font = theme.fontBold; del.TextSize = 13
    del.Text = "X"; del.ZIndex = 10
    del.Parent = f; corner(del, 4)
    guardedClick(del, function() self:_destroyBlock(blk) end)

    renderParams(blk)
end

function Canvas:addBlock(blockType, params, x, y)
    local f = Instance.new("Frame")
    f.Size = UDim2.fromOffset(BLOCK_W, BLOCK_H)
    -- Explicitly pin AutomaticSize off so no parent layout / inherited size
    -- mode can shrink the block to 0 height (which was the most plausible
    -- explanation for the "thin sliver" rendering in the user's screenshot).
    f.AutomaticSize = Enum.AutomaticSize.None
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
        if b._keyCaptureConn then pcall(function() b._keyCaptureConn:Disconnect() end); b._keyCaptureConn = nil end
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
