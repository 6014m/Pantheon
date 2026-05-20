-- Rotates own character body to face the lock-on target while camera stays free.
-- Ports LockOnPlusModule with a "battlegrounds-safe" gate:
--   Suppresses rotation when either the local OR target Humanoid is in a non-
--   walking state (Physics, FallingDown, Ragdoll, Seated, PlatformStanding) or
--   has PlatformStand=true. This catches the ragdoll-cycle window after a hit,
--   the time when forcing rotation visibly fights the move's animation/weld and
--   makes it obvious a script is running.
--
-- On resume from a suppress window, the direct CFrame snap is held back for
-- ~0.15s so the body slides into position via AlignOrientation instead of
-- teleporting.

local state = require("modules.aim.state")

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")

local LockOnPlus = {}

local BIND = "PantheonLockOnPlus"
local SMOOTH_DURATION = 0.15

local SUPPRESS_STATES = {
    [Enum.HumanoidStateType.Physics]          = true,
    [Enum.HumanoidStateType.FallingDown]      = true,
    [Enum.HumanoidStateType.Ragdoll]          = true,
    [Enum.HumanoidStateType.Seated]           = true,
    [Enum.HumanoidStateType.PlatformStanding] = true,
}

local self_state = {
    align            = nil,
    attachment       = nil,
    suppressedSince  = 0,
    smoothUntil      = 0,
    bound            = false,
}

local function lp() return Players.LocalPlayer end

local function rootOf(charOrModel)
    return charOrModel and charOrModel:FindFirstChild("HumanoidRootPart")
end

local function targetChar()
    local t = state.lockon_target
    if not t then return nil end
    if state.lockon_target_type == "player" then return t.Character end
    return t
end

local function getHumanoids()
    local myChar = lp().Character
    local myHum = myChar and myChar:FindFirstChildOfClass("Humanoid")
    local tChar = targetChar()
    local tHum = tChar and tChar:FindFirstChildOfClass("Humanoid")
    return myHum, tHum
end

local function shouldRotate()
    return state.lockon_enabled
        and state.lockon_held
        and state.lockon_locked
        and state.lockon_target ~= nil
        and state.lockonPlusEnabled
end

local function bgSuppressed()
    if not state.bgSafeEnabled then return false end
    local myHum, tHum = getHumanoids()
    if myHum then
        if myHum.PlatformStand then return true end
        if SUPPRESS_STATES[myHum:GetState()] then return true end
    end
    if tHum then
        if tHum.PlatformStand then return true end
        if SUPPRESS_STATES[tHum:GetState()] then return true end
    end
    return false
end

local function ensureConstraint(myRoot)
    if not self_state.attachment or not self_state.attachment.Parent then
        self_state.attachment = Instance.new("Attachment")
        self_state.attachment.Name = "PantheonLockOnPlusAttachment"
        self_state.attachment.Parent = myRoot
    end
    if not self_state.align or not self_state.align.Parent then
        self_state.align = Instance.new("AlignOrientation")
        self_state.align.Name = "PantheonLockOnPlusAlign"
        self_state.align.Mode = Enum.OrientationAlignmentMode.OneAttachment
        self_state.align.Attachment0 = self_state.attachment
        self_state.align.RigidityEnabled = true
        self_state.align.Responsiveness = 200
        self_state.align.MaxTorque = math.huge
        self_state.align.Parent = myRoot
    end
end

local function disableAlign()
    if self_state.align then self_state.align.Enabled = false end
end

local function step()
    if not shouldRotate() then
        disableAlign()
        return
    end

    local myChar = lp().Character
    if not myChar then return end
    local myRoot = rootOf(myChar)
    local myHum  = myChar:FindFirstChildOfClass("Humanoid")
    if not myRoot or not myHum then return end

    local tRoot = rootOf(targetChar())
    if not tRoot then return end

    if bgSuppressed() then
        self_state.suppressedSince = os.clock()
        disableAlign()
        return
    end

    local now = os.clock()
    if self_state.suppressedSince > 0 then
        self_state.smoothUntil = now + SMOOTH_DURATION
        self_state.suppressedSince = 0
    end

    local dir = tRoot.Position - myRoot.Position
    local flat = Vector3.new(dir.X, 0, dir.Z)
    if flat.Magnitude < 0.1 then return end

    myHum.AutoRotate = false
    ensureConstraint(myRoot)
    if self_state.align then
        self_state.align.Enabled = true
        self_state.align.CFrame = CFrame.lookAt(Vector3.zero, flat)
    end

    -- Skip the direct CFrame snap during the smooth-resume window so we slide
    -- in via AlignOrientation instead of teleporting after the ragdoll ends.
    if now >= self_state.smoothUntil then
        local cf = CFrame.lookAt(myRoot.Position, myRoot.Position + flat)
        local _, yAngle, _ = cf:ToEulerAnglesYXZ()
        myRoot.CFrame = CFrame.new(myRoot.Position) * CFrame.Angles(0, yAngle, 0)
    end
end

-- True when LockOn+ is currently driving the body rotation. Shiftlock uses this
-- to yield: when LockOn+ is active, shiftlock skips its own camera-based rotation.
function LockOnPlus.isActive()
    return shouldRotate() and not bgSuppressed()
end

function LockOnPlus.init()
    if self_state.bound then return end
    RunService:BindToRenderStep(BIND, Enum.RenderPriority.Camera.Value + 150, step)
    self_state.bound = true
end

function LockOnPlus.destroy()
    if self_state.bound then
        pcall(function() RunService:UnbindFromRenderStep(BIND) end)
        self_state.bound = false
    end
    if self_state.align then pcall(function() self_state.align:Destroy() end); self_state.align = nil end
    if self_state.attachment then pcall(function() self_state.attachment:Destroy() end); self_state.attachment = nil end
end

return LockOnPlus
