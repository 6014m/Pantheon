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
local CanvasUI   = require("modules.tech.canvas_ui")

local UIS        = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Players    = game:GetService("Players")

local Builder = {}

local gui, rootFrame, formScroll
local canvas, canvasContainer   -- Scratch canvas + its wrapper Frame; persist across rebuilds so blocks don't get destroyed when the form re-renders
local winDragConns = {}         -- global UIS connections for the window-drag handle; disconnected in Builder.destroy()
local draft
local animDropOpen = false   -- is the played-anim dropdown expanded right now

local CONDITIONS = {
    { id = "locked_on",      label = "Locked on"          },
    { id = "shiftlock",      label = "Shiftlock on"       },
    { id = "target_playing", label = "Target playing anim" },
}
-- palette buttons (Release is added automatically with Hold, not its own button)
local ACTION_TYPES = { "look", "rotate", "during", "wait", "within", "return", "feature", "key", "hold", "usebtn" }
local STEP_LABEL   = { look = "Look", rotate = "Rotate", wait = "Wait", during = "During",
                       within = "Within", ["return"] = "Return", feature = "Use", key = "Press",
                       hold = "Hold", release = "Release", usebtn = "Use Move" }
local YAW_PRESETS  = { 180, 135, 90, 45, 0, -45, -90, -135, -180 }

-- Scratch-style category coloring. Block fill = category color; the action's
-- specific look is the category palette + its label. Sticking to Scratch's
-- conventional groupings so the visual maps to player expectation: motion blue,
-- control orange, sensing cyan, events yellow, custom/actions purple.
local CATEGORY = {
    -- motion / facing
    look = "motion", rotate = "motion",
    -- control flow / timing
    wait = "control", during = "control", ["return"] = "control",
    hold = "control", release = "control",
    -- sensing / gating
    within = "sense",
    -- actions / "operators"
    feature = "action", key = "action", usebtn = "action",
}
local CAT_COLOR = {
    motion  = Color3.fromRGB(76, 151, 255),    -- blue
    control = Color3.fromRGB(255, 171, 25),    -- orange
    sense   = Color3.fromRGB(92, 177, 214),    -- cyan
    action  = Color3.fromRGB(159, 110, 220),   -- purple
    event   = Color3.fromRGB(255, 191, 0),     -- yellow (hat blocks)
}
local function catOf(t) return CATEGORY[t] or "action" end
local function colorOf(t) return CAT_COLOR[catOf(t)] end

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

-- A hotbar keybind label is often a DIGIT ("1".."9") but Enum.KeyCode has no "1"
-- member -- it's "One" -- and Enum.KeyCode["1"] THROWS. Map digits to their names
-- and look up safely so a numbered move key can't blow up the form.
local DIGIT_NAMES = { ["0"]="Zero",["1"]="One",["2"]="Two",["3"]="Three",["4"]="Four",
                      ["5"]="Five",["6"]="Six",["7"]="Seven",["8"]="Eight",["9"]="Nine" }
local function keyNameNorm(hint)
    if not hint then return nil end
    hint = tostring(hint)
    return DIGIT_NAMES[hint] or hint
end
local function toKeyCode(name)
    name = keyNameNorm(name)
    if not name then return nil end
    local ok, kc = pcall(function() return Enum.KeyCode[name] end)
    return ok and kc or nil
end

-- Resolve the current character name from the active per-game module's
-- detectCharacter() hook, used by char-scoped techs. Returns nil when there's
-- no per-game module or it can't determine the character yet.
local function detectCurrentCharacter()
    local ok, registry = pcall(require, "games.registry")
    if not ok or not registry then return nil end
    local mod = registry.current()
    local fn = mod and mod.detectCharacter
    if type(fn) ~= "function" then return nil end
    local ok2, name = pcall(fn)
    return ok2 and name or nil
end

-- ---------- draft <-> tech ----------
local function newDraft()
    return { name = "New Tech", scope = "game", event = "key",
             key = Enum.KeyCode.Unknown, move = nil, conditions = {}, actions = {} }
end
-- Deep-copy an action table so the in-flight draft can't accidentally mutate
-- the saved tech. AND blocks carry a `branches = {[steps],[steps]}` nested
-- structure and any new step type may add fields we haven't enumerated; the
-- generic copy keeps everything in sync without per-type maintenance.
local function copyAction(a)
    local out = {}
    for k, v in pairs(a) do
        if type(v) == "table" then
            -- shallow into branches[]: each branch is a list of actions;
            -- recurse one more level so per-step params survive.
            if k == "branches" then
                local bs = {}
                for i, branch in ipairs(v) do
                    local cb = {}
                    for j, step in ipairs(branch) do cb[j] = copyAction(step) end
                    bs[i] = cb
                end
                out[k] = bs
            else
                out[k] = v   -- non-branches tables: reference-share (rare; defensive)
            end
        else
            out[k] = v
        end
    end
    return out
end

-- Map an engine trigger.event string -> the matching canvas hat block type.
local function hatTypeForEvent(ev)
    if ev == "key" or ev == "keyhold" then return "event_key"
    elseif ev == "anim" then return "event_anim"
    elseif ev == "target_anim" then return "event_target_anim"
    elseif ev == "move" then return "event_move"
    end
    return nil
end
-- Inverse: hat type -> engine trigger.event. event_key carries the
-- key/keyhold distinction in its own .event param (set by the hat modal's
-- "Hold the key" toggle).
local function eventForHat(hat)
    if hat.type == "event_key" then return hat.event == "keyhold" and "keyhold" or "key"
    elseif hat.type == "event_anim" then return "anim"
    elseif hat.type == "event_target_anim" then return "target_anim"
    elseif hat.type == "event_move" then return "move"
    end
    return "key"
end

local function draftFromTech(t)
    local conds = {}
    for _, c in ipairs(t.trigger.conditions or {}) do conds[c] = true end
    local actions = {}
    local trigEvent = t.trigger and t.trigger.event
    if trigEvent == "or" then
        -- Multi-trigger OR tech. Reconstruct the OR block carrying
        -- subtriggers + branches; the engine "or" step in t.actions[1]
        -- gets folded into the OR block (its branches list lives there
        -- in the canvas representation). Post-OR actions stay as a tail.
        local first = t.actions and t.actions[1]
        local branches = (first and first.type == "or" and first.branches) or {}
        local subts = {}
        for i, s in ipairs(t.trigger.subtriggers or {}) do
            local copy = {}
            for k, v in pairs(s) do copy[k] = v end
            subts[i] = copy
        end
        actions[#actions + 1] = { type = "or", triggers = subts, branches = branches }
        local startAt = (first and first.type == "or") and 2 or 1
        for i = startAt, #(t.actions or {}) do
            actions[#actions + 1] = copyAction(t.actions[i])
        end
    else
        -- Single-trigger flow: prepend a hat block carrying the trigger
        -- params so the user sees the trigger as a real block on the canvas
        -- (and can drag/configure/delete it like any other step).
        local hatType = hatTypeForEvent(trigEvent)
        if hatType then
            local hat = { type = hatType }
            for k, v in pairs(t.trigger or {}) do
                if k ~= "event" and k ~= "conditions" and k ~= "subtriggers" then hat[k] = v end
            end
            if hatType == "event_key" then hat.event = t.trigger.event end   -- "key" vs "keyhold"
            actions[#actions + 1] = hat
        end
        for _, a in ipairs(t.actions or {}) do
            actions[#actions + 1] = copyAction(a)
        end
    end
    -- Decode scope. Numeric or unspecified -> "game" (saved as PlaceId/GameId on
    -- save). "universal" stays as-is. "char:<name>" maps to "char" and the
    -- pinned name (so editing preserves the char binding even if we're not
    -- currently playing as that character).
    local scope, pinChar = "game", nil
    if t.scope == "universal" then scope = "universal"
    elseif type(t.scope) == "string" then
        local cn = t.scope:match("^char:(.+)$")
        if cn then scope = "char"; pinChar = cn end
    end
    return {
        editId = t.id, name = t.name,
        scope = scope, pinChar = pinChar,
        event = t.trigger.event, key = t.trigger.key, move = t.trigger.move, movekey = t.trigger.movekey,
        modkey = t.trigger.modkey, maxRange = t.trigger.maxRange,
        animId = t.trigger.animId, animEnd = t.trigger.animEnd,
        targetAnimId = t.trigger.targetAnimId,
        suppress = t.trigger.suppress, ignoreWelds = t.trigger.ignoreWelds,
        conditions = conds, actions = actions,
    }
end
local function draftConditions()
    local conds = {}
    for _, c in ipairs(CONDITIONS) do if draft.conditions[c.id] then conds[#conds + 1] = c.id end end
    return conds
end
local function draftActions()
    -- Generic deep copy: previously a hard-coded per-type whitelist that
    -- silently DROPPED any field not in the list (which is how AND's
    -- branches were getting lost on Save). copyAction handles branches[]
    -- recursively + future-proofs against new step fields.
    local actions = {}
    for _, a in ipairs(draft.actions) do actions[#actions + 1] = copyAction(a) end
    return actions
end
local function buildTechFromDraft(id)
    -- Resolve scope (game / char / universal).
    local scope
    if draft.scope == "universal" then
        scope = "universal"
    elseif draft.scope == "char" then
        local cn = draft.pinChar or detectCurrentCharacter()
        scope = cn and ("char:" .. cn) or game.GameId
    else
        scope = game.GameId
    end

    -- Base trigger from the legacy form fields. The hat-block-on-canvas
    -- path BELOW will overwrite event + relevant params if a hat is
    -- present, taking precedence over the form. Form fields are kept as
    -- a fallback for techs the user hasn't migrated to a hat yet.
    local trigger = {
        event = draft.event, key = draft.key, move = draft.move, movekey = draft.movekey,
        modkey = draft.modkey, maxRange = draft.maxRange,
        animId = draft.animId, animEnd = draft.animEnd,
        targetAnimId = draft.targetAnimId,
        suppress = draft.suppress, ignoreWelds = draft.ignoreWelds,
        conditions = draftConditions(),
    }

    local actions = draftActions()
    -- Canvas head extraction. Three cases:
    --  * OR block at top  -> multi-trigger fork: subtriggers move to
    --    tech.trigger.subtriggers (event="or"), and the engine OR step
    --    {type="or", branches=...} re-inserts at actions[1] so runStep
    --    can pick branches[ctx.triggerIndex] at fire time.
    --  * Hat block at top -> single trigger: hat params become tech.trigger.
    --  * Neither           -> trigger came from legacy form fields (untouched).
    if actions[1] and actions[1].type == "or" then
        local orBlock = table.remove(actions, 1)
        trigger.event = "or"
        trigger.subtriggers = orBlock.triggers or {}
        table.insert(actions, 1, { type = "or", branches = orBlock.branches or {} })
    elseif actions[1] and CanvasUI.isHat(actions[1].type) then
        local hat = table.remove(actions, 1)
        trigger.event = eventForHat(hat)
        for k, v in pairs(hat) do
            if k ~= "type" and k ~= "event" then trigger[k] = v end
        end
    end

    return {
        id = id, name = (draft.name and #draft.name > 0) and draft.name or "Tech", custom = true,
        scope = scope, enabled = true,
        trigger = trigger, actions = actions,
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
    -- Sync from canvas before save: param edits (Wait seconds, Within studs,
    -- key bindings, etc.) update block.params in place but DON'T fire the
    -- canvas's onChange -- only chain ops do. Without this resync, edits made
    -- after the last drag/snap were dropped on Save.
    if canvas then draft.actions = canvas:toActions() end
    local tech = buildTechFromDraft(id)
    engine.saveCustom(tech)
    notify.success("Tech saved: " .. tech.name)
    Builder.close()
end

-- ---------- viewport preview (clone rig, ported from Animation Logger) ----------
local vpFrame, worldModel, vpCam, rigTemplate, curRig, curTrack
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
    if curTrack then pcall(function() curTrack:Stop(0) end); curTrack = nil end
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

-- play an animation on the clone's Animator (ported from the Animation Logger):
-- HRP is anchored, the rest stay jointed by Motor6D and get posed by the track.
-- VFX isn't reproduced (it's spawned by the game's own scripts, not the track).
local function playAnimOnRig(id, loop)
    if not curRig then buildRigPreview() end
    if not curRig then return end
    if curTrack then pcall(function() curTrack:Stop(0) end); curTrack = nil end
    local num = tostring(id):match("%d+"); if not num then return end
    local hum = curRig:FindFirstChildOfClass("Humanoid")
    local animator = hum and hum:FindFirstChildOfClass("Animator")
    if hum and not animator then animator = Instance.new("Animator"); animator.Parent = hum end
    if not animator then return end
    local a = Instance.new("Animation"); a.AnimationId = "rbxassetid://" .. num
    local ok, tr = pcall(function() return animator:LoadAnimation(a) end)
    if ok and tr then
        tr.Looped = loop and true or false
        pcall(function() tr.Priority = Enum.AnimationPriority.Action end)
        pcall(function() tr:Play() end)
        curTrack = tr
    end
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
    -- Pull the latest blocks off the canvas: canvas.onChange only refreshes
    -- draft.actions on chain ops, not inline param edits, so without this a
    -- Play right after editing a Wait/Look value would replay the old values.
    if canvas then draft.actions = canvas:toActions() end
    buildRigPreview()
    if not curRig then notify.warn("Preview: couldn't clone your avatar"); return end
    -- if this tech is animation-triggered, play that anim on the clone too
    if draft.event == "anim" and draft.animId then playAnimOnRig(draft.animId, true) end
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

-- ---------- step chip (Scratch-style block) ----------
-- V0 of the Scratch rewrite: visual restyle of the existing chip rows. Colored
-- by category, rounded with category-tinted background, decorative top-notch
-- and bottom-tab so blocks visually "join" in the column. Drag-and-drop +
-- snap-to-connect + nested slots arrive in V1; this layer keeps the proven
-- click-to-add palette + ^/v reorder so we ship working blocks today.
local rebuild
local function buildChip(parent, i, act)
    local cat = catOf(act.type)
    local fill = colorOf(act.type)

    -- decorative "notch" above (in the gap of the UIListLayout) so the column
    -- reads as one chain. The UIListLayout padding is set to 0 on the form so
    -- consecutive blocks visually butt up against each other.
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, 0, 0, 38); f.BackgroundColor3 = fill; f.BorderSizePixel = 0
    f.Parent = parent
    corner(f, 10)
    local s = stroke(f, theme.bgDark); s.Thickness = 2; s.Transparency = 0.4

    -- bottom "tab" -- a tiny rectangle protruding from the block's bottom edge.
    -- Visual only; on snap-connect (V1) this is the actual connector.
    local tab = Instance.new("Frame")
    tab.Size = UDim2.fromOffset(20, 3); tab.Position = UDim2.new(0, 22, 1, 0)
    tab.BackgroundColor3 = fill; tab.BorderSizePixel = 0; tab.ZIndex = (f.ZIndex or 1) + 1
    tab.Parent = f
    local tabC = Instance.new("UICorner"); tabC.CornerRadius = UDim.new(0, 2); tabC.Parent = tab

    -- left grip column = drag handle (visual only in V0; V1 wires it to a
    -- real reorder drag). Currently the ^/v buttons handle reordering.
    local grip = Instance.new("TextLabel")
    grip.Size = UDim2.fromOffset(10, 24); grip.Position = UDim2.new(0, 4, 0.5, -12)
    grip.BackgroundTransparency = 1
    grip.Text = "::"; grip.TextColor3 = theme.fg
    grip.Font = theme.fontBold; grip.TextSize = 14
    grip.TextTransparency = 0.5
    grip.Parent = f

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(0, 78, 1, 0); lbl.Position = UDim2.fromOffset(18, 0); lbl.BackgroundTransparency = 1
    lbl.Text = i .. ".  " .. (STEP_LABEL[act.type] or act.type)
    lbl.TextColor3 = theme.fg; lbl.Font = theme.fontBold; lbl.TextSize = 13
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
    val.Size = UDim2.new(1, -174, 1, -10); val.Position = UDim2.new(0, 100, 0, 5)
    val.BackgroundColor3 = theme.bgDark
    val.TextColor3 = (act.type == "return" or act.type == "during") and theme.fgDim or theme.fg
    val.Font = theme.font; val.TextSize = 12; val.Parent = f
    pcall(function() local vc = Instance.new("UICorner"); vc.CornerRadius = UDim.new(0, 6); vc.Parent = val end)

    local up = smallBtn(f, "^", -68)
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

-- "Hat block" wrapper for the trigger section header. Yellow band with a flat
-- bottom that visually connects into the first action block underneath. This
-- is decoration-only in V0 -- the trigger form fields render normally below.
local function buildHatHeader(parent, label)
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, 0, 0, 28); f.BackgroundColor3 = CAT_COLOR.event; f.BorderSizePixel = 0
    f.Parent = parent
    corner(f, 10)
    -- pin the bottom flat so it lies flush against the first action block
    local flat = Instance.new("Frame")
    flat.Size = UDim2.new(1, 0, 0, 10); flat.Position = UDim2.new(0, 0, 1, -10)
    flat.BackgroundColor3 = CAT_COLOR.event; flat.BorderSizePixel = 0; flat.Parent = f
    -- tab on the bottom matching action-block notch position
    local tab = Instance.new("Frame")
    tab.Size = UDim2.fromOffset(20, 3); tab.Position = UDim2.new(0, 22, 1, 0)
    tab.BackgroundColor3 = CAT_COLOR.event; tab.BorderSizePixel = 0; tab.Parent = f
    local tc = Instance.new("UICorner"); tc.CornerRadius = UDim.new(0, 2); tc.Parent = tab
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -16, 1, 0); lbl.Position = UDim2.fromOffset(12, 0); lbl.BackgroundTransparency = 1
    lbl.Text = label; lbl.TextColor3 = Color3.fromRGB(40, 30, 0); lbl.Font = theme.fontBold; lbl.TextSize = 13
    lbl.TextXAlignment = Enum.TextXAlignment.Left; lbl.Parent = f
    return f
end

-- ---------- Hat-block trigger editor (sub-modal) ----------
-- Click on a hat block's summary button -> open this modal. Per-type rows
-- (key picker / anim picker / move picker / etc.) write into the hat's
-- params; on Save the hat refreshes its inline summary and the draft is
-- re-synced from canvas. Each hat type renders only the params relevant
-- to that trigger event (no global show-all-fields like the legacy form).
local function openHatEditor(hatBlock)
    local t, p = hatBlock.type, hatBlock.params

    local modal = Instance.new("Frame")
    modal.Size = UDim2.new(0, 360, 0, 280)
    modal.Position = UDim2.new(0.5, -180, 0.5, -140)
    modal.BackgroundColor3 = theme.bg; modal.BorderSizePixel = 0
    modal.ZIndex = 200; modal.Parent = rootFrame
    corner(modal, 8); stroke(modal, theme.accent, 2)

    local TITLE = ({
        event_key = "When key pressed", event_anim = "When my anim plays",
        event_target_anim = "When target's anim plays", event_move = "When move pressed",
    })[t] or "Configure trigger"
    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -20, 0, 24); title.Position = UDim2.fromOffset(10, 8)
    title.BackgroundTransparency = 1; title.Text = TITLE
    title.TextColor3 = theme.fg; title.Font = theme.fontBold; title.TextSize = 14
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.ZIndex = 201; title.Parent = modal

    local body = Instance.new("ScrollingFrame")
    body.Size = UDim2.new(1, -20, 1, -76); body.Position = UDim2.fromOffset(10, 36)
    body.BackgroundTransparency = 1; body.BorderSizePixel = 0
    body.ScrollBarThickness = 4; body.CanvasSize = UDim2.new(0, 0, 0, 0)
    body.AutomaticCanvasSize = Enum.AutomaticSize.Y; body.ZIndex = 201; body.Parent = modal
    local bl = Instance.new("UIListLayout", body); bl.Padding = UDim.new(0, 6); bl.SortOrder = Enum.SortOrder.LayoutOrder

    local ord = 0
    local function place(inst) ord = ord + 1; inst.LayoutOrder = ord; inst.Parent = body; return inst end

    -- per-type rows. KeybindSetter / textRow / Toggle are the same components
    -- the legacy form section used -- DRY without refactoring.
    if t == "event_key" then
        place(wrap(28, function(host)
            local def = toKeyCode(p.key) or (typeof(p.key) == "EnumItem" and p.key) or Enum.KeyCode.Unknown
            components.KeybindSetter(host, { label = "Key", default = def,
                onChange = function(k) p.key = k end })
        end))
        place(wrap(28, function(host) components.Toggle(host, { text = "Hold (release = return)",
            default = p.event == "keyhold",
            onChange = function(v) p.event = v and "keyhold" or "key" end }) end))
        place(wrap(28, function(host) components.Toggle(host, { text = "Block this key's normal action",
            default = p.suppress == true,
            onChange = function(v) p.suppress = v or nil end }) end))
        place(wrap(28, function(host)
            local def = toKeyCode(p.modkey) or Enum.KeyCode.Unknown
            components.KeybindSetter(host, { label = "Hold-key (optional)", default = def,
                onChange = function(k) p.modkey = (k and k ~= Enum.KeyCode.Unknown) and (tostring(k):gsub("Enum.KeyCode.", "")) or nil end })
        end))
    elseif t == "event_anim" or t == "event_target_anim" then
        local isTarget = (t == "event_target_anim")
        place(textRow(body, "Anim ID", p.animId, function(s)
            local id = s and s:match("%d+"); p.animId = id or (s ~= "" and s) or nil
        end))
        place(wrap(28, function(host)
            local b = Instance.new("TextButton")
            b.Size = UDim2.new(1, 0, 0, 24); b.BackgroundColor3 = theme.bgDark
            b.AutoButtonColor = true; b.TextColor3 = theme.accent
            b.Font = theme.fontBold; b.TextSize = 12
            b.Text = isTarget and "Capture (target plays the move)" or "Capture (play the move now)"
            b.Parent = host; corner(b, 4)
            b.MouseButton1Click:Connect(function()
                b.Text = "Capturing..."
                local cap = isTarget and engine.captureTargetAnim or engine.captureAnim
                if cap then
                    cap(function(raw)
                        p.animId = tostring(raw):match("%d+") or tostring(raw)
                        b.Text = isTarget and "Capture (target plays the move)" or "Capture (play the move now)"
                    end)
                end
            end)
        end))
        place(wrap(28, function(host) components.Toggle(host, { text = "Fire on animation END (not start)",
            default = p.animEnd == true,
            onChange = function(v) p.animEnd = v or nil end }) end))
    elseif t == "event_move" then
        local res = scanner.cached() or scanner.scan()
        local moveset = res.buttons or {}
        if #moveset == 0 then
            place(components.Label(body, "No moves detected yet (run Dump GUI to map the hotbar)"))
        else
            if not p.move then
                p.move = moveset[1].name
                if moveset[1].key and not p.movekey then p.movekey = keyNameNorm(moveset[1].key) end
            end
            local labels = {}
            for _, b in ipairs(moveset) do
                local lbl = (b.text ~= "" and b.text) or b.name
                if b.key then lbl = lbl .. " [" .. b.key .. "]" end
                labels[#labels + 1] = lbl
            end
            local idx = 1
            for i, b in ipairs(moveset) do if b.name == p.move then idx = i end end
            place(cycleRow(body, "Move", labels, idx, function(i)
                p.move = moveset[i].name
                if moveset[i].key then p.movekey = keyNameNorm(moveset[i].key) end
            end))
            place(wrap(28, function(host)
                local def = toKeyCode(p.movekey) or Enum.KeyCode.Unknown
                components.KeybindSetter(host, { label = "Move key", default = def,
                    onChange = function(k) p.movekey = (k and k ~= Enum.KeyCode.Unknown) and (tostring(k):gsub("Enum.KeyCode.", "")) or nil end })
            end))
        end
        place(wrap(28, function(host) components.Toggle(host, { text = "Block move's normal fire",
            default = p.suppress == true,
            onChange = function(v) p.suppress = v or nil end }) end))
    end

    -- Save / Cancel
    local btnRow = Instance.new("Frame")
    btnRow.Size = UDim2.new(1, -20, 0, 28); btnRow.Position = UDim2.new(0, 10, 1, -34)
    btnRow.BackgroundTransparency = 1; btnRow.ZIndex = 201; btnRow.Parent = modal
    local rowL = Instance.new("UIListLayout", btnRow); rowL.FillDirection = Enum.FillDirection.Horizontal
    rowL.HorizontalAlignment = Enum.HorizontalAlignment.Right; rowL.Padding = UDim.new(0, 8)

    local close = Instance.new("TextButton")
    close.Size = UDim2.fromOffset(80, 26); close.BackgroundColor3 = theme.accent
    close.AutoButtonColor = false; close.TextColor3 = theme.fg
    close.Font = theme.fontBold; close.TextSize = 12; close.Text = "Done"
    close.ZIndex = 202; close.Parent = btnRow
    corner(close, 4)
    close.MouseButton1Click:Connect(function()
        if hatBlock._refreshHatLabel then hatBlock._refreshHatLabel() end
        if draft and canvas then draft.actions = canvas:toActions() end
        modal:Destroy()
    end)
end

-- ---------- Use Move editor (sub-modal) ----------
-- Click a "Use Move" (usebtn) block -> configure which move it fires and how.
-- Rows: a dropdown of detected hotbar moves, a manual move-name box (for moves
-- the scanner can't see), a key to press (key-fire / manual moves), and the
-- fire method. The engine's ACTIONS.usebtn reads block.params.move/key/fire.
-- Stored on the block's params so it round-trips through toActions() like any
-- other step. NOTE: key is stored as a STRING name (not an EnumItem) so the
-- block label can show it and safeKeyCode() can resolve it.
local function openUseMoveEditor(block)
    local p = block.params

    local modal = Instance.new("Frame")
    modal.Size = UDim2.new(0, 360, 0, 300)
    modal.Position = UDim2.new(0.5, -180, 0.5, -150)
    modal.BackgroundColor3 = theme.bg; modal.BorderSizePixel = 0
    modal.ZIndex = 200; modal.Parent = rootFrame
    corner(modal, 8); stroke(modal, theme.accent, 2)

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -20, 0, 24); title.Position = UDim2.fromOffset(10, 8)
    title.BackgroundTransparency = 1; title.Text = "Use Move"
    title.TextColor3 = theme.fg; title.Font = theme.fontBold; title.TextSize = 14
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.ZIndex = 201; title.Parent = modal

    local body = Instance.new("ScrollingFrame")
    body.Size = UDim2.new(1, -20, 1, -76); body.Position = UDim2.fromOffset(10, 36)
    body.BackgroundTransparency = 1; body.BorderSizePixel = 0
    body.ScrollBarThickness = 4; body.CanvasSize = UDim2.new(0, 0, 0, 0)
    body.AutomaticCanvasSize = Enum.AutomaticSize.Y; body.ZIndex = 201; body.Parent = modal
    local bl = Instance.new("UIListLayout", body); bl.Padding = UDim.new(0, 6); bl.SortOrder = Enum.SortOrder.LayoutOrder

    local ord = 0
    local function place(inst) ord = ord + 1; inst.LayoutOrder = ord; inst.Parent = body; return inst end

    -- 1. detected-move dropdown (auto-fills the key from the scan if unset)
    local res = scanner.cached() or scanner.scan()
    local moveset = res.buttons or {}
    if #moveset > 0 then
        local labels = {}
        for _, b in ipairs(moveset) do
            local lbl = (b.text ~= "" and b.text) or b.name
            if b.key then lbl = lbl .. " [" .. b.key .. "]" end
            labels[#labels + 1] = lbl
        end
        local idx = 1
        for i, b in ipairs(moveset) do if b.name == p.move then idx = i end end
        place(cycleRow(body, "Detected move", labels, idx, function(i)
            p.move = moveset[i].name
            if moveset[i].key and (not p.key or p.key == "") then p.key = keyNameNorm(moveset[i].key) end
        end))
    else
        place(components.Label(body, "No moves detected (run Dump GUI, or type the name below)"))
    end

    -- 2. manual move name -- works when the scanner can't see the move
    place(textRow(body, "Or move name", p.move, function(t)
        p.move = (t and t ~= "") and t or nil
    end))

    -- 3. key to press (used by key-fire + manual moves with no live button)
    place(wrap(28, function(host)
        local def = toKeyCode(p.key) or Enum.KeyCode.Unknown
        components.KeybindSetter(host, { label = "Key (key-fire)", default = def,
            onChange = function(k) p.key = (k and k ~= Enum.KeyCode.Unknown) and (tostring(k):gsub("Enum.KeyCode.", "")) or nil end })
    end))

    -- 4. fire method
    local FIRE_LABELS = { "Auto (smart)", "Click button", "Press key" }
    local FIRE_KEYS   = { "auto", "button", "key" }
    local fidx = 1
    for i, k in ipairs(FIRE_KEYS) do if p.fire == k then fidx = i end end
    place(cycleRow(body, "Fire method", FIRE_LABELS, fidx, function(i) p.fire = FIRE_KEYS[i] end))

    place(components.Label(body, "Auto = hook, else button, else key. Press key = VIM the key (use for typed/manual moves)."))

    -- Done
    local btnRow = Instance.new("Frame")
    btnRow.Size = UDim2.new(1, -20, 0, 28); btnRow.Position = UDim2.new(0, 10, 1, -34)
    btnRow.BackgroundTransparency = 1; btnRow.ZIndex = 201; btnRow.Parent = modal
    local rowL = Instance.new("UIListLayout", btnRow); rowL.FillDirection = Enum.FillDirection.Horizontal
    rowL.HorizontalAlignment = Enum.HorizontalAlignment.Right; rowL.Padding = UDim.new(0, 8)

    local close = Instance.new("TextButton")
    close.Size = UDim2.fromOffset(80, 26); close.BackgroundColor3 = theme.accent
    close.AutoButtonColor = false; close.TextColor3 = theme.fg
    close.Font = theme.fontBold; close.TextSize = 12; close.Text = "Done"
    close.ZIndex = 202; close.Parent = btnRow
    corner(close, 4)
    close.MouseButton1Click:Connect(function()
        if block._refreshUseMoveLabel then block._refreshUseMoveLabel() end
        if draft and canvas then draft.actions = canvas:toActions() end
        modal:Destroy()
    end)
end

-- ---------- OR fork editor (sub-modal) ----------
-- Each branch = a SUBTRIGGER (hat block at the top) + an action chain. Two
-- branches by default; engine wires each subtrigger independently and the
-- OR step picks branch[ctx.triggerIndex] at fire time. Mini canvases reuse
-- the main CanvasUI class so hat / action blocks behave identically inside.
local function openOrEditor(orBlock)
    local modal = Instance.new("Frame")
    modal.Size = UDim2.new(1, -16, 1, -52)
    modal.Position = UDim2.fromOffset(8, 44)
    modal.BackgroundColor3 = theme.bg; modal.BorderSizePixel = 0
    modal.ZIndex = 200; modal.Parent = rootFrame
    corner(modal, 8); stroke(modal, theme.accent, 2)

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -20, 0, 26); title.Position = UDim2.fromOffset(10, 6)
    title.BackgroundTransparency = 1
    title.Text = "OR fork - configure triggers + per-branch chains"
    title.TextColor3 = theme.fg; title.Font = theme.fontBold; title.TextSize = 14
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.ZIndex = 201; title.Parent = modal

    local hint = Instance.new("TextLabel")
    hint.Size = UDim2.new(1, -20, 0, 16); hint.Position = UDim2.fromOffset(10, 32)
    hint.BackgroundTransparency = 1
    hint.Text = "Each branch starts with a hat (its trigger), then steps. Engine fires the branch whose trigger fired."
    hint.TextColor3 = theme.fgDim; hint.Font = theme.font; hint.TextSize = 11
    hint.TextXAlignment = Enum.TextXAlignment.Left
    hint.ZIndex = 201; hint.Parent = modal

    local scroll = Instance.new("ScrollingFrame")
    scroll.Size = UDim2.new(1, -20, 1, -88); scroll.Position = UDim2.fromOffset(10, 54)
    scroll.BackgroundTransparency = 1; scroll.BorderSizePixel = 0
    scroll.ScrollBarThickness = 4; scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y; scroll.ZIndex = 201; scroll.Parent = modal
    local scrollLay = Instance.new("UIListLayout", scroll); scrollLay.Padding = UDim.new(0, 8); scrollLay.SortOrder = Enum.SortOrder.LayoutOrder

    local miniCanvases = {}

    local function makeBranchSection(idx)
        local sec = Instance.new("Frame")
        sec.Size = UDim2.new(1, 0, 0, 0); sec.AutomaticSize = Enum.AutomaticSize.Y
        sec.BackgroundTransparency = 1; sec.LayoutOrder = idx; sec.Parent = scroll
        local secLay = Instance.new("UIListLayout", sec); secLay.Padding = UDim.new(0, 4); secLay.SortOrder = Enum.SortOrder.LayoutOrder

        local hdr = Instance.new("TextLabel")
        hdr.Size = UDim2.new(1, 0, 0, 20); hdr.BackgroundTransparency = 1
        hdr.Text = "Branch " .. idx .. " (trigger + steps)"; hdr.TextColor3 = theme.accent
        hdr.Font = theme.fontBold; hdr.TextSize = 12
        hdr.TextXAlignment = Enum.TextXAlignment.Left
        hdr.LayoutOrder = 1; hdr.Parent = sec

        local pal = Instance.new("Frame")
        pal.Size = UDim2.new(1, 0, 0, 0); pal.AutomaticSize = Enum.AutomaticSize.Y
        pal.BackgroundTransparency = 1; pal.LayoutOrder = 2; pal.Parent = sec
        local pl = Instance.new("UIGridLayout", pal)
        pl.CellSize = UDim2.new(0, 84, 0, 32); pl.CellPadding = UDim2.new(0, 4, 0, 4)

        local mc = CanvasUI.new(sec, {})
        mc.frame.LayoutOrder = 3
        -- Mini canvas's editHatRequested -> reuse the main openHatEditor.
        mc.editHatRequested:Connect(function(h) openHatEditor(h) end)
        mc.editUseMoveRequested:Connect(function(b) openUseMoveEditor(b) end)

        -- Pre-populate from orBlock.params: triggers[idx] -> hat block,
        -- branches[idx] -> action chain after the hat.
        local triggers = orBlock.params.triggers or {}
        local branches = orBlock.params.branches or {}
        local trig = triggers[idx]
        local hatActions = {}
        if trig then
            local hatType = hatTypeForEvent(trig.event)
            if hatType then
                local hat = { type = hatType }
                for k, v in pairs(trig) do if k ~= "event" then hat[k] = v end end
                if hatType == "event_key" then hat.event = trig.event end
                hatActions[#hatActions + 1] = hat
            end
        end
        for _, a in ipairs(branches[idx] or {}) do hatActions[#hatActions + 1] = copyAction(a) end
        mc:loadActions(hatActions)
        miniCanvases[idx] = mc

        -- Palette: include hat types (so a new branch can pick a trigger
        -- type) AND the same action set the AND modal exposes.
        local function defaultParamsFor(t)
            if t == "look" then return { x = 180, y = 0 }
            elseif t == "rotate" then return { x = 180 }
            elseif t == "wait" then return { seconds = 0.5 }
            elseif t == "within" then return { studs = 5 }
            end
            return {}
        end
        local function paletteBtn(t)
            local c = colorOf(t)
            local b = Instance.new("TextButton")
            b.BackgroundColor3 = Color3.fromRGB(math.floor(c.R*255*0.78), math.floor(c.G*255*0.78), math.floor(c.B*255*0.78))
            b.AutoButtonColor = true; b.TextColor3 = theme.fg
            b.Font = theme.fontBold; b.TextSize = 12
            b.Text = "+ " .. (CanvasUI.STEP_LABEL[t] or STEP_LABEL[t] or t); b.Parent = pal
            corner(b, 8)
            b.MouseButton1Click:Connect(function() mc:addBlock(t, defaultParamsFor(t)) end)
        end
        for _, t in ipairs(CanvasUI.HAT_TYPES) do paletteBtn(t) end
        for _, t in ipairs({ "look", "rotate", "wait", "within", "return", "feature", "key", "usebtn" }) do paletteBtn(t) end
    end

    makeBranchSection(1)
    makeBranchSection(2)

    -- buttons
    local btnRow = Instance.new("Frame")
    btnRow.Size = UDim2.new(1, -20, 0, 28); btnRow.Position = UDim2.new(0, 10, 1, -34)
    btnRow.BackgroundTransparency = 1; btnRow.ZIndex = 201; btnRow.Parent = modal
    local rowL = Instance.new("UIListLayout", btnRow); rowL.FillDirection = Enum.FillDirection.Horizontal
    rowL.HorizontalAlignment = Enum.HorizontalAlignment.Right; rowL.Padding = UDim.new(0, 8)

    local function closeModal()
        for _, mc in ipairs(miniCanvases) do pcall(function() mc:destroy() end) end
        modal:Destroy()
    end

    local cancel = Instance.new("TextButton")
    cancel.Size = UDim2.fromOffset(80, 26); cancel.BackgroundColor3 = theme.bgAlt
    cancel.AutoButtonColor = false; cancel.TextColor3 = theme.fg
    cancel.Font = theme.font; cancel.TextSize = 12; cancel.Text = "Cancel"
    cancel.LayoutOrder = 1; cancel.ZIndex = 202; cancel.Parent = btnRow
    corner(cancel, 4)
    cancel.MouseButton1Click:Connect(closeModal)

    local save = Instance.new("TextButton")
    save.Size = UDim2.fromOffset(80, 26); save.BackgroundColor3 = theme.accent
    save.AutoButtonColor = false; save.TextColor3 = theme.fg
    save.Font = theme.fontBold; save.TextSize = 12; save.Text = "Save"
    save.LayoutOrder = 2; save.ZIndex = 202; save.Parent = btnRow
    corner(save, 4)
    save.MouseButton1Click:Connect(function()
        -- For each branch's mini canvas, extract its hat (if present) into
        -- a subtrigger + the remaining steps into branches[idx]. A branch
        -- without a hat saves an empty subtrigger (no event) which the
        -- engine ignores -- the user can re-open the modal and pick a hat.
        local triggers, branches = {}, {}
        for i, mc in ipairs(miniCanvases) do
            local acts = mc:toActions()
            local sub = {}
            if acts[1] and CanvasUI.isHat(acts[1].type) then
                local hat = table.remove(acts, 1)
                sub.event = eventForHat(hat)
                for k, v in pairs(hat) do
                    if k ~= "type" and k ~= "event" then sub[k] = v end
                end
            end
            triggers[i] = sub
            branches[i] = acts
        end
        orBlock.params.triggers = triggers
        orBlock.params.branches = branches
        if orBlock._refreshAndLabel then orBlock._refreshAndLabel() end
        if draft and canvas then draft.actions = canvas:toActions() end
        closeModal()
    end)
end

-- ---------- AND branch editor (sub-modal) ----------
-- Click on an AND block's branch button -> open this modal. Two mini Canvas
-- instances, one per branch, each with its own palette. Save serializes
-- branch contents back into andBlock.params.branches. Cancel discards.
local function openBranchEditor(andBlock)
    local modal = Instance.new("Frame")
    modal.Size = UDim2.new(1, -16, 1, -52)
    modal.Position = UDim2.fromOffset(8, 44)
    modal.BackgroundColor3 = theme.bg; modal.BorderSizePixel = 0
    modal.ZIndex = 200; modal.Parent = rootFrame
    corner(modal, 8); stroke(modal, theme.accent, 2)

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -20, 0, 26); title.Position = UDim2.fromOffset(10, 6)
    title.BackgroundTransparency = 1
    title.Text = "AND step - configure parallel branches"
    title.TextColor3 = theme.fg; title.Font = theme.fontBold; title.TextSize = 14
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.ZIndex = 201; title.Parent = modal

    local hint = Instance.new("TextLabel")
    hint.Size = UDim2.new(1, -20, 0, 16); hint.Position = UDim2.fromOffset(10, 32)
    hint.BackgroundTransparency = 1
    hint.Text = "Each branch runs in parallel; the AND finishes when both branches do."
    hint.TextColor3 = theme.fgDim; hint.Font = theme.font; hint.TextSize = 11
    hint.TextXAlignment = Enum.TextXAlignment.Left
    hint.ZIndex = 201; hint.Parent = modal

    local scroll = Instance.new("ScrollingFrame")
    scroll.Size = UDim2.new(1, -20, 1, -88); scroll.Position = UDim2.fromOffset(10, 54)
    scroll.BackgroundTransparency = 1; scroll.BorderSizePixel = 0
    scroll.ScrollBarThickness = 4; scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y; scroll.ZIndex = 201; scroll.Parent = modal
    local scrollLay = Instance.new("UIListLayout", scroll); scrollLay.Padding = UDim.new(0, 8); scrollLay.SortOrder = Enum.SortOrder.LayoutOrder

    local miniCanvases = {}

    -- Helper: make a "Branch N" section with its own header + mini canvas +
    -- palette of draggable blocks. Mini canvases reuse the same CanvasUI
    -- class so drag/snap/trash all work identically; their onChange writes
    -- back into the AND block's branches array at save-time.
    local function makeBranchSection(idx)
        local sec = Instance.new("Frame")
        sec.Size = UDim2.new(1, 0, 0, 0); sec.AutomaticSize = Enum.AutomaticSize.Y
        sec.BackgroundTransparency = 1; sec.LayoutOrder = idx; sec.Parent = scroll
        local secLay = Instance.new("UIListLayout", sec); secLay.Padding = UDim.new(0, 4); secLay.SortOrder = Enum.SortOrder.LayoutOrder

        local hdr = Instance.new("TextLabel")
        hdr.Size = UDim2.new(1, 0, 0, 20); hdr.BackgroundTransparency = 1
        hdr.Text = "Branch " .. idx; hdr.TextColor3 = theme.accent
        hdr.Font = theme.fontBold; hdr.TextSize = 12
        hdr.TextXAlignment = Enum.TextXAlignment.Left
        hdr.LayoutOrder = 1; hdr.Parent = sec

        -- Palette inside the branch section, scoped to its mini canvas.
        local pal = Instance.new("Frame")
        pal.Size = UDim2.new(1, 0, 0, 0); pal.AutomaticSize = Enum.AutomaticSize.Y
        pal.BackgroundTransparency = 1; pal.LayoutOrder = 2; pal.Parent = sec
        local pl = Instance.new("UIGridLayout", pal)
        pl.CellSize = UDim2.new(0, 84, 0, 32); pl.CellPadding = UDim2.new(0, 4, 0, 4)

        local mc = CanvasUI.new(sec, {})
        mc.frame.LayoutOrder = 3
        mc.editUseMoveRequested:Connect(function(b) openUseMoveEditor(b) end)
        if andBlock.params.branches and andBlock.params.branches[idx] then
            mc:loadActions(andBlock.params.branches[idx])
        end
        miniCanvases[idx] = mc

        local function defaultParamsFor(t)
            if t == "look" then return { x = 180, y = 0 }
            elseif t == "rotate" then return { x = 180 }
            elseif t == "wait" then return { seconds = 0.5 }
            elseif t == "within" then return { studs = 5 }
            end
            return {}
        end

        for _, t in ipairs({ "look", "rotate", "wait", "within", "return", "feature", "key", "usebtn" }) do
            local c = colorOf(t)
            local b = Instance.new("TextButton")
            b.BackgroundColor3 = Color3.fromRGB(math.floor(c.R*255*0.78), math.floor(c.G*255*0.78), math.floor(c.B*255*0.78))
            b.AutoButtonColor = true; b.TextColor3 = theme.fg
            b.Font = theme.fontBold; b.TextSize = 12
            b.Text = "+ " .. (STEP_LABEL[t] or t); b.Parent = pal
            corner(b, 8)
            b.MouseButton1Click:Connect(function()
                mc:addBlock(t, defaultParamsFor(t))
            end)
        end
    end

    makeBranchSection(1)
    makeBranchSection(2)

    -- Save / Cancel buttons at the bottom of the modal.
    local btnRow = Instance.new("Frame")
    btnRow.Size = UDim2.new(1, -20, 0, 28); btnRow.Position = UDim2.new(0, 10, 1, -34)
    btnRow.BackgroundTransparency = 1; btnRow.ZIndex = 201; btnRow.Parent = modal
    local rowL = Instance.new("UIListLayout", btnRow); rowL.FillDirection = Enum.FillDirection.Horizontal
    rowL.HorizontalAlignment = Enum.HorizontalAlignment.Right; rowL.Padding = UDim.new(0, 8)

    -- Tear down both mini canvases (drag conns + frames) and then drop
    -- the modal. Called from both Save and Cancel so the cleanup is the
    -- same regardless of which button closed the dialog.
    local function closeModal()
        for _, mc in ipairs(miniCanvases) do pcall(function() mc:destroy() end) end
        modal:Destroy()
    end

    local cancel = Instance.new("TextButton")
    cancel.Size = UDim2.fromOffset(80, 26); cancel.BackgroundColor3 = theme.bgAlt
    cancel.AutoButtonColor = false; cancel.TextColor3 = theme.fg
    cancel.Font = theme.font; cancel.TextSize = 12; cancel.Text = "Cancel"
    cancel.LayoutOrder = 1; cancel.ZIndex = 202; cancel.Parent = btnRow
    corner(cancel, 4)
    cancel.MouseButton1Click:Connect(closeModal)

    local save = Instance.new("TextButton")
    save.Size = UDim2.fromOffset(80, 26); save.BackgroundColor3 = theme.accent
    save.AutoButtonColor = false; save.TextColor3 = theme.fg
    save.Font = theme.fontBold; save.TextSize = 12; save.Text = "Save"
    save.LayoutOrder = 2; save.ZIndex = 202; save.Parent = btnRow
    corner(save, 4)
    save.MouseButton1Click:Connect(function()
        andBlock.params.branches = {
            miniCanvases[1]:toActions(),
            miniCanvases[2]:toActions(),
        }
        if andBlock._refreshAndLabel then andBlock._refreshAndLabel() end
        if draft and canvas then draft.actions = canvas:toActions() end
        closeModal()
    end)
end

-- ---------- form (left pane) ----------
rebuild = function()
    for _, c in ipairs(formScroll:GetChildren()) do
        -- Preserve the Scratch canvas container so the user's placed blocks
        -- survive a form re-render (toggling event type / scope must not
        -- wipe in-progress tech building). LayoutOrder is reset below when
        -- place() reaches the canvas section.
        if not c:IsA("UIListLayout") and c ~= canvasContainer then c:Destroy() end
    end
    local ord = 0
    local function place(inst) ord = ord + 1; inst.LayoutOrder = ord; inst.Parent = formScroll; return inst end

    place(textRow(formScroll, "Name", draft.name, function(t) draft.name = t end))
    -- Scope: This Game / This Character / Universal. "This Character" pins the
    -- name detected by the active per-game module (so the tech only triggers
    -- when you're playing as that character); when no char is detectable, the
    -- cycle hides the option and falls back to This Game on save.
    do
        local detectedChar = detectCurrentCharacter()
        local pinned = draft.pinChar
        local labels = { "This Game" }
        local keys   = { "game" }
        if detectedChar or pinned then
            local cn = pinned or detectedChar
            labels[#labels + 1] = "This Char (" .. tostring(cn) .. ")"
            keys[#keys + 1] = "char"
        end
        labels[#labels + 1] = "Universal"
        keys[#keys + 1] = "universal"
        local idx = 1
        for i, k in ipairs(keys) do if draft.scope == k then idx = i end end
        if not (draft.scope == "char" and (detectedChar or pinned)) and draft.scope ~= "universal" then idx = 1 end
        place(cycleRow(formScroll, "Scope", labels, idx, function(i)
            draft.scope = keys[i]
            if keys[i] == "char" then
                draft.pinChar = pinned or detectedChar
            else
                draft.pinChar = nil
            end
            rebuild()
        end))
    end

    -- Trigger lives on the canvas as a hat block now (V3.1). The legacy
    -- in-form trigger UI is gone -- drag a "When ..." block from the
    -- palette and click its inline summary to configure. The block below
    -- (suppress/modkey/hold/anim-picker/move-picker etc.) used to live
    -- here and is preserved only behind `false` so a future merge can
    -- compare; the hat-block modal in openHatEditor covers all of it.
    if false then  -- legacy form trigger UI (disabled; hat block replaces it)
    if draft.event == "anim" then
        -- bind to a played animation via a collapsible dropdown, Capture, or paste.
        local hist = engine.animHistory()
        local selLabel = "(pick an animation)"
        if draft.animId then
            for _, h in ipairs(hist) do if tostring(h.id) == tostring(draft.animId) then selLabel = h.label end end
            if selLabel == "(pick an animation)" then selLabel = "anim " .. tostring(draft.animId) end
        end
        place(wrap(28, function(p)
            local b = Instance.new("TextButton")
            b.Size = UDim2.new(1, 0, 0, 26); b.BackgroundColor3 = theme.bgDark; b.AutoButtonColor = true
            b.TextColor3 = theme.fg; b.Font = theme.font; b.TextSize = 12
            b.TextXAlignment = Enum.TextXAlignment.Left; b.TextTruncate = Enum.TextTruncate.AtEnd
            b.Text = "  " .. selLabel .. (animDropOpen and "    [x]" or "    [v]"); b.Parent = p; corner(b, 4)
            b.MouseButton1Click:Connect(function() animDropOpen = not animDropOpen; rebuild() end)
        end))
        if animDropOpen then
          if #hist == 0 then
            place(components.Label(formScroll, "(none yet - play your moves, or hit Capture below)"))
          else
            place(components.Label(formScroll, "click=preview, double-click=select"))
            place(wrap(24, function(p)
                local cb = Instance.new("TextButton")
                cb.Size = UDim2.new(1, 0, 0, 22); cb.BackgroundColor3 = theme.bgAlt; cb.AutoButtonColor = true
                cb.TextColor3 = theme.danger; cb.Font = theme.font; cb.TextSize = 11
                cb.Text = "Clear logged anims (" .. #hist .. ")"; cb.Parent = p; corner(cb, 4)
                cb.MouseButton1Click:Connect(function() engine.clearAnimHistory(); rebuild() end)
            end))
            local n = math.min(#hist, 7)
            local listWrap = Instance.new("Frame")
            listWrap.Size = UDim2.new(1, 0, 0, n * 24 + 4); listWrap.BackgroundColor3 = theme.bgDark
            listWrap.BorderSizePixel = 0; corner(listWrap, 4)
            local sf = Instance.new("ScrollingFrame")
            sf.Size = UDim2.new(1, -4, 1, -4); sf.Position = UDim2.fromOffset(2, 2)
            sf.BackgroundTransparency = 1; sf.BorderSizePixel = 0; sf.ScrollBarThickness = 4
            sf.CanvasSize = UDim2.new(0, 0, 0, 0); sf.AutomaticCanvasSize = Enum.AutomaticSize.Y; sf.Parent = listWrap
            local sl = Instance.new("UIListLayout", sf); sl.Padding = UDim.new(0, 2); sl.SortOrder = Enum.SortOrder.LayoutOrder
            for hi, h in ipairs(hist) do
                local row = Instance.new("TextButton")
                row.Size = UDim2.new(1, 0, 0, 22); row.AutoButtonColor = true; row.LayoutOrder = hi
                row.BackgroundColor3 = (tostring(draft.animId) == tostring(h.id)) and theme.accent or theme.bgAlt
                row.TextColor3 = theme.fg; row.Font = theme.font; row.TextSize = 11
                row.TextXAlignment = Enum.TextXAlignment.Left; row.TextTruncate = Enum.TextTruncate.AtEnd
                row.Text = "  " .. (h.label or tostring(h.id)) .. "  (" .. tostring(h.id) .. ")"; row.Parent = sf
                -- single click = audition in the preview; double click = fully select
                local lastClick = 0
                row.MouseButton1Click:Connect(function()
                    playAnimOnRig(h.id, true)   -- preview (looped) on every click
                    if os.clock() - lastClick < 0.35 then
                        draft.animId = tostring(h.id)   -- commit the selection
                        animDropOpen = false            -- collapse the dropdown on select
                        rebuild()
                    end
                    lastClick = os.clock()
                end)
            end
            place(listWrap)
          end
        end
        -- fire when the animation ENDS instead of when it starts
        place(wrap(30, function(p) components.Toggle(p, { text = "Fire on animation END (not start)",
            default = draft.animEnd == true,
            onChange = function(v) draft.animEnd = v or nil end }) end))
        place(wrap(28, function(p)
            local b = Instance.new("TextButton")
            b.Size = UDim2.new(1, 0, 0, 24); b.BackgroundColor3 = theme.bgDark; b.AutoButtonColor = true
            b.TextColor3 = theme.accent; b.Font = theme.fontBold; b.TextSize = 12
            b.Text = "Capture (play the move now)"; b.Parent = p; corner(b, 4)
            b.MouseButton1Click:Connect(function()
                b.Text = "Capturing... play the move now"
                pcall(function() notify.info("Capturing -- play the move now", 3) end)
                engine.captureAnim(function(raw)
                    draft.animId = tostring(raw):match("%d+") or tostring(raw)
                    animDropOpen = false
                    pcall(function() notify.success("Captured anim " .. tostring(draft.animId)) end)
                    rebuild()
                end)
            end)
        end))
        place(textRow(formScroll, "Or paste ID", draft.animId, function(t)
            local id = t and t:match("%d+")
            draft.animId = id or (t ~= "" and t) or nil
        end))
    elseif draft.event == "target_anim" then
        -- mirror of the anim branch but the picker uses the TARGET'S anim
        -- history (Engine.targetAnimHistory) and Capture binds via captureTarget
        -- Anim, so you bind to an opponent's animation. Falls back to a paste
        -- box if you haven't seen any target anims yet (no lock-on / Target
        -- Select target ever held during this session).
        local hist = engine.targetAnimHistory and engine.targetAnimHistory() or {}
        place(components.Label(formScroll, "Hint: lock onto an opponent so their played anims show up below."))
        place(wrap(28, function(p)
            local b = Instance.new("TextButton")
            b.Size = UDim2.new(1, 0, 0, 24); b.BackgroundColor3 = theme.bgDark; b.AutoButtonColor = true
            b.TextColor3 = theme.accent; b.Font = theme.fontBold; b.TextSize = 12
            b.Text = "Capture target anim (play it on the opponent)"; b.Parent = p; corner(b, 4)
            b.MouseButton1Click:Connect(function()
                b.Text = "Capturing... bait the move on opponent"
                pcall(function() notify.info("Capturing target anim", 4) end)
                if engine.captureTargetAnim then
                    engine.captureTargetAnim(function(raw)
                        draft.animId = tostring(raw):match("%d+") or tostring(raw)
                        pcall(function() notify.success("Captured target anim " .. tostring(draft.animId)) end)
                        rebuild()
                    end)
                end
            end)
        end))
        place(textRow(formScroll, "Or paste ID", draft.animId, function(t)
            local id = t and t:match("%d+")
            draft.animId = id or (t ~= "" and t) or nil
        end))
        if #hist > 0 then
            place(components.Label(formScroll, "Recently seen on target (click=set):"))
            local n = math.min(#hist, 7)
            local sf = Instance.new("ScrollingFrame")
            sf.Size = UDim2.new(1, 0, 0, n * 22 + 4); sf.BackgroundColor3 = theme.bgDark
            sf.BorderSizePixel = 0; sf.ScrollBarThickness = 4
            sf.CanvasSize = UDim2.new(0, 0, 0, 0); sf.AutomaticCanvasSize = Enum.AutomaticSize.Y
            corner(sf, 4)
            local sl = Instance.new("UIListLayout", sf); sl.Padding = UDim.new(0, 2)
            for hi, h in ipairs(hist) do
                local row = Instance.new("TextButton")
                row.Size = UDim2.new(1, 0, 0, 20); row.LayoutOrder = hi
                row.BackgroundColor3 = (tostring(draft.animId) == tostring(h.id)) and theme.accent or theme.bgAlt
                row.TextColor3 = theme.fg; row.Font = theme.font; row.TextSize = 11
                row.TextXAlignment = Enum.TextXAlignment.Left; row.TextTruncate = Enum.TextTruncate.AtEnd
                row.Text = "  " .. (h.label or tostring(h.id)) .. "  (" .. tostring(h.id) .. ")"
                row.Parent = sf
                row.MouseButton1Click:Connect(function()
                    draft.animId = tostring(h.id); rebuild()
                end)
            end
            place(sf)
        end
        place(wrap(30, function(p) components.Toggle(p, { text = "Fire on animation END (not start)",
            default = draft.animEnd == true,
            onChange = function(v) draft.animEnd = v or nil end }) end))
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
                if moveset[1].key and not draft.movekey then draft.movekey = keyNameNorm(moveset[1].key) end
            end
            local idx = 1
            for i, b in ipairs(moveset) do if b.name == draft.move then idx = i end end
            place(cycleRow(formScroll, "Move", labels, idx, function(i)
                draft.move = moveset[i].name
                if moveset[i].key then draft.movekey = keyNameNorm(moveset[i].key) end
                rebuild()
            end))
            place(wrap(28, function(p)
                local def = toKeyCode(draft.movekey) or Enum.KeyCode.Unknown
                components.KeybindSetter(p, { label = "Move key", default = def,
                    onChange = function(k)
                        draft.movekey = (k and k ~= Enum.KeyCode.Unknown) and (tostring(k):gsub("Enum.KeyCode.", "")) or nil
                    end })
            end))
        end
    else
        place(wrap(28, function(p)
            components.KeybindSetter(p, { label = "Key", default = draft.key, onChange = function(k) draft.key = k end })
        end))
    end
    -- optional modifier that must be HELD for the trigger to fire (hold A + press Q)
    place(wrap(28, function(p)
        local def = toKeyCode(draft.modkey) or Enum.KeyCode.Unknown
        components.KeybindSetter(p, { label = "Hold-key (optional)", default = def,
            onChange = function(k)
                draft.modkey = (k and k ~= Enum.KeyCode.Unknown) and (tostring(k):gsub("Enum.KeyCode.", "")) or nil
            end })
    end))
    -- Block this key's normal action (key & move triggers): the engine sinks the
    -- key so the game can't fire its move -- only this tech runs (which can fire the
    -- move itself via a Use Move step). Pointless for an anim trigger.
    if draft.event ~= "anim" then
        place(wrap(30, function(p) components.Toggle(p, { text = "Block this key's normal action",
            default = draft.suppress == true,
            onChange = function(v) draft.suppress = v or nil end }) end))
    end
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
    place(wrap(30, function(p) components.Toggle(p, { text = "Trigger on TARGET's animation instead",
        default = draft.event == "target_anim",
        onChange = function(v) draft.event = v and "target_anim" or "key"; rebuild() end }) end))
    end   -- end of `if false then` legacy trigger UI block
    place(wrap(30, function(p) components.Toggle(p, { text = "Only while locked on",
        default = draft.conditions.locked_on == true,
        onChange = function(v) draft.conditions.locked_on = v or nil end }) end))
    -- "Within X studs" gate: pair with target_playing to get the
    -- "within 5 studs AND target plays anim X" check the user asked for.
    place(textRow(formScroll, "Within X studs (0=any)", tostring(draft.maxRange or 0), function(t)
        local n = tonumber(t); draft.maxRange = (n and n > 0) and n or nil
    end))
    -- target_playing condition: parametrized; the anim id lives separately
    -- from the trigger's animId so you can fire on one anim and gate on
    -- another. Empty id = no-op (condition auto-passes).
    place(wrap(30, function(p) components.Toggle(p, { text = "Only while target is playing an anim",
        default = draft.conditions.target_playing == true,
        onChange = function(v) draft.conditions.target_playing = v or nil; rebuild() end }) end))
    if draft.conditions.target_playing then
        place(textRow(formScroll, "  Target anim ID (gate)", draft.targetAnimId, function(t)
            local id = t and t:match("%d+")
            draft.targetAnimId = id or (t ~= "" and t) or nil
        end))
        place(wrap(28, function(p)
            local b = Instance.new("TextButton")
            b.Size = UDim2.new(1, 0, 0, 24); b.BackgroundColor3 = theme.bgDark; b.AutoButtonColor = true
            b.TextColor3 = theme.accent; b.Font = theme.fontBold; b.TextSize = 12
            b.Text = "  Capture (target plays the gate move now)"; b.Parent = p; corner(b, 4)
            b.MouseButton1Click:Connect(function()
                b.Text = "  Capturing gate anim..."
                pcall(function() notify.info("Capturing target anim (gate)", 4) end)
                if engine.captureTargetAnim then
                    engine.captureTargetAnim(function(raw)
                        draft.targetAnimId = tostring(raw):match("%d+") or tostring(raw)
                        rebuild()
                    end)
                end
            end)
        end))
    end
    -- keep Lock-On / Rotation alive even while welded (grabs normally suppress them)
    place(wrap(30, function(p) components.Toggle(p, { text = "Ignore welds (keep Lock-On while grabbed)",
        default = draft.ignoreWelds == true,
        onChange = function(v) draft.ignoreWelds = v or nil end }) end))

    place(components.Section(formScroll, "Steps - drag from palette into canvas"))
    -- Scratch canvas section. The container Frame holds:
    --   * a horizontal palette of draggable block sources (top)
    --   * the CanvasUI itself (below) -- absolute-positioned blocks, drag +
    --     snap-to-connect, save back to draft.actions on change.
    -- The container is created ONCE per Builder.open lifecycle and
    -- preserved across rebuild() calls so user-placed blocks survive form
    -- re-renders (toggling event type re-runs rebuild but must not wipe
    -- the user's tech progress). LayoutOrder is reset each rebuild.
    if not canvasContainer then
        canvasContainer = Instance.new("Frame")
        canvasContainer.Size = UDim2.new(1, 0, 0, 0)
        canvasContainer.AutomaticSize = Enum.AutomaticSize.Y
        canvasContainer.BackgroundTransparency = 1
        canvasContainer.Parent = formScroll

        local stack = Instance.new("UIListLayout", canvasContainer)
        stack.SortOrder = Enum.SortOrder.LayoutOrder
        stack.Padding = UDim.new(0, 6)

        -- Palette row: tap to spawn at top of canvas, OR drag to drop at a
        -- specific canvas-local position. Drag is the primary "scratch
        -- feel"; tap remains as a one-click shortcut.
        local palette = Instance.new("Frame")
        palette.Size = UDim2.new(1, 0, 0, 0); palette.AutomaticSize = Enum.AutomaticSize.Y
        palette.BackgroundTransparency = 1; palette.LayoutOrder = 1; palette.Parent = canvasContainer
        local pl = Instance.new("UIGridLayout", palette)
        pl.CellSize = UDim2.new(0, 84, 0, 32); pl.CellPadding = UDim2.new(0, 4, 0, 4)
        pl.SortOrder = Enum.SortOrder.LayoutOrder

        local function defaultParamsFor(t)
            if t == "look" then return { x = 180, y = 0 }
            elseif t == "rotate" then return { x = 180 }
            elseif t == "wait" then return { seconds = 0.5 }
            elseif t == "within" then return { studs = 5 }
            elseif t == "feature" then local fa = feature.all(); return { feature = fa[1] and fa[1].id or nil }
            elseif t == "usebtn" then local res = scanner.cached() or scanner.scan(); local m = (res.buttons or {})[1]; return { move = m and m.name or nil }
            end
            return {}
        end

        -- Canvas itself (sits below palette in the container).
        canvas = CanvasUI.new(canvasContainer, {
            onChange = function() if draft then draft.actions = canvas:toActions() end end,
        })
        canvas.frame.LayoutOrder = 2

        -- Wire the AND-block branch editor: clicking an AND block's
        -- "[N branches] - click to edit" button on the main canvas fires
        -- editBranchesRequested with that block. We open a modal with one
        -- mini canvas per branch so each branch can be authored visually.
        -- AND and OR both fire editBranchesRequested; route to the right
        -- modal based on block.type.
        canvas.editBranchesRequested:Connect(function(block)
            if block.type == "or" then openOrEditor(block)
            else openBranchEditor(block) end
        end)

        -- Hat-block trigger editor: clicking a hat block's inline summary
        -- button fires editHatRequested with that block. Opens a per-type
        -- modal that edits the hat's trigger params in place; the hat's
        -- summary text refreshes on close and the draft re-syncs.
        canvas.editHatRequested:Connect(function(hatBlock) openHatEditor(hatBlock) end)

        -- Use Move block -> per-step config modal (move/key/fire method).
        canvas.editUseMoveRequested:Connect(function(block) openUseMoveEditor(block) end)

        -- Drag a palette button -> spawn a ghost that follows the mouse,
        -- and on release inside the canvas bounds, addBlock at the
        -- canvas-local coords so the block lands where the cursor was.
        -- (Drop outside canvas = no-op; ghost just disappears.) Click WITH
        -- no drag still works -- addBlock at canvas top so the existing
        -- click-to-add muscle memory keeps functioning.
        local function spawnDraggable(t)
            local c = colorOf(t)
            local b = Instance.new("TextButton")
            b.BackgroundColor3 = Color3.fromRGB(math.floor(c.R*255*0.78), math.floor(c.G*255*0.78), math.floor(c.B*255*0.78))
            b.AutoButtonColor = true; b.TextColor3 = theme.fg
            b.Font = theme.fontBold; b.TextSize = 12
            b.Text = "+ " .. (STEP_LABEL[t] or t); b.Parent = palette
            corner(b, 8)

            local clickStart, dragged, ghost, moveConn, endConn
            local function cleanup()
                if moveConn then moveConn:Disconnect(); moveConn = nil end
                if endConn  then endConn:Disconnect();  endConn  = nil end
                if ghost    then ghost:Destroy();       ghost    = nil end
            end
            b.InputBegan:Connect(function(input)
                if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
                clickStart = UIS:GetMouseLocation(); dragged = false

                moveConn = UIS.InputChanged:Connect(function(i)
                    if i.UserInputType ~= Enum.UserInputType.MouseMovement then return end
                    local m = UIS:GetMouseLocation()
                    if not dragged and (m - clickStart).Magnitude > 6 then
                        dragged = true
                        ghost = Instance.new("Frame")
                        ghost.Size = UDim2.fromOffset(180, 36)
                        ghost.BackgroundColor3 = colorOf(t)
                        ghost.BackgroundTransparency = 0.15
                        ghost.BorderSizePixel = 0; ghost.ZIndex = 5000
                        ghost.Parent = gui
                        corner(ghost, 10)
                        local gl = Instance.new("TextLabel")
                        gl.Size = UDim2.new(1, -16, 1, 0); gl.Position = UDim2.fromOffset(8, 0)
                        gl.BackgroundTransparency = 1; gl.Text = STEP_LABEL[t] or t
                        gl.TextColor3 = theme.fg; gl.Font = theme.fontBold; gl.TextSize = 13
                        gl.TextXAlignment = Enum.TextXAlignment.Left
                        gl.ZIndex = 5001; gl.Parent = ghost
                    end
                    if ghost then ghost.Position = UDim2.fromOffset(m.X - 90, m.Y - 18 - 36) end
                end)

                endConn = UIS.InputEnded:Connect(function(i)
                    if i.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
                    if dragged and canvas then
                        local m = UIS:GetMouseLocation()
                        local tl = canvas.frame.AbsolutePosition
                        local br = tl + canvas.frame.AbsoluteSize
                        if m.X >= tl.X and m.X <= br.X and m.Y >= tl.Y and m.Y <= br.Y then
                            local lx, ly = m.X - tl.X - 90, m.Y - tl.Y - 18
                            canvas:addBlock(t, defaultParamsFor(t), math.max(4, lx), math.max(4, ly))
                        end
                    elseif not dragged and canvas then
                        canvas:addBlock(t, defaultParamsFor(t))
                    end
                    cleanup()
                end)
            end)
        end

        -- Hat blocks first (yellow, the trigger). One per tech (V3.1); the
        -- canvas doesn't enforce uniqueness yet -- builder_ui's Save just
        -- takes the FIRST hat in toActions() as the trigger.
        for _, t in ipairs(CanvasUI.HAT_TYPES) do spawnDraggable(t) end
        for _, t in ipairs(ACTION_TYPES) do spawnDraggable(t) end
        -- AND palette entry too -- engine accepts type="and" but V1 doesn't
        -- yet support branch editing inside the block (placeholder text on
        -- the block; configure via nested editor in V2).
        spawnDraggable("and")
        -- OR palette entry (V3.2). Multi-trigger fork: drop the OR on the
        -- canvas, click its summary, configure each branch (trigger + its
        -- action chain) in the modal. Each branch wires its own subtrigger.
        spawnDraggable("or")

        -- initial load: hydrate from draft.actions
        canvas:loadActions(draft.actions)
    end
    place(canvasContainer)

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
        winDragConns[#winDragConns + 1] = UIS.InputChanged:Connect(function(i)
            if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
                local d = i.Position - dStart
                rootFrame.Position = UDim2.new(sPos.X.Scale, sPos.X.Offset + d.X, sPos.Y.Scale, sPos.Y.Offset + d.Y)
            end
        end)
        winDragConns[#winDragConns + 1] = UIS.InputEnded:Connect(function(i)
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
        -- Force a fresh hotbar scan every Open. The scanner caches a non-
        -- empty result for the session; on first Open the game's UI is
        -- often mid-build and we capture a stale snapshot (or worse, the
        -- pre-loadout one) which then survives every subsequent Open until
        -- script re-execute. Clearing forces re-scan against the LIVE PG.
        pcall(function() scanner.clearCache() end)
        draft = existingTech and draftFromTech(existingTech) or newDraft()
        animDropOpen = not (draft.animId)   -- expanded when nothing's picked yet
        -- Discard the canvas from a prior session if it exists. Use the
        -- explicit Canvas:destroy() to disconnect each block's UIS drag
        -- conns -- a bare Frame:Destroy() leaves the UIS connections
        -- registered (they internally check `dragging` and no-op, but
        -- they still fire on every mouse move + accumulate per re-open).
        if canvas then pcall(function() canvas:destroy() end); canvas = nil end
        if canvasContainer then pcall(function() canvasContainer:Destroy() end); canvasContainer = nil end
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
    if curTrack then pcall(function() curTrack:Stop(0) end); curTrack = nil end
    if curRig then pcall(function() curRig:Destroy() end); curRig = nil end
    -- Drop the canvas on close too -- next Open rebuilds fresh. Canvas:
    -- destroy() before the container Destroy() to disconnect drag conns.
    if canvas then pcall(function() canvas:destroy() end); canvas = nil end
    if canvasContainer then pcall(function() canvasContainer:Destroy() end); canvasContainer = nil end
end

function Builder.destroy()
    for _, c in ipairs(winDragConns) do pcall(function() c:Disconnect() end) end
    winDragConns = {}
    if curTrack then pcall(function() curTrack:Stop(0) end); curTrack = nil end
    if curRig then pcall(function() curRig:Destroy() end); curRig = nil end
    if rigTemplate then pcall(function() rigTemplate:Destroy() end); rigTemplate = nil end
    if gui then pcall(function() gui:Destroy() end); gui = nil end
end

return Builder
