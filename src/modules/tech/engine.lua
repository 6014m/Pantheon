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

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace  = game:GetService("Workspace")
local RS         = game:GetService("ReplicatedStorage")
local VIM        = game:GetService("VirtualInputManager")

local Engine = {}
Engine.changed = Signal.new()   -- fires when the tech set changes (UI list re-reads it)
local LP = Players.LocalPlayer

local techs = {}     -- id -> tech def
local conns = {}     -- id -> { Connection, ... } (move-trigger listeners)
local RENDER_BIND = "PantheonTechHold"
local bound = false

-- held camera/body facings; the render loop enforces these each frame while set.
local held = { cam = nil, body = nil }   -- each = { yaw, pitch } degrees, target-relative
local startCamLook                        -- camera LookVector at tech start (no-target fallback)
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

local function conditionsMet(tech)
    for _, c in ipairs(tech.trigger.conditions or {}) do
        local fn = CONDITIONS[c]
        if fn and not fn() then return false end
    end
    return true
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
        local releaseAfterWait = false
        for _, a in ipairs(tech.actions or {}) do
            if a.type == "during" then
                -- the preceding Look/Rotate lasts only as long as the NEXT Wait,
                -- then auto-returns (so "Rotate -> During -> Wait 0.5" rotates for
                -- exactly 0.5s).
                releaseAfterWait = true
            elseif a.type == "wait" then
                task.wait(a.seconds or a.x or 0.5)
                if releaseAfterWait then releaseHold(); releaseAfterWait = false end
            else
                local fn = ACTIONS[a.type]
                if fn then local ok, err = pcall(fn, a); if not ok then log.warn("[tech] action " .. tostring(a.type) .. ": " .. tostring(err)) end end
            end
        end
        -- one-shot triggers auto-clean at the end (in case the tech has no Return).
        -- hold triggers keep the held facing until the key is released.
        if not hold then releaseHold() end
        running = false
    end)
end

-- ===== trigger wiring =====
local function wireKey(tech)
    local key = tech.trigger.key
    if not key or key == Enum.KeyCode.Unknown then return end
    local isHold = tech.trigger.event == "keyhold"
    keybinds.set("tech." .. tech.id, key,
        function() if tech.enabled and conditionsMet(tech) then runTech(tech, isHold) end end,
        function() if isHold then releaseHold() end end)
end

local function wireMove(tech)
    -- ReplicatedStorage.Knit.Knit.Services.<move>.RE.Effects -- the server's
    -- broadcast of a move's VFX, which our own client also receives with the
    -- caster among the args (that's how we detect "I used this move"). Non-
    -- yielding lookup so toggling a tech never stalls. (Activated is the
    -- client->server remote, so its OnClientEvent never fires -- don't use it.)
    local knit     = RS:FindFirstChild("Knit")
    local inner    = knit and knit:FindFirstChild("Knit")
    local services = inner and inner:FindFirstChild("Services")
    local svc      = services and services:FindFirstChild(tech.trigger.move)
    local re       = svc and svc:FindFirstChild("RE")
    local eff      = re and re:FindFirstChild("Effects")
    if not eff then
        log.warn("[tech] '" .. tostring(tech.name) .. "': " .. tostring(tech.trigger.move) ..
            ".RE.Effects not found -- move trigger won't fire (check the service name)")
        return
    end
    local c = eff.OnClientEvent:Connect(function(...)
        if not tech.enabled then return end
        local ch, mine = myChar(), false
        for i = 1, select("#", ...) do
            local arg = select(i, ...)
            if arg == ch or (typeof(arg) == "Instance" and ch and arg:IsDescendantOf(ch)) then mine = true; break end
        end
        if mine and conditionsMet(tech) then runTech(tech, false) end
    end)
    conns[tech.id] = conns[tech.id] or {}
    table.insert(conns[tech.id], c)
end

function Engine.rewire()
    for _, list in pairs(conns) do for _, c in ipairs(list) do pcall(function() c:Disconnect() end) end end
    conns = {}
    for _, tech in pairs(techs) do
        local ev = tech.trigger and tech.trigger.event
        if ev == "key" or ev == "keyhold" then
            -- Only bind the key while the tech is ON; clear it when OFF so a
            -- disabled tech's key is genuinely unbound (can't fire), matching how
            -- move techs are gated.
            if tech.enabled then wireKey(tech) else keybinds.clear("tech." .. tech.id) end
        elseif ev == "move" and tech.enabled then
            wireMove(tech)
        end
    end
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
function Engine.run(tech) if tech then runTech(tech, false) end end

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
    bound = true
end

function Engine.destroy()
    if bound then pcall(function() RunService:UnbindFromRenderStep(RENDER_BIND) end); bound = false end
    for _, list in pairs(conns) do for _, c in ipairs(list) do pcall(function() c:Disconnect() end) end end
    conns = {}
    releaseHold()
    if techAlign then pcall(function() techAlign:Destroy() end); techAlign = nil end
    if techAttach then pcall(function() techAttach:Destroy() end); techAttach = nil end
end

return Engine
