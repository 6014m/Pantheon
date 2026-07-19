-- Alignment Keys: re-enables Roblox's classic , / . camera-rotation keys.
--
-- A faithful port of the old RootCamera.lua behavior: each press SNAPS the
-- camera's yaw to the nearest 45-degree increment in that direction --
-- , (comma) rotates left, . (period) rotates right -- instant on key-down,
-- no hold, no continuous spin.
--
-- Original logic (Roblox Core-Scripts RootCamera.lua):
--   local eight2Pi = math_pi / 4                       -- 45 deg snap grid
--   local angle = rotateVectorByAngleAndRound(
--       this:GetCameraLook()*Vector3.new(1,0,1), -eight2Pi*(3/4), eight2Pi)  -- comma
--   this.RotateInput = this.RotateInput + Vector2.new(angle, 0)              -- feeds yaw
-- rotateVectorByAngleAndRound nudges the flat look by rotateAngle, rounds to
-- the nearest roundAmount grid line, and returns the delta to get there. The
-- camera then applies CFrame.Angles(0, -angle, 0) to the look direction.
--
-- The modern PlayerModule removed comma/period and exposes NO RotateInput
-- setter (CameraInput only has getters). So we apply the identical yaw delta by
-- orbiting the camera around its focus. This sticks because the default
-- ClassicCamera rebases each frame off the camera's CURRENT CFrame
-- (BaseCamera:GetCameraLookVector reads workspace.CurrentCamera.CFrame), rather
-- than an internal angle accumulator -- so our one-shot orbit isn't overwritten.

local Players = game:GetService("Players")

local AlignKeys = {}

local s = {
    enabled = false,
    incDeg  = 45,   -- snap increment in degrees (45 = authentic eight2Pi)
}

-- Matches RootCamera's round() (round-half-up), so the snap grid lands on the
-- same increments the original did.
local function round(n)
    return math.floor(n + 0.5)
end

-- Faithful port of RootCamera.rotateVectorByAngleAndRound. Returns the yaw
-- delta (radians) that snaps `flatLook` to the nearest `roundAmount` grid line
-- after nudging it by `rotateAngle`. Returns 0 for a degenerate (vertical) look.
local function snapDelta(flatLook, rotateAngle, roundAmount)
    if flatLook.Magnitude < 1e-4 then return 0 end
    flatLook = flatLook.Unit
    local currAngle = math.atan2(flatLook.Z, flatLook.X)
    local newAngle  = round((currAngle + rotateAngle) / roundAmount) * roundAmount
    return newAngle - currAngle
end

-- dir: -1 = left (comma) mirrors the original's -eight2Pi*(3/4) nudge,
--      +1 = right (period) mirrors +eight2Pi*(3/4).
local function rotate(dir)
    if not s.enabled then return end
    local cam = workspace.CurrentCamera
    if not cam then return end

    local inc  = math.rad(s.incDeg)                 -- roundAmount (grid); was eight2Pi
    local look = cam.CFrame.LookVector
    local flat = Vector3.new(look.X, 0, look.Z)
    local delta = snapDelta(flat, dir * inc * (3 / 4), inc)
    if delta == 0 then return end

    -- Original applied CFrame.Angles(0, -angle, 0) to the look direction; we
    -- rotate the whole camera rig around the focus by the same -delta, so
    -- position + orientation stay consistent (same distance, same pitch, new
    -- yaw) and the camera keeps looking at its focus.
    local focus = cam.Focus.Position
    cam.CFrame = CFrame.new(focus)
        * CFrame.Angles(0, -delta, 0)
        * CFrame.new(-focus)
        * cam.CFrame
end

function AlignKeys.rotateLeft()  rotate(-1) end   -- comma
function AlignKeys.rotateRight() rotate(1)  end   -- period

function AlignKeys.setEnabled(v) s.enabled = v and true or false end
function AlignKeys.setIncrement(deg) s.incDeg = tonumber(deg) or s.incDeg end

-- No background loop: the original rotated only on key-down, instantly.
function AlignKeys.init() end
function AlignKeys.destroy() end

return AlignKeys
