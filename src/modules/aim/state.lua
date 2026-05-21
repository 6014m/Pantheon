-- Shared state for the aim-assist subsystem.
-- Target Select writes the target; Lock-On (camera) and Rotation Lock read it.

local Signal = require("core.signal")

local state = {
    -- Target (set by Target Select, read by Lock-On / Rotation Lock / Highlight)
    target              = nil,
    target_type         = nil, -- "player" or "npc"

    -- Target Select
    target_select_enabled = false,

    -- Targeting filters
    realisticEnabled       = false,
    checkHealthEnabled     = true,
    visibilityCheckEnabled = false,
    rangeLimit             = 0,    -- 0 = infinite

    -- Lock-On master + sub-toggles
    lockon_enabled       = false,
    cameraLockEnabled    = true,   -- camera force on/off
    rotationLockEnabled  = false,  -- rotation lock on/off (was lockonPlusEnabled)
    bgSafeEnabled        = true,   -- battlegrounds-safe modifier on rotation lock

    -- Resistance (modifies camera lock)
    resistance_enabled   = false,
    resistance_threshold = 5,
    resistance_strength  = 0.5,

    -- Highlight
    highlightEnabled       = true,
    highlightSecondEnabled = false,
    selfFadeEnabled        = false,

    -- Shiftlock
    shiftlock_enabled = false,
    shiftlock_active  = false,
    killForeign       = true,
    -- When true, the locked-mode rotation pass skips root.CFrame writes when
    -- we're welded to another character (grab moves) so we don't drag them
    -- around. Default OFF so we match normal-player behavior in games like
    -- JJS where strikes weld the victim but the game doesn't actually lock
    -- rotation -- the PlatformStand / Ragdoll / Physics / Dead state checks
    -- already handle the cases where the game DOES lock you (bleedout, etc).
    -- Turn ON in Battlegrounds-style games where the welded victim follows
    -- your rotation and that's not what you want.
    weldSafetyEnabled = false,
    -- When true AND Pantheon shiftlock is OFF, the pin pass + hook yield so
    -- the game's base shiftlock (custom in-game script and/or Roblox's
    -- vanilla MouseLockController) can drive the cursor. Pantheon still
    -- fully owns cursor state while its own shiftlock is on. Default OFF
    -- because the default expectation is "Pantheon shiftlock off = no
    -- shiftlock"; turn ON per-game when you want the game's shiftlock as
    -- a fallback.
    allowGameShiftlock = false,

    -- Swap
    swap_enabled = true,

    -- Misc
    lockHeightOffset = 0,
    friendlies       = {},

    -- Aim-assist prediction window. lockon's camera tracking and rotation_lock's
    -- body facing both add (target.AssemblyLinearVelocity * predictionTime) to
    -- the target's read position so the aim leads them. Without this we sit on
    -- the last network-replicated position, which feels "insanely inaccurate"
    -- on fast-moving enemies because they've already moved by the time we
    -- write the camera/body CFrame. 0 = no prediction.
    predictionTime = 0.05,

    -- Signals
    onTargetChanged = Signal.new(),
}

function state.setTarget(target, type_)
    if state.target ~= target then
        state.target = target
        state.target_type = type_
        state.onTargetChanged:Fire(target, type_)
    end
end

function state.isFriendly(plr)
    if not plr or not plr.UserId then return false end
    return state.friendlies[plr.UserId] == true
end

-- True when `character` has a Weld / WeldConstraint / Motor6D whose other
-- end is on another *player's* character (i.e. you're physically attached
-- to another player, e.g. by a grab move). Used by shiftlock's rotation
-- drag-protect (gated by weldSafetyEnabled) and lockon's camera suspension.
--
-- Specifically uses Players:GetPlayerFromCharacter, not just "any model
-- with a Humanoid". The any-humanoid check was tripping permanently in
-- games where the local character is welded to NPCs / dummies / mounts /
-- vehicles, leaving lockon paused forever. Only welds to actual player
-- characters should count for grab-style suspension.
local PlayersService = game:GetService("Players")

function state.isWeldedToOther(character)
    if not character then return false end
    for _, d in ipairs(character:GetDescendants()) do
        if d:IsA("Weld") or d:IsA("WeldConstraint") or d:IsA("Motor6D") then
            local p0, p1 = d.Part0, d.Part1
            for _, p in ipairs({ p0, p1 }) do
                if p and p.Parent and not p:IsDescendantOf(character) then
                    local m = p:FindFirstAncestorOfClass("Model")
                    if m and m ~= character then
                        if PlayersService:GetPlayerFromCharacter(m) then
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

return state
