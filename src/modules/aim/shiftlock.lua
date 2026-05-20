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

local state = require("modules.aim.state")
local log   = require("core.log")

local Players          = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService       = game:GetService("RunService")

local Shiftlock = {}

local RENDER_BIND = "PantheonShiftlock"
local GUI_NAME    = "PantheonShiftLockVGui"

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
    -- After Pantheon is disabled, hold the released state for this many
    -- seconds even though shiftlock_enabled is false. Prevents the half-tick
    -- where the game's shiftlock re-locks before we've finished writing
    -- Default + AutoRotate=true.
    releaseCooldownUntil = 0,
}

-- Cached check: are we welded (via Weld/WeldConstraint/Motor6D) to a part on
-- a different character? Battlegrounds-style grab moves weld the attacker to
-- the victim; if we then rotate our own root via shiftlock, the weld drags
-- the victim around too -- which is what the user was seeing.
local function isLocalWeldedToOther()
    local char = self_state.character
    if not char then return false end

    for _, d in ipairs(char:GetDescendants()) do
        if d:IsA("Weld") or d:IsA("WeldConstraint") or d:IsA("Motor6D") then
            local p0, p1 = d.Part0, d.Part1
            for _, p in ipairs({ p0, p1 }) do
                if p and p.Parent and not p:IsDescendantOf(char) then
                    local m = p:FindFirstAncestorOfClass("Model")
                    if m and m ~= char and m:FindFirstChildOfClass("Humanoid") then
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function weldedToOther()
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

local function installMouseBehaviorHook()
    if type(hookmetamethod) ~= "function" then
        log.debug("shiftlock: hookmetamethod unavailable; relying on connection sweep")
        return false
    end

    local hookFn = function(self, key, value)
        -- killForeign behaviour is gated on Pantheon's shiftlock master toggle.
        -- When Pantheon shiftlock is OFF the hook becomes a pass-through and
        -- the game's normal shiftlock works again. During the brief
        -- release-cooldown after disable we still block foreign writes so
        -- the hand-off doesn't flicker.
        local inCooldown = os.clock() < self_state.releaseCooldownUntil
        if state.killForeign
           and (state.shiftlock_enabled or inCooldown)
           and self == UserInputService then
            local block = false
            if key == "MouseBehavior" then
                local wanted = state.shiftlock_active
                    and Enum.MouseBehavior.LockCenter
                    or Enum.MouseBehavior.Default
                if value ~= wanted then block = true end
            elseif key == "MouseIconEnabled" then
                -- Hidden cursor while locked, visible otherwise.
                local wanted = not state.shiftlock_active
                if value ~= wanted then block = true end
            elseif key == "MouseIcon" then
                -- Foreign scripts swap the cursor image. We want the default
                -- (empty string) - block any non-empty write.
                if value ~= "" then block = true end
            end

            if block then
                self_state.blockedWrites = self_state.blockedWrites + 1
                local now = os.clock()
                if now - self_state.lastBlockedLog > 2 then
                    log.info(string.format(
                        "shiftlock: blocked %d foreign UIS write(s) (last %s = %s)",
                        self_state.blockedWrites, tostring(key), tostring(value)
                    ))
                    self_state.blockedWrites = 0
                    self_state.lastBlockedLog = now
                end
                return
            end
        end
        if realOriginal then
            return realOriginal(self, key, value)
        end
    end

    local ok, returned = pcall(hookmetamethod, UserInputService, "__newindex", hookFn)
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

-- Periodically re-install the hook. If a game's own script hooks __newindex
-- AFTER us, their hook wraps ours and a foreign value might leak through.
-- Re-installing every second puts our hook back on top of theirs.
local function spawnHookGuard()
    if self_state.hookGuardStarted then return end
    self_state.hookGuardStarted = true
    task.spawn(function()
        while task.wait(1) do
            if state.killForeign then
                installMouseBehaviorHook()
            end
        end
    end)
end

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

-- ---------- gui ----------------------------------------------------------

local function buildGui()
    if self_state.gui and self_state.gui.Parent then return end
    local pg = lp():WaitForChild("PlayerGui")

    local gui = Instance.new("ScreenGui")
    gui.Name = GUI_NAME
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.Parent = pg

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
    if not state.shiftlock_enabled then
        Shiftlock.setEnabled(true)
    end
    if state.shiftlock_active then
        Shiftlock.forceOff()
    else
        applyLock()
    end
end

function Shiftlock.setEnabled(v)
    v = v and true or false
    if state.shiftlock_enabled == v then return end
    state.shiftlock_enabled = v
    if v then
        disableGameShiftLock()
        if state.killForeign then sweepForeigns("enable") end
    else
        Shiftlock.forceOff()
        -- Hold the released state for half a second so the game's still-active
        -- shiftlock script doesn't race us back into locked-state during the
        -- transition. After the cooldown we hand control fully back -- the
        -- game's shiftlock script then drives the cursor naturally.
        --
        -- DELIBERATELY NOT setting DevEnableMouseLock = true: that re-engages
        -- Roblox's built-in MouseLockController, which is NOT what the user
        -- wants. The game's own shiftlock script (which we never disabled)
        -- is what should run.
        self_state.releaseCooldownUntil = os.clock() + 0.5
    end
end

function Shiftlock.setExternalSkipRotation(fn)
    self_state.externalSkipRotation = fn
end

local function step()
    -- "shouldLock" is the SINGLE source of truth for whether the cursor should
    -- be locked right now. It is true only when Pantheon's shiftlock is both
    -- enabled and currently active.
    local shouldLock = state.shiftlock_enabled and state.shiftlock_active

    -- ===== pin pass =====
    -- Forces all four shiftlock-related properties to our desired state every
    -- frame so foreign scripts can't ghost-control them. Runs when Pantheon
    -- is enabled, OR briefly after disable (releaseCooldownUntil) so the
    -- released state actually holds during the hand-off back to the game.
    local inCooldown = os.clock() < self_state.releaseCooldownUntil
    if state.killForeign and (state.shiftlock_enabled or inCooldown) then
        local hum = self_state.humanoid

        if hum then
            local wantedAR = not shouldLock
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
    if hum then hum.CameraOffset = Vector3.new(0, 0, 0) end

    if not state.shiftlock_active or not self_state.root or not hum then return end
    if hum.PlatformStand or hum.Health <= 0 then return end

    local st = hum:GetState()
    if st == Enum.HumanoidStateType.Ragdoll
       or st == Enum.HumanoidStateType.FallingDown
       or st == Enum.HumanoidStateType.Physics
       or st == Enum.HumanoidStateType.Dead then
        return
    end

    if self_state.externalSkipRotation and self_state.externalSkipRotation() then
        return
    end

    -- Skip the root.CFrame write while we're welded to another character
    -- (grab moves, etc.) so we don't drag them around with us.
    if weldedToOther() then return end

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
        Shiftlock.forceOff()
        if state.shiftlock_enabled and state.killForeign then
            task.defer(function() sweepForeigns("respawn") end)
        end
    end)

    self_state.focusConn = UserInputService.WindowFocusReleased:Connect(function()
        if state.shiftlock_active then Shiftlock.forceOff() end
    end)

    if not self_state.bound then
        -- RenderPriority.Last (= 2000) so we run AFTER every other
        -- BindToRenderStep callback in the frame. Combined with the
        -- __newindex hook, this means we're the final writer for
        -- MouseBehavior even if a foreign script binds at a high priority.
        RunService:BindToRenderStep(RENDER_BIND, Enum.RenderPriority.Last.Value, step)
        self_state.bound = true
    end

    -- Property-level hook: blocks foreign writes outright instead of
    -- racing them in the render pipeline.
    installMouseBehaviorHook()
    spawnHookGuard()

    -- Boot-time sweep so leftover foreign shiftlocks from previous script
    -- loads don't make ours "look enabled by default."
    if state.killForeign then
        task.defer(function() sweepForeigns("boot") end)
    end
end

function Shiftlock.destroy()
    if self_state.bound then
        pcall(function() RunService:UnbindFromRenderStep(RENDER_BIND) end)
        self_state.bound = false
    end
    Shiftlock.forceOff()
    if self_state.gui then self_state.gui:Destroy() end
    self_state.gui, self_state.vIcon = nil, nil
end

return Shiftlock
