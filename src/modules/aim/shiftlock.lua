-- Custom shiftlock. Ports ShiftLockModule with two improvements:
--   1. BindToRenderStep at Camera+100 (deterministic timing vs RenderStepped:Connect competitors)
--   2. On enable, sweeps PlayerGui for ScreenGuis matching known foreign shiftlock names
--      and Destroys them, which breaks the foreign script's loop (their WaitForChild/
--      FindFirstChild on the GUI fails downstream).
--
-- The externalSkipRotation gate from the legacy module is preserved so LockOn+ can
-- still take over rotation cleanly without two CFrame writes per frame.

local state = require("modules.aim.state")
local log   = require("core.log")

local Players          = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService       = game:GetService("RunService")

local Shiftlock = {}

local RENDER_BIND = "PantheonShiftlock"
local GUI_NAME    = "PantheonShiftLockVGui"

-- ScreenGui names commonly used by other custom shiftlock scripts. Does not
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
        if state.killForeign then
            local n = killForeignGuis()
            if n > 0 then log.info("shiftlock: killed", n, "foreign GUI(s)") end
        end
    else
        Shiftlock.forceOff()
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

    local s = hum:GetState()
    if s == Enum.HumanoidStateType.Ragdoll
       or s == Enum.HumanoidStateType.FallingDown
       or s == Enum.HumanoidStateType.Physics
       or s == Enum.HumanoidStateType.Dead then
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
