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

    -- Velocity-adaptive prediction. When predictionAuto is on, getLeadTime()
    -- derives the lead from the TARGET'S TANGENTIAL VELOCITY RELATIVE TO YOU
    -- (the orbit/strafe component the camera must rotate through). Static
    -- targets get 0 lead; a player side-dashing close around you pumps the
    -- lead via the angular-velocity term (close + fast = high angular
    -- rate, the regime where lock-on+ alone falls behind). predictionTime
    -- (slider) is the manual fallback when auto is off.
    predictionAuto   = true,
    predictionFactor = 0.003, -- seconds of lead per stud/sec of tangential speed
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
-- (body). Velocity-adaptive when predictionAuto: takes the TARGET'S TANGENTIAL
-- velocity relative to YOU (perpendicular to the line from your root to
-- theirs -- the "side-dash / orbit" component the camera must chase) and
-- the corresponding ANGULAR velocity from your POV (= tangential / distance),
-- and uses the larger of the two leads.
--
-- Why both:
--  * Linear (tangential) lead handles a fast target at any range -- 60 stud/s
--    strafe at 25 studs needs the same lead as 60 stud/s at 5 studs at the
--    LINEAR scale, but in practice the close one is harder to track.
--  * Angular lead handles "stick close to me" -- a skilled player orbiting at
--    moderate linear speed but tiny radius (1-3 studs) has very high angular
--    rate, the regime where lock-on+ rotation alone visibly falls behind.
-- Taking max() lets each formula dominate where it should.
--
-- A stationary target -- or one moving radially toward/away from you -- gets
-- zero lead by construction (no orbit/strafe to chase). Ping-based lead was
-- the V0 formula but user wanted velocity-driven; the math here doesn't need
-- ping (replicated position lag on a stationary target is uninteresting).
local lastReadT, lastReadV = 0, 0
function state.getLeadTime()
    if not state.predictionAuto then return state.predictionTime or 0 end
    -- Cache the heavy property reads -- getLeadTime is called several times
    -- per frame and the same target position rarely changes between calls.
    local now = os.clock()
    if now - lastReadT < 0.03 then return lastReadV end
    lastReadT = now

    local LP = PlayersService.LocalPlayer
    local myChar = LP.Character
    local me = myChar and myChar:FindFirstChild("HumanoidRootPart")
    local t = state.target
    if not (me and t) then lastReadV = 0; return 0 end
    local targetChar = (state.target_type == "npc") and t or t.Character
    local targetRoot = targetChar and targetChar:FindFirstChild("HumanoidRootPart")
    if not targetRoot then lastReadV = 0; return 0 end

    local relVel = targetRoot.AssemblyLinearVelocity - me.AssemblyLinearVelocity
    local toTarget = targetRoot.Position - me.Position
    local distance = toTarget.Magnitude
    if distance < 0.5 then lastReadV = 0; return 0 end

    -- Strip the radial component (motion straight at/away from you), leaving
    -- only the tangential (orbit/strafe) part.
    local radialDir = toTarget.Unit
    local radialSpeed = relVel:Dot(radialDir)
    local tangentialSpeed = (relVel - radialDir * radialSpeed).Magnitude

    local factor      = state.predictionFactor or 0.003
    local linearLead  = tangentialSpeed * factor
    local angularLead = (tangentialSpeed / math.max(distance, 1)) * 0.05
    local lead = math.max(linearLead, angularLead)

    lead = math.clamp(lead, 0, state.predictionCap or 0.3)
    lastReadV = lead
    return lead
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
