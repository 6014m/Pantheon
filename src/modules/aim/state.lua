-- Shared state for the aim-assist subsystem.
-- Targeting writes the target; lockon writes the locked/held flags; lockon+ and
-- highlight read. All sub-modules access this single table by reference.

local Signal = require("core.signal")

local state = {
    -- Lock-on
    lockon_enabled     = false,
    lockon_held        = false,
    lockon_locked      = false,
    lockon_target      = nil,
    lockon_target_type = nil, -- "player" or "npc"

    -- Targeting options
    realisticEnabled       = false,
    checkHealthEnabled     = true,
    visibilityCheckEnabled = false,
    rangeLimit             = 0,  -- 0 = infinite

    -- Highlight options
    highlightEnabled       = true,
    highlightSecondEnabled = false,
    selfFadeEnabled        = false,

    -- LockOn+ options
    lockonPlusEnabled      = false,
    bgSafeEnabled          = true,

    -- Shiftlock options
    shiftlock_enabled      = false,
    shiftlock_active       = false,
    killForeign            = true,

    -- Camera lock
    lockHeightOffset       = 0,

    -- Swap target hotkey
    swap_enabled           = true,

    -- Camera resistance modifier: deadzone-then-lerp toward target
    resistance_enabled     = false,
    resistance_threshold   = 5,    -- degrees of free-aim cone around target
    resistance_strength    = 0.5,  -- lerp alpha applied beyond threshold (0..1)

    -- Friendlies map (UserId -> true). Other systems (team filters, party
    -- modules) can mutate this freely; targeting reads at runtime.
    friendlies = {},

    -- Signals
    onTargetChanged = Signal.new(),
    onLockChanged   = Signal.new(),
}

function state.setTarget(target, type_)
    if state.lockon_target ~= target then
        state.lockon_target = target
        state.lockon_target_type = type_
        state.onTargetChanged:Fire(target, type_)
    end
end

function state.setLocked(v)
    v = v and true or false
    if state.lockon_locked ~= v then
        state.lockon_locked = v
        state.onLockChanged:Fire(v)
    end
end

function state.isFriendly(plr)
    if not plr or not plr.UserId then return false end
    return state.friendlies[plr.UserId] == true
end

return state
