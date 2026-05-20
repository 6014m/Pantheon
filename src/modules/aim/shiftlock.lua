-- Custom shiftlock. Ports ShiftLockModule with three improvements:
--   1. BindToRenderStep at Camera+100 (deterministic timing vs RenderStepped
--      competitors).
--   2. On enable AND on disable, sweeps PlayerGui for ScreenGuis matching
--      known foreign shiftlock GUI names and Destroys them.
--   3. On enable AND on disable, uses getconnections + getupvalues to find
--      foreign RenderStepped/Heartbeat connections that look like a shiftlock
--      loop (upvalue table has both `shiftLocked` and `humanoid`/`character`)
--      and Disconnects them. This is what actually frees the mouse when
--      another script's shiftlock is still running — without it, killing the
--      GUI doesn't stop the foreign loop, and that loop keeps re-locking the
--      mouse every frame.
--
-- The externalSkipRotation gate from the legacy module is preserved so LockOn+
-- can still take over rotation cleanly without two CFrame writes per frame.

local state = require("modules.aim.state")
local log   = require("core.log")

local Players          = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService       = game:GetService("RunService")

local Shiftlock = {}

local RENDER_BIND = "PantheonShiftlock"
local GUI_NAME    = "PantheonShiftLockVGui"

-- ScreenGui names commonly used by other custom shiftlock scripts. Doesn't
-- include our own GUI_NAME so the sweep never touches us.
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
}

local function lp() return Players.LocalPlayer end

local function disableGameShiftLock()
    pcall(function() lp().DevEnableMouseLock = false end)
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

-- Walk RenderStepped + Heartbeat connections looking for ones whose upvalues
-- contain a table that looks like a shiftlock state object (has a `shiftLocked`
-- field AND a `humanoid` or `character` instance reference). Our own code uses
-- BindToRenderStep + Heartbeat with state.lua's flat state table (no humanoid
-- field), so this heuristic does not catch us.
local function killForeignLoops()
    if not getconnections then return 0 end
    local getU = rawget(getfenv(), "getupvalues") or (debug and debug.getupvalues)
    if not getU then return 0 end

    local function looksLikeShiftlockState(t)
        if type(t) ~= "table" then return false end
        local hasFlag    = (t.shiftLocked ~= nil) or (t.shiftlock_locked ~= nil)
        local hasInstRef = (typeof(t.humanoid) == "Instance")
                         or (typeof(t.character) == "Instance")
                         or (typeof(t.root) == "Instance")
        return hasFlag and hasInstRef
    end

    local function shouldKill(conn)
        local ok, fn = pcall(function() return conn.Function end)
        if not ok or type(fn) ~= "function" then
            ok, fn = pcall(function() return conn.Func end)
            if not ok or type(fn) ~= "function" then return false end
        end
        local ok2, ups = pcall(getU, fn)
        if not ok2 or type(ups) ~= "table" then return false end
        for _, up in pairs(ups) do
            if looksLikeShiftlockState(up) then return true end
        end
        return false
    end

    local count = 0
    for _, signal in ipairs({ RunService.RenderStepped, RunService.Heartbeat }) do
        local ok, conns = pcall(getconnections, signal)
        if ok and type(conns) == "table" then
            for _, conn in pairs(conns) do
                if shouldKill(conn) then
                    local dok = pcall(function() conn:Disconnect() end)
                    if dok then count = count + 1 end
                end
            end
        end
    end
    return count
end

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

local function reportKills(g, l, suffix)
    if g > 0 or l > 0 then
        log.info("shiftlock:", g, "GUI(s) +", l, "loop(s) killed " .. suffix)
    end
end

function Shiftlock.setEnabled(v)
    v = v and true or false
    if state.shiftlock_enabled == v then return end
    state.shiftlock_enabled = v
    if v then
        disableGameShiftLock()
        if state.killForeign then
            reportKills(killForeignGuis(), killForeignLoops(), "(enable)")
        end
    else
        Shiftlock.forceOff()
        -- Kill foreigns here too — otherwise a competing loop keeps holding
        -- MouseBehavior=LockCenter every frame after we release, so the user
        -- sees "the shiftlock didn't actually turn off."
        if state.killForeign then
            reportKills(killForeignGuis(), killForeignLoops(), "(disable)")
        end
    end
end

function Shiftlock.setExternalSkipRotation(fn)
    self_state.externalSkipRotation = fn
end

local function step()
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

    if UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
        UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
    end

    -- Yield rotation to LockOn+ when it's actively rotating to a target
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
        Shiftlock.forceOff()
        -- On respawn, foreign scripts may reconnect their loop against the new
        -- humanoid. Re-sweep so they don't quietly take over.
        if state.shiftlock_enabled and state.killForeign then
            task.defer(function()
                reportKills(killForeignGuis(), killForeignLoops(), "(respawn)")
            end)
        end
    end)

    self_state.focusConn = UserInputService.WindowFocusReleased:Connect(function()
        if state.shiftlock_active then Shiftlock.forceOff() end
    end)

    if not self_state.bound then
        RunService:BindToRenderStep(RENDER_BIND, Enum.RenderPriority.Camera.Value + 100, step)
        self_state.bound = true
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
