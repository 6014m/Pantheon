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
    -- around. Turn off to recover rotation through nerf-style welds, e.g.
    -- JJS moves that weld your HRP to the victim to lock your aim.
    weldSafetyEnabled = true,

    -- Swap
    swap_enabled = true,

    -- Misc
    lockHeightOffset = 0,
    friendlies       = {},

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

return state
