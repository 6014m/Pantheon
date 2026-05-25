-- Tech Builder editor window -- JJS-skill-builder style, two panes:
--   LEFT  = the tech form (name, trigger, conditions, step palette + chips).
--   RIGHT = a ViewportFrame preview on a CLONE of your avatar, so "Play" runs the
--           tech (look/rotate/wait/return reenactment) INSIDE the window instead
--           of on your real character. Rig-clone/viewport approach is ported from
--           the [Uni] Animation Logger.
--
-- Built techs persist via [[modules.tech.engine]].saveCustom.

local env        = require("core.env")
local theme      = require("ui.theme")
local components = require("ui.components")
local engine     = require("modules.tech.engine")
local scanner    = require("modules.tech.scanner")
local feature    = require("ui.feature")
local persist    = require("core.persist")
local notify     = require("ui.notify")

local UIS        = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Players    = game:GetService("Players")

local Builder = {}

local gui, rootFrame, formScroll
local draft

local CONDITIONS = {
    { id = "locked_on", label = "Locked on"    },
    { id = "shiftlock", label = "Shiftlock on" },
}
-- palette buttons (Release is added automatically with Hold, not its own button)
local ACTION_TYPES = { "look", "rotate", "during", "wait", "within", "return", "feature", "key", "hold", "usebtn" }
local STEP_LABEL   = { look = "Look", rotate = "Rotate", wait = "Wait", during = "During",
                       within = "Within", ["return"] = "Return", feature = "Use", key = "Press",
                       hold = "Hold", release = "Release", usebtn = "Use Move" }
local YAW_PRESETS  = { 180, 135, 90, 45, 0, -45, -90, -135, -180 }

-- ---------- small helpers ----------
local function corner(o, r) local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r or 6); c.Parent = o; return c end
local function stroke(o, col) local s = Instance.new("UIStroke"); s.Color = col or theme.border; s.Thickness = 1; s.Parent = o; return s end

local function wrap(height, fn)
    local w = Instance.new("Frame")
    w.Size = UDim2.new(1, 0, 0, height); w.BackgroundTransparency = 1
    fn(w); return w
end

local function cycleRow(parent, labelText, options, currentIndex, onPick)
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, 0, 0, 28); f.BackgroundColor3 = theme.bgAlt; f.BorderSizePixel = 0; f.Parent = parent
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(0.4, -8, 1, 0); lbl.Position = UDim2.fromOffset(8, 0); lbl.BackgroundTransparency = 1
    lbl.Text = labelText; lbl.TextColor3 = theme.fgDim; lbl.Font = theme.font; lbl.TextSize = 12
    lbl.TextXAlignment = Enum.TextXAlignment.Left; lbl.Parent = f
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0.6, -12, 0, 20); btn.Position = UDim2.new(0.4, 4, 0.5, -10); btn.BackgroundColor3 = theme.bgDark
    btn.AutoButtonColor = false; btn.TextColor3 = theme.fg; btn.Font = theme.font; btn.TextSize = 12
    btn.TextTruncate = Enum.TextTruncate.AtEnd; btn.Text = options[currentIndex] or "<none>"; btn.Parent = f
    btn.MouseButton1Click:Connect(function()
        if #options == 0 then return end
        currentIndex = (currentIndex % #options) + 1
        btn.Text = options[currentIndex]; onPick(currentIndex)
    end)
    return f
end

local function textRow(parent, labelText, value, onCommit)
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, 0, 0, 28); f.BackgroundColor3 = theme.bgAlt; f.BorderSizePixel = 0; f.Parent = parent
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(0.4, -8, 1, 0); lbl.Position = UDim2.fromOffset(8, 0); lbl.BackgroundTransparency = 1
    lbl.Text = labelText; lbl.TextColor3 = theme.fgDim; lbl.Font = theme.font; lbl.TextSize = 12
    lbl.TextXAlignment = Enum.TextXAlignment.Left; lbl.Parent = f
    local box = Instance.new("TextBox")
    box.Size = UDim2.new(0.6, -12, 0, 20); box.Position = UDim2.new(0.4, 4, 0.5, -10); box.BackgroundColor3 = theme.bgDark
    box.TextColor3 = theme.fg; box.Font = theme.font; box.TextSize = 12; box.Text = value or ""; box.ClearTextOnFocus = false
    box.PlaceholderText = "..."; box.Parent = f
    box.FocusLost:Connect(function() onCommit(box.Text) end)
    return f
end

local function smallBtn(parent, txt, posX, color)
    local b = Instance.new("TextButton")
    b.Size = UDim2.fromOffset(20, 22); b.Position = UDim2.new(1, posX, 0.5, -11); b.BackgroundColor3 = color or theme.bgAlt
    b.AutoButtonColor = false; b.TextColor3 = theme.fg; b.Font = theme.fontBold; b.TextSize = 11; b.Text = txt; b.Parent = parent
    return b
end

local function featName(id)
    if not id then return "(pick)" end
    for _, ft in ipairs(feature.all()) do if ft.id == id then return ft.name end end
    return id
end
local function nextPreset(list, cur)
    for i, v in ipairs(list) do if math.abs(v - (cur or 0)) < 1e-3 then return list[(i % #list) + 1] end end
    return list[1]
end

-- ---------- draft <-> tech ----------
local function newDraft()
    return { name = "New Tech", scope = "game", event = "key",
             key = Enum.KeyCode.Unknown, move = nil, conditions = {}, actions = {} }
end
local function draftFromTech(t)
    local conds = {}
    for _, c in ipairs(t.trigger.conditions or {}) do conds[c] = true end
    local actions = {}
    for _, a in ipairs(t.actions or {}) do
        actions[#actions + 1] = { type = a.type, x = a.x, y = a.y, seconds = a.seconds,
            studs = a.studs, feature = a.feature, key = a.key, holdId = a.holdId, move = a.move }
    end
    return {
        editId = t.id, name = t.name,
        scope = (t.scope == "universal") and "universal" or "game",
        event = t.trigger.event, key = t.trigger.key, move = t.trigger.move, movekey = t.trigger.movekey,
        modkey = t.trigger.modkey, maxRange = t.trigger.maxRange,
        animId = t.trigger.animId, suppress = t.trigger.suppress,
        conditions = conds, actions = actions,
    }
end
local function draftConditions()
    local conds = {}
    for _, c in ipairs(CONDITIONS) do if draft.conditions[c.id] then conds[#conds + 1] = c.id end end
    return conds
end
local function draftActions()
    local actions = {}
    for _, a in ipairs(draft.actions) do
        if a.type == "look" then actions[#actions + 1] = { type = "look", x = a.x or 0, y = a.y or 0 }
        elseif a.type == "rotate" then actions[#actions + 1] = { type = "rotate", x = a.x or 0, y = a.y or 0 }
        elseif a.type == "wait" then actions[#actions + 1] = { type = "wait", seconds = a.seconds or 0.5 }
        elseif a.type == "within" then actions[#actions + 1] = { type = "within", studs = a.studs or 5 }
        elseif a.type == "during" then actions[#actions + 1] = { type = "during" }
        elseif a.type == "return" then actions[#actions + 1] = { type = "return" }
        elseif a.type == "feature" then actions[#actions + 1] = { type = "feature", feature = a.feature }
        elseif a.type == "key" then actions[#actions + 1] = { type = "key", key = a.key }
        elseif a.type == "hold" then actions[#actions + 1] = { type = "hold", key = a.key, holdId = a.holdId }
        elseif a.type == "release" then actions[#actions + 1] = { type = "release", key = a.key, holdId = a.holdId }
        elseif a.type == "usebtn" then actions[#actions + 1] = { type = "usebtn", move = a.move }
        end
    end
    return actions
end
local function buildTechFromDraft(id)
    return {
        id = id, name = (draft.name and #draft.name > 0) and draft.name or "Tech", custom = true,
        scope = (draft.scope == "universal") and "universal" or game.GameId, enabled = true,
        trigger = { event = draft.event, key = draft.key, move = draft.move, movekey = draft.movekey,
                    modkey = draft.modkey, maxRange = draft.maxRange,
                    animId = draft.animId, suppress = draft.suppress, conditions = draftConditions() },
        actions = draftActions(),
    }
end
local function onSave()
    local name = (draft.name and #draft.name > 0) and draft.name or "Tech"
    local id = draft.editId
    if not id then
        local base = "custom." .. persist.slug(name); id = base
        local n = 2
        while engine.get(id) do id = base .. "_" .. n; n = n + 1 end
    end
    local tech = buildTechFromDraft(id)
    engine.saveCustom(tech)
    notify.success("Tech saved: " .. tech.name)
    Builder.close()
end

-- ---------- viewport preview (clone rig, ported from Animation Logger) ----------
local vpFrame, worldModel, vpCam, rigTemplate, curRig
local camTarget, camDist = Vector3.new(0, 2.5, 0), 12
local curYaw, previewing = 0, false

local function captureRig()
    local char = Players.LocalPlayer.Character
    if not char then return end
    local ok, clone = pcall(function()
        local was = char.Archivable; char.Archivable = true
        local c = char:Clone(); char.Archivable = was; return c
    end)
    if not ok or not clone then return end
    for _, d in ipairs(clone:GetDescendants()) do
        if d:IsA("LuaSourceContainer") or d:IsA("Tool") or d:IsA("Sound") or d:IsA("BodyMover") then
            pcall(function() d:Destroy() end)
        end
    end
    if rigTemplate then rigTemplate:Destroy() end
    rigTemplate = clone
end

local function rigSetYaw(yaw)
    curYaw = yaw
    if curRig and curRig.PrimaryPart then pcall(function() curRig:PivotTo(CFrame.Angles(0, math.rad(yaw), 0)) end) end
end

local function buildRigPreview()
    if curRig then curRig:Destroy(); curRig = nil end
    if not rigTemplate then captureRig() end
    if not (rigTemplate and worldModel) then return end
    local rig = rigTemplate:Clone()
    local hum = rig:FindFirstChildOfClass("Humanoid")
    local hrp = rig:FindFirstChild("HumanoidRootPart") or rig.PrimaryPart
    if hum then pcall(function() hum.EvaluateStateMachine = false end) end
    rig.Parent = worldModel
    curRig = rig
    if hrp then rig.PrimaryPart = hrp; rig:PivotTo(CFrame.new(0, 0, 0)); hrp.Anchored = true end
    local cf, size = rig:GetBoundingBox()
    camTarget = cf.Position
    camDist = math.max(size.X, size.Y, size.Z) * 1.7 + 2
    -- fixed front-ish camera so the body's turn is readable
    if vpCam then vpCam.CFrame = CFrame.lookAt(camTarget + Vector3.new(0, camDist * 0.12, camDist), camTarget) end
    curYaw = 0
end

local function tweenYaw(target, dur)
    dur = dur or 0.15
    local start, t0 = curYaw, os.clock()
    while os.clock() - t0 < dur do
        rigSetYaw(start + (target - start) * ((os.clock() - t0) / dur)); task.wait()
    end
    rigSetYaw(target)
end

-- play the tech's look/rotate/wait/return as a body-turn reenactment on the clone
local function previewDraft()
    if previewing then return end
    buildRigPreview()
    if not curRig then notify.warn("Preview: couldn't clone your avatar"); return end
    previewing = true
    task.spawn(function()
        rigSetYaw(0)
        local releaseAfter = false
        for _, a in ipairs(draft.actions or {}) do
            if a.type == "look" or a.type == "rotate" then
                tweenYaw(a.x or 0)
            elseif a.type == "wait" then
                task.wait(a.seconds or 0.5)
                if releaseAfter then tweenYaw(0); releaseAfter = false end
            elseif a.type == "during" then
                releaseAfter = true
            elseif a.type == "within" then
                task.wait(0.3)   -- can't gauge range in the preview; brief beat
                if releaseAfter then tweenYaw(0); releaseAfter = false end
            elseif a.type == "return" then
                tweenYaw(0)
            end
        end
        tweenYaw(0)
        previewing = false
    end)
end

-- ---------- step chip ----------
local rebuild
local function buildChip(parent, i, act)
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, 0, 0, 30); f.BackgroundColor3 = theme.bgAlt; f.BorderSizePixel = 0; f.Parent = parent
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(0, 70, 1, 0); lbl.Position = UDim2.fromOffset(8, 0); lbl.BackgroundTransparency = 1
    lbl.Text = i .. ".  " .. (STEP_LABEL[act.type] or act.type)
    lbl.TextColor3 = theme.fg; lbl.Font = theme.fontBold; lbl.TextSize = 12
    lbl.TextXAlignment = Enum.TextXAlignment.Left; lbl.Parent = f

    local val
    if act.type == "wait" then
        val = Instance.new("TextBox"); val.ClearTextOnFocus = false; val.PlaceholderText = "seconds"
        val.Text = tostring(act.seconds or 0.5)
        val.FocusLost:Connect(function()
            local n = tonumber((val.Text:gsub("[^%d%.]", "")))
            if n then act.seconds = math.clamp(n, 0, 60) end
            val.Text = tostring(act.seconds or 0.5)
        end)
    elseif act.type == "within" then
        -- wait here until the target is within this many studs, then continue
        val = Instance.new("TextBox"); val.ClearTextOnFocus = false; val.PlaceholderText = "studs"
        val.Text = tostring(act.studs or 5)
        val.FocusLost:Connect(function()
            local n = tonumber((val.Text:gsub("[^%d%.]", "")))
            if n then act.studs = math.clamp(n, 0, 500) end
            val.Text = tostring(act.studs or 5)
        end)
    elseif act.type == "key" or act.type == "hold" or act.type == "release" then
        val = Instance.new("TextButton"); val.AutoButtonColor = false
        val.Text = act.key and ("key: " .. act.key) or "(click, press a key)"
        val.MouseButton1Click:Connect(function()
            val.Text = "press a key..."
            local conn
            conn = UIS.InputBegan:Connect(function(input)
                if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
                if input.KeyCode == Enum.KeyCode.Unknown then return end
                if input.KeyCode ~= Enum.KeyCode.Escape then
                    local kn = (tostring(input.KeyCode):gsub("Enum.KeyCode.", ""))
                    act.key = kn
                    -- Hold + Release share one key, so set both halves of the pair
                    if act.holdId then
                        for _, o in ipairs(draft.actions) do if o.holdId == act.holdId then o.key = kn end end
                    end
                end
                val.Text = act.key and ("key: " .. act.key) or "(click, press a key)"
                conn:Disconnect()
            end)
        end)
    elseif act.type == "usebtn" then
        -- pick which hotbar move's GUI button this step fires (from the live scan)
        local res = scanner.cached() or scanner.scan()
        local moveset = res.buttons or {}
        if act.move == nil and #moveset > 0 then act.move = moveset[1].name end
        val = Instance.new("TextButton"); val.AutoButtonColor = false
        local function moveLabel()
            if #moveset == 0 then return "(no moves - Dump GUI)" end
            for _, b in ipairs(moveset) do
                if b.name == act.move then return (b.text ~= "" and b.text) or b.name end
            end
            return "(pick move)"
        end
        val.Text = moveLabel()
        val.MouseButton1Click:Connect(function()
            if #moveset == 0 then return end
            local idx = 0
            for k, b in ipairs(moveset) do if b.name == act.move then idx = k end end
            act.move = moveset[(idx % #moveset) + 1].name
            val.Text = moveLabel()
        end)
    else
        val = Instance.new("TextButton"); val.AutoButtonColor = false
        local function valText()
            if act.type == "look" or act.type == "rotate" then return tostring(act.x or 0) .. "\u{00B0}"
            elseif act.type == "feature" then return featName(act.feature)
            elseif act.type == "during" then return "holds prev step for next wait"
            else return "re-face target" end
        end
        val.Text = valText()
        if act.type ~= "return" and act.type ~= "during" then
            val.MouseButton1Click:Connect(function()
                if act.type == "look" or act.type == "rotate" then
                    act.x = nextPreset(YAW_PRESETS, act.x)
                elseif act.type == "feature" then
                    local feats = feature.all()
                    table.sort(feats, function(a, b) return (a.name or a.id) < (b.name or b.id) end)
                    if #feats > 0 then
                        local idx = 0
                        for k, ft in ipairs(feats) do if ft.id == act.feature then idx = k end end
                        act.feature = feats[(idx % #feats) + 1].id
                    end
                end
                val.Text = valText()
            end)
        end
    end
    val.Size = UDim2.new(1, -154, 1, -8); val.Position = UDim2.new(0, 84, 0, 4)
    val.BackgroundColor3 = theme.bgDark
    val.TextColor3 = (act.type == "return" or act.type == "during") and theme.fgDim or theme.fg
    val.Font = theme.font; val.TextSize = 12; val.Parent = f

    local up = smallBtn(f, "^", -70)
    up.MouseButton1Click:Connect(function()
        if i > 1 then draft.actions[i], draft.actions[i-1] = draft.actions[i-1], draft.actions[i]; rebuild() end
    end)
    local down = smallBtn(f, "v", -46)
    down.MouseButton1Click:Connect(function()
        if i < #draft.actions then draft.actions[i], draft.actions[i+1] = draft.actions[i+1], draft.actions[i]; rebuild() end
    end)
    local rem = smallBtn(f, "X", -22, theme.danger)
    rem.MouseButton1Click:Connect(function() table.remove(draft.actions, i); rebuild() end)
    return f
end

-- ---------- form (left pane) ----------
rebuild = function()
    for _, c in ipairs(formScroll:GetChildren()) do
        if not c:IsA("UIListLayout") then c:Destroy() end
    end
    local ord = 0
    local function place(inst) ord = ord + 1; inst.LayoutOrder = ord; inst.Parent = formScroll; return inst end

    place(textRow(formScroll, "Name", draft.name, function(t) draft.name = t end))
    place(wrap(30, function(p) components.Toggle(p, { text = "Use in all games (universal)",
        default = draft.scope == "universal",
        onChange = function(v) draft.scope = v and "universal" or "game" end }) end))

    place(components.Section(formScroll, "Trigger"))
    if draft.event == "anim" then
        -- bind to an animation: paste its id, or Capture the next one you play
        place(components.Label(formScroll, "Fires when this animation plays on you:"))
        place(textRow(formScroll, "Anim ID", draft.animId, function(t)
            local id = t and t:match("%d+")
            draft.animId = id or (t ~= "" and t) or nil
        end))
        place(wrap(30, function(p)
            local b = Instance.new("TextButton")
            b.Size = UDim2.new(1, 0, 0, 26); b.BackgroundColor3 = theme.bgDark; b.AutoButtonColor = true
            b.TextColor3 = theme.accent; b.Font = theme.fontBold; b.TextSize = 12
            b.Text = "Capture (play the move now)"; b.Parent = p; corner(b, 4)
            b.MouseButton1Click:Connect(function()
                b.Text = "Capturing... play the move now"
                pcall(function() notify.info("Capturing -- play the move now", 3) end)
                engine.captureAnim(function(raw)
                    draft.animId = tostring(raw):match("%d+") or tostring(raw)
                    pcall(function() notify.success("Captured anim " .. tostring(draft.animId)) end)
                    rebuild()
                end)
            end)
        end))
    elseif draft.event == "move" then
        local res = scanner.cached() or scanner.scan()
        local moveset = res.buttons or {}
        if #moveset == 0 then
            place(components.Label(formScroll, "No moves detected yet (run 'Dump GUI' so I can map your hotbar)"))
        else
            local labels = {}
            for _, b in ipairs(moveset) do
                local lbl = (b.text ~= "" and b.text) or b.name
                if b.key then lbl = lbl .. " [" .. b.key .. "]" end
                labels[#labels + 1] = lbl
            end
            if not draft.move then
                draft.move = moveset[1].name
                if moveset[1].key and not draft.movekey then draft.movekey = moveset[1].key end
            end
            local idx = 1
            for i, b in ipairs(moveset) do if b.name == draft.move then idx = i end end
            place(cycleRow(formScroll, "Move", labels, idx, function(i)
                draft.move = moveset[i].name
                if moveset[i].key then draft.movekey = moveset[i].key end
                rebuild()
            end))
            place(wrap(28, function(p)
                local def = (draft.movekey and Enum.KeyCode[draft.movekey]) or Enum.KeyCode.Unknown
                components.KeybindSetter(p, { label = "Move key", default = def,
                    onChange = function(k)
                        draft.movekey = (k and k ~= Enum.KeyCode.Unknown) and (tostring(k):gsub("Enum.KeyCode.", "")) or nil
                    end })
            end))
            -- cancel the move's own fire so its key runs ONLY this tech (the tech
            -- fires the move itself via a "Use Move" step). Best-effort.
            place(wrap(30, function(p) components.Toggle(p, { text = "Cancel move's normal fire",
                default = draft.suppress == true,
                onChange = function(v) draft.suppress = v or nil end }) end))
        end
    else
        place(wrap(28, function(p)
            components.KeybindSetter(p, { label = "Key", default = draft.key, onChange = function(k) draft.key = k end })
        end))
    end
    -- optional modifier that must be HELD for the trigger to fire (hold A + press Q)
    place(wrap(28, function(p)
        local def = (draft.modkey and Enum.KeyCode[draft.modkey]) or Enum.KeyCode.Unknown
        components.KeybindSetter(p, { label = "Hold-key (optional)", default = def,
            onChange = function(k)
                draft.modkey = (k and k ~= Enum.KeyCode.Unknown) and (tostring(k):gsub("Enum.KeyCode.", "")) or nil
            end })
    end))
    if draft.event == "key" or draft.event == "keyhold" then
        place(wrap(30, function(p) components.Toggle(p, { text = "Hold the key (release = return)",
            default = draft.event == "keyhold",
            onChange = function(v)
                if v then draft.event = "keyhold" elseif draft.event == "keyhold" then draft.event = "key" end
                rebuild()
            end }) end))
    end
    place(wrap(30, function(p) components.Toggle(p, { text = "Trigger on a move instead",
        default = draft.event == "move",
        onChange = function(v) draft.event = v and "move" or "key"; rebuild() end }) end))
    place(wrap(30, function(p) components.Toggle(p, { text = "Trigger on an animation instead",
        default = draft.event == "anim",
        onChange = function(v) draft.event = v and "anim" or "key"; rebuild() end }) end))
    place(wrap(30, function(p) components.Toggle(p, { text = "Only while locked on",
        default = draft.conditions.locked_on == true,
        onChange = function(v) draft.conditions.locked_on = v or nil end }) end))

    place(components.Section(formScroll, "Steps - tap to add"))
    do
        local palette = Instance.new("Frame")
        palette.Size = UDim2.new(1, 0, 0, 0); palette.AutomaticSize = Enum.AutomaticSize.Y; palette.BackgroundTransparency = 1
        local pl = Instance.new("UIGridLayout", palette)
        pl.CellSize = UDim2.new(0, 80, 0, 26); pl.CellPadding = UDim2.new(0, 4, 0, 4); pl.SortOrder = Enum.SortOrder.LayoutOrder
        for i, t in ipairs(ACTION_TYPES) do
            local b = Instance.new("TextButton")
            b.BackgroundColor3 = theme.bgDark; b.AutoButtonColor = true; b.TextColor3 = theme.accent
            b.Font = theme.fontBold; b.TextSize = 12; b.Text = "+ " .. (STEP_LABEL[t] or t); b.LayoutOrder = i; b.Parent = palette
            b.MouseButton1Click:Connect(function()
                if t == "hold" then
                    -- add a Hold + Release pair (shared key); put steps between them
                    local hid = "h" .. tostring(math.floor(os.clock() * 1000))
                    draft.actions[#draft.actions + 1] = { type = "hold", key = nil, holdId = hid }
                    draft.actions[#draft.actions + 1] = { type = "release", key = nil, holdId = hid }
                    rebuild(); return
                end
                local a = { type = t }
                if t == "look" then a.x = 180; a.y = 0
                elseif t == "rotate" then a.x = 180
                elseif t == "wait" then a.seconds = 0.5
                elseif t == "within" then a.studs = 5
                elseif t == "feature" then local fa = feature.all(); a.feature = fa[1] and fa[1].id or nil
                elseif t == "usebtn" then local res = scanner.cached() or scanner.scan(); local m = (res.buttons or {})[1]; a.move = m and m.name or nil end
                draft.actions[#draft.actions + 1] = a; rebuild()
            end)
        end
        place(palette)
    end
    if #draft.actions == 0 then
        place(components.Label(formScroll, "(no steps yet - tap a button above)"))
    else
        for i, act in ipairs(draft.actions) do place(buildChip(formScroll, i, act)) end
    end

    do
        local bf = Instance.new("Frame")
        bf.Size = UDim2.new(1, 0, 0, 36); bf.BackgroundTransparency = 1
        local bl = Instance.new("UIListLayout", bf)
        bl.FillDirection = Enum.FillDirection.Horizontal; bl.HorizontalAlignment = Enum.HorizontalAlignment.Right
        bl.VerticalAlignment = Enum.VerticalAlignment.Center; bl.Padding = UDim.new(0, 8)
        local cancel = Instance.new("TextButton")
        cancel.Size = UDim2.fromOffset(86, 26); cancel.BackgroundColor3 = theme.bgAlt; cancel.AutoButtonColor = false
        cancel.TextColor3 = theme.fg; cancel.Font = theme.font; cancel.TextSize = 12; cancel.Text = "Cancel"
        cancel.LayoutOrder = 1; cancel.Parent = bf
        cancel.MouseButton1Click:Connect(function() Builder.close() end)
        local save = Instance.new("TextButton")
        save.Size = UDim2.fromOffset(100, 26); save.BackgroundColor3 = theme.accent; save.AutoButtonColor = false
        save.TextColor3 = theme.fg; save.Font = theme.fontBold; save.TextSize = 12; save.Text = "Save Tech"
        save.LayoutOrder = 2; save.Parent = bf
        save.MouseButton1Click:Connect(onSave)
        place(bf)
    end
end

-- ---------- window ----------
local function ensureGui()
    if gui and gui.Parent then return end
    gui = Instance.new("ScreenGui")
    gui.Name = "_" .. math.random(100000, 999999)
    gui.ResetOnSpawn = false
    gui.Parent = env.guiParent()
    if env.protectGui then env.protectGui(gui) end

    rootFrame = Instance.new("Frame")
    rootFrame.Size = UDim2.fromOffset(620, 420)
    rootFrame.Position = UDim2.new(0.5, -310, 0.5, -210)
    rootFrame.BackgroundColor3 = theme.bg; rootFrame.BorderSizePixel = 0; rootFrame.Visible = false; rootFrame.Active = true
    rootFrame.Parent = gui
    corner(rootFrame, 10); stroke(rootFrame, theme.accent)

    local header = Instance.new("Frame")
    header.Size = UDim2.new(1, 0, 0, 30); header.BackgroundColor3 = theme.accent; header.BorderSizePixel = 0; header.Parent = rootFrame
    corner(header, 10)
    local dragBtn = Instance.new("TextButton")
    dragBtn.Size = UDim2.fromScale(1, 1); dragBtn.BackgroundTransparency = 1; dragBtn.Text = ""; dragBtn.AutoButtonColor = false
    dragBtn.ZIndex = 2; dragBtn.Parent = header
    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -98, 1, 0); title.Position = UDim2.fromOffset(12, 0); title.BackgroundTransparency = 1
    title.Text = "Tech Builder"; title.TextColor3 = theme.fg; title.Font = theme.fontBold; title.TextSize = 13
    title.TextXAlignment = Enum.TextXAlignment.Left; title.ZIndex = 3; title.Parent = header
    local newBtn = Instance.new("TextButton")
    newBtn.Size = UDim2.fromOffset(58, 22); newBtn.Position = UDim2.new(1, -92, 0.5, -11); newBtn.BackgroundColor3 = theme.bgDark
    newBtn.AutoButtonColor = false; newBtn.Text = "+ New"; newBtn.TextColor3 = theme.fg; newBtn.Font = theme.fontBold
    newBtn.TextSize = 11; newBtn.ZIndex = 4; newBtn.Parent = header
    newBtn.MouseButton1Click:Connect(function() Builder.open() end)
    local close = Instance.new("TextButton")
    close.Size = UDim2.fromOffset(26, 22); close.Position = UDim2.new(1, -30, 0.5, -11); close.BackgroundColor3 = theme.danger
    close.AutoButtonColor = false; close.Text = "X"; close.TextColor3 = theme.fg; close.Font = theme.fontBold
    close.TextSize = 12; close.ZIndex = 4; close.Parent = header
    close.MouseButton1Click:Connect(function() Builder.close() end)

    do
        local dragging, dStart, sPos = false, nil, nil
        dragBtn.InputBegan:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
                dragging, dStart, sPos = true, i.Position, rootFrame.Position
            end
        end)
        UIS.InputChanged:Connect(function(i)
            if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
                local d = i.Position - dStart
                rootFrame.Position = UDim2.new(sPos.X.Scale, sPos.X.Offset + d.X, sPos.Y.Scale, sPos.Y.Offset + d.Y)
            end
        end)
        UIS.InputEnded:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
        end)
    end

    -- LEFT: form
    formScroll = Instance.new("ScrollingFrame")
    formScroll.Size = UDim2.new(0, 296, 1, -44); formScroll.Position = UDim2.fromOffset(8, 36)
    formScroll.BackgroundTransparency = 1; formScroll.BorderSizePixel = 0
    formScroll.ScrollBarThickness = 4; formScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    formScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y; formScroll.Parent = rootFrame
    local fl = Instance.new("UIListLayout", formScroll); fl.SortOrder = Enum.SortOrder.LayoutOrder; fl.Padding = UDim.new(0, 3)

    -- RIGHT: preview
    local right = Instance.new("Frame")
    right.Size = UDim2.new(1, -320, 1, -44); right.Position = UDim2.fromOffset(312, 36)
    right.BackgroundColor3 = theme.bgAlt; right.BorderSizePixel = 0; right.Parent = rootFrame
    corner(right, 8); stroke(right)
    local rpad = Instance.new("UIPadding", right)
    rpad.PaddingTop = UDim.new(0, 8); rpad.PaddingBottom = UDim.new(0, 8); rpad.PaddingLeft = UDim.new(0, 8); rpad.PaddingRight = UDim.new(0, 8)

    vpFrame = Instance.new("ViewportFrame")
    vpFrame.Size = UDim2.new(1, 0, 1, -40); vpFrame.BackgroundColor3 = theme.bgDark; vpFrame.BorderSizePixel = 0
    vpFrame.Ambient = Color3.fromRGB(190, 190, 200); vpFrame.LightColor = Color3.fromRGB(255, 255, 255)
    vpFrame.LightDirection = Vector3.new(-0.4, -1, -0.2); vpFrame.Parent = right
    corner(vpFrame, 8)
    worldModel = Instance.new("WorldModel"); worldModel.Parent = vpFrame
    vpCam = Instance.new("Camera"); vpCam.FieldOfView = 50; vpCam.Parent = vpFrame; vpFrame.CurrentCamera = vpCam

    local playBtn = Instance.new("TextButton")
    playBtn.Size = UDim2.new(1, 0, 0, 32); playBtn.Position = UDim2.new(0, 0, 1, -32); playBtn.BackgroundColor3 = theme.accent
    playBtn.AutoButtonColor = true; playBtn.Text = "Play preview"; playBtn.TextColor3 = theme.fg; playBtn.Font = theme.fontBold
    playBtn.TextSize = 13; playBtn.Parent = right; corner(playBtn, 6)
    playBtn.MouseButton1Click:Connect(previewDraft)
end

function Builder.open(existingTech)
    local ok, err = pcall(function()
        ensureGui()
        draft = existingTech and draftFromTech(existingTech) or newDraft()
        rebuild()
        captureRig()
        buildRigPreview()
        rootFrame.Visible = true
    end)
    if not ok then
        warn("[Pantheon] Tech Builder open error: " .. tostring(err))
        pcall(function() notify.warn("Tech Builder error: " .. tostring(err), 8) end)
    end
end

function Builder.close()
    if rootFrame then rootFrame.Visible = false end
    if curRig then pcall(function() curRig:Destroy() end); curRig = nil end
end

function Builder.destroy()
    if curRig then pcall(function() curRig:Destroy() end); curRig = nil end
    if rigTemplate then pcall(function() rigTemplate:Destroy() end); rigTemplate = nil end
    if gui then pcall(function() gui:Destroy() end); gui = nil end
end

return Builder
