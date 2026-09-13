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
local drainConn          -- Heartbeat that runs queued techs off the trigger signal thread
local targetChangedConn  -- state.onTargetChanged subscription (re-hooks target_anim)
local charAddedConn      -- LP.CharacterAdded subscription (re-hooks the Animator on respawn)

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

-- Rotate is BODY-ONLY: yaw is an offset from the body's facing CAPTURED AT TECH
-- START (yaw 0 = same as start, 180 = opposite). NOT camera-relative, NOT
-- target-relative (Look handles target-relative camera). Anchoring to the start
-- facing (not live LookVector) avoids per-frame yaw compounding -> spin.
local function bodyBaseFlat()
    if startBodyLook then return Vector3.new(startBodyLook.X, 0, startBodyLook.Z) end
    local r = myRoot()
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

local function applyCamHold()
    if not held.cam then return end
    local cam = Workspace.CurrentCamera
    local base = camBaseFlat()
    if cam and base.Magnitude > 1e-3 then
        local dir = offsetDir(base, held.cam.yaw)
        local pitch = math.rad(held.cam.pitch or 0)
        local look = Vector3.new(dir.X * math.cos(pitch), math.sin(pitch), dir.Z * math.cos(pitch))
        cam.CFrame = CFrame.new(cam.CFrame.Position, cam.CFrame.Position + look)
    end
end
local function applyBodyHold()
    if not held.body then return end
    local root = myRoot()
    local base = bodyBaseFlat()
    if root and base.Magnitude > 1e-3 then
        local ch = myChar()
        local hum = ch and ch:FindFirstChildOfClass("Humanoid")
        if hum and hum.AutoRotate then hum.AutoRotate = false; bodyARDisabled = true end
        local dir = offsetDir(base, held.body.yaw)
        ensureBodyConstraint(root)
        techAlign.Enabled = true
        techAlign.CFrame = CFrame.lookAt(Vector3.zero, dir)
        local cf = CFrame.lookAt(root.Position, root.Position + dir)
        local _, yAngle = cf:ToEulerAnglesYXZ()
        root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, yAngle, 0)
    end
end
-- Releases the cam/body override flags. If `snap` is true (explicit Return /
-- bounded During->Wait / keyhold release / shutdown / timed-hold expiry), also
-- snaps that axis back to where the tech started. Default false: rotation PERSISTS
-- until the next move/input naturally turns you, the desired behavior when a tech
-- rotates and never adds a Return -- otherwise a 180 instantly snaps back at one-
-- shot end. Split per-axis so a timed Look (cam) and a timed Rotate (body) can
-- expire independently (renderHold releases whichever's `expire` has passed).
local function releaseCam(snap)
    held.cam = nil
    state.techCamOverride = false
    if snap and not (state.lockon_enabled and state.target) then
        local cam = Workspace.CurrentCamera
        if cam and startCamLook then cam.CFrame = CFrame.new(cam.CFrame.Position, cam.CFrame.Position + startCamLook) end
    end
end
local function releaseBody(snap)
    local didRotate = bodyARDisabled   -- a Rotate step actually turned the body
    -- The old "snap camera to body yaw under shiftlock so rotation persists" path
    -- is removed -- the camera flip at one-shot end was disorienting. Trade-off:
    -- without it the rotation does NOT persist under shiftlock past tech end (the
    -- game's shiftlock snaps body back to face camera on its next pass). For
    -- "rotate-and-stay-rotated" use a keyhold-event tech instead.
    held.body = nil
    state.techBodyOverride = false
    if bodyARDisabled then
        local ch = myChar()
        local hum = ch and ch:FindFirstChildOfClass("Humanoid")
        if hum then hum.AutoRotate = true end
        bodyARDisabled = false
    end
    if techAlign then techAlign.Enabled = false end
    if snap and not (state.lockon_enabled and state.target) and didRotate and startBodyLook then
        local root = myRoot()
        local flat = Vector3.new(startBodyLook.X, 0, startBodyLook.Z)
        if root and flat.Magnitude > 1e-3 then
            root.CFrame = CFrame.lookAt(root.Position, root.Position + flat.Unit)
        end
    end
end
local function releaseHold(snap) releaseCam(snap); releaseBody(snap) end

-- renderHold runs every RenderStep (bound in init). Before re-applying the held
-- facings it expires any timed Look/Rotate ("keep for N seconds"), snapping that
-- axis back the instant its hold elapses -- independent of the tech coroutine.
local function renderHold()
    local now = os.clock()
    if held.cam  and held.cam.expire  and now >= held.cam.expire  then releaseCam(true)  end
    if held.body and held.body.expire and now >= held.body.expire then releaseBody(true) end
    applyCamHold(); applyBodyHold()
end

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

-- ===== actions =====
local ACTIONS = {}
-- Apply immediately (in addition to setting the held state for renderhold to
-- re-apply each frame), so a single-step Rotate/Look with no Wait after still
-- visibly turns the body/camera -- runner had time to finish the action and
-- restoreAll BEFORE the next render frame ever fired renderhold.
-- a.hold (seconds) = "keep this look/rotation for N seconds" then auto-snap back
-- (0/nil = hold until a Return / During->Wait / tech end, the prior behavior).
-- Non-blocking: later steps run while it's held; renderHold expires it on schedule.
ACTIONS.look = function(a)
    held.cam = { yaw = a.x or 0, pitch = a.y or 0 }
    local d = tonumber(a.hold); if d and d > 0 then held.cam.expire = os.clock() + d end
    state.techCamOverride = true; applyCamHold()
end
ACTIONS.rotate = function(a)
    held.body = { yaw = a.x or 0, pitch = a.y or 0 }
    local d = tonumber(a.hold); if d and d > 0 then held.body.expire = os.clock() + d end
    state.techBodyOverride = true; applyBodyHold()
end
ACTIONS.wait   = function(a) task.wait(a.seconds or a.x or 0.5) end
ACTIONS["return"] = function() releaseHold(true) end
ACTIONS.feature = function(a)
    if a.value == nil then feature.fire(a.feature) else feature.setEnabled(a.feature, a.value) end
end
-- send a real keyboard key (a.key is the short name, e.g. "R"), so a tech can
-- press keys -- e.g. fire a game move via its keybind, dash, jump, etc.
ACTIONS.key = function(a)
    local kc = safeKeyCode(a.key)   -- digit names ("1") resolve to One..Nine instead of throwing
    if not kc or kc == Enum.KeyCode.Unknown then return end
    VIM:SendKeyEvent(true, kc, false, game)
    task.wait(tonumber(a.hold) or 0.04)
    VIM:SendKeyEvent(false, kc, false, game)
end
-- Mouse buttons: "MouseButton1"/"M1" -> 0, "MouseButton2"/"M2" -> 1, "MouseButton3"/"M3" -> 2.
-- Returns nil for anything that isn't a mouse button (so callers can fall back to KeyCode).
local MOUSE_BTN = { M1 = 0, M2 = 1, M3 = 2, MouseButton1 = 0, MouseButton2 = 1, MouseButton3 = 2 }
local function mouseButtonOf(name) return name and MOUSE_BTN[tostring(name)] or nil end
-- Send a mouse button down/up at the CURRENT cursor position. GetMouseLocation is
-- inset-inclusive, which is the space VIM wants (fireButton adds +36 to
-- AbsolutePosition for the same reason).
local function sendMouse(btn, down)
    local pos = UIS:GetMouseLocation()
    VIM:SendMouseButtonEvent(pos.X, pos.Y, btn, down, game, 0)
end
-- Click step: press + release a mouse button where the cursor is (a.button =
-- "M1"|"M2"|"M3", default M1; a.hold = seconds held, default one frame-ish).
-- Goes through VIM so the game's own M1 handler sees a normal click.
ACTIONS.click = function(a)
    local btn = mouseButtonOf(a.button) or 0
    sendMouse(btn, true)
    task.wait(tonumber(a.hold) or 0.04)
    sendMouse(btn, false)
end
Engine.mouseButtonOf = mouseButtonOf
Engine.sendMouse = sendMouse
Engine.ACTIONS = ACTIONS

-- ===== conditions =====
-- Conditions receive the firing tech so parametrized checks (e.g. target
-- playing a specific anim) can read the id out of trigger.<field>. Stateless
-- checks just ignore the arg.
local CONDITIONS = {}
-- "Locked on" = TARGET SELECT is engaged on someone: the feature is on AND holds a
-- target. Bound to Target Select (the user's actual lock), NOT the Lock-On camera.
-- state.target is written/cleared ONLY by Target Select -- setEnabled(false) and
-- target death both releaseTarget() -- so this is true exactly while you're locked
-- onto a live target and false the instant you drop it. (state.target alone would
-- behave the same since only Target Select sets it; the explicit flag makes the
-- binding unambiguous.)
CONDITIONS.locked_on = function() return state.target_select_enabled == true and state.target ~= nil end
CONDITIONS.shiftlock = function() return state.shiftlock_active == true end

-- target_playing: TRUE iff the current target's Animator currently has a track
-- playing whose AnimationId contains the configured trigger.targetAnimId. Pairs
-- naturally with trigger.maxRange to give "within X studs AND target playing Y".
CONDITIONS.target_playing = function(tech)
    local want = tech and tech.trigger and tech.trigger.targetAnimId
    if not want or want == "" then return true end
    local t = state.target
    if not t then return false end
    local ch = (state.target_type == "npc") and t or t.Character
    if not ch then return false end
    local hum = ch:FindFirstChildOfClass("Humanoid")
    local animator = hum and hum:FindFirstChildOfClass("Animator")
    if not animator then return false end
    local idNum = tostring(want):match("(%d+)")
    if not idNum then return false end
    local ok, tracks = pcall(function() return animator:GetPlayingAnimationTracks() end)
    if not ok or not tracks then return false end
    for _, track in ipairs(tracks) do
        local a = track.Animation
        if a and tostring(a.AnimationId):find(idNum, 1, true) then return true end
    end
    return false
end

Engine.CONDITIONS = CONDITIONS


-- optional modifier key that must be HELD for a key/move trigger to fire
-- (e.g. hold A + press Q). Takes a TRIGGER (not the whole tech) so multi-
-- trigger "or" techs can have per-subtrigger modkeys.
local function modifierHeld(trig, top)
    local m = trig and trig.modkey
    if m == nil and top and top ~= trig then m = top.modkey end   -- OR wrapper's hold-key applies to every branch
    if not m then return true end
    local kc = safeKeyCode(m)
    return kc ~= nil and UIS:IsKeyDown(kc)
end

-- Iterate every trigger registered on a tech. For event="or" techs the
-- subtriggers[] array is the actual fire list; for legacy single-trigger
-- techs it's just {tech.trigger}. Yields (index, trig) so callers can
-- pass the index down to queueRun -> runTech.ctx.triggerIndex.
local function techTriggers(tech)
    local trig = tech.trigger
    if trig and trig.event == "or" and type(trig.subtriggers) == "table" then
        return trig.subtriggers
    elseif trig then
        return { trig }
    end
    return {}
end

-- Takes the FIRING trigger so an "or" tech's per-subtrigger conditions/maxRange
-- are honored (they live on each subtrigger, not the top-level "or" wrapper).
-- Legacy single-trigger techs pass trig == tech.trigger, so the fallback keeps
-- their behavior identical.
local function gatesPass(tech, trig)
    for _, c in ipairs(trig.conditions or {}) do
        local fn = CONDITIONS[c]
        if fn and not fn(tech) then return false end
    end
    -- distance gate: only fire within maxRange studs of the target (0/nil = any).
    -- Needs a target (lock-on / target select); fails closed if there's none.
    local maxR = tonumber(trig.maxRange)
    if maxR and maxR > 0 then
        local mr, tr = myRoot(), targetRoot()
        if not (mr and tr) then return false end
        if (tr.Position - mr.Position).Magnitude > maxR then return false end
    end
    return true
end
local function conditionsMet(tech, trig)
    local top = tech.trigger or {}
    trig = trig or top
    if not gatesPass(tech, trig) then return false end
    -- An OR tech's "Only while locked on" / "Within X studs" toggles live on the
    -- WRAPPER trigger (the form), not on each subtrigger -- they were silently
    -- ignored for multi-trigger techs. Check the wrapper too.
    if trig ~= top and not gatesPass(tech, top) then return false end
    return true
end

-- Scope gate at trigger fire time. Universal techs always match; numeric scopes
-- match by PlaceId or GameId; "char:<name>" scopes call the current game's
-- detectCharacter() and compare. Unknown / unmatched scopes block the fire.
local function scopeMatches(tech)
    local s = tech.scope
    if s == nil or s == "universal" then return true end
    if s == game.PlaceId or s == game.GameId then return true end
    if type(s) == "string" then
        local want = s:match("^char:(.+)$")
        if want then
            local ok_reg, registry = pcall(require, "games.registry")
            if not ok_reg or not registry then return false end
            local mod = registry.current()
            local detect = mod and mod.detectCharacter
            if type(detect) ~= "function" then return false end
            local ok, cur = pcall(detect)
            return ok and cur == want or false
        end
    end
    return false
end
Engine.scopeMatches = scopeMatches

-- ===== move buttons: fire + suppress =====
-- Resolve a hotbar move button by the name the scanner recorded for it (e.g. TSB
-- slot "1"). Re-scans so it tracks the live GUI.
-- Pass a pre-scanned `res` to reuse one scan across many lookups (applySuppression
-- does this so it doesn't walk the whole PlayerGui once per suppressed tech).
local function findMoveButton(name, res)
    if not name then return nil end
    if not res then
        local ok, r = pcall(function() return scanner.scan() end)
        if not ok or not r then return nil end
        res = r
    end
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

-- Flag-based CAS sink bypass: while bypassKeys[kc] is true, any Pantheon CAS
-- sink for that key returns Pass instead of Sink, so the VIM-sent key reaches
-- the game's handler instead of being swallowed (and re-triggering us). Cleaner
-- than unbind/rebind -- no race window, sink stays bound throughout.
Engine.bypassKeys = {}
local bypassKeys = Engine.bypassKeys

local function fireKeyBypass(kc)
    if not kc or kc == Enum.KeyCode.Unknown then return end
    -- Fully release the body-pin for the VIM key window. A previous AR-only
    -- restore wasn't enough: renderHold's applyBodyHold ran on every frame
    -- during the 60ms wait and (a) re-set AutoRotate=false, (b) re-enabled the
    -- rigid AlignOrientation with infinite torque, (c) re-wrote root.CFrame --
    -- which kept JJS's Projection Breaker (and similar gated casts) from
    -- starting even though we'd briefly set AR=true. Clearing held.body makes
    -- applyBodyHold early-exit, we also explicitly drop the AlignOrientation
    -- and lift AR, fire the key, then restore so the rotation snaps back via
    -- the next applyBodyHold tick (the held.body value is preserved).
    local ch = myChar()
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    local wasARDisabled = bodyARDisabled
    local savedBody = held.body
    held.body = nil
    if techAlign then techAlign.Enabled = false end
    if hum and (not hum.AutoRotate) then hum.AutoRotate = true end
    bypassKeys[kc] = true
    pcall(function() VIM:SendKeyEvent(true, kc, false, game) end)
    task.wait(0.06)
    pcall(function() VIM:SendKeyEvent(false, kc, false, game) end)
    bypassKeys[kc] = nil
    held.body = savedBody
    if not savedBody then
        -- nothing left holding; if AR had been disabled, leave it for the
        -- runner's restoreAll/releaseHold to clean up (bodyARDisabled flag).
        if wasARDisabled and hum and hum.Parent then hum.AutoRotate = false end
    end
    -- if savedBody was set, next renderHold tick's applyBodyHold re-disables
    -- AR + re-enables techAlign + re-pins root.CFrame to the held facing.
end

-- ACTION: fire a move via its scanned entry. Order of attempts:
-- 1. Per-game `useMove(name, entry)` hook on the current game module (if it
--    exists and returns truthy) -- this is the DIRECT path that fires the
--    move's Knit RE itself (e.g. ProjectionBreakerService.RE.Activated:
--    FireServer()) -- the most reliable, since it bypasses VIM/CAS/animation
--    state gating entirely.
-- 2. useKey=true (JJS-style hotbar where keypress fires the move and the
--    button is visual-only): VIM-send the slot key with CAS bypass.
-- 3. Default: click the GUI button (TSB-style: button click fires the move).
-- a.move = scanned button name OR a hand-typed move name; a.key = key to press
-- (string name, e.g. "Q"/"One"); a.fire = "auto"|"button"|"key" (default auto).
ACTIONS.usebtn = function(a)
    local fire = a.fire or "auto"
    -- Always resolve the button from a LIVE scan -- the game rebuilds its hotbar
    -- (respawn, move swap) so any cached button reference goes dead. Never trust
    -- the cache for firing: re-find the CURRENT button by name on every fire.
    -- Cached scan first; only re-walk the PlayerGui (expensive, and this runs
    -- MID-COMBO) when the cached button for this move is gone (respawn / move
    -- swap rebuilds the hotbar).
    local function findEntry(res)
        for _, b in ipairs((res and res.buttons) or {}) do
            if b.name == a.move then return b end
        end
        return nil
    end
    local entry = findEntry(scanner.cached())
    if not (entry and entry.button and entry.button.Parent) then
        entry = findEntry(scanner.scan())
    end
    -- Explicit "press key": VIM the key. Works for MANUAL moves the scanner
    -- can't see (no live button to click) -- only needs a key.
    if fire == "key" then
        local kc = safeKeyCode(a.key or (entry and entry.key))
        if kc then fireKeyBypass(kc) end
        return
    end
    -- Auto: per-game direct hook first (fires the move's RE itself), then the
    -- JJS-style useKey hotbar (keypress fires, button is visual-only).
    if fire == "auto" then
        local ok_reg, registry = pcall(require, "games.registry")
        if ok_reg and registry then
            local mod = registry.current()
            if mod and type(mod.useMove) == "function" then
                local ok_um, handled = pcall(mod.useMove, a.move, entry)
                if ok_um and handled then return end
            end
        end
        if entry and entry.useKey and entry.key then
            local kc = safeKeyCode(entry.key)
            if kc then fireKeyBypass(kc); return end
        end
    end
    -- Click the GUI button ("button", or "auto" with a real button).
    if entry and entry.button then fireButton(entry.button); return end
    -- No live button (manual move / scan miss): fall back to a key press if one
    -- is set, so a typed move with a key still fires.
    local kc = safeKeyCode(a.key or (entry and entry.key))
    if kc then fireKeyBypass(kc) end
end

-- Reconcile which move buttons should be "cancelled" right now: every ENABLED
-- move tech whose trigger has suppress=true cancels its move button. Buttons no
-- longer wanted get re-enabled. Best-effort -- needs getconnections + the button
-- to exist; called from rewire and re-tried when techs change.
function Engine.applySuppression()
    local want = {}
    -- One hotbar scan for the whole pass; findMoveButton reuses it per tech.
    local ok, res = pcall(function() return scanner.scan() end)
    res = ok and res or nil
    for _, tech in pairs(techs) do
        local tr = tech.trigger
        if tech.enabled and tr and tr.event == "move" and tr.suppress then
            local b = findMoveButton(tr.move, res); if b then want[b] = true end
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
-- ===== trace =====
-- Timestamped trace of anim-trigger events + run steps, appended to
-- pantheon_tech_trace.txt in the executor workspace, so timing questions
-- ("did it fire at 0.6s or at the end?") can be answered from the file
-- instead of guessed. Truncated on init. Cheap: only fires/steps write.
Engine.traceEnabled = true
local TRACE_FILE = "pantheon_tech_trace.txt"
local traceStart = os.clock()
local function trace(msg)
    if not Engine.traceEnabled then return end
    local line = string.format("%8.3f  %s\n", os.clock() - traceStart, tostring(msg))
    if typeof(appendfile) == "function" then pcall(appendfile, TRACE_FILE, line) end
end
local function traceReset()
    if typeof(writefile) == "function" then pcall(writefile, TRACE_FILE, "# Pantheon tech trace " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n") end
end

local running = false
local runningSince = 0
local armedFires = {}    -- timed anim-trigger fires, checked every Heartbeat (see checkArmedFires)
local checkArmedFires    -- defined with the anim section below
local lastPlayed         -- { track, id, t, seq } = most recent non-locomotion anim on us ("Anim at" fallback)
local playingTrackById   -- defined with the anim section below
-- keyhold techs park their run context here while the trigger key is down, so
-- the key-up path can release Hold-step keys/buttons and restore toggled
-- features (previously: keys released instantly at the end of the actions,
-- features never restored at all).
local activeHold = {}   -- tech.id -> ctx

-- Single-step runner used by both the top-level action loop AND recursive
-- contexts (AND branches). ctx carries per-run state shared across branches
-- (releaseAfterWait flag, heldKeys, featRestore, restoreAll thunk) so e.g. a
-- key held in one branch is releasable from another or by the safety cleanup.
local function runStep(a, ctx)
    if a.type == "during" then
        -- the preceding Look/Rotate lasts only as long as the NEXT Wait,
        -- then auto-returns (so "Rotate -> During -> Wait 0.5" rotates for
        -- exactly 0.5s).
        ctx.releaseAfterWait = true
    elseif a.type == "wait" then
        task.wait(a.seconds or a.x or 0.5)
        if ctx.releaseAfterWait then releaseHold(true); ctx.releaseAfterWait = false end
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
        if ctx.releaseAfterWait then releaseHold(true); ctx.releaseAfterWait = false end
    elseif a.type == "animwait" then
        -- gate: wait until an animation reaches `at` seconds. Which animation:
        --   * a.animId set      -> that anim (already playing, or starts within 2s)
        --   * anim-triggered    -> the track that fired the trigger
        --   * key-triggered     -> the move's OWN anim: the most recent non-
        --                          locomotion anim if it just started, else the
        --                          next one to start (2s cap). So "Press R ->
        --                          Anim at 0.4 -> Press E" times E to R's animation.
        -- Stops early if the anim ends first (cancelled move), 10s cap.
        local at = tonumber(a.at) or 0
        local tr
        local want = a.animId and tostring(a.animId):match("%d+")
        if want then
            tr = playingTrackById and playingTrackById(want)
            local t0 = os.clock()
            while not tr and os.clock() - t0 < 2 do task.wait(); tr = playingTrackById and playingTrackById(want) end
        else
            tr = ctx.animTrack
            local alive = false
            pcall(function() alive = tr ~= nil and tr.IsPlaying end)
            if not alive then
                -- The move's own anim starts a frame or two around the trigger
                -- (before runStart if the game fired the move off the same key
                -- press we triggered on, after it if a Press step fired it), so
                -- accept anims from ~0.1s before the run began onward; anything
                -- older is a leftover from a previous move, even if still playing.
                local lp = lastPlayed
                local lpAlive = false
                pcall(function() lpAlive = lp ~= nil and lp.track.IsPlaying and lp.t >= (ctx.runStart or 0) - 0.1 end)
                if lpAlive then tr = lp.track
                else
                    local seq0 = lp and lp.seq or 0
                    local t0 = os.clock()
                    tr = nil
                    while os.clock() - t0 < 2 do
                        task.wait()
                        if lastPlayed and lastPlayed.seq ~= seq0 then tr = lastPlayed.track; break end
                    end
                end
                if tr then ctx.animTrack = tr end   -- later Anim at steps ride the same track
            end
        end
        if tr and at > 0 then
            local t0 = os.clock()
            while os.clock() - t0 < 10 do
                local playing, pos = false, 0
                pcall(function() playing, pos = tr.IsPlaying, tr.TimePosition end)
                if not playing or pos >= at then break end
                task.wait()
            end
            pcall(function() trace(("  animwait %.2f reached at pos=%.3f playing=%s"):format(at, tr.TimePosition, tostring(tr.IsPlaying))) end)
        elseif at > 0 then
            trace("  animwait: no animation to bind to (fell through)")
        end
        if ctx.releaseAfterWait then releaseHold(true); ctx.releaseAfterWait = false end
    elseif a.type == "hold" then
        -- press the key DOWN and keep it held until the matching Release
        -- (or the safety release at the end), so steps in between run while held.
        -- a.key may also be a mouse button ("MouseButton1"/"M1" ...).
        local mb = mouseButtonOf(a.key)
        if mb then
            pcall(sendMouse, mb, true); ctx.heldMouse[mb] = true
        else
            local kc = a.key and safeKeyCode(a.key)
            if kc then pcall(function() VIM:SendKeyEvent(true, kc, false, game) end); ctx.heldKeys[kc] = true end
        end
    elseif a.type == "release" then
        local mb = mouseButtonOf(a.key)
        if mb then
            pcall(sendMouse, mb, false); ctx.heldMouse[mb] = nil
        else
            local kc = a.key and safeKeyCode(a.key)
            if kc then pcall(function() VIM:SendKeyEvent(false, kc, false, game) end); ctx.heldKeys[kc] = nil end
        end
    elseif a.type == "feature" then
        if a.feature then
            if ctx.featRestore[a.feature] == nil then ctx.featRestore[a.feature] = feature.getEnabled(a.feature) end
            if a.value == nil then feature.fire(a.feature) else feature.setEnabled(a.feature, a.value) end
        end
    elseif a.type == "return" then
        ctx.restoreAll(true)
    elseif a.type == "and" then
        -- AND step: run each branch as a parallel coroutine; the step finishes
        -- when ALL branches have completed. ctx is shared, so any Hold step
        -- in one branch is released by Release in another (or by the safety
        -- cleanup at tech end).
        local branches = a.branches or {}
        local n = #branches
        if n == 0 then return end
        local done = 0
        for _, branch in ipairs(branches) do
            task.spawn(function()
                -- pcall per branch: an error in one branch must still count it
                -- as finished, or the wait below never ends and `running` sticks.
                local ok, err = pcall(function()
                    for _, step in ipairs(branch or {}) do runStep(step, ctx) end
                end)
                if not ok then log.warn("[tech] AND branch error: " .. tostring(err)) end
                done = done + 1
            end)
        end
        local t0 = os.clock()
        while done < n and os.clock() - t0 < 30 do task.wait(0.03) end   -- 30s cap: never wedge the runner
    elseif a.type == "or" then
        -- OR step: picks ONE branch based on which subtrigger fired this run.
        -- ctx.triggerIndex was set by runTech from the trigger that queueRun'd
        -- us. Branches and triggers are indexed 1:1; out-of-range falls
        -- through (no-op). Steps after the OR keep running in the main flow,
        -- so common "post-merge" actions can follow.
        local branches = a.branches or {}
        local idx = ctx.triggerIndex or 1
        local branch = branches[idx]
        if branch then
            for _, step in ipairs(branch) do runStep(step, ctx) end
        end
    else
        local fn = ACTIONS[a.type]
        if fn then
            local ok, err = pcall(fn, a)
            if not ok then log.warn("[tech] action " .. tostring(a.type) .. ": " .. tostring(err)) end
        end
    end
end

local function runTech(tech, hold, triggerIndex, animTrack)
    if running then return end
    running = true
    runningSince = os.clock()
    task.spawn(function()
        local cam = Workspace.CurrentCamera
        startCamLook = cam and cam.CFrame.LookVector or nil
        local r0 = myRoot()
        startBodyLook = r0 and r0.CFrame.LookVector or nil
        -- "Ignore welds": keep Lock-On/Rotation alive even while welded for this run.
        -- For multi-trigger techs, the firing subtrigger's ignoreWelds wins.
        local triggers = techTriggers(tech)
        local firingTrig = triggers[triggerIndex or 1] or tech.trigger
        local ignoreWelds = firingTrig and firingTrig.ignoreWelds
        if ignoreWelds then state.techIgnoreWelds = true end
        local heldKeys = {}    -- keys pressed by a Hold step, released by a Release (or at the end)
        local heldMouse = {}   -- mouse buttons (VIM index) held by a Hold step
        local featRestore = {} -- [featureId] = state BEFORE this tech toggled it, for Return/end
        local ctx = {
            releaseAfterWait = false, heldKeys = heldKeys, heldMouse = heldMouse, featRestore = featRestore,
            triggerIndex = triggerIndex or 1,   -- which subtrigger fired (OR step reads this)
            animTrack = animTrack,              -- the track that fired an anim trigger ("Anim at" steps wait on it)
            runStart = os.clock(),              -- "Anim at" on a key tech only binds anims that started with this run
        }
        ctx.restoreAll = function(snap)
            releaseHold(snap)
            for id, prev in pairs(featRestore) do pcall(function() feature.setEnabled(id, prev) end); featRestore[id] = nil end
            for kc in pairs(heldKeys) do pcall(function() VIM:SendKeyEvent(false, kc, false, game) end); heldKeys[kc] = nil end
            for mb in pairs(heldMouse) do pcall(sendMouse, mb, false); heldMouse[mb] = nil end
        end
        -- Wrap the whole run so a throw in any step can't leave `running` stuck
        -- true -- that would silently brick EVERY tech (the guard at the top of
        -- runTech bails while running) until a re-execute. The most likely
        -- culprit is an invalid Enum.KeyCode[a.key] on a Hold/Release step with a
        -- bad/hand-edited key name (digit names throw). Cleanup runs either way.
        trace(("run %s (trigger %d)%s"):format(tostring(tech.name), ctx.triggerIndex, animTrack and " anim-bound" or ""))
        local ok, err = pcall(function()
            for i, a in ipairs(tech.actions or {}) do
                if Engine.traceEnabled then
                    local pos = ""
                    pcall(function() if ctx.animTrack then pos = (" animpos=%.3f"):format(ctx.animTrack.TimePosition) end end)
                    trace(("  step %d %s%s"):format(i, tostring(a.type), pos))
                end
                runStep(a, ctx)
            end
            -- one-shot techs auto-clean at the end -- features toggled go back,
            -- held keys release. If a Rotate ran, hold the rotation briefly past
            -- tech end so it is VISIBLE under shiftlock (the game's shiftlock
            -- snaps body back to face cam the instant we release techBodyOverride)
            -- AND so a move fired server-side at the rotated facing has time to
            -- land. ~0.6s = long enough to see + for a JJS cast handshake to
            -- commit; short enough not to feel stuck.
            if not hold then
                -- keep the run alive while any timed Look/Rotate hold is still
                -- counting down (renderHold snaps that axis back when its `expire`
                -- passes); otherwise fall back to the legacy ~0.6s post-rotate
                -- visibility / cast-landing hold.
                local now = os.clock()
                local waitUntil = now
                if held.cam  and held.cam.expire  then waitUntil = math.max(waitUntil, held.cam.expire)  end
                if held.body and held.body.expire then waitUntil = math.max(waitUntil, held.body.expire) end
                if waitUntil > now then
                    task.wait(math.min(waitUntil - now, 30))   -- cap so a stray value can't wedge the runner
                elseif bodyARDisabled then
                    task.wait(0.6)
                end
                ctx.restoreAll(false)
            else
                -- keyhold tech: leave Hold-step keys/buttons + toggled features as
                -- they are; releaseHoldTech() restores them on the trigger key-up.
                if activeHold[tech.id] and activeHold[tech.id] ~= ctx then pcall(function() activeHold[tech.id].restoreAll(false) end) end
                activeHold[tech.id] = ctx
            end
        end)
        if not ok then
            log.warn("[tech] run error: " .. tostring(err))
            pcall(function() ctx.restoreAll(false) end)   -- release holds/keys/features even on error
        end
        -- one-shot: release the weld-ignore now; hold techs keep it until key release
        if ignoreWelds and not hold then state.techIgnoreWelds = false end
        running = false
    end)
end

-- Key-up of a keyhold trigger: snap the facing back AND restore whatever the
-- hold run changed (Hold-step keys, toggled features). Safe to call when the
-- tech never ran (conditions failed): only the facing release happens then.
local function releaseHoldTech(tech, trig)
    local ctx = activeHold[tech.id]
    activeHold[tech.id] = nil
    if ctx then pcall(function() ctx.restoreAll(true) end) else releaseHold(true) end
    if trig and trig.ignoreWelds then state.techIgnoreWelds = false end
end

-- Run a tech FROM A TRIGGER. One-shot techs are queued and dispatched on Heartbeat
-- (drainPending) instead of run straight from the trigger's signal callback: a
-- coroutine task.spawn'd inside an RBXScriptSignal handler doesn't reliably get its
-- task.wait resumed on some executors, which froze a tech at its first Wait. Hold
-- techs just set a facing instantly (no meaningful wait), so they run immediately
-- to avoid a 1-frame gap / fast-tap stuck-facing.
local pendingRuns = {}
local function queueRun(tech, hold, triggerIndex, animTrack)
    if hold then
        runTech(tech, true, triggerIndex, animTrack)
    else
        pendingRuns[#pendingRuns + 1] = { tech = tech, triggerIndex = triggerIndex or 1, animTrack = animTrack }
    end
end
local function drainPending()
    -- watchdog: a run that somehow never cleared `running` (yield that never
    -- resumed) would silently disable every tech; recover after 60s.
    if running and os.clock() - runningSince > 60 then
        log.warn("[tech] runner watchdog: forcing reset")
        running = false
    end
    if checkArmedFires then checkArmedFires() end
    if #pendingRuns == 0 then return end
    local q = pendingRuns; pendingRuns = {}
    for _, item in ipairs(q) do runTech(item.tech, false, item.triggerIndex, item.animTrack) end
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
-- Cached per character: locomotion ids are static once the Animate folder
-- populates, but this is queried on EVERY AnimationPlayed (frequent during
-- movement). The old per-call Animate:GetDescendants() walk + table alloc was
-- steady churn. Rebuild only when the character changes (or the cache hasn't
-- captured anything yet, e.g. Animate not populated on the first call).
local locomotionCache, locomotionCacheChar = nil, nil
local function locomotionIds()
    local ch = LP.Character
    if locomotionCache and locomotionCacheChar == ch and next(locomotionCache) ~= nil then
        return locomotionCache
    end
    local set = {}
    local animate = ch and ch:FindFirstChild("Animate")
    if animate then
        for _, d in ipairs(animate:GetDescendants()) do
            local v = (d:IsA("Animation") and d.AnimationId) or (d:IsA("StringValue") and d.Value)
            local n = v and animIdNum(v); if n then set[n] = true end
        end
    end
    locomotionCache, locomotionCacheChar = set, ch
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
local targetAnimLogRef   -- set once targetAnimLog exists below (Engine.animLength reads both)
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
    local len = 0
    pcall(function() len = track and track.Length or 0 end)
    animLog[#animLog + 1] = { id = id, raw = raw, label = label or ("anim " .. id), length = len }
end
function Engine.animHistory() return animLog end
-- Length (seconds) of an animation we've seen play, for the editor's timeline.
-- nil if never seen (the editor then loads it on the preview rig to measure).
function Engine.animLength(id)
    local n = animIdNum(id)
    if not n then return nil end
    for _, h in ipairs(animLog) do if h.id == n and (h.length or 0) > 0 then return h.length end end
    for _, h in ipairs(targetAnimLogRef or {}) do if h.id == n and (h.length or 0) > 0 then return h.length end end
    return nil
end
-- wipe the played-anim log (the dropdown gets cluttered with emotes/effects)
function Engine.clearAnimHistory()
    for i = #animLog, 1, -1 do animLog[i] = nil end
    for k in pairs(animLogSeen) do animLogSeen[k] = nil end
end

-- Fire `fire()` at the point in `track` the trigger asks for: start (default),
-- a time in seconds (trig.animAt), or the end (trig.animEnd). The timed path
-- polls TimePosition per frame; if the track stops before reaching the time it
-- never fires (a cancelled move shouldn't run the follow-up).
local function armAnimFire(track, trig, fire)
    local at = tonumber(trig.animAt)
    -- a picked time wins over a leftover animEnd (older saves can carry both)
    if at and at > 0 then
        -- Polled from Heartbeat (drainPending), NOT from a thread spawned here:
        -- a coroutine task.spawn'd inside a signal handler doesn't reliably get
        -- its task.wait resumed on Wave (the same reason trigger runs are
        -- queued to Heartbeat), so an in-handler poll loop fired late or never.
        armedFires[#armedFires + 1] = { track = track, at = at, fire = fire, t0 = os.clock() }
        local len = 0; pcall(function() len = track.Length end)
        trace(("armed anim fire @%.2fs (track len %.2f)"):format(at, len or 0))
    elseif trig.animEnd then
        local conn
        conn = track.Stopped:Connect(function()
            if conn then conn:Disconnect(); conn = nil end
            fire()
        end)
    else
        fire()
    end
end
-- Every Heartbeat: fire any armed timed trigger whose track has reached its
-- time; drop ones whose track stopped first (cancelled move) or timed out.
checkArmedFires = function()
    if #armedFires == 0 then return end
    local keep = {}
    for _, e in ipairs(armedFires) do
        local ok, pos, playing = pcall(function() return e.track.TimePosition, e.track.IsPlaying end)
        if not ok then
            trace("armed fire dropped (track gone)")
        elseif pos >= e.at then
            trace(("anim fire @%.3f (armed for %.2f)"):format(pos, e.at))
            e.fire()
        elseif playing and os.clock() - e.t0 < 30 then
            keep[#keep + 1] = e
        else
            trace(("armed fire dropped (anim stopped at %.3f before %.2f)"):format(pos, e.at))
        end
    end
    armedFires = keep
end

-- The local player's currently playing track for an anim id (for "Anim at" with an explicit id).
playingTrackById = function(idNum)
    local ch = LP.Character
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    local an = hum and hum:FindFirstChildOfClass("Animator")
    if not an then return nil end
    local ok, tracks = pcall(function() return an:GetPlayingAnimationTracks() end)
    if not ok or not tracks then return nil end
    for _, tr in ipairs(tracks) do
        local a = tr.Animation
        if a and tostring(a.AnimationId):find(idNum, 1, true) then return tr end
    end
    return nil
end

local function animAtLabel(trig)
    local at = tonumber(trig.animAt)
    if at and at > 0 then return string.format(" @%.2fs", at) end
    if trig.animEnd then return " @end" end
    return ""
end

local function onAnimPlayed(track)
    local raw = track and track.Animation and track.Animation.AnimationId
    local id = animIdNum(raw)
    if not id then return end
    -- a first play can report Length 0 before the asset streams in; fix it up
    for _, h in ipairs(animLog) do
        if h.id == id and (h.length or 0) == 0 then pcall(function() h.length = track.Length end) end
    end
    local watching = false
    for _, tech in pairs(techs) do
        if tech.enabled then
            for tidx, trig in ipairs(techTriggers(tech)) do
                if trig.event == "anim" then
                    watching = true
                    if animIdNum(trig.animId) == id and modifierHeld(trig, tech.trigger) and conditionsMet(tech, trig) and scopeMatches(tech) then
                        armAnimFire(track, trig, function()
                            -- re-check gates if we waited (time/end): the situation may have changed
                            if (trig.animEnd or tonumber(trig.animAt)) and not (tech.enabled and modifierHeld(trig, tech.trigger) and conditionsMet(tech, trig) and scopeMatches(tech)) then return end
                            log.info("[tech] anim trigger fired: " .. tostring(tech.name) .. " <- " .. id .. animAtLabel(trig))
                            queueRun(tech, false, tidx, track)
                        end)
                    end
                end
            end
        end
    end
    -- diagnostic: with an anim tech ON, log every id that plays so you can see
    -- whether the hook catches your move and what id to bind it to.
    if watching then log.info("[tech] anim played: " .. id) end
    -- below: moves only -- skip locomotion AND emotes so the dropdown/Capture
    -- stay clean. Emote anims live under paths containing "Emote" (e.g.
    -- ReplicatedStorage.Emotes.* in JJS); a played emote was flooding the picker
    -- as the moveset list. Note: existing anim techs bound to an emote id still
    -- fire (the firing check above runs before this filter); we just don't add
    -- new emote anims to history or hand them to Capture.
    if locomotionIds()[id] then return end
    do
        local path = animNameMap[id]
        if not path then
            local a = track and track.Animation
            local ok, full = pcall(function() return a and a:GetFullName() end)
            if ok and full then path = full end
        end
        if path and path:lower():find("emote", 1, true) then return end
    end
    lastPlayed = { track = track, id = id, t = os.clock(), seq = (lastPlayed and lastPlayed.seq or 0) + 1 }
    if Engine.traceEnabled then
        local len = 0; pcall(function() len = track.Length end)
        trace(("anim played %s (len %.2f)"):format(id, len or 0))
    end
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

-- ===== target_anim event =====
-- Mirror of the local-player anim hook but watching state.target's Animator,
-- re-hooked whenever the target changes (state.onTargetChanged). The dispatcher
-- only fires target_anim-event techs (NOT the LP anim techs). target anim
-- history is kept separately so the editor picker doesn't conflate them.
local targetAnimLog, targetAnimLogSeen = {}, {}
targetAnimLogRef = targetAnimLog   -- upvalue for Engine.animLength (declared above it)
local targetAnimCaptureCbs = {}
function Engine.targetAnimHistory() return targetAnimLog end
function Engine.clearTargetAnimHistory()
    for i = #targetAnimLog, 1, -1 do targetAnimLog[i] = nil end
    for k in pairs(targetAnimLogSeen) do targetAnimLogSeen[k] = nil end
end
function Engine.captureTargetAnim(cb) targetAnimCaptureCbs[#targetAnimCaptureCbs + 1] = cb end

local function recordTargetAnim(track, id, raw)
    if targetAnimLogSeen[id] then return end
    loadAnimNames()
    local label = animNameMap[id] and shortPath(animNameMap[id])
    if not label then
        local a = track and track.Animation
        local ok, full = pcall(function() return a and a:GetFullName() end)
        if ok and full and full ~= "" and full ~= "Animation" then label = shortPath(full)
        elseif a and a.Name and a.Name ~= "" and a.Name ~= "Animation" then label = a.Name end
    end
    targetAnimLogSeen[id] = true
    local len = 0
    pcall(function() len = track and track.Length or 0 end)
    targetAnimLog[#targetAnimLog + 1] = { id = id, raw = raw, label = label or ("anim " .. id), length = len }
end

local function onTargetAnimPlayed(track)
    local raw = track and track.Animation and track.Animation.AnimationId
    local id = animIdNum(raw)
    if not id then return end
    for _, tech in pairs(techs) do
        if tech.enabled then
            for tidx, trig in ipairs(techTriggers(tech)) do
                if trig.event == "target_anim" then
                    if animIdNum(trig.animId) == id and modifierHeld(trig, tech.trigger) and conditionsMet(tech, trig) and scopeMatches(tech) then
                        armAnimFire(track, trig, function()
                            if (trig.animEnd or tonumber(trig.animAt)) and not (tech.enabled and modifierHeld(trig, tech.trigger) and conditionsMet(tech, trig) and scopeMatches(tech)) then return end
                            log.info("[tech] target_anim trigger fired: " .. tostring(tech.name) .. " <- " .. id .. animAtLabel(trig))
                            queueRun(tech, false, tidx, track)
                        end)
                    end
                end
            end
        end
    end
    recordTargetAnim(track, id, raw)
    if #targetAnimCaptureCbs > 0 then
        local cbs = targetAnimCaptureCbs; targetAnimCaptureCbs = {}
        for _, cb in ipairs(cbs) do pcall(cb, raw) end
    end
end

local targetAnimConns = {}
local function clearTargetAnimHook()
    for _, c in ipairs(targetAnimConns) do pcall(function() c:Disconnect() end) end
    targetAnimConns = {}
end
local function hookTargetAnimator()
    clearTargetAnimHook()
    local t = state.target
    if not t then return end
    local ch = (state.target_type == "npc") and t or t.Character
    if not ch then
        -- Player target whose Character hasn't spawned yet -- wait for it.
        if state.target_type ~= "npc" and t.CharacterAdded then
            targetAnimConns[#targetAnimConns + 1] = t.CharacterAdded:Connect(function() hookTargetAnimator() end)
        end
        return
    end
    local hum = ch:FindFirstChildOfClass("Humanoid")
    if not hum then
        targetAnimConns[#targetAnimConns + 1] = ch.ChildAdded:Connect(function(c)
            if c:IsA("Humanoid") then hookTargetAnimator() end
        end)
        return
    end
    local animator = hum:FindFirstChildOfClass("Animator")
    if animator then
        targetAnimConns[#targetAnimConns + 1] = animator.AnimationPlayed:Connect(onTargetAnimPlayed)
        log.info("[tech] target_anim hook connected (" .. tostring(ch.Name) .. ")")
    else
        targetAnimConns[#targetAnimConns + 1] = hum.ChildAdded:Connect(function(c)
            if c:IsA("Animator") then hookTargetAnimator() end
        end)
    end
end

-- ===== trigger wiring =====
-- All trigger wiring takes (tech, trig, tidx) so multi-trigger "or" techs
-- bind each subtrigger with a unique keybind id + CAS action name. tidx
-- flows down to queueRun -> runTech.ctx.triggerIndex so the OR step picks
-- the right branch on fire.
local function wireKey(tech, trig, tidx)
    local key = trig.key
    if not key or key == Enum.KeyCode.Unknown then return end
    local isHold = trig.event == "keyhold"
    local bindId = "tech." .. tech.id .. "." .. tidx
    if trig.suppress then
        keybinds.clear(bindId)
        local action = "PantheonTech_" .. tech.id .. "_" .. tidx
        CAS:BindActionAtPriority(action, function(_, inputState)
            if bypassKeys[key] then return Enum.ContextActionResult.Pass end
            if inputState == Enum.UserInputState.Begin then
                if tech.enabled and modifierHeld(trig, tech.trigger) and conditionsMet(tech, trig) and scopeMatches(tech) then queueRun(tech, isHold, tidx) end
            elseif inputState == Enum.UserInputState.End and isHold then
                releaseHoldTech(tech, trig)
            end
            return Enum.ContextActionResult.Sink
        end, false, 3000, key)
        casBound[tech.id .. ".." .. tidx] = action
        return
    end
    keybinds.set(bindId, key,
        function()
            if bypassKeys[key] then return end   -- our own VIM-sent key (Press step) must not re-trigger us
            if tech.enabled and modifierHeld(trig, tech.trigger) and conditionsMet(tech, trig) and scopeMatches(tech) then queueRun(tech, isHold, tidx) end
        end,
        function() if isHold then releaseHoldTech(tech, trig) end end)
end

local function wireMove(tech, trig, tidx)
    local keyName = trig.movekey
    local kc = keyName and safeKeyCode(keyName)
    if not kc or kc == Enum.KeyCode.Unknown then
        log.warn("[tech] '" .. tostring(tech.name) .. "': move trigger has no key set -- pick the move's key")
        return
    end
    local bindId = "tech." .. tech.id .. "." .. tidx
    if trig.suppress then
        keybinds.clear(bindId)
        local action = "PantheonTech_" .. tech.id .. "_" .. tidx
        CAS:BindActionAtPriority(action, function(_, inputState)
            if bypassKeys[kc] then return Enum.ContextActionResult.Pass end
            if inputState == Enum.UserInputState.Begin
               and tech.enabled and modifierHeld(trig, tech.trigger) and conditionsMet(tech, trig) and scopeMatches(tech) then
                queueRun(tech, false, tidx)
            end
            return Enum.ContextActionResult.Sink
        end, false, 3000, kc)
        casBound[tech.id .. ".." .. tidx] = action
        return
    end
    keybinds.set(bindId, kc,
        function()
            if bypassKeys[kc] then return end
            if tech.enabled and modifierHeld(trig, tech.trigger) and conditionsMet(tech, trig) and scopeMatches(tech) then queueRun(tech, false, tidx) end
        end,
        nil)
end

-- Rewire + list refresh are coalesced to once per frame: loadCustom / a game
-- module registering N techs used to do N full rewires, each walking the whole
-- PlayerGui for move-button suppression, and N UI list rebuilds.
local rewireScheduled = false
local function scheduleRewire()
    if rewireScheduled then return end
    rewireScheduled = true
    local function go() rewireScheduled = false; Engine.rewire(); Engine.changed:Fire() end
    if task and task.defer then task.defer(go) else go() end
end

function Engine.rewire()
    for _, list in pairs(conns) do for _, c in ipairs(list) do pcall(function() c:Disconnect() end) end end
    conns = {}
    for _, action in pairs(casBound) do pcall(function() CAS:UnbindAction(action) end) end
    casBound = {}
    for _, tech in pairs(techs) do
        -- Clear any prior trigger keybinds (legacy single-slot + multi-slot
        -- 1..8 for safety -- a tech that was an "or" with 5 subtriggers but
        -- got edited down to 2 shouldn't leave 3..5 bound).
        keybinds.clear("tech." .. tech.id)
        for i = 1, 8 do keybinds.clear("tech." .. tech.id .. "." .. i) end
        if tech.enabled then
            for tidx, trig in ipairs(techTriggers(tech)) do
                local ev = trig.event
                if ev == "key" or ev == "keyhold" then
                    wireKey(tech, trig, tidx)
                elseif ev == "move" then
                    wireMove(tech, trig, tidx)
                end
                -- anim / target_anim are dispatched by the persistent Animator
                -- hooks (onAnimPlayed / onTargetAnimPlayed) and don't need
                -- per-trigger wiring here.
            end
        end
    end
    pcall(Engine.applySuppression)   -- cancel/restore move buttons per current techs
end

-- ===== persistence =====
-- enabled-state is persisted per tech for EVERY tech (examples + custom) so
-- toggles survive reloads. Custom (user-built) techs also persist their full
-- definition under one "tech.custom" map, rehydrated on boot via loadCustom().
local ENABLED_KEY = "tech.enabled."
-- Custom techs are stored under this key in TWO tiers: the per-game store for
-- game/char-scoped techs, and the cross-game GLOBAL store (persist.*Global) for
-- "universal" techs so they transfer to every experience. saveCustom routes by
-- scope; loadCustom reads both (and migrates legacy per-game universals up).
local CUSTOM_KEY  = "tech.custom"

-- Serialize a single trigger table (used for tech.trigger AND each entry in
-- tech.trigger.subtriggers for "or" techs). Same field shape either way.
local function serializeTrigger(trig)
    if not trig then return {} end
    return {
        event      = trig.event,
        key        = persist.keyToString(trig.key),
        move       = trig.move,
        movekey    = trig.movekey,
        modkey     = trig.modkey,
        maxRange   = trig.maxRange,
        animId     = trig.animId,
        animEnd    = trig.animEnd,
        animAt     = trig.animAt,
        targetAnimId = trig.targetAnimId,
        suppress   = trig.suppress,
        ignoreWelds = trig.ignoreWelds,
    }
end
local function deserializeTrigger(s)
    if not s then return nil end
    -- a picked time wins: older saves can carry animEnd=true next to animAt
    local animEnd = s.animEnd
    local at = tonumber(s.animAt)
    if at and at > 0 then animEnd = nil end
    return {
        event      = s.event,
        key        = persist.stringToKey(s.key),
        move       = s.move,
        movekey    = s.movekey,
        modkey     = s.modkey,
        maxRange   = s.maxRange,
        animId     = s.animId,
        animEnd    = animEnd,
        animAt     = s.animAt,
        targetAnimId = s.targetAnimId,
        suppress   = s.suppress,
        ignoreWelds = s.ignoreWelds,
    }
end

local function serialize(tech)
    local trig = tech.trigger or {}
    local serTrig = serializeTrigger(trig)
    serTrig.conditions = trig.conditions or {}
    -- "or" techs carry an array of subtriggers; serialize each.
    if trig.event == "or" and type(trig.subtriggers) == "table" then
        local sub = {}
        for i, st in ipairs(trig.subtriggers) do sub[i] = serializeTrigger(st) end
        serTrig.subtriggers = sub
    end
    return {
        id      = tech.id,
        name    = tech.name,
        scope   = tech.scope,
        enabled = tech.enabled,
        trigger = serTrig,
        actions = tech.actions or {},
    }
end

local function deserialize(s)
    local trigOut = deserializeTrigger(s.trigger) or {}
    trigOut.conditions = (s.trigger and s.trigger.conditions) or {}
    if s.trigger and s.trigger.event == "or" and type(s.trigger.subtriggers) == "table" then
        local sub = {}
        for i, st in ipairs(s.trigger.subtriggers) do sub[i] = deserializeTrigger(st) end
        trigOut.subtriggers = sub
    end
    return {
        id      = s.id,
        name    = s.name,
        scope   = s.scope,
        enabled = s.enabled,
        custom  = true,
        trigger = trigOut,
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
    -- Built-in techs persist their on/off per-game via ENABLED_KEY. Custom techs
    -- instead carry `enabled` inside their stored definition (per-game OR the
    -- cross-game map for universal techs), so don't let a stale per-game
    -- ENABLED_KEY override a custom's saved state.
    if not tech.custom then
        local savedEnabled = persist.get(ENABLED_KEY .. tech.id)
        if savedEnabled ~= nil then tech.enabled = savedEnabled and true or false end
    end
    techs[tech.id] = tech
    scheduleRewire()
end

-- Persist a user-built tech's full definition (and add/replace it live).
function Engine.saveCustom(tech)
    tech.custom = true
    Engine.add(tech)
    local ser = serialize(tech)
    -- Route by scope: universal -> cross-game store, else per-game. Always clear
    -- the OTHER tier too, so changing a tech's scope MOVES it instead of leaving a
    -- stale duplicate that would reappear / fire in the wrong place.
    local g = persist.getGlobal(CUSTOM_KEY, {}) or {}
    local m = persist.get(CUSTOM_KEY, {}) or {}
    if tech.scope == "universal" then
        g[tech.id] = ser; m[tech.id] = nil
    else
        m[tech.id] = ser; g[tech.id] = nil
    end
    persist.setGlobal(CUSTOM_KEY, g)
    persist.set(CUSTOM_KEY, m)
    persist.scheduleSave()
end

-- Rehydrate persisted user-built techs. Call once at init.
function Engine.loadCustom()
    -- cross-game (universal) customs: load in EVERY game
    local g = persist.getGlobal(CUSTOM_KEY, {}) or {}
    for _, s in pairs(g) do
        if s and s.id then Engine.add(deserialize(s)) end
    end
    -- per-game customs: load here. Older builds saved UNIVERSAL techs in the
    -- per-game file (so they never transferred) -- migrate those up to the global
    -- store now, then they'll load everywhere from the branch above going forward.
    local m = persist.get(CUSTOM_KEY, {}) or {}
    local migrated = false
    for id, s in pairs(m) do
        if s and s.id then
            Engine.add(deserialize(s))
            if s.scope == "universal" then
                g[id] = s
                m[id] = nil          -- safe: deleting the current key during pairs()
                migrated = true
            end
        end
    end
    if migrated then
        persist.setGlobal(CUSTOM_KEY, g)
        persist.set(CUSTOM_KEY, m)
        persist.scheduleSave()
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
    -- Custom techs keep their on/off inside the stored definition (so a universal
    -- tech's state is the same in every game); built-ins persist it per-game.
    if t.custom then
        if t.scope == "universal" then
            local g = persist.getGlobal(CUSTOM_KEY, {}) or {}
            if g[id] then g[id].enabled = t.enabled; persist.setGlobal(CUSTOM_KEY, g) end
        else
            local m = persist.get(CUSTOM_KEY, {}) or {}
            if m[id] then m[id].enabled = t.enabled; persist.set(CUSTOM_KEY, m); persist.scheduleSave() end
        end
    else
        persist.set(ENABLED_KEY .. id, t.enabled)
    end
    scheduleRewire()
end

function Engine.remove(id)
    local t = techs[id]
    techs[id] = nil
    persist.set(ENABLED_KEY .. id, nil)
    if t and t.custom then
        -- could live in either tier (universal -> global, else per-game); clear both
        local m = persist.get(CUSTOM_KEY, {}) or {}; m[id] = nil
        local g = persist.getGlobal(CUSTOM_KEY, {}) or {}; g[id] = nil
        persist.set(CUSTOM_KEY, m)
        persist.setGlobal(CUSTOM_KEY, g)
        persist.scheduleSave()
    end
    keybinds.clear("tech." .. id)
    for i = 1, 8 do keybinds.clear("tech." .. id .. "." .. i) end   -- per-trigger binds too, or a deleted tech keeps firing
    if activeHold[id] then pcall(function() activeHold[id].restoreAll(true) end); activeHold[id] = nil end
    scheduleRewire()
end

function Engine.init()
    if bound then return end
    traceReset()
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
    charAddedConn = LP.CharacterAdded:Connect(function(ch)
        task.spawn(function()
            local hum = ch:WaitForChild("Humanoid", 10)
            if hum then hum:WaitForChild("Animator", 5) end
            hookAnimator()
        end)
    end)
    -- target_anim hook: re-arm whenever the lock-on/target-select target changes
    -- so triggers can fire on the opponent's animation. Hook the initial target
    -- (if Target Select is already active when init runs) and reset on target
    -- becoming nil too (clearTargetAnimHook).
    hookTargetAnimator()
    targetChangedConn = state.onTargetChanged:Connect(function()
        hookTargetAnimator()
    end)
    bound = true
end

function Engine.destroy()
    if bound then pcall(function() RunService:UnbindFromRenderStep(RENDER_BIND) end); bound = false end
    if drainConn then pcall(function() drainConn:Disconnect() end); drainConn = nil end
    if targetChangedConn then pcall(function() targetChangedConn:Disconnect() end); targetChangedConn = nil end
    if charAddedConn then pcall(function() charAddedConn:Disconnect() end); charAddedConn = nil end
    -- the persistent Animator.AnimationPlayed hook survives a script reload (the
    -- Animator isn't destroyed), so disconnect it or the old instance keeps
    -- firing onAnimPlayed alongside the new one after a re-execute.
    for _, c in ipairs(animHookConns) do pcall(function() c:Disconnect() end) end
    animHookConns = {}
    clearTargetAnimHook()
    for _, list in pairs(conns) do for _, c in ipairs(list) do pcall(function() c:Disconnect() end) end end
    conns = {}
    -- key sinks / keybinds / cancelled move buttons must not outlive this instance:
    -- after a re-execute the old closures kept sinking keys and firing dead techs.
    for _, action in pairs(casBound) do pcall(function() CAS:UnbindAction(action) end) end
    casBound = {}
    for id in pairs(techs) do
        keybinds.clear("tech." .. id)
        for i = 1, 8 do keybinds.clear("tech." .. id .. "." .. i) end
    end
    for b in pairs(suppressed) do unsuppressButton(b) end
    for id, ctx in pairs(activeHold) do pcall(function() ctx.restoreAll(true) end); activeHold[id] = nil end
    pendingRuns = {}
    running = false
    releaseHold(true)
    if techAlign then pcall(function() techAlign:Destroy() end); techAlign = nil end
    if techAttach then pcall(function() techAttach:Destroy() end); techAttach = nil end
end

return Engine
