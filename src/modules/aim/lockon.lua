-- Lock-On: aim-assist applicator. Reads target from Target Select, applies
-- the camera force when state.lockon_enabled AND state.cameraLockEnabled AND a
-- target exists. Resistance gate is the same dt-scaled exponential approach.
--
-- Rotation Lock lives in a separate module (rotation_lock.lua) with its own
-- keybind and hold/toggle mode.

local state = require("modules.aim.state")

local RunService = game:GetService("RunService")

local LockOn = {}

local CAM_BIND = "PantheonLockOnCamera"

local s = {
    bound   = false,
    lastDir = nil,
}

local function rootOf(charOrModel)
    return charOrModel and charOrModel:FindFirstChild("HumanoidRootPart")
end

local function targetCharacter()
    local t = state.target
    if not t then return nil end
    if state.target_type == "player" then return t.Character end
    return t
end

local function cameraStep(dt)
    if not state.lockon_enabled then return end
    if not state.cameraLockEnabled then return end
    if not state.target then return end

    local cam = workspace.CurrentCamera
    if not cam then return end

    -- Suspend the camera-tracking write whenever we're welded to another
    -- character (grab moves). Checked every frame with no cache so the
    -- resumption is on the literal next frame after the weld breaks --
    -- a 50ms cache like shiftlock's would leave the camera frozen for
    -- up to a render after the user is freed.
    if state.isWeldedToOther(Players.LocalPlayer.Character) then return end

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
            s.lastDir = currentLook
            return
        end
        local smoothness = (state.resistance_strength or 0.5) * 20
        local alpha = 1 - math.exp(-smoothness * (dt or 1/60))
        local blended = currentLook:Lerp(dir, alpha)
        if blended.Magnitude > 0.001 then dir = blended.Unit end
    end

    s.lastDir = dir
    cam.CFrame = CFrame.new(camPos, camPos + dir)
end

function LockOn.setEnabled(v)
    state.lockon_enabled = v and true or false
end

function LockOn.init()
    if s.bound then return end
    RunService:BindToRenderStep(CAM_BIND, Enum.RenderPriority.Camera.Value + 1, cameraStep)
    s.bound = true
end

function LockOn.destroy()
    if s.bound then
        pcall(function() RunService:UnbindFromRenderStep(CAM_BIND) end)
        s.bound = false
    end
end

return LockOn
