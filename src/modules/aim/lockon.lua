-- Main lock-on driver:
--   * Hotkey dispatch comes through core.keybinds (handled by the feature row),
--     so this module only exposes the press/release entry points.
--   * Heartbeat loop validates the current target (drops if dead/gone/friendly).
--   * RenderStep loop forces the camera to point at the target while locked,
--     gated by the Resistance modifier:
--       - resistance off    : camera snaps to target every frame
--       - resistance on     : within `resistance_threshold` deg of target the
--                             camera is left alone (free aim); past the
--                             threshold it lerps toward the target by
--                             `resistance_strength` per frame.

local state     = require("modules.aim.state")
local targeting = require("modules.aim.targeting")
local highlight = require("modules.aim.highlight")

local RunService = game:GetService("RunService")
local Players    = game:GetService("Players")

local LockOn = {}

local CAM_BIND = "PantheonLockOnCamera"

local s = {
    holdMode   = false,
    holdActive = false,
    runConn    = nil,
    bound      = false,
    lastDir    = nil,
}

local function lp() return Players.LocalPlayer end

local function rootOf(charOrModel)
    return charOrModel and charOrModel:FindFirstChild("HumanoidRootPart")
end

local function targetCharacter()
    local t = state.lockon_target
    if not t then return nil end
    if state.lockon_target_type == "player" then return t.Character end
    return t
end

local function releaseLock()
    state.setLocked(false)
    state.lockon_held = false
    state.setTarget(nil, nil)
    s.holdActive = false
    s.lastDir = nil
    highlight.update(nil, nil)
end

local function engageLock()
    local t = targeting.getBestTarget()
    if not t then return false end
    state.setTarget(t, "player")
    state.setLocked(true)
    state.lockon_held = true
    return true
end

-- Heartbeat: drop the target if it stops being valid.
local function validateStep()
    if not state.lockon_enabled or not state.lockon_locked then return end

    local t = state.lockon_target
    if state.lockon_target_type == "player" then
        local char = t and t.Character
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        if not hum or hum.Health <= 0 or not char.Parent or state.isFriendly(t) then
            releaseLock()
            return
        end
    elseif state.lockon_target_type == "npc" then
        local hum = t and t:FindFirstChildOfClass("Humanoid")
        if not hum or hum.Health <= 0 or not t.Parent then
            releaseLock()
            return
        end
    end

    highlight.update(t, function(exclude) return targeting.getBestTarget(exclude) end)
end

-- RenderStep: force camera to look at target, optionally gated by resistance.
local function cameraStep()
    if not state.lockon_enabled or not state.lockon_locked then return end

    local cam = workspace.CurrentCamera
    if not cam then return end

    local tRoot = rootOf(targetCharacter())
    if not tRoot then return end

    local camPos  = cam.CFrame.Position
    local lookPos = tRoot.Position + Vector3.new(0, state.lockHeightOffset or 0, 0)
    local desired = lookPos - camPos
    if desired.Magnitude < 0.5 then
        if s.lastDir then
            cam.CFrame = CFrame.new(camPos, camPos + s.lastDir)
        end
        return
    end
    local dir = desired.Unit

    if state.resistance_enabled then
        local currentLook = cam.CFrame.LookVector
        local cosTheta = math.clamp(currentLook:Dot(dir), -1, 1)
        local angleDeg = math.deg(math.acos(cosTheta))
        if angleDeg < (state.resistance_threshold or 0) then
            -- Within deadzone: leave the camera alone so the player can free-aim.
            s.lastDir = currentLook
            return
        end
        local strength = state.resistance_strength or 0.5
        local blended = currentLook:Lerp(dir, strength)
        if blended.Magnitude > 0.001 then dir = blended.Unit end
    end

    s.lastDir = dir
    cam.CFrame = CFrame.new(camPos, camPos + dir)
end

-- Cycle to the next-best target (excluding the current one).
function LockOn.swapTarget()
    if not state.swap_enabled then return end
    if not state.lockon_enabled or not state.lockon_locked then return end
    local next_ = targeting.getBestTarget(state.lockon_target)
    if next_ then
        state.setTarget(next_, "player")
        s.lastDir = nil
    end
end

-- Called by the central keybind dispatcher on key press.
function LockOn.hotkeyPress()
    if not state.lockon_enabled then return end
    if s.holdMode then
        if not state.lockon_locked then engageLock() end
        s.holdActive = true
    else
        if state.lockon_locked then releaseLock() else engageLock() end
    end
end

-- Called by the central keybind dispatcher on key release.
function LockOn.hotkeyRelease()
    if s.holdMode and s.holdActive and state.lockon_locked then
        releaseLock()
    end
end

function LockOn.setHoldMode(v)
    s.holdMode = v and true or false
end

function LockOn.setEnabled(v)
    state.lockon_enabled = v and true or false
    if not v then releaseLock() end
end

function LockOn.init()
    s.runConn = RunService.Heartbeat:Connect(validateStep)
    if not s.bound then
        RunService:BindToRenderStep(CAM_BIND, Enum.RenderPriority.Camera.Value + 1, cameraStep)
        s.bound = true
    end
end

function LockOn.destroy()
    if s.runConn then s.runConn:Disconnect(); s.runConn = nil end
    if s.bound then
        pcall(function() RunService:UnbindFromRenderStep(CAM_BIND) end)
        s.bound = false
    end
end

return LockOn
