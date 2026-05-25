-- Tech Builder editor window (opened by "Open Tech Builder").
--
-- A separate draggable window for CREATING / EDITING techs: name, scope, trigger
-- (event + key/move + conditions) and an ordered list of action steps. Save ->
-- engine.saveCustom (persists + adds live). This is the form editor; the avatar
-- + dummy viewport with the timeline replay is a later stage and gets added to
-- this same window.
--
-- Built techs persist via [[modules.tech.engine]].saveCustom, so they survive
-- reloads (the engine rehydrates them with loadCustom at boot).

local env        = require("core.env")
local theme      = require("ui.theme")
local components = require("ui.components")
local engine     = require("modules.tech.engine")
local feature    = require("ui.feature")
local persist    = require("core.persist")

local UIS = game:GetService("UserInputService")
local RS  = game:GetService("ReplicatedStorage")

local Builder = {}

local gui, rootFrame, formScroll
local draft

local EVENTS = {
    { id = "key",     label = "Key press" },
    { id = "keyhold", label = "Key hold"  },
    { id = "move",    label = "Move used"  },
}
local CONDITIONS = {
    { id = "locked_on", label = "Locked on"    },
    { id = "shiftlock", label = "Shiftlock on" },
}
local ACTION_TYPES = { "look", "rotate", "wait", "return", "feature" }
local ACTION_LABEL = {
    look = "Look (camera)", rotate = "Rotate (body)", wait = "Wait",
    ["return"] = "Return", feature = "Use feature",
}

-- move services usable as triggers = those with an RE.Effects broadcast.
local function moveOptions()
    local out = {}
    local knit     = RS:FindFirstChild("Knit")
    local inner    = knit and knit:FindFirstChild("Knit")
    local services = inner and inner:FindFirstChild("Services")
    if services then
        for _, c in ipairs(services:GetChildren()) do
            local re = c:FindFirstChild("RE")
            if re and re:FindFirstChild("Effects") then out[#out + 1] = c.Name end
        end
        table.sort(out)
    end
    return out
end

local function featureOptions()
    local out = feature.all()
    table.sort(out, function(a, b) return (a.name or a.id) < (b.name or b.id) end)
    return out
end

-- ---- small UI helpers ----
-- Wrap a component (which returns an api, not its frame) in a LayoutOrder-able
-- host of the right height so the form's UIListLayout orders it correctly.
local function wrap(height, fn)
    local w = Instance.new("Frame")
    w.Size = UDim2.new(1, 0, 0, height)
    w.BackgroundTransparency = 1
    fn(w)
    return w
end

local function cycleRow(parent, labelText, options, currentIndex, onPick)
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, 0, 0, 28)
    f.BackgroundColor3 = theme.bgAlt
    f.BorderSizePixel = 0
    f.Parent = parent

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(0.4, -8, 1, 0)
    lbl.Position = UDim2.fromOffset(8, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = labelText
    lbl.TextColor3 = theme.fgDim
    lbl.Font = theme.font
    lbl.TextSize = 12
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = f

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0.6, -12, 0, 20)
    btn.Position = UDim2.new(0.4, 4, 0.5, -10)
    btn.BackgroundColor3 = theme.bgDark
    btn.AutoButtonColor = false
    btn.TextColor3 = theme.fg
    btn.Font = theme.font
    btn.TextSize = 12
    btn.TextTruncate = Enum.TextTruncate.AtEnd
    btn.Text = options[currentIndex] or "<none>"
    btn.Parent = f

    btn.MouseButton1Click:Connect(function()
        if #options == 0 then return end
        currentIndex = (currentIndex % #options) + 1
        btn.Text = options[currentIndex]
        onPick(currentIndex)
    end)
    return f
end

local function textRow(parent, labelText, value, onCommit)
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, 0, 0, 28)
    f.BackgroundColor3 = theme.bgAlt
    f.BorderSizePixel = 0
    f.Parent = parent

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(0.4, -8, 1, 0)
    lbl.Position = UDim2.fromOffset(8, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = labelText
    lbl.TextColor3 = theme.fgDim
    lbl.Font = theme.font
    lbl.TextSize = 12
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = f

    local box = Instance.new("TextBox")
    box.Size = UDim2.new(0.6, -12, 0, 20)
    box.Position = UDim2.new(0.4, 4, 0.5, -10)
    box.BackgroundColor3 = theme.bgDark
    box.TextColor3 = theme.fg
    box.Font = theme.font
    box.TextSize = 12
    box.Text = value or ""
    box.ClearTextOnFocus = false
    box.PlaceholderText = "name..."
    box.Parent = f

    box.FocusLost:Connect(function() onCommit(box.Text) end)
    return f
end

local function smallBtn(parent, txt, posX, color)
    local b = Instance.new("TextButton")
    b.Size = UDim2.fromOffset(20, 22)
    b.Position = UDim2.new(1, posX, 0, 0)
    b.BackgroundColor3 = color or theme.bgAlt
    b.AutoButtonColor = false
    b.TextColor3 = theme.fg
    b.Font = theme.fontBold
    b.TextSize = 11
    b.Text = txt
    b.Parent = parent
    return b
end

-- ---- draft <-> tech ----
local function newDraft()
    return {
        name = "New Tech", scope = "game", event = "key",
        key = Enum.KeyCode.Unknown, move = nil, conditions = {}, actions = {},
    }
end

local function draftFromTech(t)
    local conds = {}
    for _, c in ipairs(t.trigger.conditions or {}) do conds[c] = true end
    local actions = {}
    for _, a in ipairs(t.actions or {}) do
        actions[#actions + 1] = { type = a.type, x = a.x, y = a.y, seconds = a.seconds, feature = a.feature }
    end
    return {
        editId = t.id,
        name = t.name,
        scope = (t.scope == "universal") and "universal" or "game",
        event = t.trigger.event, key = t.trigger.key, move = t.trigger.move,
        conditions = conds, actions = actions,
    }
end

local function onSave()
    local name = (draft.name and #draft.name > 0) and draft.name or "Tech"

    local id = draft.editId
    if not id then
        local base = "custom." .. persist.slug(name)
        id = base
        local n = 2
        while engine.get(id) do id = base .. "_" .. n; n = n + 1 end
    end

    local conds = {}
    for _, c in ipairs(CONDITIONS) do if draft.conditions[c.id] then conds[#conds + 1] = c.id end end

    local actions = {}
    for _, a in ipairs(draft.actions) do
        if a.type == "look" then
            actions[#actions + 1] = { type = "look", x = a.x or 0, y = a.y or 0 }
        elseif a.type == "rotate" then
            actions[#actions + 1] = { type = "rotate", x = a.x or 0, y = a.y or 0 }
        elseif a.type == "wait" then
            actions[#actions + 1] = { type = "wait", seconds = a.seconds or 0.5 }
        elseif a.type == "return" then
            actions[#actions + 1] = { type = "return" }
        elseif a.type == "feature" then
            actions[#actions + 1] = { type = "feature", feature = a.feature }
        end
    end

    engine.saveCustom({
        id = id, name = name, custom = true,
        scope = (draft.scope == "universal") and "universal" or game.GameId,
        enabled = true,
        trigger = { event = draft.event, key = draft.key, move = draft.move, conditions = conds },
        actions = actions,
    })
    Builder.close()
end

-- ---- form (mutually recursive: rebuild builds rows; rows call rebuild) ----
local rebuild

local function buildActionRow(parent, i, act)
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, 0, 0, 0)
    f.AutomaticSize = Enum.AutomaticSize.Y
    f.BackgroundColor3 = theme.bgDark
    f.BorderSizePixel = 0
    f.Parent = parent

    local pad = Instance.new("UIPadding", f)
    pad.PaddingTop = UDim.new(0, 4); pad.PaddingBottom = UDim.new(0, 4)
    pad.PaddingLeft = UDim.new(0, 4); pad.PaddingRight = UDim.new(0, 4)
    local list = Instance.new("UIListLayout", f)
    list.SortOrder = Enum.SortOrder.LayoutOrder
    list.Padding = UDim.new(0, 3)

    local head = Instance.new("Frame")
    head.Size = UDim2.new(1, 0, 0, 22)
    head.BackgroundTransparency = 1
    head.LayoutOrder = 1
    head.Parent = f

    local typeBtn = Instance.new("TextButton")
    typeBtn.Size = UDim2.new(1, -80, 1, 0)
    typeBtn.BackgroundColor3 = theme.bgAlt
    typeBtn.AutoButtonColor = false
    typeBtn.TextColor3 = theme.fg
    typeBtn.Font = theme.font
    typeBtn.TextSize = 12
    typeBtn.TextXAlignment = Enum.TextXAlignment.Left
    typeBtn.Text = "  " .. i .. ". " .. (ACTION_LABEL[act.type] or act.type)
    typeBtn.Parent = head
    local ti = 1
    for k, t in ipairs(ACTION_TYPES) do if t == act.type then ti = k end end
    typeBtn.MouseButton1Click:Connect(function()
        ti = (ti % #ACTION_TYPES) + 1
        act.type = ACTION_TYPES[ti]
        rebuild()
    end)

    local up = smallBtn(head, "^", -76)
    up.MouseButton1Click:Connect(function()
        if i > 1 then
            draft.actions[i], draft.actions[i - 1] = draft.actions[i - 1], draft.actions[i]
            rebuild()
        end
    end)
    local down = smallBtn(head, "v", -52)
    down.MouseButton1Click:Connect(function()
        if i < #draft.actions then
            draft.actions[i], draft.actions[i + 1] = draft.actions[i + 1], draft.actions[i]
            rebuild()
        end
    end)
    local rem = smallBtn(head, "X", -24, theme.danger)
    rem.MouseButton1Click:Connect(function()
        table.remove(draft.actions, i)
        rebuild()
    end)

    local pord = 1
    local function pplace(inst) pord = pord + 1; inst.LayoutOrder = pord; inst.Parent = f end

    if act.type == "look" then
        pplace(wrap(42, function(p) components.Slider(p, { text = "Yaw", min = -180, max = 180, step = 5, default = act.x or 0, onChange = function(v) act.x = v end }) end))
        pplace(wrap(42, function(p) components.Slider(p, { text = "Pitch", min = -80, max = 80, step = 5, default = act.y or 0, onChange = function(v) act.y = v end }) end))
    elseif act.type == "rotate" then
        pplace(wrap(42, function(p) components.Slider(p, { text = "Yaw", min = -180, max = 180, step = 5, default = act.x or 0, onChange = function(v) act.x = v end }) end))
    elseif act.type == "wait" then
        pplace(wrap(42, function(p) components.Slider(p, { text = "Seconds", min = 0, max = 5, step = 0.1, default = act.seconds or 0.5, onChange = function(v) act.seconds = v end }) end))
    elseif act.type == "feature" then
        local feats = featureOptions()
        local labels = {}
        for _, ft in ipairs(feats) do labels[#labels + 1] = ft.name end
        local fi = 1
        for k, ft in ipairs(feats) do if ft.id == act.feature then fi = k end end
        if not act.feature and feats[1] then act.feature = feats[1].id end
        pplace(cycleRow(f, "Feature", labels, fi, function(idx) act.feature = feats[idx].id end))
    end
    -- "return" has no params

    return f
end

rebuild = function()
    for _, c in ipairs(formScroll:GetChildren()) do
        if not c:IsA("UIListLayout") then c:Destroy() end
    end

    local ord = 0
    local function place(inst) ord = ord + 1; inst.LayoutOrder = ord; return inst end

    place(textRow(formScroll, "Name", draft.name, function(t) draft.name = t end))

    do
        local scopeOpts = { "This Game", "Universal" }
        local idx = (draft.scope == "universal") and 2 or 1
        place(cycleRow(formScroll, "Scope", scopeOpts, idx, function(i) draft.scope = (i == 2) and "universal" or "game" end))
    end

    place(components.Section(formScroll, "Trigger"))
    do
        local labels = {}
        for _, e in ipairs(EVENTS) do labels[#labels + 1] = e.label end
        local idx = 1
        for i, e in ipairs(EVENTS) do if e.id == draft.event then idx = i end end
        place(cycleRow(formScroll, "Event", labels, idx, function(i) draft.event = EVENTS[i].id; rebuild() end))
    end

    if draft.event == "move" then
        local opts = moveOptions()
        if #opts == 0 then
            place(components.Label(formScroll, "No move services found (are you in a Knit game?)"))
        else
            if not draft.move then draft.move = opts[1] end
            local idx = 1
            for i, n in ipairs(opts) do if n == draft.move then idx = i end end
            place(cycleRow(formScroll, "Move", opts, idx, function(i) draft.move = opts[i] end))
        end
    else
        place(wrap(28, function(p)
            components.KeybindSetter(p, { label = "Key", default = draft.key, onChange = function(k) draft.key = k end })
        end))
    end

    place(components.Section(formScroll, "Conditions (all must be true)"))
    for _, cond in ipairs(CONDITIONS) do
        place(wrap(30, function(p)
            components.Toggle(p, { text = cond.label, default = draft.conditions[cond.id] == true,
                onChange = function(v) draft.conditions[cond.id] = v or nil end })
        end))
    end

    place(components.Section(formScroll, "Actions (in order)"))
    for i, act in ipairs(draft.actions) do
        place(buildActionRow(formScroll, i, act))
    end
    place(components.Button(formScroll, { text = "+ Add Step", onClick = function()
        draft.actions[#draft.actions + 1] = { type = "look", x = 180, y = 0, seconds = 0.5 }
        rebuild()
    end }))

    do
        local bf = Instance.new("Frame")
        bf.Size = UDim2.new(1, 0, 0, 34)
        bf.BackgroundTransparency = 1
        local bl = Instance.new("UIListLayout", bf)
        bl.FillDirection = Enum.FillDirection.Horizontal
        bl.HorizontalAlignment = Enum.HorizontalAlignment.Right
        bl.VerticalAlignment = Enum.VerticalAlignment.Center
        bl.Padding = UDim.new(0, 8)

        local cancel = Instance.new("TextButton")
        cancel.Size = UDim2.fromOffset(90, 26); cancel.BackgroundColor3 = theme.bgAlt
        cancel.AutoButtonColor = false; cancel.TextColor3 = theme.fg; cancel.Font = theme.font
        cancel.TextSize = 12; cancel.Text = "Cancel"; cancel.LayoutOrder = 1; cancel.Parent = bf
        cancel.MouseButton1Click:Connect(function() Builder.close() end)

        local save = Instance.new("TextButton")
        save.Size = UDim2.fromOffset(90, 26); save.BackgroundColor3 = theme.accent
        save.AutoButtonColor = false; save.TextColor3 = theme.fg; save.Font = theme.fontBold
        save.TextSize = 12; save.Text = "Save Tech"; save.LayoutOrder = 2; save.Parent = bf
        save.MouseButton1Click:Connect(onSave)

        place(bf)
    end
end

local function ensureGui()
    if gui and gui.Parent then return end
    gui = Instance.new("ScreenGui")
    gui.Name = "_" .. math.random(100000, 999999)
    gui.ResetOnSpawn = false
    gui.Parent = env.guiParent()
    if env.protectGui then env.protectGui(gui) end

    rootFrame = Instance.new("Frame")
    rootFrame.Size = UDim2.fromOffset(380, 470)
    rootFrame.Position = UDim2.new(0.5, -190, 0.5, -235)
    rootFrame.BackgroundColor3 = theme.bg
    rootFrame.BorderSizePixel = 0
    rootFrame.Visible = false
    rootFrame.Parent = gui

    local header = Instance.new("Frame")
    header.Size = UDim2.new(1, 0, 0, 30)
    header.BackgroundColor3 = theme.accent
    header.BorderSizePixel = 0
    header.Parent = rootFrame

    local dragBtn = Instance.new("TextButton")
    dragBtn.Size = UDim2.fromScale(1, 1)
    dragBtn.BackgroundTransparency = 1
    dragBtn.Text = ""
    dragBtn.AutoButtonColor = false
    dragBtn.ZIndex = 2
    dragBtn.Parent = header

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -40, 1, 0)
    title.Position = UDim2.fromOffset(10, 0)
    title.BackgroundTransparency = 1
    title.Text = "Tech Builder"
    title.TextColor3 = theme.fg
    title.Font = theme.fontBold
    title.TextSize = 13
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.ZIndex = 3
    title.Parent = header

    local close = Instance.new("TextButton")
    close.Size = UDim2.fromOffset(26, 22)
    close.Position = UDim2.new(1, -30, 0.5, -11)
    close.BackgroundColor3 = theme.danger
    close.AutoButtonColor = false
    close.Text = "X"
    close.TextColor3 = theme.fg
    close.Font = theme.fontBold
    close.TextSize = 12
    close.ZIndex = 4
    close.Parent = header
    close.MouseButton1Click:Connect(function() Builder.close() end)

    do
        local dragging, dragStart, startPos = false, nil, nil
        dragBtn.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
               or input.UserInputType == Enum.UserInputType.Touch then
                dragging, dragStart, startPos = true, input.Position, rootFrame.Position
            end
        end)
        UIS.InputChanged:Connect(function(input)
            if not dragging then return end
            if input.UserInputType == Enum.UserInputType.MouseMovement
               or input.UserInputType == Enum.UserInputType.Touch then
                local d = input.Position - dragStart
                rootFrame.Position = UDim2.new(
                    startPos.X.Scale, startPos.X.Offset + d.X,
                    startPos.Y.Scale, startPos.Y.Offset + d.Y)
            end
        end)
        UIS.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
               or input.UserInputType == Enum.UserInputType.Touch then
                dragging = false
            end
        end)
    end

    formScroll = Instance.new("ScrollingFrame")
    formScroll.Size = UDim2.new(1, -12, 1, -76)
    formScroll.Position = UDim2.fromOffset(6, 36)
    formScroll.BackgroundTransparency = 1
    formScroll.BorderSizePixel = 0
    formScroll.ScrollBarThickness = 4
    formScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    formScroll.AutomaticCanvasSize = Enum.AutomaticCanvasSize.Y
    formScroll.Parent = rootFrame
    local fl = Instance.new("UIListLayout", formScroll)
    fl.SortOrder = Enum.SortOrder.LayoutOrder
    fl.Padding = UDim.new(0, 3)

    local note = Instance.new("TextLabel")
    note.Size = UDim2.new(1, -12, 0, 30)
    note.Position = UDim2.new(0, 6, 1, -34)
    note.BackgroundTransparency = 1
    note.Text = "Avatar + dummy viewport & timeline replay coming soon"
    note.TextColor3 = theme.fgDim
    note.Font = theme.font
    note.TextSize = 10
    note.TextWrapped = true
    note.Parent = rootFrame
end

function Builder.open(existingTech)
    ensureGui()
    draft = existingTech and draftFromTech(existingTech) or newDraft()
    rebuild()
    rootFrame.Visible = true
end

function Builder.close()
    if rootFrame then rootFrame.Visible = false end
end

function Builder.destroy()
    if gui then pcall(function() gui:Destroy() end); gui = nil end
end

return Builder
