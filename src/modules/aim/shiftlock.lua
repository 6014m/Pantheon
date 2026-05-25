-- Custom shiftlock. Replaces Roblox's built-in and any competing custom
-- shiftlock loops. Three layers of foreign-killer:
--   1. PlayerGui sweep: destroy ScreenGuis with known foreign names.
--   2. Connection sweep: walk RenderStepped/Heartbeat/Stepped and disconnect
--      any callback whose bytecode constants include both "MouseBehavior" AND
--      "LockCenter" — every shiftlock loop has to reference those literals to
--      actually do anything. Backup heuristic looks at upvalue tables for a
--      shiftLocked-flag + Humanoid-ref pattern.
--   3. PlayerScripts sweep: disable LocalScripts whose name contains
--      "shiftlock".
-- Runs on boot, enable, disable, and respawn so foreign code that reconnects
-- doesn't quietly take back over.

local env      = require("core.env")
local state    = require("modules.aim.state")
local log      = require("core.log")
local keybinds = require("core.keybinds")

local Players             = game:GetService("Players")
local UserInputService    = game:GetService("UserInputService")
local RunService          = game:GetService("RunService")
local VirtualInputManager = game:GetService("VirtualInputManager")

local Shiftlock = {}

local ZERO3 = Vector3.new(0, 0, 0)
local RENDER_BIND = "PantheonShiftlock"
-- Randomised at script-load so game-side ScreenGui-name scanners can't
-- pattern-match "PantheonShiftLockVGui" / "ShiftLockVGui". Lives in
-- self_state once the GUI is built; killForeignGuis(), which only checks
-- PlayerGui anyway, doesn't need to know it (the GUI is parented to
-- env.guiParent() = gethui sandbox, not PlayerGui, so scans miss it).
local GUI_NAME    = "_" .. tostring(math.random(100000, 999999))

local FOREIGN_GUI_NAMES = {
    "ShiftLockVGui", "ShiftLockIcon", "ShiftLockHud", "ShiftLockButton",
    "CustomShiftLock", "ShiftLockGui", "ShiftlockGui",
}

local self_state = {
    character = nil,
    humanoid  = nil,
    root      = nil,
    gui       = nil,
    vIcon     = nil,
    charConn  = nil,
    humConn   = nil,
    focusConn = nil,
    externalSkipRotation = nil,
    bound = false,
    hookInstalled = false,
    blockedWrites = 0,
    lastBlockedLog = 0,
    weldCheckLast = 0,
    weldCheckResult = false,
    -- pair mode: are we currently hiding the game's shiftlock icon?
    iconsHidden = false,
    -- Set true by Shiftlock.destroy() so the previously-installed hook
    -- becomes a pure pass-through and the hookGuard task exits, letting a
    -- freshly re-executed Pantheon take over without thrashing.
    shutdown = false,
}

-- Cached weld-to-other-character check. Battlegrounds-style grab moves
-- weld the attacker to the victim; if we then rotate our own root via
-- shiftlock, the weld drags the victim around too. Wraps the shared helper
-- in [[modules.aim.state]] with a 50ms cache so the rotation pass isn't
-- walking the character descendants on every render.
local function isLocalWeldedToOther()
    return state.isWeldedToOther(self_state.character)
end

local function weldedToOther()
    -- User can opt out of the safety entirely (per-game via persisted
    -- setting). Used to recover rotation through grab-style welds that
    -- some games rely on for "nerf" moves -- e.g. JJS locking your aim by
    -- welding your HRP to the victim. With the safety off, root.CFrame
    -- writes still go through and the rotation tracks the camera.
    if not state.weldSafetyEnabled then return false end
    -- 50ms cache so we don't walk descendants every frame.
    local now = os.clock()
    if now - self_state.weldCheckLast > 0.05 then
        self_state.weldCheckResult = isLocalWeldedToOther()
        self_state.weldCheckLast = now
    end
    return self_state.weldCheckResult
end

local function lp() return Players.LocalPlayer end

local function disableGameShiftLock()
    pcall(function() lp().DevEnableMouseLock = false end)
end

-- ---------- foreign killer helpers --------------------------------------

local function getConnectionFunction(conn)
    for _, key in ipairs({ "Function", "Func", "func" }) do
        local ok, fn = pcall(function() return conn[key] end)
        if ok and type(fn) == "function" then return fn end
    end
    return nil
end

local function getConstants(fn)
    local f = (getconstants) or (debug and debug.getconstants)
    if not f then return nil end
    local ok, c = pcall(f, fn)
    if not ok then return nil end
    return c
end

local function getUpvalues(fn)
    local f = (getupvalues) or (debug and debug.getupvalues)
    if not f then return nil end
    local ok, c = pcall(f, fn)
    if not ok then return nil end
    return c
end

-- Strong signature: function code contains both literals.
local function functionLooksLikeShiftlock(fn)
    local consts = getConstants(fn)
    if not consts then return false end
    local hasMB, hasLC = false, false
    for _, c in pairs(consts) do
        if type(c) == "string" then
            if c == "MouseBehavior" then hasMB = true end
            if c == "LockCenter"    then hasLC = true end
        end
    end
    return hasMB and hasLC
end

-- Backup signature: upvalue table looks like a ShiftLockModule self-state.
local function upvaluesLookLikeShiftlock(fn)
    local ups = getUpvalues(fn)
    if not ups then return false end
    for _, up in pairs(ups) do
        if type(up) == "table" then
            local hasFlag = (up.shiftLocked ~= nil) or (up.shiftlock_locked ~= nil)
                         or (up.locked ~= nil) or (up.isLocked ~= nil)
            local hasInstRef = (typeof(up.humanoid)  == "Instance")
                            or (typeof(up.character) == "Instance")
                            or (typeof(up.root)      == "Instance")
                            or (typeof(up.hrp)       == "Instance")
            if hasFlag and hasInstRef then return true end
        end
    end
    return false
end

local function killForeignGuis()
    local pg = lp():FindFirstChildOfClass("PlayerGui")
    if not pg then return 0 end
    local count = 0
    for _, gui in ipairs(pg:GetChildren()) do
        if gui:IsA("ScreenGui") and gui.Name ~= GUI_NAME then
            for _, foreign in ipairs(FOREIGN_GUI_NAMES) do
                if gui.Name == foreign then
                    gui:Destroy()
                    count = count + 1
                    break
                end
            end
        end
    end
    return count
end

local function killForeignLoops()
    if not getconnections then return 0, 0 end
    local killed, scanned = 0, 0
    for _, signal in ipairs({ RunService.RenderStepped, RunService.Heartbeat, RunService.Stepped }) do
        local ok, conns = pcall(getconnections, signal)
        if ok and type(conns) == "table" then
            for _, conn in pairs(conns) do
                scanned = scanned + 1
                local fn = getConnectionFunction(conn)
                if fn and (functionLooksLikeShiftlock(fn) or upvaluesLookLikeShiftlock(fn)) then
                    local dok = pcall(function() conn:Disconnect() end)
                    if dok then killed = killed + 1 end
                end
            end
        end
    end
    return killed, scanned
end

-- (deliberately no disableForeignScripts / reEnableForeignScripts: the
-- __newindex hook and the step-pin pass already block the game's writes when
-- Pantheon is on, and the LocalScript stays running the whole time. When
-- Pantheon goes off the hook is pass-through and the game's shiftlock works
-- exactly as if Pantheon were never loaded. This avoids the toggle lag from
-- walking PlayerScripts:GetDescendants() and the re-enable race that left
-- the cursor stuck locked after disable.)

-- Install a __newindex hook on UserInputService so we intercept every write to
-- MouseBehavior. With killForeign on, only writes that match Pantheon's
-- current desired state get through; everything else is silently swallowed.
-- This is what actually beats foreign shiftlocks that win via BindToRenderStep
-- at higher priority than us, or that run on Heartbeat, or that use any other
-- path - they can't write the property at all.
--
-- Persists `realOriginal` across re-installs so if a foreign script also hooks
-- __newindex and we re-install on top of theirs, we still pass through to the
-- real engine setter at the end of the chain (not theirs).
local realOriginal = nil

-- Forward declarations. These are referenced by closures defined ABOVE their
-- real definitions: the hook closure uses shouldEnforce(), and Shiftlock.setEnabled
-- uses the lazy aliases. Declaring them as locals here means those references
-- capture the right upvalue instead of resolving to a nil global -- the previous
-- ordering made the hook error on every write and setEnabled error on every
-- enable/respawn.
local shouldEnforce
local installMouseBehaviorHookLazy, spawnHookGuardLazy

local function installMouseBehaviorHook()
    if type(hookmetamethod) ~= "function" then
        log.debug("shiftlock: hookmetamethod unavailable; relying on connection sweep")
        return false
    end

    -- Decides whether to swallow a write. Run via pcall in hookFn below so a bug
    -- in here can never error on -- or crash -- the game's property writes (this
    -- runs on EVERY Instance __newindex, since they share one metatable).
    local function shouldBlock(self, key, value)
        if self_state.shutdown then return false end
        -- shouldEnforce() gates the hook the same as the pin pass: on while
        -- killForeign is on, EXCEPT when allowGameShiftlock is on AND Pantheon
        -- shiftlock is off (so the game's shiftlock can drive the cursor).
        if not (shouldEnforce() and self == UserInputService) then return false end
        local block = false
        if key == "MouseBehavior" then
            local wanted = state.shiftlock_active
                and Enum.MouseBehavior.LockCenter
                or Enum.MouseBehavior.Default
            if value ~= wanted then block = true end
        elseif key == "MouseIconEnabled" then
            if value ~= (not state.shiftlock_active) then block = true end
        elseif key == "MouseIcon" then
            if value ~= "" then block = true end
        end
        if block then
            self_state.blockedWrites = self_state.blockedWrites + 1
            local now = os.clock()
            if now - self_state.lastBlockedLog > 2 then
                log.info(string.format(
                    "shiftlock: blocked %d foreign UIS write(s) (last %s)",
                    self_state.blockedWrites, tostring(key)))
                self_state.blockedWrites = 0
                self_state.lastBlockedLog = now
            end
        end
        return block
    end

    local hookFn = function(self, key, value)
        local ok, blocked = pcall(shouldBlock, self, key, value)
        if ok and blocked then return end   -- swallow the foreign write
        if realOriginal then return realOriginal(self, key, value) end
    end

    -- Wrap the hook in newcclosure so the metamethod looks like a C function
    -- when an anticheat reads back UIS's metatable. Without this, the hook
    -- is a plain Lua closure and a debug.info / typeof comparison can
    -- separate it from the engine's original native __newindex.
    local wrapped = (env.newcclosure and env.newcclosure(hookFn)) or hookFn

    local ok, returned = pcall(hookmetamethod, UserInputService, "__newindex", wrapped)
    if not ok or not returned then
        if not self_state.hookInstalled then
            log.warn("shiftlock: hookmetamethod failed:", tostring(returned))
        end
        return false
    end

    -- First successful install: returned IS the real engine setter. Save it.
    -- Subsequent re-installs: returned is our PREVIOUS hook (or a foreign
    -- script's hook that has chained on top of us). Discard it so the chain
    -- stays at depth-1 and we always pass through to the real original.
    if not realOriginal then realOriginal = returned end

    if not self_state.hookInstalled then
        log.info("shiftlock: MouseBehavior hook installed (foreign writes will be blocked)")
    end
    self_state.hookInstalled = true
    return true
end

-- Lazy-install entry points: aliases used by Shiftlock.setEnabled /
-- Shiftlock.setKillForeign (the upvalues forward-declared further up the
-- file). Defers the hookmetamethod call past script-load until the user
-- actually enables the feature.
installMouseBehaviorHookLazy = installMouseBehaviorHook

-- Periodically re-install the hook. If a game's own script hooks __newindex
-- AFTER us, their hook wraps ours and a foreign value might leak through.
-- Re-installing every second puts our hook back on top of theirs.
local function spawnHookGuard()
    if self_state.hookGuardStarted then return end
    self_state.hookGuardStarted = true
    task.spawn(function()
        while task.wait(1) do
            if self_state.shutdown then return end
            if state.killForeign and state.shiftlock_enabled then
                installMouseBehaviorHook()
            end
        end
    end)
end

spawnHookGuardLazy = spawnHookGuard

local function sweepForeigns(label)
    local g = killForeignGuis()
    local k, s = killForeignLoops()
    if g > 0 or k > 0 then
        log.info(string.format(
            "shiftlock [%s]: killed %d GUI(s), %d/%d connection(s)",
            label, g, k, s
        ))
    else
        log.debug(string.format(
            "shiftlock [%s]: scanned %d connection(s), nothing matched",
            label, s
        ))
    end
end

-- PAIR mode: hide the GAME's own shiftlock icon while Pantheon's shiftlock is
-- active, so only our icon shows -- WITHOUT destroying it (we still pair with the
-- game's shiftlock state for sync + rotation). Heuristic: any ScreenGui/GuiObject
-- under PlayerGui whose name contains "shiftlock". Remembers exactly what it hid
-- and restores it when Pantheon's shiftlock goes inactive.
-- NOTE: if JJS names its icon something without "shiftlock" in it, this won't
-- catch it -- grab the icon's instance name (Dex/explorer) and we target it.
local hiddenStore = {}   -- { {inst, prop, originalValue}, ... }
local iconScanT = 0

-- (re)scan PlayerGui for shiftlock-named GUIs, recording any new ones with their
-- original value (so we can restore later). Throttled by the caller.
local function nameClean(s) return (s and (s:lower():gsub("%s", ""))) or "" end
local lastIconLog = 0
local function scanShiftlockIcons()
    local pg = lp():FindFirstChildOfClass("PlayerGui")
    if not pg then return end
    local known = {}
    for _, e in ipairs(hiddenStore) do known[e[1]] = true end
    for _, gobj in ipairs(pg:GetDescendants()) do
        local isSG = gobj:IsA("ScreenGui")
        if (isSG or gobj:IsA("GuiObject")) and not known[gobj] then
            -- match the element's own name OR its parent's name (the icon image
            -- 'Lock' lives inside a 'ShiftLock' container -- catch both).
            local hit = (string.find(nameClean(gobj.Name), "shiftlock") ~= nil)
                or (gobj.Parent and string.find(nameClean(gobj.Parent.Name), "shiftlock") ~= nil)
            if hit then
                local prop = isSG and "Enabled" or "Visible"
                local ok, cur = pcall(function() return gobj[prop] end)
                if ok then hiddenStore[#hiddenStore + 1] = { gobj, prop, cur } end
            end
        end
    end
    -- diagnostic: confirm whether we're actually finding JJS's icon (F9 console)
    if os.clock() - lastIconLog > 3 then
        lastIconLog = os.clock()
        local names = {}
        for _, e in ipairs(hiddenStore) do names[#names + 1] = e[1].Name end
        log.info("shiftlock icon-hide: " .. #hiddenStore .. " element(s) [" .. table.concat(names, ", ") .. "]")
    end
end

-- Keep the game's shiftlock icon hidden. Re-asserts EVERY frame (cheap -- only a
-- few stored instances) so it stays hidden even if the game's own script re-shows
-- it each frame, and re-scans periodically to catch icons created later. Called
-- from step() which runs at RenderPriority.Last, so our hide wins end-of-frame --
-- a one-shot hide loses to a game that re-shows its icon, which is why the icon
-- kept reappearing.
local function enforceShiftlockHidden()
    if os.clock() - iconScanT > 0.4 then
        iconScanT = os.clock()
        scanShiftlockIcons()
    end
    for i = #hiddenStore, 1, -1 do
        local gobj, prop = hiddenStore[i][1], hiddenStore[i][2]
        if gobj and gobj.Parent then
            pcall(function() if gobj[prop] ~= false then gobj[prop] = false end end)
        else
            table.remove(hiddenStore, i)
        end
    end
end

local function restoreShiftlockIcons()
    for _, e in ipairs(hiddenStore) do
        local gobj, prop, orig = e[1], e[2], e[3]
        if gobj and gobj.Parent then
            pcall(function() gobj[prop] = (orig == nil) and true or orig end)
        end
    end
    hiddenStore = {}
    iconScanT = 0
end

-- ---------- gui ----------------------------------------------------------

local function buildGui()
    if self_state.gui and self_state.gui.Parent then return end

    local gui = Instance.new("ScreenGui")
    gui.Name = GUI_NAME
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    -- env.guiParent() = gethui() (or CoreGui fallback). PlayerGui is fully
    -- enumerable by any game script (TSB-style anticheats scan it for
    -- unknown ScreenGuis and detach the camera as a punishment); gethui's
    -- container is hidden from those scans.
    gui.Parent = env.guiParent()
    env.protectGui(gui)

    local vIcon = Instance.new("ImageLabel")
    vIcon.Name = "VIcon"
    vIcon.BackgroundTransparency = 1
    vIcon.Size = UDim2.new(0, 150, 0, 150)
    vIcon.AnchorPoint = Vector2.new(0.5, 0.5)
    vIcon.Position = UDim2.new(0.5, 0, 0.5, 0)
    vIcon.Visible = false
    vIcon.Image = "rbxassetid://18913450789"
    vIcon.ScaleType = Enum.ScaleType.Fit
    vIcon.BorderSizePixel = 5
    vIcon.BorderColor3 = Color3.new(1, 1, 1)
    vIcon.Parent = gui

    self_state.gui = gui
    self_state.vIcon = vIcon
end

local function updateCharRefs(char)
    self_state.character = char
    self_state.humanoid  = char:WaitForChild("Humanoid")
    self_state.root      = char:WaitForChild("HumanoidRootPart")

    if self_state.humConn then self_state.humConn:Disconnect() end
    self_state.humConn = self_state.humanoid.Died:Connect(function()
        state.shiftlock_active = false
        Shiftlock.forceOff()
    end)
end

local function applyLock()
    state.shiftlock_active = true
    disableGameShiftLock()
    if self_state.humanoid then self_state.humanoid.AutoRotate = false end
    if self_state.vIcon    then self_state.vIcon.Visible = true end
    UserInputService.MouseIconEnabled = false
    UserInputService.MouseBehavior    = Enum.MouseBehavior.LockCenter
end

function Shiftlock.forceOff()
    state.shiftlock_active = false
    if self_state.humanoid then self_state.humanoid.AutoRotate = true end
    if self_state.vIcon    then self_state.vIcon.Visible = false end
    UserInputService.MouseIconEnabled = true
    UserInputService.MouseBehavior    = Enum.MouseBehavior.Default
end

function Shiftlock.toggle()
    -- Gated on the feature master toggle so the Shift key only locks the
    -- cursor when the user has explicitly enabled Pantheon shiftlock.
    -- Same pattern as target_select / rotation_lock hotkeys.
    if not state.shiftlock_enabled then return end
    if state.shiftlockMirror then return end   -- mirror mode: the game owns Shift; we just follow its state
    if state.shiftlock_active then
        Shiftlock.forceOff()
    else
        applyLock()
    end
end

-- (installMouseBehaviorHookLazy / spawnHookGuardLazy are forward-declared at the
-- top of the file and assigned right after their implementations above, so the
-- functions below see the real functions instead of nil.)

function Shiftlock.setEnabled(v)
    v = v and true or false
    if state.shiftlock_enabled == v then return end
    state.shiftlock_enabled = v
    if v then
        -- Mirror mode follows the game's shiftlock, so DON'T disable or sweep it
        -- away -- that would kill the very thing we're mirroring.
        if not state.shiftlockMirror then
            disableGameShiftLock()
            if state.killForeign then
                sweepForeigns("enable")
                -- Lazy hook install: only when the user actually wants enforcement
                -- (killForeign on + master toggled on). Defers the hookmetamethod
                -- call past script-load so anticheats scanning UIS metatable at
                -- execute time (TSB-style) don't see the hook.
                installMouseBehaviorHookLazy()
                spawnHookGuardLazy()
            end
        end
    else
        Shiftlock.forceOff()
        -- No release cooldown needed -- when killForeign is on the pin pass
        -- and hook are always enforcing free-movement state whenever
        -- shouldLock is false, so the post-disable transition is
        -- self-stabilising on every frame.
        -- If the user wants the game's vanilla MouseLockController as their
        -- shiftlock fallback, restore DevEnableMouseLock so it can engage.
        -- (Custom in-game shiftlock scripts don't care about DevEnableMouseLock,
        -- but the pin-pass + hook gate handles them via shouldEnforce()).
        if state.allowGameShiftlock then
            pcall(function() lp().DevEnableMouseLock = true end)
        end
    end
end

function Shiftlock.setAllowGameShiftlock(v)
    state.allowGameShiftlock = v and true or false
    -- Wake Roblox's vanilla MouseLockController if the user just opted in
    -- and Pantheon's master is off. The shouldEnforce() gate is what
    -- actually lets foreign LockCenter writes through; this is just the
    -- DevEnableMouseLock side of the same intent.
    if state.allowGameShiftlock and not state.shiftlock_enabled then
        pcall(function() lp().DevEnableMouseLock = true end)
    end
end

-- PAIR mode: Pantheon syncs its shiftlock on/off to the game's own shiftlock and
-- keeps rotating in lockstep, but lets the game own the CURSOR (no pin/hook fight).
-- Replaces the old independent toggle that drifted out of sync and overlapped.
-- Enabling it releases our current cursor writes once so the game takes the cursor.
function Shiftlock.setShiftlockMirror(v)
    state.shiftlockMirror = v and true or false
    if state.shiftlockMirror then Shiftlock.forceOff() end
end

-- Pin pass + hook enforce when this is true. Returns false to fully yield
-- (cursor management is whatever the game scripts and Roblox engine want).
-- NOTE: assigns the forward-declared upvalue (no `local`) so the hook closure
-- defined earlier captures it instead of a nil global.
-- Enforce (pin pass + __newindex hook) ONLY while Pantheon is actively locking.
-- When our lock is off we fully RELEASE so the game's own shiftlock stays in sync
-- with ours (both react to Shift) and the body free-rotates normally. The old
-- always-on enforcement dominated the game's shiftlock and left rotation stuck
-- when toggled off -- the user wants the two paired, not Pantheon winning.
function shouldEnforce()
    if state.shiftlockMirror then return false end   -- mirror mode: never touch/fight the game's cursor
    if not state.killForeign then return false end
    return state.shiftlock_enabled and state.shiftlock_active
end

function Shiftlock.setExternalSkipRotation(fn)
    self_state.externalSkipRotation = fn
end

-- Auto-repair pairing with the game's shiftlock after respawn.
--
-- Symptom: the user has Pantheon shiftlock running alongside the game's own
-- shiftlock script and they're normally in sync (Pantheon's Shift keybind
-- triggers both because UIS.InputBegan fans out to every listener). Sometimes
-- the game's shiftlock state machine resets on respawn while Pantheon's
-- still thinks it was locked from before death; the result is a glitched
-- "free rotate broken" (cursor stuck LockCenter or AutoRotate stuck false).
--
-- Fix: 0.5s after CharacterAdded, if shiftlock_active says we should be
-- free but the cursor/AutoRotate disagree, cycle Pantheon's master once
-- to reset our internal state, then fire a single synthetic Shift key
-- event so the game's state machine retriggers and lands in the same
-- state Pantheon now has.
local function autoRepair()
    if state.shiftlock_active then return end  -- we expect locked; not glitched
    local cursorLocked = UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
    local hum = self_state.humanoid
    local rotLocked = hum and (not hum.AutoRotate)
    if not (cursorLocked or rotLocked) then return end

    log.info("shiftlock: post-respawn pairing glitch detected, re-pairing")

    if state.shiftlock_enabled then
        Shiftlock.setEnabled(false)
        task.wait(0.05)
        Shiftlock.setEnabled(true)
    end

    -- Retrigger the game's shiftlock keybind handler. Use the user's actual
    -- bound key so custom binds still work.
    local key = (keybinds.get and keybinds.get("aim.shiftlock")) or Enum.KeyCode.LeftShift
    if key and key ~= Enum.KeyCode.Unknown then
        pcall(function()
            VirtualInputManager:SendKeyEvent(true,  key, false, game)
            task.wait(0.03)
            VirtualInputManager:SendKeyEvent(false, key, false, game)
        end)
    end
end

local function step()
    -- PAIR mode: instead of toggling our shiftlock independently (which drifts out
    -- of sync with the game's and overlaps it), SYNC our shiftlock_active to the
    -- game's own shiftlock by reading its cursor lock. We do NOT pin the cursor
    -- (shouldEnforce() returns false in pair mode, so the game owns the cursor --
    -- no fight), but we FALL THROUGH to our own rotation pass below, so Pantheon's
    -- shiftlock stays ACTIVE (rotating in lockstep) alongside the game's -- paired,
    -- not replaced. They lock/unlock together because our state tracks the game's.
    if state.shiftlockMirror then
        state.shiftlock_active = state.shiftlock_enabled
            and (UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter) or false
        -- pair mode doesn't call applyLock(), so drive our shiftlock icon here so it
        -- shows while the paired shiftlock is active...
        if self_state.vIcon then self_state.vIcon.Visible = state.shiftlock_active end
        -- ...and keep the GAME's own shiftlock icon hidden the WHOLE time Pantheon
        -- shiftlock is enabled (not just while actively locking) -- some games show
        -- their shiftlock icon as a persistent indicator even when not in
        -- LockCenter, so gating on shiftlock_active left it visible.
        if state.shiftlock_enabled then
            enforceShiftlockHidden()
            self_state.iconsHidden = true
        elseif self_state.iconsHidden then
            restoreShiftlockIcons()
            self_state.iconsHidden = false
        end
    elseif self_state.iconsHidden then
        -- left pair mode (or shiftlock off) -> give the game its icon back
        restoreShiftlockIcons()
        self_state.iconsHidden = false
    end

    -- "shouldLock" is the SINGLE source of truth for whether the cursor should
    -- be locked right now. It is true only when Pantheon's shiftlock is both
    -- enabled and currently active.
    local shouldLock = state.shiftlock_enabled and state.shiftlock_active

    -- ===== pin pass =====
    -- Forces all four shiftlock-related properties to our desired state every
    -- frame so foreign scripts can't ghost-control them. Runs continuously
    -- whenever shouldEnforce() is true -- including when Pantheon shiftlock
    -- is off (so a game shiftlock script's CharacterAdded handler / delayed
    -- task / off-cycle render binding can't sneak the cursor back into
    -- LockCenter after the user toggles Pantheon shiftlock off). The
    -- allowGameShiftlock toggle yields this enforcement when Pantheon
    -- shiftlock is off, so the game's base shiftlock can drive the cursor.
    if shouldEnforce() then
        local hum = self_state.humanoid
        local rotLockActive = self_state.externalSkipRotation
            and self_state.externalSkipRotation()

        -- Skip AutoRotate writes while Rotation Lock is driving the body,
        -- otherwise we fight it for free-rotate vs locked-rotate.
        if hum and not rotLockActive then
            -- hand AutoRotate back during a grab so the game can turn/move us
            -- instead of leaving the body frozen ("stuck in place").
            local wantedAR = (not shouldLock) or state.isGrabbing()
            if hum.AutoRotate ~= wantedAR then
                hum.AutoRotate = wantedAR
            end
        end

        local wantedMB = shouldLock
            and Enum.MouseBehavior.LockCenter
            or Enum.MouseBehavior.Default
        if UserInputService.MouseBehavior ~= wantedMB then
            UserInputService.MouseBehavior = wantedMB
        end

        local wantedEnabled = not shouldLock
        if UserInputService.MouseIconEnabled ~= wantedEnabled then
            UserInputService.MouseIconEnabled = wantedEnabled
        end

        if UserInputService.MouseIcon ~= "" then
            UserInputService.MouseIcon = ""
        end
    end

    -- ===== locked-mode rotation pass (only when our shiftlock is engaged) =====
    if not state.shiftlock_enabled then return end

    local hum = self_state.humanoid
    if hum and hum.CameraOffset ~= ZERO3 then hum.CameraOffset = ZERO3 end

    if not state.shiftlock_active or not self_state.root or not hum then return end
    if hum.Health <= 0 then return end

    local st = hum:GetState()
    if st == Enum.HumanoidStateType.Dead then return end

    -- Being grabbed (welded to a player, or held by a foreign BodyGyro/Position)
    -- => never rotate the body: it drags the grabbed player (we're the attacker)
    -- or fights + glitches their grab of us (we're the victim). Grabs can keep
    -- the humanoid in the RUNNING state, so check this DIRECTLY, not via state.
    if state.isGrabbing() then return end
    -- Hard locks (bleedout / downed / seated) + knockback/ragdoll physics:
    -- suppress so the body doesn't spin while the game controls us.
    if hum.PlatformStand then return end
    if st == Enum.HumanoidStateType.Ragdoll
       or st == Enum.HumanoidStateType.FallingDown
       or st == Enum.HumanoidStateType.Physics then
        return
    end

    if self_state.externalSkipRotation and self_state.externalSkipRotation() then
        return
    end

    local cam = workspace.CurrentCamera
    if not cam then return end
    local look = cam.CFrame.LookVector
    local flat = Vector3.new(look.X, 0, look.Z)
    if flat.Magnitude > 0 then
        self_state.root.CFrame = CFrame.lookAt(self_state.root.Position, self_state.root.Position + flat)
    end
end

function Shiftlock.init()
    buildGui()

    local char = lp().Character or lp().CharacterAdded:Wait()
    updateCharRefs(char)

    self_state.charConn = lp().CharacterAdded:Connect(function(c)
        updateCharRefs(c)
        -- Only intervene on respawn when Pantheon shiftlock is actually enabled.
        -- When Pantheon shiftlock is OFF the game's shiftlock script (which we
        -- never disabled) owns the cursor; calling forceOff here races its own
        -- CharacterAdded and left free movement broken after dying.
        if state.shiftlock_enabled and not state.shiftlockMirror then
            Shiftlock.forceOff()
            if state.killForeign then
                task.defer(function() sweepForeigns("respawn") end)
            end
            -- Auto-repair pairing with the game's shiftlock once the
            -- game's post-respawn scripts have settled (~0.5s).
            task.delay(0.5, autoRepair)
        end
    end)

    self_state.focusConn = UserInputService.WindowFocusReleased:Connect(function()
        if state.shiftlock_active then Shiftlock.forceOff() end
    end)

    if not self_state.bound then
        -- RenderPriority.Last (= 2000) so we run AFTER every other
        -- BindToRenderStep callback in the frame. The pin pass alone is
        -- enough to keep our wanted state at end-of-frame; the property
        -- hook is a within-frame extra that's installed lazily on first
        -- user enable, so anticheats scanning the UIS metatable at
        -- script-load (TSB-style) don't see it.
        RunService:BindToRenderStep(RENDER_BIND, Enum.RenderPriority.Last.Value, step)
        self_state.bound = true
    end

    -- NB: hookmetamethod + hookGuard are no longer installed at boot.
    -- Deferred to Shiftlock.setEnabled(true) so that simply loading the
    -- script doesn't write the UIS metatable at all (anticheat surface).
end

-- Called by the "Kill foreign shiftlock GUIs / loops" cog toggle. Lazy-
-- installs the hook + guard if the user toggles killForeign on while
-- Pantheon shiftlock is already enabled (otherwise the hook was deferred
-- and would never install in that direction).
function Shiftlock.setKillForeign(v)
    state.killForeign = v and true or false
    if state.killForeign and state.shiftlock_enabled then
        installMouseBehaviorHookLazy()
        spawnHookGuardLazy()
    end
end

function Shiftlock.destroy()
    -- Flips the previously-installed hookmetamethod into pass-through mode
    -- and stops the hookGuard re-install loop.
    self_state.shutdown = true

    -- restore the game's shiftlock icon if we were hiding it
    if self_state.iconsHidden then
        restoreShiftlockIcons()
        self_state.iconsHidden = false
    end

    if self_state.bound then
        pcall(function() RunService:UnbindFromRenderStep(RENDER_BIND) end)
        self_state.bound = false
    end

    Shiftlock.forceOff()

    if self_state.charConn  then self_state.charConn:Disconnect();  self_state.charConn  = nil end
    if self_state.humConn   then self_state.humConn:Disconnect();   self_state.humConn   = nil end
    if self_state.focusConn then self_state.focusConn:Disconnect(); self_state.focusConn = nil end

    if self_state.gui then pcall(function() self_state.gui:Destroy() end) end
    self_state.gui, self_state.vIcon = nil, nil
end

return Shiftlock
