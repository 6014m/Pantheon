-- Huss Valley: Crack Shiftlock -- makes Pantheon's Rotation Lock actually stick in this game
-- (user 2026-10-03: "we really need to crack this games shiftlock i think its breaking the
-- rotation lock").
--
-- The game runs its own body-facing engine on top of Roblox's (BodyFacingConfig: Enabled,
-- BodyFollowRate 10, MaxTravelYaw 90, TorsoLookShare 0.25, MaxHipTwist 25, MaxHeadYaw 65).
-- Its movement step -- bound at RenderPriority Input+1, body unreadable (irreducible
-- bytecode) -- keeps steering the body toward ITS idea of facing every frame, and the
-- TorsoLookShare / MaxHipTwist numbers mean part of that twist is layered into the R6
-- RootJoint Motor6D Transform. Rotation Lock only ever wrote the ROOT part, so the root could
-- be locked dead on the target while the TORSO -- what you actually see -- still turned away
-- with the camera.
--
-- Counter, active only while Rotation Lock is driving (state.rotationLockFacing is set):
--   * enforce (PreRender, after Rotation Lock's own write at Camera+150): re-asserts the root
--     yaw after every other PreRender writer, then measures the TORSO's yaw relative to the
--     root straight off the RootJoint (C0 * Transform * C1^-1) and takes it out in joint
--     space -- animation pitch, roll and bounce survive, only the twist goes. The game and
--     the animator rebuild the twist every frame, so this runs every frame too.
--   * probe (PreRender, before the game's step): how far had the root been pulled off the
--     lock since our last write? Logged every few seconds when someone IS fighting us, so the
--     log says who wins each phase instead of us guessing.
--
-- Known and left alone: facing away from your travel slows you by the game's own movement
-- rules (SideSpeedMultiplier 0.9 / BackSpeedMultiplier 0.75 past 60 degrees off). That is the
-- game's server-checked movement model, not something a facing fix can or should touch.

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")

local state = require("modules.aim.state")
local log   = require("core.log")

local LP = Players.LocalPlayer

local Facing = {}
local CFG = { enabled = true }

local PROBE   = "PantheonHussShiftlockProbe"
local ENFORCE = "PantheonHussShiftlockCrack"
local bound = false
local maxDrift, maxTwist, lastReport = 0, 0, 0
local lastFacing = nil

-- the game's own yaw convention (BodyFacingModel.yaw): 0 = facing -Z, positive = left
local function yawOf(look)
    return math.atan2(-look.X, -look.Z)
end

local function wrap(a)
    return math.atan2(math.sin(a), math.cos(a))
end

local function rootOf()
    local c = LP.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

-- Before the game's movement step: how far did the root get pulled off the lock since our
-- last write (physics + whatever ran after us last frame)?
local function probe()
    local dir = CFG.enabled and state.rotationLockFacing or nil
    local root = dir and rootOf()
    if root and lastFacing then
        local drift = math.deg(math.abs(wrap(yawOf(root.CFrame.LookVector) - yawOf(lastFacing))))
        if drift > maxDrift then maxDrift = drift end
    end
    lastFacing = dir
end

local function enforce()
    local dir = CFG.enabled and state.rotationLockFacing or nil
    if not dir then return end
    local root = rootOf()
    if not root or root.Anchored then return end

    -- the root once more, after every other PreRender writer this frame
    local pos = root.Position
    root.CFrame = CFrame.new(pos, pos + Vector3.new(dir.X, 0, dir.Z))

    -- the torso: take the game's layered twist back out of the RootJoint motor
    local j = root:FindFirstChild("RootJoint")
    if j and j:IsA("Motor6D") then
        local rel = j.C0 * j.Transform * j.C1:Inverse()   -- the torso's CFrame in ROOT space
        local lv = rel.LookVector
        local yaw = math.atan2(-lv.X, -lv.Z)
        if math.abs(yaw) > math.rad(2) then
            local deg = math.deg(math.abs(yaw))
            if deg > maxTwist then maxTwist = deg end
            -- counter-rotate in root space, carried into joint space through C0: pitch/roll
            -- and the walk cycle's own offsets stay, only the yaw between torso and root goes
            j.Transform = j.C0:Inverse() * CFrame.Angles(0, -yaw, 0) * j.C0 * j.Transform
        end
    end

    local t = os.clock()
    if t - lastReport >= 3 then
        if maxDrift > 12 or maxTwist > 4 then
            log.info(string.format(
                "[ShiftlockCrack] last 3 s: game pulled the root up to %.0f deg off the lock; stripped up to %.0f deg of torso twist",
                maxDrift, maxTwist))
        end
        lastReport, maxDrift, maxTwist = t, 0, 0
    end
end

function Facing.start()
    if bound then return end
    bound = true
    maxDrift, maxTwist, lastFacing = 0, 0, nil
    lastReport = os.clock()
    RunService:BindToRenderStep(PROBE, Enum.RenderPriority.Input.Value - 10, function() pcall(probe) end)
    RunService:BindToRenderStep(ENFORCE, Enum.RenderPriority.Camera.Value + 152, function() pcall(enforce) end)
    log.info("[ShiftlockCrack] on")
end

function Facing.stop()
    if not bound then return end
    bound = false
    pcall(function() RunService:UnbindFromRenderStep(PROBE) end)
    pcall(function() RunService:UnbindFromRenderStep(ENFORCE) end)
    lastFacing = nil
end

function Facing.feature()
    return {
        id          = "huss.shiftlock_crack",
        name        = "Crack Shiftlock",
        description = "Makes Rotation Lock stick in Huss Valley. This game runs its own facing engine that keeps turning your body -- and twisting your torso through the character's joints -- toward where IT wants you to look, every frame, which fought Rotation Lock. While Rotation Lock is driving, this re-asserts your facing after the game's writes each frame and takes the game's twist back out of your torso, so you actually face your locked target. It also logs how hard the game fought, so it can be tuned from the log. Does nothing while Rotation Lock is off.",
        default     = true,
        onToggle    = function(v)
            CFG.enabled = v and true or false
            if CFG.enabled then Facing.start() else Facing.stop() end
        end,
    }
end

return Facing
