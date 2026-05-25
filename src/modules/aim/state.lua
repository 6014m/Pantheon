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
    highlightSecondEnabled = true,    -- yellow outline on the swap target (next-best) by default
    targetInfoEnabled      = true,    -- healthbar + username billboard over highlighted targets
    selfFadeEnabled        = false,

    -- Shiftlock
    shiftlock_enabled = false,
    shiftlock_active  = false,
    killForeign       = true,
    -- Mirror mode: FOLLOW the game's own shiftlock (shiftlock_active tracks its
    -- cursor lock) and write nothing ourselves, so the two never overlap. Turn
    -- on per-game in games that ship their own shiftlock (e.g. JJS).
    shiftlockMirror   = false,
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

    -- Tech Builder: while a tech is driving the camera/body (a Look/Rotate step),
    -- Lock-On (camera) and Rotation Lock (body) yield so they don't fight it.
    techCamOverride  = false,
    techBodyOverride = false,
    -- Tech Builder: a tech with "Ignore welds" set turns this on while it runs, so
    -- isGrabbing() reports false and Lock-On/Rotation stay active even when welded.
    techIgnoreWelds  = false,

    -- Misc
    lockHeightOffset = 0,
    friendlies       = {},

    -- Aim-assist prediction window. lockon's camera tracking and rotation_lock's
    -- body facing both add (target.AssemblyLinearVelocity * predictionTime) to
    -- the target's read position so the aim leads them. Without this we sit on
    -- the last network-replicated position, which feels "insanely inaccurate"
    -- on fast-moving enemies because they've already moved by the time we
    -- write the camera/body CFrame. 0 = no prediction; 0.1 leads ~5 studs
    -- against a 50-stud/s sprinter, which is closer to the typical ping
    -- compensation a battlegrounds-style game needs.
    predictionTime = 0.1,

    -- Ping-adaptive prediction. When predictionAuto is on, getLeadTime() derives
    -- the lead from live ping (ping * factor, capped) so it self-tunes per
    -- server; predictionTime above becomes the manual value used when auto off.
    predictionAuto   = true,
    predictionFactor = 1.0,   -- multiplier on the ping-derived lead
    predictionCap    = 0.3,   -- hard cap (seconds) on the lead

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

-- True when `character` is rigidly attached (Weld / WeldConstraint / Motor6D)
-- to another *player's* character -- i.e. a grab move has stuck you to them.
-- Used by shiftlock's rotation drag-protect (gated by weldSafetyEnabled) and
-- lockon's camera suspension.
--
-- Specifically uses Players:GetPlayerFromCharacter, not just "any model
-- with a Humanoid". The any-humanoid check was tripping permanently in
-- games where the local character is welded to NPCs / dummies / mounts /
-- vehicles, leaving lockon paused forever. Only welds to actual player
-- characters should count for grab-style suspension.
local PlayersService = game:GetService("Players")
local StatsService   = game:GetService("Stats")

-- Effective aim lead (seconds), shared by lockon (camera) and rotation_lock
-- (body). Ping-adaptive when predictionAuto: a target's replicated position is
-- ~ping behind, so leading by velocity * ping faces where they actually are
-- now -- this self-tunes per server instead of a fixed guess. Falls back to the
-- manual predictionTime slider when auto is off.
-- Cache the live ping read. GetValue() through StatsService.Network is a pcall +
-- property traversal, and getLeadTime() is called several times per frame (lockon
-- camera + rotation_lock's render+stepped double-bind). Ping barely moves frame to
-- frame, so refreshing it 4x/s instead of ~240x/s is free perf. The cheap lead
-- math (ping * factor, capped) still runs per call so factor/cap stay live.
local pingCacheT, pingCacheV = 0, 0.1
function state.getLeadTime()
    if state.predictionAuto then
        local now = os.clock()
        if now - pingCacheT > 0.25 then
            pingCacheT = now
            local ok, ms = pcall(function()
                return StatsService.Network.ServerStatsItem["Data Ping"]:GetValue()
            end)
            pingCacheV = (ok and ms or 100) / 1000
        end
        return math.min(pingCacheV * (state.predictionFactor or 1), state.predictionCap or 0.3)
    end
    return state.predictionTime or 0
end

function state.isWeldedToOther(character)
    if not character then return false end

    -- A part that belongs to a different *player's* character (not ours, and
    -- not an NPC / dummy / mount).
    local function foreignPlayerPart(p)
        if not p or not p.Parent then return false end
        if p:IsDescendantOf(character) then return false end
        local m = p:FindFirstAncestorOfClass("Model")
        return m ~= nil and m ~= character
            and PlayersService:GetPlayerFromCharacter(m) ~= nil
    end

    local function joinsToForeign(j)
        return (j:IsA("Weld") or j:IsA("WeldConstraint") or j:IsA("Motor6D"))
            and (foreignPlayerPart(j.Part0) or foreignPlayerPart(j.Part1))
    end

    for _, d in ipairs(character:GetDescendants()) do
        if d:IsA("BasePart") then
            -- GetJoints() finds joints by their Part0/Part1 references no matter
            -- where the joint instance is *parented*. Grab moves frequently
            -- parent the weld on the VICTIM's character (or in workspace) so it
            -- replicates with them -- a walk that only inspects our own
            -- descendants misses those entirely, which is why we still dragged
            -- enemies around. Parent-agnostic lookup catches both sides.
            local ok, joints = pcall(function() return d:GetJoints() end)
            if ok and joints then
                for _, j in ipairs(joints) do
                    if joinsToForeign(j) then return true end
                end
            end
        elseif d:IsA("Weld") or d:IsA("WeldConstraint") or d:IsA("Motor6D") then
            -- Fallback: a weld instance parented inside our own character, in
            -- case GetJoints under-reports WeldConstraints on this executor.
            if joinsToForeign(d) then return true end
        end
    end
    return false
end

-- Cached "am I welded to another player right now" = a grab is happening (e.g.
-- JJS Decisive Strikes). 50ms cache so the rotation passes can cheaply ASK
-- without walking descendants every frame. Independent of weldSafetyEnabled:
-- that toggle decides what to DO with a grab; this just detects it. The rotation
-- passes use it to keep rotating THROUGH a grab (the game parks you in
-- PlatformStand/Physics during it, but you still want to aim).
-- "Am I grabbed by / grabbing another PLAYER right now" = a grab.
-- TRUE only when we're rigidly welded to ANY part of another player's character
-- (part-agnostic -- grabs use HRP<->HRP, arm<->leg, etc., confirmed via the grab
-- inspector). While true, the rotation passes write NOTHING to our body and
-- disable their AlignOrientation so we don't drag the welded player (attacker) or
-- glitch their grab of us (victim).
--
-- Deliberately does NOT count a foreign BodyGyro/BodyPosition/AlignOrientation on
-- our HRP: SELF-moves (e.g. Naoya's ult) hold you with those WITHOUT welding you
-- to a player, and those should NOT block lockon. A grab means another player is
-- involved, which the weld check captures.
local grabCacheT, grabCacheV = 0, false
function state.isGrabbing()
    -- a tech opted out of grab-suppression so Lock-On keeps working while welded
    if state.techIgnoreWelds then return false end
    local now = os.clock()
    if now - grabCacheT > 0.05 then
        grabCacheT = now
        local c = PlayersService.LocalPlayer and PlayersService.LocalPlayer.Character
        grabCacheV = c ~= nil and state.isWeldedToOther(c)
    end
    return grabCacheV
end

return state
