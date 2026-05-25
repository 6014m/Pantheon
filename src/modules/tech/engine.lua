-- Tech Builder engine.
--
-- A "tech" = a TRIGGER (event + conditions) -> an ordered list of ACTIONS. The
-- engine is data-driven and extensible: EVENTS, CONDITIONS and ACTIONS are open
-- registries so new types drop in without reworking the runner.
--
--   trigger = { event = "key"|"keyhold"|"move", key = KeyCode, move = "ServiceName",
--               conditions = { "locked_on", ... } }
--   actions = { {type="look", x=180,y=0,z=0}, {type="wait", seconds=0.5}, {type="return"},
--               {type="rotate", x=180}, {type="feature", feature="aim.rotation_lock", value=true} }
--
-- Look/Rotate are TARGET-RELATIVE (yaw 0 = at the lock target, 180 = facing away),
-- ported from the lock-on script's reverse-lock. While a Look/Rotate step is held,
-- the engine sets state.techCamOverride / techBodyOverride so Lock-On / Rotation
-- Lock yield; Return clears them and hands control back (re-aims at the target).

local state    = require("modules.aim.state")
local feature  = require("ui.feature")
local keybinds = require("core.keybinds")
local persist  = require("core.persist")
local log      = require("core.log")
local Signal   = require("core.signal")
local scanner  = require("modules.tech.scanner")

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace  = game:GetService("Workspace")
local RS         = game:GetService("ReplicatedStorage")
local VIM        = game:GetService("VirtualInputManager")
local UIS        = game:GetService("UserInputService")
local CAS        = game:GetService("ContextActionService")

local Engine = {}
Engine.changed = Signal.new()   -- fires when the tech set changes (UI list re-reads it)
local LP = Players.LocalPlayer

local techs = {}     -- id -> tech def
local conns = {}     -- id -> { Connection, ... } (move-trigger listeners)
local casBound = {}  -- id -> CAS action name (suppress move triggers that sink the key)
local RENDER_BIND = "PantheonTechHold"
local bound = false
local drainConn      -- Heartbeat that runs queued techs off the trigger signal thread

-- held camera/body facings; the render loop enforces these each frame while set.
local held = { cam = nil, body = nil }   -- each = { yaw, pitch } degrees, target-relative
local startCamLook                        -- camera LookVector at tech start (no-target fallback)
local startBodyLook                        -- root LookVector at tech start (no-target fallback)
local bodyARDisabled = false              -- did a Rotate step turn off Humanoid.AutoRotate?
local techAlign, techAttach               -- rigid AlignOrientation body-rotate (same type as Lock-On+)

-- ===== geometry =====
local function myChar() return LP.Character end
local function myRoot() local c = myChar(); return c and c:FindFirstChild("HumanoidRootPart") end
local function targetRoot()
    local t = state.target
    if not t then return nil end
    local ch = (state.target_type == "npc") and t or t.Character
    return ch and ch:FindFirstChild("HumanoidRootPart")
end

local function offsetDir(baseFlat, yawDeg)
    if baseFlat.Magnitude < 1e-3 then return baseFlat end
    return (CFrame.fromAxisAngle(Vector3.yAxis, math.rad(yawDeg or 0)) * baseFlat).Unit
end

local function camBaseFlat()
    local cam = Workspace.CurrentCamera
    local tr = targetRoot()
    if tr and cam then local d = tr.Position - cam.CFrame.Position; return Vector3.new(d.X, 0, d.Z) end
    if startCamLook then return Vector3.new(startCamLook.X, 0, startCamLook.Z) end
    return cam and Vector3.new(cam.CFrame.LookVector.X, 0, cam.CFrame.LookVector.Z) or Vector3.zAxis
end

local function bodyBaseFlat()
    local r, tr = myRoot(), targetRoot()
    if r and tr then local d = tr.Position - r.Position; return Vector3.new(d.X, 0, d.Z) end
    -- No target: anchor to the facing CAPTURED AT TECH START, not the live LookVector.
    -- Re-reading the live look each frame compounds the yaw -> the body spins.
    if startBodyLook then return Vector3.new(startBodyLook.X, 0, startBodyLook.Z) end
    if r then local l = r.CFrame.LookVector; return Vector3.new(l.X, 0, l.Z) end
    return Vector3.zAxis
end

-- Lock-On+ (rotation_lock) faces the body with a rigid AlignOrientation; the
-- Rotate action reuses that exact mechanism (its own instance so it doesn't fight
-- rotation_lock's) for identical feel/replication instead of a raw CFrame snap.
local function ensureBodyConstraint(root)
    if not techAttach or not techAttach.Parent then
        techAttach = Instance.new("Attachment")
        techAttach.Name = "PantheonTechAlignAtt"
        techAttach.Parent = root
    end
    if not techAlign or not techAlign.Parent then
        techAlign = Instance.new("AlignOrientation")
        techAlign.Name = "PantheonTechAlign"
        techAlign.Mode = Enum.OrientationAlignmentMode.OneAttachment
        techAlign.Attachment0 = techAttach
        techAlign.RigidityEnabled = true
        techAlign.Responsiveness = 200
        techAlign.MaxTorque = math.huge
        techAlign.Parent = root
    end
end

local function renderHold()
    if held.cam then
        local cam = Workspace.CurrentCamera
        local base = camBaseFlat()
        if cam and base.Magnitude > 1e-3 then
            local dir = offsetDir(base, held.cam.yaw)
            local pitch = math.rad(held.cam.pitch or 0)
            local look = Vector3.new(dir.X * math.cos(pitch), math.sin(pitch), dir.Z * math.cos(pitch))
            cam.CFrame = CFrame.new(cam.CFrame.Position, cam.CFrame.Position + look)
        end
    end
    if held.body then
        local root = myRoot()
        local base = bodyBaseFlat()
        if root and base.Magnitude > 1e-3 then
            -- stop the humanoid auto-rotating back while we hold the facing
            local ch = myChar()
            local hum = ch and ch:FindFirstChildOfClass("Humanoid")
            if hum and hum.AutoRotate then hum.AutoRotate = false; bodyARDisabled = true end
            local dir = offsetDir(base, held.body.yaw)
            -- same rotation type as Lock-On+: rigid AlignOrientation + CFrame nudge
            ensureBodyConstraint(root)
            techAlign.Enabled = true
            techAlign.CFrame = CFrame.lookAt(Vector3.zero, dir)
            local cf = CFrame.lookAt(root.Position, root.Position + dir)
            local _, yAngle = cf:ToEulerAnglesYXZ()
            root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, yAngle, 0)
        end
    end
end

local function releaseHold()
    held.cam, held.body = nil, nil
    state.techCamOverride = false
    state.techBodyOverride = false
    -- hand auto-rotate back if a Rotate step took it (lockon/shiftlock re-manage
    -- it next frame if they're active, since the override flags are now clear).
    if bodyARDisabled then
        local ch = myChar()
        local hum = ch and ch:FindFirstChildOfClass("Humanoid")
        if hum then hum.AutoRotate = true end
        bodyARDisabled = false
    end
    if techAlign then techAlign.Enabled = false end
    -- no Lock-On to re-aim us? snap the camera back to where we started.
    if not (state.lockon_enabled and state.target) and startCamLook then
        local cam = Workspace.CurrentCamera
        if cam then cam.CFrame = CFrame.new(cam.CFrame.Position, cam.CFrame.Position + startCamLook) end
    end
end

-- ===== actions =====
local ACTIONS = {}
ACTIONS.look   = function(a) held.cam  = { yaw = a.x or 0, pitch = a.y or 0 }; state.techCamOverride  = true end
ACTIONS.rotate = function(a) held.body = { yaw = a.x or 0, pitch = a.y or 0 }; state.techBodyOverride = true end
ACTIONS.wait   = function(a) task.wait(a.seconds or a.x or 0.5) end
ACTIONS["return"] = function() releaseHold() end
ACTIONS.feature = function(a)
    if a.value == nil then feature.fire(a.feature) else feature.setEnabled(a.feature, a.value) end
end
-- send a real keyboard key (a.key is the short name, e.g. "R"), so a tech can
-- press keys -- e.g. fire a game move via its keybind, dash, jump, etc.
ACTIONS.key = function(a)
    local kc = a.key and Enum.KeyCode[a.key]
    if not kc then return end
    VIM:SendKeyEvent(true, kc, false, game)
    task.wait(tonumber(a.hold) or 0.04)
    VIM:SendKeyEvent(false, kc, false, game)
end
Engine.ACTIONS = ACTIONS

-- ===== conditions =====
local CONDITIONS = {}
CONDITIONS.locked_on = function() return state.target ~= nil end
CONDITIONS.shiftlock = function() return state.shiftlock_active == true end
Engine.CONDITIONS = CONDITIONS

-- A move key hint can be a DIGIT ("1".."9") but Enum.KeyCode["1"] THROWS (the
-- member is "One"). Map digits to names and look up safely so a numbered move key
-- never errors out wiring/dispatch.
local DIGIT_NAMES = { ["0"]="Zero",["1"]="One",["2"]="Two",["3"]="Three",["4"]="Four",
                      ["5"]="Five",["6"]="Six",["7"]="Seven",["8"]="Eight",["9"]="Nine" }
local function safeKeyCode(name)
    if not name then return nil end
    name = DIGIT_NAMES[tostring(name)] or name
    local ok, kc = pcall(function() return Enum.KeyCode[name] end)
    return ok and kc or nil
end

-- optional modifier key that must be HELD for a key/move trigger to fire
-- (e.g. hold A + press Q). trigger.modkey is the short key name, or nil.
local function modifierHeld(tech)
    local m = tech.trigger and tech.trigger.modkey
    if not m then return true end
    local kc = safeKeyCode(m)
    return kc ~= nil and UIS:IsKeyDown(kc)
end

local function conditionsMet(tech)
    for _, c in ipairs(tech.trigger.conditions or {}) do
        local fn = CONDITIONS[c]
        if fn and not fn() then return false end
    end
    -- distance gate: only fire within maxRange studs of the target (0/nil = any).
    -- Needs a target (lock-on / target select); fails closed if there's none.
    local maxR = tonumber(tech.trigger.maxRange)
    if maxR and maxR > 0 then
        local mr, tr = myRoot(), targetRoot()
        if not (mr and tr) then return false end
        if (tr.Position - mr.Position).Magnitude > maxR then return false end
    end
    return true
end

-- ===== move buttons: fire + suppress =====
-- Resolve a hotbar move button by the name the scanner recorded for it (e.g. TSB
-- slot "1"). Re-scans so it tracks the live GUI.
local function findMoveButton(name)
    if not name then return nil end
    local ok, res = pcall(function() return scanner.scan() end)
    if not ok or not res then return nil end
    for _, b in ipairs(res.buttons or {}) do
        if b.name == name and b.button and b.button.Parent then return b.button end
    end
    return nil
end

-- executor connection helpers (Wave: getconnections/firesignal). Used to "cancel"
-- a move button's own click handlers so its key/click no longer fires the move,
-- and to fire it ourselves on demand.
local suppressed = {}   -- [button] = { connection, ... } we've disabled
local function getConns(sig)
    if typeof(getconnections) ~= "function" then return nil end
    local ok, r = pcall(getconnections, sig)
    if ok and type(r) == "table" then return r end
    return nil
end
local function suppressButton(btn)
    if not btn or suppressed[btn] then return end
    local cs = getConns(btn.Activated); if not cs then return end
    for _, c in ipairs(cs) do pcall(function() c:Disable() end) end
    suppressed[btn] = cs
end
local function unsuppressButton(btn)
    local cs = suppressed[btn]; if not cs then return end
    for _, c in ipairs(cs) do pcall(function() c:Enable() end) end
    suppressed[btn] = nil
end

-- Fire the click signal a button ACTUALLY has handlers on -- firing an empty signal
-- "succeeds" but does nothing, so we must check getconnections first and pick the
-- live one (Activated / MouseButton1Click / MouseButton1Down+Up). Returns true if
-- something was actually fired.
local function fireSignalsOf(b)
    if typeof(firesignal) ~= "function" then return false end
    -- Action move buttons fire on PRESS, and the MouseButton1Down/Up handlers take
    -- (x, y), so pass the button center. Try down(+up) FIRST (TSB fires here -- a
    -- prior build fired Click and nothing happened), then click, then activated.
    local cx = b.AbsolutePosition.X + b.AbsoluteSize.X / 2
    local cy = b.AbsolutePosition.Y + b.AbsoluteSize.Y / 2
    local down = getConns(b.MouseButton1Down)
    if down and #down > 0 then
        pcall(firesignal, b.MouseButton1Down, cx, cy)
        local up = getConns(b.MouseButton1Up)
        if up and #up > 0 then pcall(firesignal, b.MouseButton1Up, cx, cy) end
        return true
    end
    local click = getConns(b.MouseButton1Click)
    if click and #click > 0 then pcall(firesignal, b.MouseButton1Click); return true end
    local act = getConns(b.Activated)
    if act and #act > 0 then pcall(firesignal, b.Activated); return true end
    return false
end

-- Fire a move button as if clicked. If it's currently suppressed, briefly re-enable
-- its handlers so our fire lands, then re-suppress -- so a tech can be the ONLY
-- thing that fires a move whose key we've cancelled. Tries the button itself, then
-- any descendant button (the real handler is often on an inner "Base" button), then
-- a real mouse click as a last resort.
local function fireButton(btn)
    if not btn then return end
    local supp = suppressed[btn]
    if supp then for _, c in ipairs(supp) do pcall(function() c:Enable() end) end end
    local fired = fireSignalsOf(btn)
    if not fired then
        for _, c in ipairs(btn:GetDescendants()) do
            if (c:IsA("TextButton") or c:IsA("ImageButton")) and fireSignalsOf(c) then fired = true; break end
        end
    end
    if not fired then
        -- last resort: a real mouse click at the button's center (GuiInset offset)
        local p, s = btn.AbsolutePosition, btn.AbsoluteSize
        local x, y = p.X + s.X / 2, p.Y + s.Y / 2 + 36
        pcall(function()
            VIM:SendMouseButtonEvent(x, y, 0, true, game, 0)
            task.wait()
            VIM:SendMouseButtonEvent(x, y, 0, false, game, 0)
        end)
    end
    if supp then task.defer(function() for _, c in ipairs(supp) do pcall(function() c:Disable() end) end end) end
end

-- ACTION: fire a move via its GUI button (a.move = the scanned button name)
ACTIONS.usebtn = function(a) fireButton(findMoveButton(a.move)) end

-- Reconcile which move buttons should be "cancelled" right now: every ENABLED
-- move tech whose trigger has suppress=true cancels its move button. Buttons no
-- longer wanted get re-enabled. Best-effort -- needs getconnections + the button
-- to exist; called from rewire and re-tried when techs change.
function Engine.applySuppression()
    local want = {}
    for _, tech in pairs(techs) do
        local tr = tech.trigger
        if tech.enabled and tr and tr.event == "move" and tr.suppress then
            local b = findMoveButton(tr.move); if b then want[b] = true end
        end
    end
    for b in pairs(want) do suppressButton(b) end
    for b in pairs(suppressed) do if not want[b] then unsuppressButton(b) end end
end

-- ===== runner =====
-- Only one tech sequence drives the camera/body at a time. A second trigger
-- while one is mid-run (e.g. during a Wait) is ignored, so two techs can't fight
-- over the held facing. Hold techs run their (instant) actions and finish the
-- coroutine immediately, so `running` clears right away and re-pressing works.
local running = false
local function runTech(tech, hold)
    if running then return end
    running = true
    task.spawn(function()
        local cam = Workspace.CurrentCamera
        startCamLook = cam and cam.CFrame.LookVector or nil
        local r0 = myRoot()
        startBodyLook = r0 and r0.CFrame.LookVector or nil
        local releaseAfterWait = false
        local heldKeys = {}    -- keys pressed by a Hold step, released by a Release (or at the end)
        local featRestore = {} -- [featureId] = state BEFORE this tech toggled it, for Return/end
        local function restoreAll()
            releaseHold()
            for id, prev in pairs(featRestore) do pcall(function() feature.setEnabled(id, prev) end); featRestore[id] = nil end
            for kc in pairs(heldKeys) do pcall(function() VIM:SendKeyEvent(false, kc, false, game) end); heldKeys[kc] = nil end
        end
        for _, a in ipairs(tech.actions or {}) do
            if a.type == "during" then
                -- the preceding Look/Rotate lasts only as long as the NEXT Wait,
                -- then auto-returns (so "Rotate -> During -> Wait 0.5" rotates for
                -- exactly 0.5s).
                releaseAfterWait = true
            elseif a.type == "wait" then
                task.wait(a.seconds or a.x or 0.5)
                if releaseAfterWait then releaseHold(); releaseAfterWait = false end
            elseif a.type == "within" then
                -- gate: hold here until the target is within `studs`, then continue
                -- (e.g. rotate 90 -> Within 6 -> Use Rotation Lock -> side-dash).
                -- 6s cap so it can't hang if you never close the distance.
                local studs = tonumber(a.studs) or 5
                local t0 = os.clock()
                while os.clock() - t0 < 6 do
                    local mr, tr = myRoot(), targetRoot()
                    if mr and tr and (tr.Position - mr.Position).Magnitude <= studs then break end
                    task.wait(0.05)
                end
                -- a preceding During holds the look/rotate only until THIS gate clears
                if releaseAfterWait then releaseHold(); releaseAfterWait = false end
            elseif a.type == "hold" then
                -- press the key DOWN and keep it held until the matching Release
                -- (or the safety release at the end), so steps in between run while held.
                local kc = a.key and Enum.KeyCode[a.key]
                if kc then pcall(function() VIM:SendKeyEvent(true, kc, false, game) end); heldKeys[kc] = true end
            elseif a.type == "release" then
                local kc = a.key and Enum.KeyCode[a.key]
                if kc then pcall(function() VIM:SendKeyEvent(false, kc, false, game) end); heldKeys[kc] = nil end
            elseif a.type == "feature" then
                -- remember the feature's state before we touch it, so Return/end
                -- can put it back exactly how it was.
                if a.feature then
                    if featRestore[a.feature] == nil then featRestore[a.feature] = feature.getEnabled(a.feature) end
                    if a.value == nil then feature.fire(a.feature) else feature.setEnabled(a.feature, a.value) end
                end
            elseif a.type == "return" then
                -- Return = restore EVERYTHING to how it was before: drop the held
                -- facing, undo every feature this tech toggled, release held keys.
                restoreAll()
            else
                local fn = ACTIONS[a.type]
                if fn then local ok, err = pcall(fn, a); if not ok then log.warn("[tech] action " .. tostring(a.type) .. ": " .. tostring(err)) end end
            end
        end
        -- one-shot techs auto-restore at the end (in case there's no explicit
        -- Return) -- facing, feature toggles, and held keys all reset. Hold techs
        -- keep their facing until the key is released.
        if not hold then restoreAll() else
            for kc in pairs(heldKeys) do pcall(function() VIM:SendKeyEvent(false, kc, false, game) end) end
        end
        running = false
    end)
end

-- Run a tech FROM A TRIGGER. One-shot techs are queued and dispatched on Heartbeat
-- (drainPending) instead of run straight from the trigger's signal callback: a
-- coroutine task.spawn'd inside an RBXScriptSignal handler doesn't reliably get its
-- task.wait resumed on some executors, which froze a tech at its first Wait. Hold
-- techs just set a facing instantly (no meaningful wait), so they run immediately
-- to avoid a 1-frame gap / fast-tap stuck-facing.
local pendingRuns = {}
local function queueRun(tech, hold)
    if hold then runTech(tech, true) else pendingRuns[#pendingRuns + 1] = tech end
end
local function drainPending()
    if #pendingRuns == 0 then return end
    local q = pendingRuns; pendingRuns = {}
    for _, t in ipairs(q) do runTech(t, false) end
end

-- ===== animation triggers + capture =====
-- One persistent hook on the character's Animator drives ALL "anim" techs (and the
-- editor's "Capture" button), re-hooking on respawn. Gated on tech.enabled so
-- there's nothing to wire/unwire per tech.
local animCaptureCbs = {}     -- one-shot callbacks: next anim played -> cb(rawId)
local function animIdNum(s)    -- "rbxassetid://123" / "http://...id=123" / "123" -> "123"
    if not s then return nil end
    return tostring(s):match("(%d+)")
end
-- the character's default locomotion anim ids (walk/run/idle/jump/fall/climb/sit),
-- so history/Capture skip them -- otherwise they'd grab "walk" the instant you move.
local function locomotionIds()
    local set = {}
    local ch = LP.Character
    local animate = ch and ch:FindFirstChild("Animate")
    if animate then
        for _, d in ipairs(animate:GetDescendants()) do
            local v = (d:IsA("Animation") and d.AnimationId) or (d:IsA("StringValue") and d.Value)
            local n = v and animIdNum(v); if n then set[n] = true end
        end
    end
    return set
end

-- Friendly names for anim ids, parsed lazily from pantheon_anim_dump.txt ("id  path")
-- so the editor dropdown can show "Dash7_Right" instead of a bare id.
local animNameMap, animNamesLoaded = {}, false
local function loadAnimNames()
    if animNamesLoaded then return end
    animNamesLoaded = true
    if typeof(readfile) ~= "function" then return end
    local ok, data = pcall(function()
        if typeof(isfile) == "function" and not isfile("pantheon_anim_dump.txt") then return nil end
        return readfile("pantheon_anim_dump.txt")
    end)
    if ok and data then
        for line in tostring(data):gmatch("[^\r\n]+") do
            local idp, path = line:match("^(%S+)%s+(.+)$")
            local n = idp and animIdNum(idp)
            if n and path then animNameMap[n] = path end
        end
    end
end
local function shortPath(p)              -- last 2 dot-segments of a GetFullName path
    local segs = {}
    for s in tostring(p):gmatch("[^%.]+") do segs[#segs + 1] = s end
    if #segs <= 2 then return p end
    return segs[#segs - 1] .. "." .. segs[#segs]
end

-- history of non-locomotion anims you've played this session, for the dropdown
local animLog, animLogSeen = {}, {}
local function recordAnim(track, id, raw)
    if animLogSeen[id] then return end
    loadAnimNames()
    local label = animNameMap[id] and shortPath(animNameMap[id])
    if not label then
        local a = track and track.Animation
        local ok, full = pcall(function() return a and a:GetFullName() end)
        if ok and full and full ~= "" and full ~= "Animation" then label = shortPath(full)
        elseif a and a.Name and a.Name ~= "" and a.Name ~= "Animation" then label = a.Name end
    end
    animLogSeen[id] = true
    animLog[#animLog + 1] = { id = id, raw = raw, label = label or ("anim " .. id) }
end
function Engine.animHistory() return animLog end

local function onAnimPlayed(track)
    local raw = track and track.Animation and track.Animation.AnimationId
    local id = animIdNum(raw)
    if not id then return end
    local watching = false
    for _, tech in pairs(techs) do
        local tr = tech.trigger
        if tech.enabled and tr and tr.event == "anim" then
            watching = true
            if animIdNum(tr.animId) == id and modifierHeld(tech) and conditionsMet(tech) then
                log.info("[tech] anim trigger fired: " .. tostring(tech.name) .. " <- " .. id)
                queueRun(tech, false)
            end
        end
    end
    -- diagnostic: with an anim tech ON, log every id that plays so you can see
    -- whether the hook catches your move and what id to bind it to.
    if watching then log.info("[tech] anim played: " .. id .. (animIdNum(raw) ~= id and "" or "")) end
    -- below: moves only -- skip locomotion so the dropdown/Capture stay clean
    if locomotionIds()[id] then return end
    recordAnim(track, id, raw)
    if #animCaptureCbs > 0 then
        local cbs = animCaptureCbs; animCaptureCbs = {}
        for _, cb in ipairs(cbs) do pcall(cb, raw) end
    end
end
local animHookConns = {}
local function hookAnimator()
    for _, c in ipairs(animHookConns) do pcall(function() c:Disconnect() end) end
    animHookConns = {}
    local ch = LP.Character
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    local animator = hum and hum:FindFirstChildOfClass("Animator")
    if animator then
        animHookConns[#animHookConns + 1] = animator.AnimationPlayed:Connect(onAnimPlayed)
        log.info("[tech] anim hook connected")
    elseif hum then
        log.warn("[tech] anim hook: no Animator yet, waiting")
        animHookConns[#animHookConns + 1] = hum.ChildAdded:Connect(function(c)
            if c:IsA("Animator") then hookAnimator() end
        end)
    else
        log.warn("[tech] anim hook: no Humanoid yet")
    end
end
-- Arm a one-shot: the next animation you play is delivered to cb(rawId). Editor uses
-- this for "Capture" so you bind to the move's real runtime animation id.
function Engine.captureAnim(cb) animCaptureCbs[#animCaptureCbs + 1] = cb end

-- ===== trigger wiring =====
local function wireKey(tech)
    local key = tech.trigger.key
    if not key or key == Enum.KeyCode.Unknown then return end
    local isHold = tech.trigger.event == "keyhold"
    if tech.trigger.suppress then
        -- "Block this key's normal action": intercept the key with a high-priority
        -- CAS bind + Sink, so the press runs THIS tech and the game never sees the
        -- key (so it can't fire the move). The tech fires the move via Use Move.
        keybinds.clear("tech." .. tech.id)
        local action = "PantheonTech_" .. tech.id
        CAS:BindActionAtPriority(action, function(_, inputState)
            if inputState == Enum.UserInputState.Begin then
                if tech.enabled and modifierHeld(tech) and conditionsMet(tech) then queueRun(tech, isHold) end
            elseif inputState == Enum.UserInputState.End and isHold then
                releaseHold()
            end
            return Enum.ContextActionResult.Sink
        end, false, 3000, key)
        casBound[tech.id] = action
        return
    end
    keybinds.set("tech." .. tech.id, key,
        function() if tech.enabled and modifierHeld(tech) and conditionsMet(tech) then queueRun(tech, isHold) end end,
        function() if isHold then releaseHold() end end)
end

-- The "move" trigger fires the INSTANT the move's KEY is pressed (keydown), so the
-- tech runs BEFORE the move starts -- NOT on the move's button click or its Effects
-- broadcast (both happen after the move begins). The move is picked from your
-- scanned moveset (for the label); trigger.movekey is that move's key (auto-filled
-- from the scan, editable). Bound through the keybind dispatcher (UIS.InputBegan)
-- exactly like a key trigger, so it lands on keydown.
local function wireMove(tech)
    local keyName = tech.trigger.movekey
    local kc = keyName and safeKeyCode(keyName)
    if not kc or kc == Enum.KeyCode.Unknown then
        log.warn("[tech] '" .. tostring(tech.name) .. "': move trigger has no key set -- pick the move's key")
        return
    end
    if tech.trigger.suppress then
        keybinds.clear("tech." .. tech.id)   -- drop any prior UIS bind (mode switch)
        -- "Cancel the move's normal fire": intercept the key with a high-priority
        -- ContextActionService bind and SINK it, so the press runs THIS tech and the
        -- game's own keybind for the move never sees it. The tech fires the move
        -- itself via a Use Move step. (Sink only blocks lower CAS binds, not raw
        -- UserInputService listeners -- see notes; applySuppression covers the button
        -- path too.) This is the "fast filter": key down -> us -> sink.
        local action = "PantheonTech_" .. tech.id
        CAS:BindActionAtPriority(action, function(_, inputState)
            if inputState == Enum.UserInputState.Begin
               and tech.enabled and modifierHeld(tech) and conditionsMet(tech) then
                queueRun(tech, false)
            end
            return Enum.ContextActionResult.Sink
        end, false, 3000, kc)
        casBound[tech.id] = action
        return
    end
    keybinds.set("tech." .. tech.id, kc,
        function() if tech.enabled and modifierHeld(tech) and conditionsMet(tech) then queueRun(tech, false) end end,
        nil)
end

function Engine.rewire()
    for _, list in pairs(conns) do for _, c in ipairs(list) do pcall(function() c:Disconnect() end) end end
    conns = {}
    for _, action in pairs(casBound) do pcall(function() CAS:UnbindAction(action) end) end
    casBound = {}
    for _, tech in pairs(techs) do
        local ev = tech.trigger and tech.trigger.event
        if ev == "key" or ev == "keyhold" then
            -- Only bind the key while the tech is ON; clear it when OFF so a
            -- disabled tech's key is genuinely unbound (can't fire), matching how
            -- move techs are gated.
            if tech.enabled then wireKey(tech) else keybinds.clear("tech." .. tech.id) end
        elseif ev == "move" then
            -- move trigger is keydown on the move's key -> same bind/clear gating
            if tech.enabled then wireMove(tech) else keybinds.clear("tech." .. tech.id) end
        elseif ev == "anim" then
            -- handled by the persistent Animator hook (gated on tech.enabled); nothing to bind
            keybinds.clear("tech." .. tech.id)
        end
    end
    pcall(Engine.applySuppression)   -- cancel/restore move buttons per current techs
end

-- ===== persistence =====
-- enabled-state is persisted per tech for EVERY tech (examples + custom) so
-- toggles survive reloads. Custom (user-built) techs also persist their full
-- definition under one "tech.custom" map, rehydrated on boot via loadCustom().
local ENABLED_KEY = "tech.enabled."
local CUSTOM_KEY  = "tech.custom"

local function serialize(tech)
    return {
        id      = tech.id,
        name    = tech.name,
        scope   = tech.scope,
        enabled = tech.enabled,
        trigger = {
            event      = tech.trigger.event,
            key        = persist.keyToString(tech.trigger.key),
            move       = tech.trigger.move,
            movekey    = tech.trigger.movekey,
            modkey     = tech.trigger.modkey,
            maxRange   = tech.trigger.maxRange,
            animId     = tech.trigger.animId,
            suppress   = tech.trigger.suppress,
            conditions = tech.trigger.conditions or {},
        },
        actions = tech.actions or {},
    }
end

local function deserialize(s)
    return {
        id      = s.id,
        name    = s.name,
        scope   = s.scope,
        enabled = s.enabled,
        custom  = true,
        trigger = {
            event      = s.trigger and s.trigger.event,
            key        = s.trigger and persist.stringToKey(s.trigger.key),
            move       = s.trigger and s.trigger.move,
            movekey    = s.trigger and s.trigger.movekey,
            modkey     = s.trigger and s.trigger.modkey,
            maxRange   = s.trigger and s.trigger.maxRange,
            animId     = s.trigger and s.trigger.animId,
            suppress   = s.trigger and s.trigger.suppress,
            conditions = (s.trigger and s.trigger.conditions) or {},
        },
        actions = s.actions or {},
    }
end

-- ===== public API =====
function Engine.add(tech)
    if not (tech and tech.id) then return end
    -- A user-saved custom override wins over a code-defined re-add of the same id.
    -- (Editing a built-in example saves a custom tech under the built-in's id; on
    -- reload loadCustom() adds the override, then the game/example module re-adds
    -- the original -- this keeps the override instead of clobbering it.)
    local existing = techs[tech.id]
    if existing and existing.custom and not tech.custom then return end
    if tech.enabled == nil then tech.enabled = true end
    -- a persisted enabled-state overrides the declared default
    local savedEnabled = persist.get(ENABLED_KEY .. tech.id)
    if savedEnabled ~= nil then tech.enabled = savedEnabled and true or false end
    techs[tech.id] = tech
    Engine.rewire()
    Engine.changed:Fire()
end

-- Persist a user-built tech's full definition (and add/replace it live).
function Engine.saveCustom(tech)
    tech.custom = true
    Engine.add(tech)
    local map = persist.get(CUSTOM_KEY, {}) or {}
    map[tech.id] = serialize(tech)
    persist.set(CUSTOM_KEY, map)
    persist.scheduleSave()
end

-- Rehydrate persisted user-built techs. Call once at init.
function Engine.loadCustom()
    local map = persist.get(CUSTOM_KEY, {}) or {}
    for _, s in pairs(map) do
        if s and s.id then Engine.add(deserialize(s)) end
    end
end

function Engine.all() return techs end
function Engine.get(id) return techs[id] end

-- Run a tech's action sequence once, now, ignoring its trigger/conditions.
-- Used by the editor's "Test" button to preview a draft against the world.
-- Queued like a trigger so its Waits resume reliably.
function Engine.run(tech) if tech then queueRun(tech, false) end end

function Engine.setEnabled(id, v)
    local t = techs[id]; if not t then return end
    t.enabled = v and true or false
    persist.set(ENABLED_KEY .. id, t.enabled)
    -- keep the custom map's snapshot in sync so a reload restores this state
    if t.custom then
        local map = persist.get(CUSTOM_KEY, {}) or {}
        if map[id] then map[id].enabled = t.enabled; persist.set(CUSTOM_KEY, map) end
    end
    Engine.rewire()
    Engine.changed:Fire()
end

function Engine.remove(id)
    local t = techs[id]
    techs[id] = nil
    persist.set(ENABLED_KEY .. id, nil)
    if t and t.custom then
        local map = persist.get(CUSTOM_KEY, {}) or {}
        map[id] = nil
        persist.set(CUSTOM_KEY, map)
    end
    keybinds.clear("tech." .. id)
    Engine.rewire()
    Engine.changed:Fire()
end

function Engine.init()
    if bound then return end
    RunService:BindToRenderStep(RENDER_BIND, Enum.RenderPriority.Camera.Value + 2, renderHold)
    -- dispatch queued trigger runs from a stable thread so their Waits resume
    drainConn = RunService.Heartbeat:Connect(drainPending)
    -- persistent Animator hook for "anim" triggers + the editor's Capture, re-hooked
    -- on respawn (Humanoid/Animator aren't there the instant the character spawns).
    hookAnimator()
    -- retry for the CURRENT character too (executing mid-game, the Animator may not
    -- be resolved on the first pass)
    task.spawn(function()
        local ch = LP.Character
        if ch then
            local hum = ch:FindFirstChildOfClass("Humanoid") or ch:WaitForChild("Humanoid", 10)
            if hum then hum:WaitForChild("Animator", 10) end
            hookAnimator()
        end
    end)
    LP.CharacterAdded:Connect(function(ch)
        task.spawn(function()
            local hum = ch:WaitForChild("Humanoid", 10)
            if hum then hum:WaitForChild("Animator", 5) end
            hookAnimator()
        end)
    end)
    bound = true
end

function Engine.destroy()
    if bound then pcall(function() RunService:UnbindFromRenderStep(RENDER_BIND) end); bound = false end
    if drainConn then pcall(function() drainConn:Disconnect() end); drainConn = nil end
    for _, list in pairs(conns) do for _, c in ipairs(list) do pcall(function() c:Disconnect() end) end end
    conns = {}
    releaseHold()
    if techAlign then pcall(function() techAlign:Destroy() end); techAlign = nil end
    if techAttach then pcall(function() techAttach:Destroy() end); techAttach = nil end
end

return Engine
