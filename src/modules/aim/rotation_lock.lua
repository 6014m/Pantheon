-- Rotation Lock (formerly Lock-On+): rotates the local body to face the
-- target while the camera stays free. Has its own keybind (default Q, set in
-- Lock-On's settings panel) with hold/toggle mode. Gated by:
--   - state.lockon_enabled       (Lock-On master toggle)
--   - state.rotationLockEnabled  (Rotation Lock sub-toggle)
--   - state.target               (Target Select has acquired someone)
--   - s.holdActive               (hotkey is engaged per hold/toggle mode)
-- Battlegrounds-safe gate (state.bgSafeEnabled) suppresses rotation only
-- while OUR humanoid is in a non-walking state (PlatformStand / Ragdoll /
-- Physics / etc). We deliberately don't check the target's state -- doing
-- so was losing block windows during their attacks, because knockback
-- briefly puts attackers into Physics state and we'd stop tracking.

local state = require("modules.aim.state")

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")

local RotationLock = {}

local BIND = "PantheonRotationLock"

local SUPPRESS_STATES = {
    [Enum.HumanoidStateType.Physics]          = true,
    [Enum.HumanoidStateType.FallingDown]      = true,
    [Enum.HumanoidStateType.Ragdoll]          = true,
    [Enum.HumanoidStateType.Seated]           = true,
    [Enum.HumanoidStateType.PlatformStanding] = true,
}

local s = {
    align      = nil,
    attachment = nil,
    bound      = false,
    holdMode   = true,   -- default: hold-to-engage
    holdActive = false,  -- unified flag: true when rotation should engage
    wasActive  = false,  -- active->inactive edge, so we hand AutoRotate back once
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

local function getHumanoids()
    local myChar = Players.LocalPlayer.Character
    local myHum  = myChar and myChar:FindFirstChildOfClass("Humanoid")
    local tChar  = targetCharacter()
    local tHum   = tChar and tChar:FindFirstChildOfClass("Humanoid")
    return myHum, tHum
end

local function shouldRotate()
    if state.techBodyOverride then return false end   -- a Tech Builder step is driving the body; yield
    if not state.lockon_enabled then return false end
    if not state.rotationLockEnabled then return false end
    if not state.target then return false end
    if not s.holdActive then return false end
    return true
end

local function myHumanoid()
    local myChar = Players.LocalPlayer.Character
    return myChar and myChar:FindFirstChildOfClass("Humanoid")
end

local function bgSuppressed(myHum)
    -- A grab (welded to a player, or held by a foreign BodyGyro/BodyPosition)
    -- can keep the humanoid in the RUNNING state -- the SwingForce throw does
    -- exactly that (grab inspector: their HRP welded to ours, state=Running). A
    -- state-only check misses it, so we'd write root.CFrame and either DRAG the
    -- welded player (we're the attacker) or fight + GLITCH their grab of us
    -- (we're the victim). So: being grabbed => ALWAYS suppress, regardless of
    -- state or the weld-safety toggle. Returning true makes step() deactivate(),
    -- which also disables our AlignOrientation so it stops torquing against the
    -- grab and hands AutoRotate back.
    if state.isGrabbing() then return true end
    if not state.bgSafeEnabled then return false end
    myHum = myHum or myHumanoid()
    if myHum then
        local st = myHum:GetState()
        -- Hard locks (bleedout / downed / seated) and knockback/ragdoll physics:
        -- suppress so the body doesn't spin while the game controls us.
        if myHum.PlatformStand
           or st == Enum.HumanoidStateType.PlatformStanding
           or st == Enum.HumanoidStateType.Seated
           or SUPPRESS_STATES[st] then
            return true
        end
        -- Knockback: being launched fast with NO movement input. Our per-frame
        -- root.CFrame write fights/cancels the knockback (TSB), so yield. A dash
        -- holds a direction (MoveDirection > 0) so it's NOT caught here.
        local char = Players.LocalPlayer.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if hrp and myHum.MoveDirection.Magnitude < 0.1 then
            local v = hrp.AssemblyLinearVelocity
            if Vector3.new(v.X, 0, v.Z).Magnitude > (myHum.WalkSpeed * 1.6 + 8) then return true end
        end
    end
    -- Intentionally NOT checking the target's state -- knockback briefly puts
    -- them in Physics during their attacks and we still want to track for blocks.
    return false
end

local function ensureConstraint(myRoot)
    if not s.attachment or not s.attachment.Parent then
        s.attachment = Instance.new("Attachment")
        s.attachment.Name = "PantheonRotationLockAttachment"
        s.attachment.Parent = myRoot
    end
    if not s.align or not s.align.Parent then
        s.align = Instance.new("AlignOrientation")
        s.align.Name = "PantheonRotationLockAlign"
        s.align.Mode = Enum.OrientationAlignmentMode.OneAttachment
        s.align.Attachment0 = s.attachment
        s.align.RigidityEnabled = true
        s.align.Responsiveness = 200
        s.align.MaxTorque = math.huge
        s.align.Parent = myRoot
    end
end

local function disableAlign()
    if s.align then s.align.Enabled = false end
end

-- Disengage: drop the constraint and, on the active->inactive edge only, hand
-- AutoRotate back to the humanoid so the body can turn normally again. The
-- one-shot guard (s.wasActive) means we DON'T set AutoRotate every idle frame
-- and fight shiftlock's per-frame pin: if shiftlock is on it re-takes AutoRotate
-- next frame; if it's off, AutoRotate correctly stays true.
local function deactivate()
    disableAlign()
    if s.wasActive then
        local myHum = getHumanoids()
        if myHum then myHum.AutoRotate = true end
        s.wasActive = false
    end
end

local function step()
    if not shouldRotate() then
        deactivate()
        return
    end

    local myChar = Players.LocalPlayer.Character
    if not myChar then return end
    local myRoot = rootOf(myChar)
    local myHum  = myChar:FindFirstChildOfClass("Humanoid")
    if not myRoot or not myHum then return end
    if myHum.Health <= 0 then deactivate(); return end  -- never rotate a dead body

    local tRoot = rootOf(targetCharacter())
    if not tRoot then return end

    if bgSuppressed(myHum) then
        deactivate()
        return
    end

    -- Lead the target the same way [[modules.aim.lockon]] does, so the body
    -- faces where they'll be at impact, not where they were on the last
    -- network update. Critical for block timing on fast-moving attackers.
    local tVel = tRoot.AssemblyLinearVelocity
    local predicted = tRoot.Position + (tVel * state.getLeadTime())
    local dir = predicted - myRoot.Position
    local flat = Vector3.new(dir.X, 0, dir.Z)
    -- Only skip when the target is genuinely co-located with us (a 0.1
    -- stud guard was conservative; lowering keeps the rotation engaged
    -- right up against the target so combat-range facing never glitches).
    if flat.Magnitude < 0.001 then return end

    myHum.AutoRotate = false
    s.wasActive = true
    ensureConstraint(myRoot)
    if s.align then
        s.align.Enabled = true
        s.align.CFrame = CFrame.lookAt(Vector3.zero, flat)
    end

    -- Direct root.CFrame write every frame -- no smooth-resume window.
    -- The old 0.15s smoothing after an unsuppression cost block windows
    -- (target ragdolls briefly -> suppression -> unsuppression -> 0.15s
    -- of catch-up where direct CFrame write was skipped -> hit lands).
    -- Snap-to-face is what the user wants for combat.
    local cf = CFrame.lookAt(myRoot.Position, myRoot.Position + flat)
    local _, yAngle, _ = cf:ToEulerAnglesYXZ()
    myRoot.CFrame = CFrame.new(myRoot.Position) * CFrame.Angles(0, yAngle, 0)
end

function RotationLock.hotkeyPress()
    if not state.rotationLockEnabled then return end
    if s.holdMode then
        s.holdActive = true
    else
        s.holdActive = not s.holdActive
    end
end

function RotationLock.hotkeyRelease()
    if s.holdMode then
        s.holdActive = false
    end
end

function RotationLock.setHoldMode(v)
    s.holdMode = v and true or false
    -- Switching to toggle mode while engaged would leave holdActive stuck on.
    if not s.holdMode then s.holdActive = false end
end

function RotationLock.setEnabled(v)
    state.rotationLockEnabled = v and true or false
    if not v then
        s.holdActive = false
        deactivate()
    end
end

-- True when Rotation Lock is currently driving the body. Shiftlock uses this
-- to yield: when Rotation Lock is active, shiftlock skips its own rotation.
function RotationLock.isActive()
    return shouldRotate() and not bgSuppressed()
end

function RotationLock.init()
    if s.bound then return end
    -- Bound to BOTH RenderStepped (pre-render) and Stepped (pre-physics) so
    -- we rotate twice per frame -- once for what physics sees this tick,
    -- once for what render shows. The user wants godspeed; doubling the
    -- write rate eliminates the half-frame visual lag where rotation
    -- "catches up" between physics and render, and ensures the
    -- physics-side rotation (used for hit registration on movable parts)
    -- always reflects the latest target position.
    RunService:BindToRenderStep(BIND, Enum.RenderPriority.Camera.Value + 150, step)
    s.steppedConn = RunService.Stepped:Connect(function() step() end)
    s.bound = true
end

function RotationLock.destroy()
    if s.bound then
        pcall(function() RunService:UnbindFromRenderStep(BIND) end)
        if s.steppedConn then s.steppedConn:Disconnect(); s.steppedConn = nil end
        s.bound = false
    end
    -- hand the body back to the humanoid on teardown / re-exec
    if s.wasActive then
        local myHum = getHumanoids()
        if myHum then pcall(function() myHum.AutoRotate = true end) end
        s.wasActive = false
    end
    if s.align then pcall(function() s.align:Destroy() end); s.align = nil end
    if s.attachment then pcall(function() s.attachment:Destroy() end); s.attachment = nil end
end

return RotationLock
