-- The Veil: Auto Weave. Presses your weave key so the weave's i-frames cover incoming hits.
--
-- Everything here comes from two recorded sessions ([Dev] Veil Combat Recorder, 2026-09-25,
-- ~40 min, 900+ hits, 270 weaves; analysis in Desktop\The Veil Wiki\combat):
--   * Weave = F. LeftWeave / RightWeave anim starts on the press frame, lasts 0.2 s, and
--     presses closer than ~0.5 s apart are eaten (cooldown).
--   * A weave pressed 0.15-0.40 s before the hit lands dodges it (clean), earlier than
--     0.45 or later than 0.05 gets hit. So we aim for ~0.25 s before impact (ping 46 ms).
--   * Melee is server-side: no hitbox part ever shows up before a swing lands, so swings
--     are timed from the mob's attack animation. Most mobs share one swing anim
--     (107426583476702) whose damage lands a steady 0.58 s after it starts.
--   * Projectiles (GreenBeam, SentryLaser, ShatterProjectile) and a few AoE parts DO exist
--     client-side, so those are tracked directly. Only KNOWN hostile names by default:
--     Ichor (~24 stud/s, dropped by half the bestiary) homes straight into you and looked
--     exactly like a projectile, but it is a pickup (user, live test 2026-09-25).
--   * Several "hitboxes" near you are your own (Aegis Banner's BannerExplode, FlowerExplode,
--     summon bursts, your sprint part) or mob limbs; those are ignored.
-- Undodgeable attacks are out of scope on purpose.

local Players   = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local UIS       = game:GetService("UserInputService")
local VIM       = game:GetService("VirtualInputManager")

local log   = require("core.log")
local state = require("modules.aim.state")

local LP = Players.LocalPlayer

local Weave = {}

-- Decision log: workspace/Veil_Combat/autoweave_<time>.log, one line per decision, stamped
-- with os.clock() so it lines up with the Combat Recorder (its start event carries the same
-- clock). Lets any hit that got through be traced to the exact reason.
local DLOG_DIR = "Veil_Combat"
local dlogPath, dlogBuf = nil, {}
local function dlog(fmt, ...)
    local ok, line = pcall(string.format, fmt, ...)
    dlogBuf[#dlogBuf + 1] = string.format("%.3f %s", os.clock(), ok and line or fmt)
end
local function dlogFlush()
    if #dlogBuf == 0 or not writefile then table.clear(dlogBuf); return end
    if not dlogPath then
        pcall(function() if makefolder and isfolder and not isfolder(DLOG_DIR) then makefolder(DLOG_DIR) end end)
        dlogPath = DLOG_DIR .. "/autoweave_" .. os.date("%m%d_%H%M%S") .. ".log"
        pcall(writefile, dlogPath, "")
    end
    local chunk = table.concat(dlogBuf, "\n") .. "\n"
    if appendfile and pcall(appendfile, dlogPath, chunk) then table.clear(dlogBuf) end
    if #dlogBuf > 4000 then table.clear(dlogBuf) end
end

local CFG = {
    enabled      = false,
    key          = Enum.KeyCode.F,
    lead         = 0.25,    -- press this long before impact (measured sweet spot at 46 ms ping)
    basePing     = 0.046,   -- ping the lead was measured at; extra ping adds to the lead
    cooldown     = 0.5,     -- presses closer than this are ignored by the game
    meleeRange   = 15,      -- mob must be this close when its swing starts (Bones / Hivelings lunge in from 11-14)
    targetCheck  = true,    -- skip swings aimed at an Explorer / summon / other player in front of you
    swingReach   = 9,       -- studs: a normal swing only lands if the mob is this close when it hits
    meleeFacing  = 180,     -- off: mobs turn mid-swing; swings that started >80 deg away hit you as often (15-22%) as ones facing you (17%)
    melee        = true,
    projectiles  = true,
    projMiss     = 4,       -- a projectile passing closer than this counts as a hit
    hitboxes     = true,
    hitboxDelay  = 0.3,     -- static AoE hitboxes: seconds after they cover you before weaving
    pvp          = true,    -- other players outside your party (and their summons) are enemies
    reflex       = false,
    usePredictions = false, -- shift a weave early for a PREDICTED follow-up (off: wait for the real attack)   -- weave the moment a mob explosion lands on you (tested: too late, 7/19 hit)
    verbose      = false,   -- print every weave and its reason to the console
    dash         = true,    -- dash (i-frames too) when a weave can't cover a hit
    dashKey      = Enum.KeyCode.Q,
    dashReserve  = 0,       -- stamina to leave for yourself
    dashBackup   = true,    -- also dash when a weave can't make it (only with a spare dash banked)
    bossFocus    = true,    -- while you're fighting a boss its attacks come first (see DASH.fighting)
    tankHits     = 5,       -- user (2026-09-27): "we can tank at least 5 hits before dashing" -- in
    tankWindow   = 4,       --   crowds it dashed far too much. Only a boss's must-dash move (a real
                            --   unweavable) dashes straight away; every other dash waits until you've
                            --   taken this many hits (>= 5 dmg) in the last tankWindow seconds
    swordMobility = false,  -- use the Enchanted Sword (Elite mobility cast, ~0 stamina) when a dash can't go
    dashDir      = "Away from the attack",
    pillarDodge  = true,    -- move out of the Festering Wound's rot pillar as soon as it spawns
    escapePush   = true,    -- push you out of reach of long AoE channels (Wound ground punches)
    jumpStyle    = "Single jump",   -- slams: a plain jump (no cooldown) or the double jump (2 s cooldown)
    bombPush     = true,    -- shove loose bombs (Crowned Nothing's WhiteOrbBomb) away from you
    orbMode      = "Jump + dash into it",   -- gas balls (RotOrb): "Jump + dash into it" / "Push away" / "Off"
                            --   push (09-27) "didn't work out too well"; the pull-in (09-28) "looks too
                            --   obvious I'm cheating" -> jump, aim the camera exactly at the ball, dash
                            --   at it: you go through it with the dash's i-frames up
}

-- attack animation -> seconds from anim start to damage (median of clean hits on you)
local ATTACKS = {
    -- The Bell (megaboss, fight 2026-09-29): it plays an indicator sound as each attack starts --
    -- WeaveIndi / JumpIndi / DodgeIndi -- that says which evasion the attack wants.
    ["81529985859552"]  = 0.86,  -- The Bell stab (WeaveIndi): dashes in from 55-76 studs, Stab 0.71; fight 2: 33 plays, hits 0.85-0.94
    ["107426583476702"] = 0.58,  -- shared swing: Skeleton, Armored Skeleton, Wraith, Hivelings, Alien...
    ["110285618672790"] = 0.57,  -- Ancient Bones
    ["102522251341739"] = 0.65,  -- Ancient Bones
    ["116165199693856"] = 0.34,  -- Shrouded
    ["84146368125308"]  = 0.57,  -- Clown
    -- (Imp 85194526199823 is its fireball CAST, not a swing: the fireball is timed instead)
    ["127688919744763"] = 0.50,  -- Runner / Cambion
    ["74743744689930"]  = 0.65,  -- Runner
    ["117802002100480"] = 0.80,  -- Minotaur big swing (0.74-0.88 recorded, 32-240 dmg)
    ["131201775492062"] = 0.91,  -- Enchanted Sword slash (0.89 / 0.92 / 0.93, from up to 19 studs)
    -- Cursed Hammer BASIC attack (38 plays a session): its real hit is 38.5 at 0.90-0.94 s. It
    -- used to be weaved at 0.42 (a 15-dmg nick at 0.23-0.25), which burned the cooldown -> 27
    -- weaves, 2 caught. (Briefly dashed by mistake -- user: that's his basic, weave it.)
    ["120338508145604"] = 0.92,
    ["115142136659049"] = 1.03,  -- Starving Warrior lunging slash (1.02-1.05, 32 dmg, from 11-19 studs)
    ["91438445642768"]  = 0.56,  -- Gigazapper zap (0.55 / 0.57 / 0.55, 27.6 dmg) -- Martian Saucer add
    ["91414483216673"]  = 0.50,  -- Gigazapper second attack (1 sample)
    -- Stone Husk (fight 2026-09-27, user: "needs a re-assessment"): NONE of its attacks were
    -- known, so nothing was weaved. Main swing lunges in from 12-20 studs: 38.5 at 0.55-0.72
    -- (8 hits, median ~0.65, keyframe 0.59-0.63). WeaveIndi swing 100666197209295 (the game
    -- plays a "WeaveIndi" sound as it starts): 44 at 0.84 from 16 studs (1 sample).
    ["109307767575462"] = 0.65,
    ["100666197209295"] = 0.84,
    -- Smelter Demon CHAIN PULL 81155999312581 (user 2026-09-28: "you can weave the chains before
    -- they're attached"): the chain lands 10.5 at 0.36-0.42 s (median 0.38, every recorded pull,
    -- 16-55 studs) and then drags you in. Weaved just before it attaches. (Still in NEVER_LEARN so
    -- the learner can't overwrite this with a noisy value.)
    ["81155999312581"]  = 0.38,
    -- Smelter Demon (boss)
    ["91349317972378"]  = 1.60,  -- fire burst: 80-stud SmelterFireBurstPart ~1.5-1.6 s in (55 dmg; 57.75 at 1.62/1.65 in fight 2)
    ["134186092103081"] = 1.14,  -- main swing: 36.75 dmg at 1.05-1.24 (median 1.14, 16 hits in fight 2, never weaved before)
    ["130122482089218"] = 0.76,  -- leaping slam: 35 dmg at 0.74-0.79 s from up to 46 studs
    ["90623661509768"]  = 1.30,  -- charge along a line of Hitbox parts 1.0-1.6 s in (40 dmg at 1.39)
    ["110148940035265"] = 0.54,  -- Pillar Mimic hit: 26 dmg at 0.51-0.57 s from ~9-11 studs
    -- The Festering Wound (recorded fight 2026-09-25)
    -- (Wound rush 100113874261999 is NOT timed from its anim: its hits moved with distance --
    -- 0.97-1.18 / 2.0 in one fight, 1.07-1.37 / 2.65-2.88 in another -- so the size-aware
    -- rush tracker times each rush from his actual approach instead)
    ["83705524958250"]  = 0.70,  -- punch: 0.62 / 0.67 / 0.77 + a weave caught at 0.77
    ["82381115462756"]  = 0.73,  -- punch 2: weaves caught it at 0.72 / 0.72 / 0.74
    -- The Stormcaller (boss)
    ["129783803036051"] = 1.08,  -- heavy swing: 30 dmg at 1.07-1.10 s
    -- (Stormcaller lightning stomp 77025178675756 is jumped: JUMP_ATTACKS)
    ["123223658247605"] = 0.72,  -- Turret Golem up close (0.69 / 0.75, 25 dmg); from range it fires a
                                 -- LaserProjectile -> explosion (GOLEM_LASER below)
}

-- attacks that land more than once: extra hits (seconds after the anim starts)
local EXTRA_HITS = {
}

-- mobs whose "facing" means nothing (a floating sword spins while it attacks)
local NO_FACING = {
    ["131201775492062"] = true,
    -- Minotaur swing: it turns while lunging -- swings that hit started facing 109-145 deg
    -- away, so facing says nothing about whether it lands
    ["117802002100480"] = true,
}

-- attacks that reach further than CFG.meleeRange (the mob lunges in while swinging)
local ATTACK_RANGE = {
    ["81529985859552"]  = 95,    -- The Bell stab: it closes the gap itself (fight 2 starts 12-79 studs)
    ["117802002100480"] = 18,    -- Minotaur swing starts 11-14 studs out, closing ~15 stud/s
    ["131201775492062"] = 20,    -- Enchanted Sword slash reached 19 studs
    ["120338508145604"] = 14,    -- Cursed Hammer smash lunges in (closing ~15 stud/s)
    ["115142136659049"] = 21,    -- Starving Warrior slash reached 19 studs
    ["123223658247605"] = 14,    -- Turret Golem close-range hit (beyond this it's the laser)
    ["102522251341739"] = 90,    -- Ancient Bones spike erupts under you ~0.65 s later, even from 57-85 studs
    ["110285618672790"] = 17,    -- Ancient Bones swing: starts 11-15 studs out and still lands (unseen twice)
    ["100113874261999"] = 70,    -- Wound rush: started 14-59 studs out
    ["83705524958250"]  = 30,    -- Wound punch (it moves while punching)
    ["82381115462756"]  = 22,    -- Wound punch 2
    ["109307767575462"] = 22,    -- Stone Husk swing (lunges in from 12-20)
    ["100666197209295"] = 22,    -- Stone Husk WeaveIndi swing (started 16 out)
    ["91349317972378"]  = 45,    -- Smelter fire burst (80-stud cube)
    ["134186092103081"] = 30,    -- Smelter main swing (started ~15 studs out)
    ["81155999312581"]  = 58,    -- Smelter chain pull: reaches you from 16-55 studs
    ["130122482089218"] = 50,    -- Smelter leap
    ["90623661509768"]  = 40,    -- Smelter charge
    ["129783803036051"] = 22,    -- Stormcaller swing
    ["77025178675756"]  = 32,    -- Stormcaller stomp (60-stud ring)
}

-- beyond this distance the attack targets where you ARE (a spike under you): it only lands
-- if you're nearly still, so it's only woven then (a whiff = 1.4 s lockout)
local STILL_ONLY_BEYOND = {
    ["102522251341739"] = 15,
}

-- RHYTHM: instant attacks (damage lands with the animation) that can only be dodged by
-- predicting the next one. Alien Gunner's GreenBeam: 2 shots 0.21 s apart, a burst every
-- 2.23 s (19 recorded gaps, +-0.02 s), damage 0.00-0.07 s after the shot anim starts.
local RHYTHM = {
    ["87947721952194"] = { hit = 0.04, burst = 0.21, cycle = 2.23, range = 35, facing = 30 },
}
local lastShot = setmetatable({}, { __mode = "k" })   -- model -> time of its last shot
local channelUntil = setmetatable({}, { __mode = "k" })  -- model -> end of its channel (charge)
local mobRoots = setmetatable({}, { __mode = "k" })      -- hooked mob -> its root part
local rushQueued = setmetatable({}, { __mode = "k" })    -- model -> last time a rush was queued
local rushImpact = setmetatable({}, { __mode = "k" })    -- model -> its queued impact (kept up to date)

-- WINDUPS: a charge-up anim, then a dash through you. The warning when you're standing
-- where it launches from (the rush tracker alone would see it too late).
-- Enchanted Sword: wind-up 90831939847969 -> the dash starts ~2.78 s later (6 recorded:
-- 2.74-2.83 s) at ~100 stud/s from wherever it is; hits landed 2.73-2.98 s after the wind-up.
local WINDUPS = {
    ["90831939847969"] = { delay = 2.75, speed = 100, range = 75 },   -- predicted vs real hits: -0.13..+0.08 s
}

-- VOLLEYS: one cast, several strikes at fixed times. The strike appears on the frame it
-- damages, so it's timed from the cast. Starving Warrior void pierce 108816257830139:
-- VoidPierceProjectile at +0.70 / +1.17 / +1.65 s every time; they landed on the user
-- when standing still and mostly missed while moving -- and a whiff locks weaving ~1.4 s,
-- so the volley is only woven while you're nearly still.
local VOLLEYS = {
    ["108816257830139"] = { times = { 0.70, 1.17, 1.65 }, range = 80, facing = 30, stillBelow = 6 },
}

local function myHorizontalSpeed()
    local r = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
    if not r then return 0 end
    local v = r.AssemblyLinearVelocity
    return Vector3.new(v.X, 0, v.Z).Magnitude
end

-- BEAMS: a telegraphed beam that ticks for a while -- one weave can't cover it, so it's a
-- dash timed to the beam's arrival, SIDEWAYS (out of a narrow beam, not along it).
-- Martian Saucer big laser 100715676859600: BigLaserHitbox (27 x 5 x 5) lands ~1.05 s after
-- the anim, then 15 dmg every ~0.24 s (4 ticks), twice in a row.
local BEAMS = {
    ["100715676859600"] = { first = 1.2, range = 130, name = "Saucer big laser", dir = "Sideways" },
    -- Ancient Bones black orb 76685049242709: BlackFlash (33-49 stud cube around the Bones)
    -- 1.17-1.23 s after the anim, 152-240 dmg. Unweavable, dodgeable: dash AWAY as it goes off.
    ["76685049242709"] = { first = 1.25, range = 32, name = "Ancient Bones black orb", dir = "Away from the attack" },
}

-- CHANNELS: long attacks you can't weave (you're hit a little no matter what). Answer:
-- dash AWAY the moment it starts, keep attacking while you back off (user's call).
-- Minotaur charge: looped anim, ~3 s, 3.68 dmg every ~0.2 s while it's on you.
local CHANNELS = {
    ["83727072964250"] = { name = "Minotaur charge", range = 20 },
    -- Festering Wound RAPID GROUND PUNCHES 127293443282395 (user-confirmed; 4.65 s, its
    -- AIHold attribute is on for the whole move): TripleSmashEffects at 0, punches landing
    -- 36.75 at ~0.96 / ~1.41 s and on (user: get away or lose ~90% HP). Enchanted Sword
    -- launch straight away from him first (if enabled), else dash away; punches that still
    -- reach you (within 20 studs) are woven.
    -- (user: forget the Enchanted Sword here -- two dashes away get you out of range)
    -- (user: being double-jumped when the punching starts avoids it at once, but you can't
    -- stay up for the whole thing -> double jump over the first punch, then dash away before
    -- landing. Only if the double jump is off cooldown; else straight to the dashes.)
    -- REACH (fight 2026-09-27, user: "if I'm just within its range it won't get me out"): he
    -- stands still, the ring is 85 wide (TripleSmashEffects), but punches hit you from 42-55
    -- studs (the server sees you ~0.2-0.3 s behind) and it only reacted inside 45 and only
    -- dashed. Now: escape = push you out to 60 studs for the whole move (learned further if a
    -- punch still lands out there), jump + dashes still cover the first punches on the way.
    ["127293443282395"] = { name = "Festering Wound ground punches", range = 45, dashes = 2,
                            strikes = { 0.96, 1.41 }, jumpFirst = 0.96, dashAt = 1.2,
                            escape = 60, duration = 4.65, edgeBand = 15 },
    -- edgeBand (user 2026-09-28: "I get pushed out before my character gets the chance to double
    -- jump and dash away"): the push only acts in the outer 15 studs of the reach; inside, the
    -- double jump + dashes do the escaping
    -- (Festering Wound rot pillar/beam 111237192632620 -- 10.5 dmg ticks every ~0.1 s, beam2
    -- 5x4x82 follows you -- is NOT dashed: 3 sideways dashes in fight 3 escaped nothing and
    -- burned 110 stamina the gas balls then needed. Waiting on how it's really avoided.)
}

-- JUMP_ATTACKS: undashable + unweavable -> be in the air when it lands (double jump).
-- Festering Wound JUMP / slam-down 80778819711637 (user-confirmed; wind-up
-- 106952798050011 ~2 s before): shockwave (TripleSmashEffects, 85 wide) ~1.2 s in. His root
-- never leaves the ground (the jump is only the animation), so it's timed from the anim.
local JUMP_ATTACKS = {
    -- The Bell leap smash (JumpIndi): leaps in from 55-88 studs, Smash 0.68-0.76, 60.5 dmg at 0.90
    ["124469150178302"] = { impacts = { 0.85 }, range = 100, name = "The Bell leap smash", double = true },
    -- The Bell's TANTRUM 77689631365456 (user: "2 slams then a bell ring which does a shit ton of
    -- damage in an AoE"): JumpIndi at 0, Smash1/Smash2 + JumpIndi at 1.02 -> 55 at 1.12-1.14,
    -- Rumble 1.52, GrabStab 2.64, then the BELL RING (BellSound3 + Explode + Geyser 3.06-3.10) ->
    -- 88 at 3.18-3.22 + a burn (5 of 5 recorded). The slams are double jumped (free: fight 4 jumped
    -- them 2/2 with no damage) and the stamina is saved for a DASH through the ring.
    -- fight 5: jumping slam 1 left you to land into the 2nd slam (Rumble 1.52) -> 55 at 1.87 +
    -- ragdoll; and the ring hit 0.09 s into a dash's i-frames (dash doesn't stop it) -> slam 2 is
    -- dashed, the ring is WOVEN (untested -- check the next fight)
    -- fights 5-6 (2026-09-29, user: "we aren't auto dashing away from the bell ring"): the ring
    -- is escaped by DISTANCE, nothing else -- dashes at +3.01 / +3.13 were hit 70-88 mid i-frames,
    -- while spamming dash away from +1.93 (and a tantrum that started 66 studs out) missed. Hit
    -- when starting 24-26 studs out; real radius unknown -> clear 60 (learned further if it still
    -- lands, like the Wound's punches). So: after slam 2's dash, keep dashing AWAY until clear
    -- or the ring has gone off, and walk out too (escape push). No weave for the ring.
    ["77689631365456"]  = { impacts = { 1.13 }, range = 80, name = "The Bell tantrum slams", double = true,
    -- fight 2026-10-01 (lost at the very end to exactly this): slam 2 hit 55 at 1.76, 0.09 s into
    -- the 1.67 dash (again), the knock-down made the two timed escape dashes count as "already
    -- protected" so NEITHER went out, and the ring landed 88 + 247 at 39 studs. So no timed
    -- dashes at all any more: walk out from the first frame (push), and from 1.25 s -- right
    -- after slam 1's jump -- dash away back to back (i-frames 1.25-2.0 span slam 2's 1.35-1.88),
    -- retrying refused presses, until you're clear or the ring has gone off.
                            thenEscape = { from = 1.25, till = 3.25, clear = 60, name = "The Bell ring" } },
    -- 2nd recorded fight: the slam's 47 dmg landed 1.34-1.60 s in (8 hits) -> 1.45
    -- double = always the double jump (user 2026-09-28: "a regular jump barely ever works for the
    -- festering wound")
    ["80778819711637"] = { impacts = { 1.45 }, range = 90, name = "Festering Wound jump slam", double = true },
    -- Smelter Demon two-stage = ONE anim, 130122482089218 (user, 2026-09-27: "the horizontal
    -- slice into the vertical" -- double jump the horizontal, then dash or weave). Horizontal:
    -- SlashSound 0.60-0.63 s, 36.75 dmg at 0.67-1.01 (median ~0.75); dashing it failed (hit at
    -- 0.73 / 1.00 right after Q). Vertical: 36.75 at 1.54 / 1.57, and weaves CAUGHT hits at
    -- 1.72 / 1.80 in earlier fights -> weaved (thenWeave).
    -- double = true (user 2026-09-28: "it doesnt double jump soon enough for the smelter demon"):
    -- the single jump went out 0.30 s before 0.74 = 0.44 s in, too late for the 0.67 hits; the
    -- double jump's first tap goes out right as the swing starts (lead 0.65)
    ["130122482089218"] = { impacts = { 0.74 }, thenWeave = { 1.56 }, range = 50, double = true,
                            name = "Smelter Demon horizontal slice" },
    -- Stormcaller lightning stomp (user, 2026-09-27: "we're meant to jump that"): 60-stud
    -- LightningStompHitbox, 40-43 dmg at 0.84-0.90 s (2 recorded hits) -- was weaved
    ["77025178675756"] = { impacts = { 0.87 }, range = 34, name = "Stormcaller lightning stomp" },
    -- The Crowned Nothing SMASH 112497450787518: Indicator + CreakSound as it starts, a 68-wide
    -- CrownedSmashEffect ring 1.36-1.44 s in; the killing hits (38.5 then 220) landed 1.11 /
    -- 1.24 s in -> jump for ~1.2 (Discord: "jump when he starts smashing").
    ["112497450787518"] = { impacts = { 1.2 }, range = 40, name = "Crowned Nothing smash" },
    -- Stone Husk SLAM DOWN 96618374539761 (user: "needs to be double jumped"): Indicator sound
    -- the moment it starts, leaps in from up to ~44 studs (read as a 45-56 stud/s "rush" ->
    -- stray weaves), lands 55 dmg at 1.25 s (2/2 hits, 8-16 studs).
    ["96618374539761"] = { impacts = { 1.25 }, range = 50, name = "Stone Husk slam down" },
    -- (81155999312581 was mapped here as the Smelter "horizontal swing" -- it is his CHAIN PULL,
    -- weaved before it attaches: see ATTACKS.)
}
-- DASH_ATTACKS: always dashed (never weaved), timed from the anim. (130122482089218 used to
-- be dashed here as the "vertical leap slam" -- it's the two-stage, see JUMP_ATTACKS.)
local DASH_ATTACKS = {
    -- The Bell, DodgeIndi = dash: swing 126421074291598 (DodgeSwing 1.03, 71.5 dmg at 1.17),
    -- kick 116385041102685 (Kick sound 0.61; no hit recorded -> ~0.68). Its grab 82316911117911
    -- (Windup at start, Grab 0.58-0.63, grabbed at 0.81, then a 77 slam at 1.53 you can't
    -- weave out of -- a weave pressed while held was refused) is dashed before it grabs.
    ["126421074291598"] = { impact = 1.15, range = 95, name = "The Bell swing" },   -- fight 2: 4 of 5 hits started 61-68 out (was 60 -> ignored)
    ["116385041102685"] = { impact = 0.76, range = 90, name = "The Bell kick" },   -- fight 2: Kick 0.63, 60.5 dmg at 0.76
    ["82316911117911"]  = { impact = 0.78, range = 90, name = "The Bell grab" },
    -- Cursed Hammer LEAP SLAM 136161739984425 = its unweavable (user 2026-09-27). The game says so:
    -- it opens with the "Indicator" sound (like the Husk slam / Crowned smash) where weavable
    -- specials play "WeaveIndi" (its spin dash 90831939847969: 5 weaves caught, 0 hits). "Go" at
    -- ~1.52 s, 46.2 dmg at 1.1-2.1 s (often two ~0.43 apart) and weaves didn't stop it -> dash,
    -- planned for 1.5 so the i-frames (~0.46 s) sit over the 1.2-1.7 bulk of the hits.
    ["136161739984425"] = { impact = 1.50, range = 35, name = "Cursed Hammer leap slam" },
    -- Smelter fire burst (80-stud cube, 55-57.75 dmg at ~1.6 s): dashed 13/13 while it was
    -- learned unweavable; once that learning reset it was treated as weavable -> CANT + 2 hits
    ["91349317972378"]  = { impact = 1.60, range = 45, name = "Smelter Demon fire burst" },
}
local extra = {}   -- user-added "id=seconds" pairs from the settings textbox

-- ---- learning new attacks ----------------------------------------------------------
-- There will always be mobs nobody has recorded yet (the Minotaur went through untouched).
-- So: when a mob close to you and facing you starts an attack animation that isn't in the
-- table, it's remembered for 1.5 s; if a real hit (>= 5 dmg) lands on you in that time,
-- the delay is a sample for that animation. Two samples within 0.15 s of each other and
-- it joins the table (saved, so it survives re-executes).
local learnedAttacks = {}     -- anim id -> seconds (persisted)
local attackSamples = {}      -- anim id -> { delays }
local attackPlays = {}        -- anim id -> times it started near you (learning needs a hit RATE)
-- never learn these: idle / float loops that happen to overlap hits (the Wraith's float
-- 110431028319368 played 236 times near the user and "hit" 3 -- once learned it caused 30+
-- whiffed weaves, each a ~1.4 s lockout)
-- 111237192632620 = the Festering Wound's rot pillar cast (its 10.5 ticks got "learned" as a
-- 0.17 s swing -> pointless weaves); the pillar is dodged by moving (pillarGuard) instead
-- 81155999312581 = Smelter Demon chain pull (user: unavoidable no matter what, keeps you from
-- running); its small ~10 dmg at 0.39 s would otherwise get it learned and weaved at
-- 96252443340298 = Cursed Hammer's 4 s Action anim (112 plays in one session): it got learned
-- as a 0.93 swing, but hits "after" it land anywhere from 0.05 to 1.24 s -> 15 weaves, 3 caught
local NEVER_LEARN = { ["110431028319368"] = true, ["111237192632620"] = true, ["81155999312581"] = true,
                      ["96252443340298"] = true }
local unknownSeen = {}        -- recent unknown attack anims: { id, t, root, label }
local persistRef = nil

local function saveLearned()
    if not persistRef then return end
    local parts = {}
    for id, sec in pairs(learnedAttacks) do parts[#parts + 1] = id .. "=" .. string.format("%.2f", sec) end
    pcall(persistRef.set, "veil.auto_weave.learned_attacks", table.concat(parts, ","))
end

local function sampleUnknown(tHit)
    local r = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
    if not r then return end
    local best, bestD
    for i = #unknownSeen, 1, -1 do
        local u = unknownSeen[i]
        local dt = tHit - u.t
        if dt > 1.5 then
            table.remove(unknownSeen, i)
        elseif dt >= 0.1 and u.root.Parent then
            local d = (u.root.Position - r.Position).Magnitude
            if not bestD or d < bestD then best, bestD = u, d end
        end
    end
    if not best or bestD > 15 or NEVER_LEARN[best.id] then return end
    local list = attackSamples[best.id] or {}
    attackSamples[best.id] = list
    list[#list + 1] = tHit - best.t
    -- at least 3 hits that agree, AND it hit on >= 30% of the times it played near you
    if #list >= 3 and #list / math.max(attackPlays[best.id] or 1, 1) >= 0.3 then
        table.sort(list)
        for i = 1, #list - 2 do
            if list[i + 2] - list[i] <= 0.15 then
                local sec = list[i + 1]
                learnedAttacks[best.id] = sec
                log.info(string.format("[Weave] learned attack %s (%s): hits %.2f s after it starts", best.id, best.label, sec))
                dlog("LEARN attack %s %s %.2f", best.id, best.label, sec)
                saveLearned()
                attackSamples[best.id] = nil
                break
            end
        end
    end
end

-- aimed ranged attacks timed from the shooting animation: hit lands `impact` s after it
-- starts, from any distance up to `range`, only when the shooter is aiming at you
local RANGED = {
    -- Cambion's shot: 9.2 dmg ~0.43 s after the anim starts at 19-62 studs alike (practically
    -- hitscan); fires in bursts ~0.52 s apart
    ["103401623213387"] = { impact = 0.43, range = 80, facing = 20 },
    -- (Cursed Hammer leap slam 136161739984425 is DASHED now: DASH_ATTACKS)
    -- The Crowned Nothing DASH 86888546045147 (fight 2026-09-27, events_0927_205224 ~t 4575-4598):
    -- starts with a "WeaveIndi" sound (the Discord's "weave his dashes, use the audio cue"),
    -- 44 dmg at 0.69 / 0.72 from 13-15 studs and 0.89 from 42 -> 0.6 s + 0.007 s per stud; he
    -- dashes in from up to ~60 studs. Aimed at you from anywhere, so no facing check.
    ["86888546045147"] = { impact = 0.60, perStud = 0.007, range = 65, facing = 180 },
    -- Angry Nimbus (recorded 2026-09-27, user: "wasn't ready for him in the slightest"): one
    -- attack, looped every ~0.8 s. Up close 21-22 dmg at 0.41-0.42 s (4 studs, 3 of 3); from
    -- ~24 studs the same anim drops a bolt (0.5-wide segments ~0.37 s, LightningStrike 11-cube
    -- on you 0.59 s) -> 20 dmg at 0.63 s. So: 0.37 s + 0.011 s per stud.
    ["129213508660940"] = { impact = 0.37, perStud = 0.011, range = 35, facing = 45 },
    -- NOT the Imp fireball cast: timing fireballs from the cast (0.26 s + distance / 59) was
    -- replayed against the recordings and never beat timing them from the fireball itself
    -- (78.1% vs 73-78%), because most casts target your summons and the extra weaves crowd
    -- out real dodges. Point-blank fireballs were being missed for an ownership reason instead.
}

-- Parts a mob carries INSIDE its own model that are attacks (everything else inside a
-- mob -- limbs, accessories -- is ignored). Loose parts a mob launches don't need a name.
local HOSTILE_PARTS = {
    Bladey = true, Blade = true, BlackSpikePart = true, Spike = true, GreenBeam = true, SentryLaser = true,
}
-- NOT used as triggers any more: explosion hitboxes (BombExplosionHitbox, ImpFireballExplosion,
-- GiantExplosionHitbox, LightningStrike, BlackFlash, SmashHitbox...) appear on the SAME frame
-- the damage lands (recorded lead -0.14..+0.05 s), so a weave started from them is always
-- late and only burns the cooldown before the next hit. Attacks are caught earlier instead:
-- the projectile in flight, the bomb fuse, the fireball timing, the melee animation.
-- ShatterStab / ShatterProjectile are the user's own Shatterpoint rapier (only an enemy
-- player's count, via the player rules).

-- Mob explosions. Their damage lands on the frame they appear, so the planner can't use
-- them -- but the user believes a weave pressed the moment one lands still dodges it
-- (untested: nobody ever weaved that late in the recordings). So they get a REFLEX weave:
-- only when nothing is planned and the weave is off cooldown, so it can never cost a
-- planned dodge. The recorder will show whether these reflex weaves actually dodge.
local REFLEX = {
    BombExplosionHitbox = true, ImpFireballExplosion = true, GiantExplosionHitbox = true,
    MourningWakeExplosionHitbox = true, LightningStrike = true, BlackFlash = true,
    SmashHitbox = true, DeathExplosionHitbox = true, HellfireBulletExplosionHitbox = true,
}

-- loose flying parts that are NOT attacks (bomb bits are handled by the fuse, Ichor is a pickup)
local PROJ_IGNORE = { Bomb = true, Circle = true, Plane = true, Ichor = true }

-- Projectiles that never visibly move on your client (the flight is drawn locally): timed
-- from spawn instead. ImpFireball, recorded: damage lands ~0.12 s + distance / 59 after it
-- appears (16 of 19 hits inside the weave window); beyond ~34 studs it lands where you WERE.
-- Cambion hellfire: an invisible 2.5-stud cube named "Main" (72 of 80 were followed by a
-- HellfireBulletExplosionHitbox; it lingers ~3 s after exploding). It HOMES and is slow, so
-- a flight-time guess (~0.49 s + distance / 68.4) lands anywhere from 0.3 s early to 0.55 s
-- late. Instead it is followed every frame and woven when it's about to reach you (user:
-- "just weave when they're like 2 studs from me"). The flight-time guess is only a fallback
-- for a fireball that never visibly moves on your client.
local HELLFIRE = { hold = 0.49, speed = 68.4, maxDist = 90, proximity = true }
local POINT_BLANK = 8        -- timed projectiles closer than this can't be tracked in time
local HELLFIRE_CONTACT = 2.5   -- fireball radius + your body: "reached you" at this distance
local HELLFIRE_CLOSE   = 2     -- weave when it's this many studs from contact (more if it's fast)

local GOLEM_LASER = { impact = 0.39, reach = 10, centre = 12 }

local TIMED_PROJ = {
    -- flight to the explosion: 0.076 s + distance / 54.4 (fit on 131 fireballs that landed on
    -- you). They HOME: 8 of 13 fired from 35-79 studs still landed on you.
    ImpFireball = { hold = 0.076, speed = 54.4, maxDist = 90 },
}

-- which timing rule (if any) a freshly spawned part follows
local function timedFor(part)
    local t = TIMED_PROJ[part.Name]
    if t then return t end
    if part.Name == "Main" then
        local sz = part.Size
        if math.abs(sz.X - 2.5) < 0.3 and math.abs(sz.Y - 2.5) < 0.3 and math.abs(sz.Z - 2.5) < 0.3 then
            return HELLFIRE
        end
    end
    return nil
end

-- yours or harmless: never weave for these
local IGNORE_PARTS = {
    BannerExplode = true, FlowerExplode = true, WhiteBurstSummonEffect = true, SummonEffect = true,
    SuperRunPart = true, VeilFollowerPart = true, PotionModel = true, Glade = true,
    Ichor = true,   -- the orb mobs drop that flies INTO you (pickup), not an attack
    WaxPuddle = true,   -- your Candlewick's Wax (T): a puddle ~0.4 s after every T press (Bell fight 2)
}

--------------------------------------------------------------------- state

local conns = {}
local mobConns = {}        -- model -> { connections }
local impacts = {}         -- hits we know are coming: { t, reason }
local preds = {}           -- model -> predicted time of that mob's NEXT hit (from its swing rhythm)
local done = {}            -- CONFIRMED weave start times (your LeftWeave / RightWeave anim played)
local attempt = nil        -- the weave being pressed right now: { plan, started, lastPress, deadline }
local animHooked = false   -- false = can't see your weave anim, so a press counts as a weave
local tracked = {}         -- part -> { first, pos, t, fired }
local weaves, running = 0, false

local function now() return os.clock() end

local function root()
    local c = LP.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function alive()
    local c = LP.Character
    local h = c and c:FindFirstChildOfClass("Humanoid")
    return h ~= nil and h.Health > 0
end

local function pingExtra()
    local ok, p = pcall(function() return LP:GetNetworkPing() end)
    if not ok or type(p) ~= "number" then return 0 end
    return math.clamp(p - CFG.basePing, 0, 0.3)
end

local function leadNow() return CFG.lead + pingExtra() end

local function isSummon(model)
    if tonumber(model.Name) then return true end
    if model:FindFirstChild("PlayerID") then return true end
    return model:FindFirstChild("SummonNameGui", true) ~= nil
end

local classify   -- friend/foe for models (defined with the ownership rules below)

--------------------------------------------------------------------- pressing

-- The game refuses a weave while you're busy (your "Doing" flag: mid-M1, mid-ability, in
-- hitstun) and the cooldown sometimes runs a little past 0.5 s. Recorded: 108 of 438 presses
-- did nothing, mostly with Doing = true. So a planned weave is PRESSED REPEATEDLY until your
-- weave animation actually plays, or until it could no longer cover the hit.
-- Hitstun is real too: after a big hit 0 of 12 presses worked for 0.3 s, about half until
-- ~0.6 s. Retrying covers that as well -- the weave goes out the moment the stun lifts, if
-- that is still in time; a hit landing inside the stun simply can't be dodged.
local RETRY = 0.06

local function sendKey()
    pcall(function() VIM:SendKeyEvent(true, CFG.key, false, game) end)
    task.delay(0.03, function() pcall(function() VIM:SendKeyEvent(false, CFG.key, false, game) end) end)
end

-- A weave that CATCHES an attack can be followed by another 0.5 s later. A weave that
-- WHIFFS locks weaving out for ~1.4 s (recorded: after a whiff almost every press between
-- 0.5 and 1.3 s was refused; after a catch they went through from 0.5 s). The server
-- confirms a catch with WeaveBuffEvent (your new stack count > 0), so after each weave the
-- planner knows which cooldown applies. Whiffs are expensive -- don't weave at maybes.
local WHIFF_LOCK = 1.45
local lastCatch = -math.huge

-- The game's own weave timer (user: track it): the character attribute WeaveCdUntil (server
-- time). Recorded: ~0.1 s after a press it's set to the weave's end (~0.49 s after the
-- press); on a whiff the "Weave" cooldown (AbilityCooldownEvent, 1 s) fires ~0.41 s in and
-- pushes it to ~1.4 s after the press. When it's there it replaces the guessed lockout.
local function weaveCdAttr()
    local c = LP.Character
    local v = c and c:GetAttribute("WeaveCdUntil")
    if type(v) ~= "number" then return nil end
    local ok, sn = pcall(function() return Workspace:GetServerTimeNow() end)
    if not ok then return nil end
    return now() + (v - sn)
end

local function weaveReadyAt(t)
    local last = done[#done]
    local attr = weaveCdAttr()
    if not last then return attr or -math.huge end
    local est
    if lastCatch >= last - 0.05 then est = last + CFG.cooldown         -- caught: short cooldown
    elseif t < last + 0.55 then est = last + CFG.cooldown             -- verdict still pending
    else est = last + WHIFF_LOCK end                                   -- whiffed: locked out
    -- the game's timer is exact once it has caught up with this weave (it's set ~0.1 s after)
    if attr and t > last + 0.15 then return math.max(attr, last + CFG.cooldown) end
    return math.max(est, attr or -math.huge)
end

local watchCovered   -- set below: registers the hits a confirmed weave is expected to cover

local function confirmWeave(t)
    done[#done + 1] = t
    if #done > 8 then table.remove(done, 1) end
    if watchCovered then watchCovered(t) end
    dlog("WEAVE %s", attempt and attempt.reason or "(manual)")
    if attempt then
        weaves += 1
        if CFG.verbose then
            log.info(string.format("[Weave] #%d %s (%.0f ms after first press)", weaves, attempt.reason,
                (t - attempt.started) * 1000))
        end
        attempt = nil
    end
end

-- ---- dash (Q) ------------------------------------------------------------------
-- Recorded (sessions 6-8, 416 dashes): a dash sets your DodgeUntil attribute ~0.44 s ahead
-- (only 1 of 175 big hits landed while it was up), costs 50 stamina (regen ~13/s, max
-- ~150) and can be used again ~0.43 s later. Direction = the movement key held with it
-- (hold A + Q = dash left). Weaves are free, so dashes are the BACKUP: they cover hits a
-- weave can't (weave on cooldown, hits bunched too tightly), with a longer window.
-- DASH.hits = times you took a real hit (for CFG.tankHits); a field, not a local: this
-- chunk is at Luau's 200-local limit
-- DASH.orbs = live gas balls (RotOrb) for the push-away (pillarStep); same reason
-- DASH.escapes = live "get out of reach" zones ({ root, till, id, clear }); DASH.reach = learned
-- reach per channel anim (persisted veil.auto_weave.escape_reach)
-- DASH.orbReach = how far (ground distance) a gas ball reaches you, learned from its hits
-- DASH.rushVel = per-mob closing speed + its smoothed change (braking), for stepRushes
-- DASH.orbDashAt = ground distance at which a gas ball gets jumped + dashed into (orbDashedAt = last)
local DASH = { hits = {}, orbs = {}, orbReach = 12, orbDashAt = 14, orbDashedAt = nil, rushVel = setmetatable({}, { __mode = "k" }), escapes = {}, reach = {}, from = 0.05, to = 0.40, lead = 0.20, cost = 50, cooldown = 0.45, afterWeave = 0.25 }
local dashes = {}          -- confirmed dash start times

-- ---- boss first ----------------------------------------------------------------
-- (user 2026-09-30: "i seem to get worse at dodging whenever i have summons around and other
-- enemies so our priority whenever were actively fighting a boss is the bosses attacks. now
-- just coz there is a boss doesnt always mean im fighting that boss".) The logs agree: in boss
-- fights ~120 hits landed right after a weave went to a small mob, 25 of them boss hits the
-- weave was then on cooldown for (a whiffed weave locks it out ~1.4 s).
-- "Fighting" = the boss started an attack that can reach you in the last 8 s; standing back
-- and watching never sets it. While it's set, a lesser mob's hit gives way to the boss's
-- (see plan() and tryDash()). Fields of DASH, not locals: this chunk is at the 200-local limit.
-- DASH.owner = the mob whose attack animation is being read right now (stamped on its hits)
DASH.bossNames = { ["Hiveling Titan"] = true, ["Smelter Demon"] = true, ["Goblin Warlock"] = true,
                   ["Festering Wound"] = true }
DASH.boss = { model = nil, till = 0 }
function DASH.isBoss(model)
    if not model or isSummon(model) then return false end
    return DASH.bossNames[model.Name] == true or string.sub(model.Name, 1, 4) == "The "
end
function DASH.fighting(t)
    local b = DASH.boss.model
    if not b or t > DASH.boss.till or not b.Parent then return nil end
    return b
end
-- hit h comes from this mob; a boss's hit means you're fighting it
function DASH.own(h, model)
    h.owner = model
    if not DASH.isBoss(model) then return end
    local t = now()
    if DASH.fighting(t) ~= model then dlog("BOSSFIGHT %s", model.Name) end
    DASH.boss.model, DASH.boss.till = model, t + 8
end
local lastInject = -math.huge

-- The game keeps Stamina in a sub-folder of your character; the old direct-child lookup
-- read 0 every time, so NO dash ever went out (session 0925_215838: zero dashes logged).
local staminaValue = nil
local function stamina()
    local c = LP.Character
    if not c then return 0 end
    if not (staminaValue and staminaValue.Parent and staminaValue:IsDescendantOf(c)) then
        staminaValue = nil
        for _, d in ipairs(c:GetDescendants()) do
            if d.Name == "Stamina" and d:IsA("ValueBase") then staminaValue = d; break end
        end
        if not staminaValue then
            local plr = LP:FindFirstChild("Stamina", true)
            if plr and plr:IsA("ValueBase") then staminaValue = plr end
        end
    end
    return staminaValue and (tonumber(staminaValue.Value) or 0) or 0
end

-- The game marks your own protection with server-time attributes on your character:
-- DodgeUntil (dash) and ImmuneUntil (~0.66 s after you get knocked down). A hit landing
-- before those run out needs nothing -- no point burning a weave on it.
local function protectedAt(i)
    local c = LP.Character
    if not c then return false end
    local ok, serverNow = pcall(function() return Workspace:GetServerTimeNow() end)
    if not ok then return false end
    local si = serverNow + (i - now())
    for _, a in ipairs({ "ImmuneUntil", "DodgeUntil" }) do
        local v = c:GetAttribute(a)
        if type(v) == "number" and v >= si + 0.02 then return true end
    end
    return false
end

local MOVE_KEYS = { Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D }

-- Dash direction (user): Q alone dashes straight forward; W/A/S/D + Q dashes that way,
-- camera-relative. If you're already holding a movement key, the dash goes where you're
-- going. Otherwise the camera-relative key pointing away from the attack (or sideways to
-- it, or toward it for gas balls you dash THROUGH) is held for the press.
local function dashKeyFor(threat, mode)
    -- an attack that asks for a specific direction (get-away moves) overrides the keys you're
    -- holding (Auto Sprint keeps W held -> every escape dash went FORWARD into the boss);
    -- otherwise a held movement key wins
    if not mode then
        for _, k in ipairs(MOVE_KEYS) do
            if UIS:IsKeyDown(k) then return nil end
        end
    end
    mode = mode or CFG.dashDir
    if mode == "Where you're moving only" then return nil end
    local r = root()
    local cam = Workspace.CurrentCamera
    if not (r and cam) then return Enum.KeyCode.S end
    local away = threat and Vector3.new(r.Position.X - threat.X, 0, r.Position.Z - threat.Z) or Vector3.zero
    if away.Magnitude < 0.5 then
        local lv = cam.CFrame.LookVector
        away = -Vector3.new(lv.X, 0, lv.Z)
    end
    if mode == "Sideways" then away = Vector3.new(-away.Z, 0, away.X) end
    if mode == "Toward the attack" then away = -away end
    local f = Vector3.new(cam.CFrame.LookVector.X, 0, cam.CFrame.LookVector.Z)
    local rt = Vector3.new(cam.CFrame.RightVector.X, 0, cam.CFrame.RightVector.Z)
    local df, dr = away:Dot(f.Unit), away:Dot(rt.Unit)
    if math.abs(df) >= math.abs(dr) then
        return df > 0 and Enum.KeyCode.W or Enum.KeyCode.S
    end
    return dr > 0 and Enum.KeyCode.D or Enum.KeyCode.A
end

-- Escape dashes (a direction was asked for): like Rotation Lock -- turn the CHARACTER (yaw
-- only, camera untouched) to face the escape direction, block every W/A/S/D input (your
-- real keys and Auto Sprint's held W) so nothing steers it, and press plain Q (Q alone
-- dashes straight forward). Your held keys are pressed again afterwards.
local CAS_D = game:GetService("ContextActionService")
local MOVE_GUARD = "PantheonDashMoveGuard"
local MOVE_INPUTS = { Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D,
                      Enum.KeyCode.Up, Enum.KeyCode.Down, Enum.KeyCode.Left, Enum.KeyCode.Right }
local RS_D = game:GetService("RunService")
local aimOk, aimState = pcall(require, "modules.aim.state")
if not aimOk then aimState = {} end

local function escapeVector(threat, mode)
    local r = root()
    if not r then return nil end
    local away = threat and Vector3.new(r.Position.X - threat.X, 0, r.Position.Z - threat.Z) or Vector3.zero
    if away.Magnitude < 0.5 then
        local lv = r.CFrame.LookVector
        away = -Vector3.new(lv.X, 0, lv.Z)
    end
    away = away.Unit
    if mode == "Sideways" then away = Vector3.new(-away.Z, 0, away.X) end
    if mode == "Toward the attack" then away = -away end
    return away
end

-- Walls (user: it double dashed me right into a wall): sweep the dash path at waist and chest
-- height and turn toward the nearest direction that's actually open -- straight away first,
-- then 30/60/90/120 degrees either side; if nothing is fully open, the roomiest one.
local DASH_REACH = 24
local function clearance(from, dir)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { LP.Character }
    params.RespectCanCollide = true
    local best = DASH_REACH
    for _, h in ipairs({ -1, 1.2 }) do
        local o = from + Vector3.new(0, h, 0)
        local hit = Workspace:Raycast(o, dir * DASH_REACH, params)
        if hit then best = math.min(best, hit.Distance) end
    end
    return best
end

local function openDirection(dir)
    local r = root()
    if not r then return dir end
    local pick, room = dir, -1
    for _, deg in ipairs({ 0, 30, -30, 60, -60, 90, -90, 120, -120 }) do
        local d = (CFrame.Angles(0, math.rad(deg), 0) * CFrame.new(Vector3.zero, dir)).LookVector
        d = Vector3.new(d.X, 0, d.Z).Unit
        local c = clearance(r.Position, d)
        if c >= DASH_REACH - 0.5 then return d end
        if c > room then pick, room = d, c end
    end
    return pick
end

-- One shared "dash facing" session: a second dash inside the first (double dash) extends it
-- instead of starting its own -- before, the second dash saved AutoRotate while the first
-- had it switched off and "restored" it to off, so rotation never came back (user).
local dashFace = { active = false, untilT = 0, autoRotate = true, hum = nil, dir = nil, held = {} }

-- "Around the enemy" (user 2026-10-01: "sideways around the enemy basically utilizing rotation
-- lock to keep me facing the opponent during the dash"): the body is held facing the attacker
-- (yaw only, like Rotation Lock, camera untouched) while the dash goes along the circle around
-- it. W/A/S/D + Q dashes that way camera-relative, so the movement key nearest that direction
-- is held for the dash and every other movement input is blocked (your keys, Auto Sprint's W).
-- Side = the one with more room; about even -> the way you're already drifting, else right.
-- Returns false when it can't (no camera, standing on the attacker, an escape dash is turning
-- you): the caller falls back to a plain dash.
-- The facing is done by Rotation Lock itself (user 2026-10-01: "the dash around thing isnt
-- using rotation lock on the enemy in question" -- the first version only wrote the CFrame once
-- a frame at render time and the dash turned you anyway): aimState.strafeFace hands it the
-- attacker's root part (face; else the point the attack came from) for the dash, so it holds
-- the body with its rigid AlignOrientation + per-physics-step writes, and follows the enemy.
function DASH.strafe(threat, face)
    local function press()
        task.wait(0.03)                                  -- let the key + turn land first
        pcall(function() VIM:SendKeyEvent(true, CFG.dashKey, false, game) end)
        task.wait(0.08)
        pcall(function() VIM:SendKeyEvent(false, CFG.dashKey, false, game) end)
    end
    if DASH.strafing and now() < DASH.strafeUntil then   -- a retry press: same session
        DASH.strafeUntil = now() + 0.4
        DASH.strafeFaceEnd = math.max(DASH.strafeFaceEnd or 0, now() + 0.4)
        pcall(function() aimState.strafeFaceUntil = os.clock() + 0.4 end)
        task.spawn(press)
        return true
    end
    if dashFace.active then return false end
    local r, cam = root(), Workspace.CurrentCamera
    local c = LP.Character
    local hum = c and c:FindFirstChildOfClass("Humanoid")
    if not (r and cam and hum) then return false end
    local to = Vector3.new(threat.X - r.Position.X, 0, threat.Z - r.Position.Z)
    if to.Magnitude < 0.5 then return false end
    to = to.Unit
    local right = Vector3.new(-to.Z, 0, to.X)
    local roomR, roomL = clearance(r.Position, right), clearance(r.Position, -right)
    local vel = r.AssemblyLinearVelocity
    local side = right
    if math.abs(roomR - roomL) > 2 then
        side = roomR > roomL and right or -right
    elseif Vector3.new(vel.X, 0, vel.Z):Dot(right) < -1 then
        side = -right
    end
    local f = Vector3.new(cam.CFrame.LookVector.X, 0, cam.CFrame.LookVector.Z)
    local rt = Vector3.new(cam.CFrame.RightVector.X, 0, cam.CFrame.RightVector.Z)
    if f.Magnitude < 0.01 or rt.Magnitude < 0.01 then return false end
    local df, dr = side:Dot(f.Unit), side:Dot(rt.Unit)
    local key
    if math.abs(df) >= math.abs(dr) then key = df > 0 and Enum.KeyCode.W or Enum.KeyCode.S
    else key = dr > 0 and Enum.KeyCode.D or Enum.KeyCode.A end

    -- (a new dash can start while the last one's facing is still held: the newest session owns
    -- the teardown)
    local session = (DASH.strafeSession or 0) + 1
    DASH.strafeSession = session
    DASH.strafing, DASH.strafeUntil = true, now() + 0.4
    -- the lock lasts the WHOLE dash (user: "it needs to be rotation locked onto the opponent for
    -- the entire dash duration"): 0.4 s to begin with, then stretched to the dash's real end
    -- when the game confirms it (DodgeUntil, see Weave.start) -- the user's dash runs ~0.7 s,
    -- so the old fixed 0.4 s let go halfway through. The movement key is only held for 0.4 s.
    DASH.strafeFaceEnd = math.max(DASH.strafeFaceEnd or 0, now() + 0.4)
    pcall(function()
        aimState.strafeFace = (face and face.Parent) and face or threat
        aimState.strafeFaceUntil = os.clock() + 0.4
        aimState.dashBodyUntil = os.clock() + 0.4        -- shiftlock yields (Rotation Lock checks strafeFace first)
    end)
    local held, keyWasDown = {}, UIS:IsKeyDown(key)
    local blocked = {}
    for _, k in ipairs(MOVE_INPUTS) do if k ~= key then blocked[#blocked + 1] = k end end
    for _, k in ipairs(MOVE_KEYS) do if k ~= key and UIS:IsKeyDown(k) then held[#held + 1] = k end end
    pcall(function()
        CAS_D:BindActionAtPriority(MOVE_GUARD .. "Strafe", function() return Enum.ContextActionResult.Sink end, false,
            Enum.ContextActionPriority.High.Value + 1000, table.unpack(blocked))
    end)
    if not keyWasDown then pcall(function() VIM:SendKeyEvent(true, key, false, game) end) end
    hum.AutoRotate = false
    local bind = "PantheonDashStrafe"
    pcall(function() RS_D:UnbindFromRenderStep(bind) end)
    RS_D:BindToRenderStep(bind, Enum.RenderPriority.Last.Value, function()
        local rr = root()
        if not rr or dashFace.active or now() > DASH.strafeFaceEnd then return end
        local fp = (face and face.Parent) and face.Position or threat
        local at = Vector3.new(fp.X, rr.Position.Y, fp.Z)
        if (at - rr.Position).Magnitude > 0.5 then pcall(function() rr.CFrame = CFrame.lookAt(rr.Position, at) end) end
    end)
    task.spawn(press)
    task.spawn(function()
        while now() < DASH.strafeUntil do task.wait(math.max(0.01, DASH.strafeUntil - now())) end
        -- movement back to you...
        if not keyWasDown then pcall(function() VIM:SendKeyEvent(false, key, false, game) end) end
        pcall(function() CAS_D:UnbindAction(MOVE_GUARD .. "Strafe") end)
        for _, k in ipairs(held) do
            if UIS:IsKeyDown(k) then pcall(function() VIM:SendKeyEvent(true, k, false, game) end) end
        end
        -- ...the facing only once the dash itself is over
        while now() < DASH.strafeFaceEnd do task.wait(math.max(0.01, DASH.strafeFaceEnd - now())) end
        if DASH.strafeSession ~= session then return end
        pcall(function() RS_D:UnbindFromRenderStep(bind) end)
        if not dashFace.active then pcall(function() hum.AutoRotate = true end) end
        DASH.strafing = false
    end)
    dlog("STRAFE %s around the attacker (room right %.0f, left %.0f)", key.Name, roomR, roomL)
    return true
end

local function sendDash(threat, mode, face)
    lastInject = now()
    if not mode and CFG.dashDir == "Around the enemy" and threat and DASH.strafe(threat, face) then return end
    -- "setting" = a timed boss attack that's dodged by the dash itself (Smelter fire burst, the
    -- Bell's swing / kick / grab): it goes where your Dash direction setting says (user
    -- 2026-10-01: "the only attacks we should be dashing away from automatically is tantrums").
    -- Tantrums / get-away moves pass "Away from the attack" and ignore the setting.
    if mode == "setting" then
        mode = CFG.dashDir
        if mode == "Around the enemy" then
            if threat and DASH.strafe(threat, face) then return end
            mode = "Away from the attack"                -- couldn't strafe: away is the safe fallback
        end
    end
    local r = root()
    local c = LP.Character
    local hum = c and c:FindFirstChildOfClass("Humanoid")
    local dirVec = (mode and mode ~= "Where you're moving only") and escapeVector(threat, mode) or nil
    if dirVec then dirVec = openDirection(dirVec) end
    if not (dirVec and r and hum) then
        -- no direction asked for: plain Q, your held key (if any) steers it
        pcall(function() VIM:SendKeyEvent(true, CFG.dashKey, false, game) end)
        task.delay(0.08, function() pcall(function() VIM:SendKeyEvent(false, CFG.dashKey, false, game) end) end)
        return
    end
    dashFace.dir = dirVec
    dashFace.untilT = now() + 0.35
    pcall(function() aimState.dashBodyUntil = os.clock() + 0.35 end)   -- lock-on rotation yields, then resumes
    local function press()
        task.wait(0.03)                                  -- let the turn land first
        pcall(function() VIM:SendKeyEvent(true, CFG.dashKey, false, game) end)
        task.wait(0.08)
        pcall(function() VIM:SendKeyEvent(false, CFG.dashKey, false, game) end)
    end
    if dashFace.active then                              -- already facing for a dash: extend
        task.spawn(press)
        return
    end
    dashFace.active, dashFace.hum, dashFace.autoRotate = true, hum, hum.AutoRotate
    -- remember which movement keys were down, then block all movement input
    table.clear(dashFace.held)
    for _, k in ipairs(MOVE_KEYS) do if UIS:IsKeyDown(k) then dashFace.held[#dashFace.held + 1] = k end end
    pcall(function()
        CAS_D:BindActionAtPriority(MOVE_GUARD, function() return Enum.ContextActionResult.Sink end, false,
            Enum.ContextActionPriority.High.Value + 1000, table.unpack(MOVE_INPUTS))
    end)
    -- face the escape direction (yaw only) every frame for the dash, camera untouched
    hum.AutoRotate = false
    local bind = "PantheonDashFace"
    pcall(function() RS_D:UnbindFromRenderStep(bind) end)
    RS_D:BindToRenderStep(bind, Enum.RenderPriority.Last.Value, function()
        local rr = root()
        if not rr or now() > dashFace.untilT or not dashFace.dir then return end
        pcall(function() rr.CFrame = CFrame.lookAt(rr.Position, rr.Position + dashFace.dir) end)
    end)
    task.spawn(press)
    task.spawn(function()
        while now() < dashFace.untilT do task.wait(math.max(0.01, dashFace.untilT - now())) end
        pcall(function() RS_D:UnbindFromRenderStep(bind) end)
        pcall(function() CAS_D:UnbindAction(MOVE_GUARD) end)
        -- hand rotation back: AutoRotate on; Rotation Lock / Shift Lock re-take it next frame if
        -- they're engaged (restoring the saved value could leave it off after they let go)
        pcall(function() dashFace.hum.AutoRotate = true end)
        dashFace.active = false
        -- your keys were swallowed while blocked: press the ones still held again
        for _, k in ipairs(dashFace.held) do
            if UIS:IsKeyDown(k) then pcall(function() VIM:SendKeyEvent(true, k, false, game) end) end
        end
    end)
end

-- ---- double jump (Space, Space) ------------------------------------------------------
-- Third tier (user): weave -> dash for unweavables -> DOUBLE JUMP for undashables, e.g. the
-- Festering Wound's slam-downs: be in the air when it lands. Airborne coverage assumed
-- ~0.15-0.85 s after the first tap (to be tuned from recordings).
-- lead 0.5 (user: jumps went out a little late); the second tap waits until you're actually
-- airborne (user: a fixed 0.14 s gap only produced a single jump)
local JUMP = { lead = 0.65, gap = 0.14, from = 0.15, to = 1.1, cooldown = 1.0,   -- lead 0.5 -> 0.65 (user: a little earlier)
               -- SINGLE jump (user 2026-09-27: "the slams need to be jumped, a double jump doesn't have
               -- a short enough cooldown"): JumpPower 50 at gravity 196 = ~0.5 s airborne, apex at
               -- ~0.25 s -> tap 0.3 s before impact, covered ~0.08-0.5 s after the tap, and it can
               -- go again once you've landed
               single = {}, singleLead = 0.30, singleFrom = 0.08, singleTo = 0.50, singleCooldown = 0.55 }
local jumps = {}

-- double jump, the pattern the user verified in-game: Space, wait until actually airborne
-- (Freefall / FloorMaterial Air, up to 0.5 s), a 0.12 s beat, Space again
-- your M1s during the jump made the double jump go silent (user): swallow left clicks from
-- the first tap until the second tap is out (you're airborne), then give them back
local CAS = game:GetService("ContextActionService")
local M1_GUARD = "PantheonJumpM1Guard"
-- (user 2026-10-01: "we need more m1 eating because our jump often times just doesnt fire at
-- the right time or isnt a double jump".) What was wrong with the old on/off guard:
--   * a HELD left button kept swinging straight through it (only new clicks were blocked), and
--     the block also ate the button's RELEASE, so the game went on thinking it was held;
--   * each guard had its own 1.6 s "off" timer, so an earlier jump's timer switched the block
--     off in the middle of the next jump.
-- Now: one shared deadline (guardM1(seconds) extends it, guardM1(false) ends it), the held
-- button is let go for the game before the block goes up, and releases always pass through.
local function guardM1(secs)
    if not secs then DASH.m1Until = 0; return end
    DASH.m1Until = math.max(DASH.m1Until or 0, now() + secs)
    if DASH.m1On then return end
    DASH.m1On = true
    if UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
        local p = UIS:GetMouseLocation()
        pcall(function() VIM:SendMouseButtonEvent(p.X, p.Y, 0, false, game, 0) end)
    end
    pcall(function()
        CAS:BindActionAtPriority(M1_GUARD, function(_, state)
            if state == Enum.UserInputState.Begin then return Enum.ContextActionResult.Sink end
            return Enum.ContextActionResult.Pass
        end, false, Enum.ContextActionPriority.High.Value + 1000, Enum.UserInputType.MouseButton1)
    end)
    task.spawn(function()
        while now() < (DASH.m1Until or 0) do task.wait(0.03) end
        pcall(function() CAS:UnbindAction(M1_GUARD) end)
        DASH.m1On = false
    end)
end

-- a swing sets JumpPower 0 and the Doing flag while it plays; a Space press then does
-- nothing (user-verified test): wait until jumping is allowed again before each tap
local function canJump(hum)
    local c = LP.Character
    local doingV = nil
    if c then
        for _, d in ipairs(c:GetDescendants()) do
            if d.Name == "Doing" and d:IsA("ValueBase") then doingV = d; break end
        end
    end
    local jp = hum.UseJumpPower and hum.JumpPower or hum.JumpHeight
    return jp > 0 and not (doingV and doingV.Value == true)
end

local function waitCanJump(hum, limit)
    local t = now()
    while hum and now() - t < limit do
        if canJump(hum) then return end
        task.wait()
    end
end

-- The game's double jump has a cooldown (AbilityCooldownEvent "Double Jump", duration 2 s,
-- tracked in Weave.start). While it's cooling down only a regular jump goes out -- the user
-- found a well-timed plain jump still partly dodges the slam.
local djUntil = -math.huge
local function doubleJumpReady(at) return (at or now()) >= djUntil end

-- Cancel your M1 (user: "just cancel my m1's"): a swing sets JumpPower 0 for ~0.3 s, and
-- blocking clicks can't undo a swing already going. Your character's physics are yours, so
-- stop the swing animation and give the body a normal jump's lift (JumpPower 50 -> 50
-- stud/s up) directly. JumpPower itself is left alone (the game watches it: JumpPowerDirty).
local function cancelSwingAndLift(hum)
    local c = LP.Character
    local r = c and c:FindFirstChild("HumanoidRootPart")
    if not (r and hum) then return false end
    local animator = hum:FindFirstChildOfClass("Animator")
    if animator then
        for _, tr in ipairs(animator:GetPlayingAnimationTracks()) do
            local pr = tr.Priority
            if pr == Enum.AnimationPriority.Action or pr == Enum.AnimationPriority.Action2
               or pr == Enum.AnimationPriority.Action3 or pr == Enum.AnimationPriority.Action4 then
                local n = tr.Animation and tr.Animation.Name or ""
                if not string.find(n, "Weave") then pcall(function() tr:Stop(0.05) end) end
            end
        end
    end
    local base = c:GetAttribute("BaseJumpPower")
    local v = r.AssemblyLinearVelocity
    pcall(function() r.AssemblyLinearVelocity = Vector3.new(v.X, tonumber(base) or 50, v.Z) end)
    pcall(function() hum:ChangeState(Enum.HumanoidStateType.Freefall) end)
    return true
end

local function sendDoubleJump(timeLeft, wantDouble)
    lastInject = now()
    local single = not (wantDouble or CFG.jumpStyle == "Double jump") or not doubleJumpReady()
    if single and CFG.jumpStyle == "Double jump" then dlog("JUMP single (double jump cooling down %.2f s)", djUntil - now()) end
    local sp = Enum.KeyCode.Space
    guardM1(1.6)                                      -- at most: never leave clicks blocked
    task.spawn(function()
        local c = LP.Character
        local hum = c and c:FindFirstChildOfClass("Humanoid")
        local function tap()
            pcall(function() VIM:SendKeyEvent(true, sp, false, game) end)
            task.wait(0.05)
            pcall(function() VIM:SendKeyEvent(false, sp, false, game) end)
        end
        local t0 = now()
        -- mid-swing: wait the lock out if there's time for it...
        if hum and not canJump(hum) and (timeLeft or 1) >= 0.55 then waitCanJump(hum, 0.25) end
        if hum and not canJump(hum) then
            -- ...and if the swing still locks jumping, cancel it (before, the tap went out
            -- anyway after the wait and did nothing: the jump that "just doesn't fire")
            dlog("M1CANCEL swing locked jumping -> cancelled + lifted (hit in %.2f)", timeLeft or -1)
            cancelSwingAndLift(hum)
        else
            t0 = now()
            tap()
        end
        while hum and now() - t0 < 0.5 do
            if hum:GetState() == Enum.HumanoidStateType.Freefall or hum.FloorMaterial == Enum.Material.Air then break end
            task.wait()
        end
        if single then guardM1(false); return end
        task.wait(0.12)
        waitCanJump(hum, 0.3)
        if hum and not canJump(hum) then
            -- a swing got in between the taps: stop it, or the second tap is silent (single jump)
            dlog("M1CANCEL swing locked the 2nd jump -> cancelled")
            local animator = hum:FindFirstChildOfClass("Animator")
            for _, tr in ipairs(animator and animator:GetPlayingAnimationTracks() or {}) do
                local pr = tr.Priority
                local n = tr.Animation and tr.Animation.Name or ""
                if (pr == Enum.AnimationPriority.Action or pr == Enum.AnimationPriority.Action2
                    or pr == Enum.AnimationPriority.Action3 or pr == Enum.AnimationPriority.Action4)
                   and not string.find(n, "Weave") then pcall(function() tr:Stop(0.05) end) end
            end
            waitCanJump(hum, 0.1)
        end
        tap()
        guardM1(false)                                -- airborne: your M1s are back
    end)
end

local function jumpCovers(p, h)
    local d = h.t - p
    if JUMP.single[p] then return d >= JUMP.singleFrom and d <= JUMP.singleTo end
    return d >= JUMP.from and d <= JUMP.to
end

-- ---- Enchanted Sword mobility (optional) ---------------------------------------------
-- The user's Enchanted Sword is an Elite "cast weapon" Tool (IsCastWeapon, its own
-- _ConsumableActivator script) that launches you forward for ~0 stamina; left click uses
-- it. It has NO i-frames (user), so it never stands in for a dash -- it's only for GET-AWAY
-- moves (e.g. the Festering Wound's rapid ground punches), where distance is what saves you.
-- Not everyone owns one, so it's an optional toggle.
local SWORD_NAME = "Enchanted Sword"
local SWORD_COOLDOWN = 3.0     -- guess until the logs show its real cooldown
local lastSword = -math.huge
local swording = false

local function findSword()
    local bp = LP:FindFirstChildOfClass("Backpack")
    local c = LP.Character
    return (c and c:FindFirstChild(SWORD_NAME)) or (bp and bp:FindFirstChild(SWORD_NAME))
end

-- The sword launches you straight FORWARD, so for a get-away the camera and your character
-- are turned to face directly away from the threat for a moment (RenderStep after the
-- camera scripts -- the same trick as Pantheon's lock-on), the sword fires, and control is
-- handed back (your camera / lock-on resume from where they were).
local RunServiceRS = game:GetService("RunService")
local function faceAwayFor(from, seconds)
    local r = root()
    if not (from and r) then return end
    local d = Vector3.new(r.Position.X - from.X, 0, r.Position.Z - from.Z)
    if d.Magnitude < 0.1 then return end
    d = d.Unit
    local name = "PantheonWeaveFaceAway"
    local untilT = now() + seconds
    pcall(function() RunServiceRS:UnbindFromRenderStep(name) end)
    RunServiceRS:BindToRenderStep(name, Enum.RenderPriority.Camera.Value + 2, function()
        local rr = root()
        local cam = Workspace.CurrentCamera
        if now() > untilT or not rr then
            pcall(function() RunServiceRS:UnbindFromRenderStep(name) end)
            return
        end
        pcall(function()
            rr.CFrame = CFrame.lookAt(rr.Position, rr.Position + d)
            if cam then
                local eye = rr.Position - d * 12 + Vector3.new(0, 5, 0)
                cam.CFrame = CFrame.lookAt(eye, rr.Position + d * 30)
            end
        end)
    end)
end

local function useSword(reason, awayFrom)
    if not CFG.swordMobility or swording or now() - lastSword < SWORD_COOLDOWN then return false end
    local sword = findSword()
    local c = LP.Character
    local hum = c and c:FindFirstChildOfClass("Humanoid")
    if not (sword and sword:IsA("Tool") and hum) then return false end
    swording = true
    lastSword = now()
    local held = c:FindFirstChildOfClass("Tool")
    if awayFrom then faceAwayFor(awayFrom, 0.3) end
    task.spawn(function()
        pcall(function()
            if held ~= sword then hum:EquipTool(sword) end
            task.wait(0.06)                       -- let the turn land before firing
            sword:Activate()                      -- = left click
            task.wait(0.2)
            if held and held ~= sword and held.Parent then
                hum:EquipTool(held)               -- back to what you had
            elseif not held then
                hum:UnequipTools()
            end
        end)
        swording = false
    end)
    dlog("SWORD %s", reason)
    return true
end

local function confirmDash(t)
    dashes[#dashes + 1] = t
    if #dashes > 8 then table.remove(dashes, 1) end
    if attempt and attempt.dash then
        weaves += 1
        if CFG.verbose then log.info(string.format("[Weave] #%d DASH %s", weaves, attempt.reason)) end
        dlog("DASH %s dir=%s", attempt.reason, tostring((attempt.dashDir ~= "setting" and attempt.dashDir) or CFG.dashDir))
        attempt = nil
    end
end

local function dashCovers(p, h)
    local pe = pingExtra()
    local d = h.t - p
    return d >= DASH.from + pe and d <= DASH.to + pe
end

-- ---- weave windows ----------------------------------------------------------
-- WHEN a weave has to start depends on how the hit arrives. Measured over every recorded
-- weave (sessions 2-6) against the moment the damage landed:
--   melee swing / aimed shot  start 0.14-0.36 s before the hit  (at 0.25: 1 hit in 172)
--   landing (fireball, bomb,  start 0.05-0.25 s before the explosion appears (49 of 50
--   explosion, projectile)    fireballs dodged) -- weaving AS it appears is too late
-- Weaving earlier than the window gets you hit (the weave is over before the hit lands).
local WINDOWS = {
    melee = { from = 0.14, to = 0.36, lead = 0.25 },
    -- landings are timed to the moment the EXPLOSION APPEARS (your HP drops ~0.10 s later):
    -- weave started 0.05-0.25 s before it dodged 49 of 50 fireballs, at the moment it
    -- appears 7 of 19 got hit (sessions 3-7)
    land  = { from = 0.05, to = 0.25, lead = 0.18 },   -- lead: replay optimum (0.13 window centre + the fit's 0.05 s lateness)
}

local function win(h)
    local w = WINDOWS[h.kind] or WINDOWS.melee
    local pe = pingExtra()
    return w.from + pe, w.to + pe, w.lead * (CFG.lead / 0.25) + pe
end

-- would a weave pressed at p cover hit h?
local function coversHit(p, h)
    local from, to = win(h)
    local d = h.t - p
    return d >= from and d <= to
end

-- ---- planner ----------------------------------------------------------------
-- Hits rarely arrive together: one mob swings, another 0.2-0.4 s later, then a third. A
-- weave dodges every hit landing while it's active, and the next weave needs the cooldown.
-- So every frame the planner looks at every hit it knows is coming (plus each nearby mob's
-- PREDICTED next attack from its rhythm) and picks the press time that
--   1. covers the earliest uncovered hit, together with any others close enough to share
--      the same weave, and
--   2. is early enough that the cooldown is over in time for the NEXT hit after that group.

-- minimum seconds between two attacks of the same mob (recorded, p10), by anim id
local REATTACK = {
    ["107426583476702"] = 1.48, ["110285618672790"] = 1.28, ["84146368125308"] = 1.28,
    ["103401623213387"] = 0.52,   -- Cambion shoots in bursts
    ["85194526199823"]  = 4.05,   -- Imp fireball cast
}

-- ---- unweavables --------------------------------------------------------------
-- Dashes are for attacks a weave can't stop (user's rule; double jumps come later for the
-- ones a dash can't). None showed up in the recordings (every attack type with a weave in
-- its window was dodged 95-100%), so they're LEARNED live: an attack that hits you through
-- a correctly timed weave at least twice, and at least half the time, becomes unweavable.
-- The settings box adds attacks by hand (anim ids or names like Bomb / Hellfire / ImpFireball).
local manualUnweavable = {}
local learned = {}            -- key -> true
local verdict = {}            -- key -> { fail, ok }
local watching = {}           -- weaved hits waiting for a verdict: { key, t, kind, done }

local function isUnweavable(key)
    return key ~= nil and (manualUnweavable[key] or learned[key]) or false
end

local function parseUnweavable(text)
    table.clear(manualUnweavable)
    for word in string.gmatch(text or "", "[^,%s]+") do manualUnweavable[word] = true end
end

local function judge(key, failed)
    local v = verdict[key] or { fail = 0, ok = 0 }
    verdict[key] = v
    if failed then v.fail += 1 else v.ok += 1 end
    if not learned[key] and v.fail >= 2 and v.fail / (v.fail + v.ok) >= 0.5 then
        learned[key] = true
        log.info(string.format("[Weave] learned: %s goes through weaves (%d of %d) -- dashing it from now on",
            key, v.fail, v.fail + v.ok))
        dlog("LEARN unweavable %s", key)
    end
end

-- you lost HP: blame any weaved hit that was due right now
local sampleUnknownRef   -- set once the learner exists (defined with the attack tables)

local function onMyDamage(amount)
    if amount < 5 then return end   -- DoT ticks
    dlog("HIT -%.1f", amount)
    local t = now()
    DASH.hits[#DASH.hits + 1] = t
    if #DASH.hits > 20 then table.remove(DASH.hits, 1) end
    local me = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
    -- a gas ball got you (~35 dmg + ragdoll): log where it was, and if it reached you from
    -- further than we keep it, keep it further from now on
    if me and amount >= 25 then
        local best
        for _, orb in ipairs(DASH.orbs) do
            if orb.Parent then
                local d = Vector3.new(me.Position.X - orb.Position.X, 0, me.Position.Z - orb.Position.Z).Magnitude
                if not best or d < best.d then best = { d = d, up = orb.Position.Y - me.Position.Y } end
            end
        end
        if best and best.d < 25 then
            dlog("ORBHIT -%.1f nearest gas ball %.1f studs across, %.1f up (keeping %.0f)", amount, best.d, best.up, DASH.orbReach)
            if best.d + 3 > DASH.orbReach then
                DASH.orbReach = math.min(25, best.d + 3)
                dlog("LEARN gas ball reach -> %.0f", DASH.orbReach)
                if persistRef then pcall(persistRef.set, "veil.auto_weave.orb_reach", DASH.orbReach) end
            end
        end
    end
    -- hit near/over the edge of an escape zone: its real reach is further -> learn it
    for _, e in ipairs(DASH.escapes) do
        if me and e.root.Parent and t <= e.till and amount >= 20 then
            local d = Vector3.new(me.Position.X - e.root.Position.X, 0, me.Position.Z - e.root.Position.Z).Magnitude
            if d >= e.clear - 3 and d + 5 > e.clear then
                e.clear = math.min(95, d + 5)
                DASH.reach[e.id] = e.clear
                dlog("LEARN reach %s -> %.0f studs (hit at %.0f)", e.id, e.clear, d)
                if persistRef then
                    local parts = {}
                    for k, v in pairs(DASH.reach) do parts[#parts + 1] = k .. "=" .. string.format("%.0f", v) end
                    pcall(persistRef.set, "veil.auto_weave.escape_reach", table.concat(parts, ","))
                end
            end
        end
    end
    local explained = false
    for _, h in ipairs(impacts) do
        if math.abs(h.t - t) <= 0.3 then explained = true; break end
    end
    for _, w in ipairs(watching) do   -- a known, weaved hit that got through
        if math.abs(w.t - t) <= 0.3 then explained = true; break end
    end
    if not explained and sampleUnknownRef then pcall(sampleUnknownRef, t) end
    if not explained and Weave._pvpHit then pcall(Weave._pvpHit, t) end
    for _, w in ipairs(watching) do
        if not w.done then
            local d = t - w.t
            local due
            if w.kind == "land" then due = d >= -0.05 and d <= 0.3 else due = math.abs(d) <= 0.15 end
            if due then w.done = true; judge(w.key, true) end
        end
    end
end

local function settleWatching(t)
    for i = #watching, 1, -1 do
        local w = watching[i]
        if w.done then
            table.remove(watching, i)
        elseif t > w.t + 0.35 then
            table.remove(watching, i)
            judge(w.key, false)
        end
    end
end

-- WEAVE-ONLY attacks: dash i-frames don't stop them. The Bell's stab (WeaveIndi) hit through a
-- dash's i-frames 3 of 3 times (fight 2: dash at +0.26-0.40, 0.70 s of i-frames, hit at 0.85-0.89)
-- because the planner counted the dash as cover and never weaved.
local WEAVE_ONLY = { ["81529985859552"] = true }

local function covered(h)
    if h.jump then
        for _, p in ipairs(jumps) do if jumpCovers(p, h) then return true end end
        return false   -- only being airborne helps against a slam
    end
    if not (h.unweavable or isUnweavable(h.key)) then
        for _, p in ipairs(done) do if coversHit(p, h) then return true end end
    end
    if WEAVE_ONLY[h.key] then return false end
    for _, p in ipairs(dashes) do if dashCovers(p, h) then return true end end
    return protectedAt(h.t)
end

watchCovered = function(p)
    for _, h in ipairs(impacts) do
        if h.key and not h.unweavable and not isUnweavable(h.key) and coversHit(p, h) then
            watching[#watching + 1] = { key = h.key, t = h.t, kind = h.kind }
        end
    end
end

-- handled = a weave covers it, or the one being pressed right now will
local function handled(h)
    if covered(h) then return true end
    if not attempt then return false end
    if attempt.dash then return not WEAVE_ONLY[h.key] and dashCovers(attempt.started, h) end
    return not (h.unweavable or isUnweavable(h.key)) and coversHit(attempt.started, h)
end

-- kind: "melee" (timed from an animation) or "land" (projectile / bomb / explosion)
local function want(impact, reason, kind, from, key)
    impacts[#impacts + 1] = { t = impact, reason = reason, kind = kind or "melee", from = from, key = key }
    if DASH.owner then DASH.own(impacts[#impacts], DASH.owner) end
end

-- Dash for hit h if a weave can't: returns true when a dash will take care of it (now or
-- later this frame loop), false when even a dash can't make it.
-- primary = an unweavable: may spend your last dash. Otherwise (a weave just can't make
-- it in time) only dash while a spare dash stays banked for unweavables.
local function tryDash(t, h, primary)
    if not CFG.dash then
        if primary then dlog("NODASH %s (dashing is switched off)", h.reason) end
        return false
    end
    if not primary and not CFG.dashBackup then return false end
    -- boss first: while you're fighting a boss, a lesser mob's hit never gets a backup dash,
    -- and its unweavable only gets one that leaves a dash banked for the boss
    local boss = CFG.bossFocus and DASH.fighting(t)
    local lesser = boss and h.owner and h.owner ~= boss and not DASH.isBoss(h.owner)
    if lesser and not primary then
        if not h.yieldLogged then h.yieldLogged = true; dlog("YIELD dash %s (fighting %s)", h.reason, boss.Name) end
        return false
    end
    -- a BOSS's hit the weave can't make (fight 2026-10-01: a weave whiffed on a Blood Hiveling,
    -- locked out 1.45 s, and the Smelter Demon's 240 swing was left to land because "tank 5 hits
    -- before dashing" still applied): never tanked, and it may spend your last dash
    local bossHit = CFG.bossFocus and h.owner ~= nil and DASH.isBoss(h.owner)
    if not h.unweavable and CFG.tankHits > 0 and not bossHit then
        -- tank it: only dash once you've already eaten tankHits hits recently
        local n = 0
        for _, ht in ipairs(DASH.hits) do if t - ht <= CFG.tankWindow then n += 1 end end
        if n < CFG.tankHits then
            if not h.tankLogged then h.tankLogged = true; dlog("TANK %s (%d/%d hits)", h.reason, n, CFG.tankHits) end
            return false
        end
    end
    local st = stamina()
    if st < DASH.cost + CFG.dashReserve + (((primary or bossHit) and not lesser) and 0 or DASH.cost) then
        if primary or bossHit then
            dlog("NODASH %s (stamina %.0f)", h.reason, st)
        end
        return false
    end
    -- A small Dissonant's death blast (a few 5-dmg ticks) must not spend your LAST dash while a
    -- boss is around (Bell fight 5: it did, 0.03 s before the Bell's 77-dmg grab -> NODASH)
    -- (user 2026-09-29: with an AoE DoT + Symbiotic Bloom the Dissonants HEAL you -> never dash
    -- their small blasts while a boss is around, whatever your stamina; the Brute's still counts)
    if h.key == "death blast"
       and string.find(h.reason, "Dissonant", 1, true) and not string.find(h.reason, "Brute", 1, true) then
        local me = root()
        for model, mr in pairs(mobRoots) do
            if me and mr.Parent and string.sub(model.Name, 1, 4) == "The "
               and (mr.Position - me.Position).Magnitude < 120 then
                if not h.saveLogged then h.saveLogged = true; dlog("SAVEDASH %s (boss near, stamina %.0f)", h.reason, st) end
                return false
            end
        end
    end
    local pe = pingExtra()
    local earliest = math.max(t, (dashes[#dashes] or -math.huge) + DASH.cooldown,
                              (done[#done] or -math.huge) + DASH.afterWeave)
    -- (a dash is exactly what covers a hit that lands in a whiff lockout)
    local lo, hi = h.t - DASH.to - pe, h.t - DASH.from - pe
    local loNow = math.max(lo, earliest)
    if loNow > hi then
        return false
    end
    if t >= math.clamp(h.t - DASH.lead - pe, loNow, hi) then
        if UIS:GetFocusedTextBox() or not alive() then return false end
        attempt = { started = t, lastPress = t, deadline = hi, reason = h.reason, dash = true, from = h.from,
                    dashDir = h.dashDir, face = h.owner and mobRoots[h.owner] or h.faceRoot or h.root }
        dlog("PRESS dash for %s (hit in %.2f, stamina %.0f)", h.reason, h.t - t, stamina())
        sendDash(h.from, h.dashDir, attempt.face)
    end
    return true
end

local function reflex(t, reason)
    if attempt or not CFG.reflex then return end
    if t < weaveReadyAt(t) then return end
    for _, h in ipairs(impacts) do
        if h.t - t < 0.9 and not covered(h) then return end   -- the planner has something coming
    end
    if UIS:GetFocusedTextBox() or not alive() then return end
    attempt = { started = t, lastPress = t, deadline = t + 0.12, reason = "reflex: " .. reason }
    sendKey()
    if not animHooked then confirmWeave(t) end
end

-- the mob that swung is dead / gone (its planned hit will never land)
local function mobDown(model)
    if not model or not model.Parent then return true end
    if model:GetAttribute("MobDead") then return true end
    local hum = model:FindFirstChildOfClass("Humanoid")
    return hum ~= nil and hum.Health <= 0
end

local function plan(t)
    settleWatching(t)
    -- drop past and covered hits
    local me = root()
    for i = #impacts, 1, -1 do
        local h = impacts[i]
        local gone = h.root and (not h.root.Parent or not me or (h.root.Position - me.Position).Magnitude > h.range)
        if not gone and h.model and not h.deadLogged and mobDown(h.model) then
            gone = true; h.deadLogged = true
            dlog("DEADSWING %s (the mob died before it landed)", h.reason)
        end
        if h.t < t - 0.05 or gone or h.cut or covered(h) then table.remove(impacts, i) end
    end
    if attempt then
        if t > attempt.deadline then
            if CFG.verbose then log.info("[Weave] game refused every press (busy / stun / cooldown): " .. attempt.reason) end
            dlog("REFUSED %s %s", attempt.dash and "dash" or "weave", attempt.reason)
            attempt = nil
        elseif t - attempt.lastPress >= RETRY then
            attempt.lastPress = t
            if attempt.dash then sendDash(attempt.from, attempt.dashDir, attempt.face) else sendKey() end
        end
        return
    end
    -- FLEE (the Bell's ring): only distance saves you, so dash away again the moment the last
    -- dash's cooldown is over -- not a timed hit, so i-frames / knock-down immunity never cancel
    -- it and a refused press is simply pressed again next frame.
    local fl = DASH.flee
    if fl then
        local off = me and fl.root.Parent and (me.Position - fl.root.Position)
        if not off or t > fl.till or Vector3.new(off.X, 0, off.Z).Magnitude > fl.clear then
            dlog("FLEE %s over (%s)", fl.name, (off and t <= fl.till) and "clear" or "time up")
            DASH.flee = nil
        elseif t >= fl.from and t >= (dashes[#dashes] or -math.huge) + DASH.cooldown + 0.03
               and CFG.dash and alive() and not UIS:GetFocusedTextBox() then
            local st = stamina()
            if st >= DASH.cost + CFG.dashReserve then
                attempt = { started = t, lastPress = t, deadline = t + 0.25, reason = fl.name .. " (flee)", dash = true,
                            from = fl.root.Position, dashDir = "Away from the attack" }
                dlog("PRESS dash for %s (flee, %.0f studs out of %.0f, stamina %.0f)", fl.name,
                    Vector3.new(off.X, 0, off.Z).Magnitude, fl.clear, st)
                sendDash(fl.root.Position, "Away from the attack")
                return
            elseif not fl.dry then
                fl.dry = true
                dlog("NODASH %s (flee, stamina %.0f)", fl.name, st)
            end
        end
    end
    local open = {}
    for _, h in ipairs(impacts) do
        if not handled(h) and (not h.cond or h.cond()) then open[#open + 1] = h end
    end
    if #open == 0 then return end
    table.sort(open, function(a, b) return a.t < b.t end)

    -- undashable (slam-downs): double jump so you're airborne when it lands. Your clicks are
    -- blocked 0.6 s before the jump so the swing in progress ends first (user-verified)
    for _, h in ipairs(open) do
        -- from 0.9 s before the jump goes out until the hit has landed, re-asserted every frame
        if h.jump and h.t - t <= JUMP.lead + 0.9 then
            if not h.guarded then h.guarded = true; dlog("M1GUARD %s (lands in %.2f)", h.reason, h.t - t) end
            guardM1(math.max(0.1, h.t - t + 0.1))
        end
    end
    for _, h in ipairs(open) do
        local singleJ = (CFG.jumpStyle ~= "Double jump" and not h.double) or not doubleJumpReady()
        if h.jump and h.t - t <= (singleJ and JUMP.singleLead or JUMP.lead) + 0.02 then
            local last = jumps[#jumps] or -math.huge
            local cd = JUMP.single[last] and JUMP.singleCooldown or JUMP.cooldown
            if t - last >= cd and not UIS:GetFocusedTextBox() and alive() then
                jumps[#jumps + 1] = t
                if singleJ then JUMP.single[t] = true end
                if #jumps > 6 then JUMP.single[table.remove(jumps, 1)] = nil end
                sendDoubleJump(h.t - t, not singleJ)
                dlog("JUMP %s (lands in %.2f)", h.reason, h.t - t)
            end
            return
        end
    end

    -- a hit waiting for its jump is not a weave's business: weaving it (or "can't cover" -> drop
    -- it) lost the jump twice in the 2026-09-27 fight
    for i = #open, 1, -1 do if open[i].jump then table.remove(open, i) end end
    if #open == 0 then return end

    -- BOSS FIRST: with a boss hit coming, a lesser mob's earlier hit is let through unless the
    -- same weave covers both -- a weave spent on it could still be locked out (a whiff: ~1.4 s)
    -- when the boss's lands.
    local boss = CFG.bossFocus and DASH.fighting(t)
    if boss then
        local bh
        for _, h in ipairs(open) do
            if h.owner == boss and not (h.unweavable or isUnweavable(h.key)) then bh = h; break end
        end
        if bh then
            local bFrom, bTo = win(bh)
            local ready = math.max(t, weaveReadyAt(t))
            for i = #open, 1, -1 do
                local h = open[i]
                if h.t < bh.t and h.owner and h.owner ~= boss and not DASH.isBoss(h.owner) then
                    local from, to = win(h)
                    local lo = math.max(h.t - to, bh.t - bTo, ready)
                    local hi = math.min(h.t - from, bh.t - bFrom)
                    if lo > hi - 0.01 and math.max(h.t - to, ready) + WHIFF_LOCK > bh.t - bFrom then
                        if not h.yieldLogged then
                            h.yieldLogged = true
                            dlog("YIELD %s (boss hit in %.2f: %s)", h.reason, bh.t - t, bh.reason)
                        end
                        table.remove(open, i)
                    end
                end
            end
        end
    end

    -- unweavable: dash it (if even a dash can't, a weave is still better than nothing)
    for _, h in ipairs(open) do
        if (h.unweavable or isUnweavable(h.key)) and h.t - t < 0.6 then
            if tryDash(t, h, true) then return end
            if h.unweavable then
                -- a channel (Minotaur charge) with no dash available: a weave is useless, drop it
                dlog("DROP %s (no dash possible, hit in %.2f)", h.reason, h.t - t)
                for i, x in ipairs(impacts) do if x == h then table.remove(impacts, i); break end end
                return
            end
            break
        end
    end

    local cdEnd = weaveReadyAt(t)
    local earliest = math.max(t, cdEnd)

    -- press-time window for one hit: [t - to, t - from]
    local function range(h)
        local from, to, lead = win(h)
        return h.t - to, h.t - from, h.t - lead
    end

    -- group: the first open hit plus every later one the same weave can still cover
    local lo, hi, ideal = range(open[1])
    local idealSum, n = ideal, 1
    for i = 2, #open do
        local l2, h2, i2 = range(open[i])
        local nlo, nhi = math.max(lo, l2), math.min(hi, h2)
        -- keep >= 1.5 frames of slack, a window narrower than that is a coin flip
        if math.max(nlo, earliest) <= nhi - 0.01 then
            lo, hi, idealSum, n = nlo, nhi, idealSum + i2, i
        else
            break
        end
    end
    local loNow = math.max(lo, earliest)
    if loNow > hi then
        -- a weave can't make it (cooldown / too late): a dash might
        if tryDash(t, open[1]) then return end
        if CFG.verbose then log.info("[Weave] can't cover: " .. open[1].reason) end
        dlog("CANT %s in=%.2f readyIn=%.2f", open[1].reason, open[1].t - t, cdEnd - t)
        for i, h in ipairs(impacts) do if h == open[1] then table.remove(impacts, i); break end end
        return
    end
    local target = math.clamp(idealSum / n, loNow, hi)

    -- be ready for the next hit after this group: known, or a nearby mob's predicted attack
    local nextHit = open[n + 1]
    for model, pr in pairs(CFG.usePredictions and preds or {}) do
        if pr.t < t or not model.Parent or not pr.root.Parent
           or not me or (pr.root.Position - me.Position).Magnitude > pr.range then
            if pr.t < t or not model.Parent then preds[model] = nil end
        elseif pr.t > open[n].t + 0.05 and (not nextHit or pr.t < nextHit.t) then
            nextHit = { t = pr.t, kind = pr.kind }
        end
    end
    if nextHit then
        -- compare against the window WITHOUT "now": once the ideal moment has passed the
        -- answer is "press immediately", not "forget about it"
        local loFixed = math.max(lo, cdEnd)
        local nlo, nhi, nideal = range(nextHit)
        local ready = nideal - CFG.cooldown                      -- next weave lands centred
        if ready < loFixed then ready = nhi - CFG.cooldown - 0.03 end   -- or at least inside
        if ready >= loFixed and ready < target then target = ready end
    end

    if t >= target then
        local names = {}
        for i = 1, n do names[i] = open[i].reason end
        attempt = { started = t, lastPress = t, deadline = hi, reason = table.concat(names, " + ") }
        dlog("PRESS weave for %s (hits in %.2f..%.2f, ready %.2f)", attempt.reason, open[1].t - t, open[n].t - t,
            cdEnd - t)
        if UIS:GetFocusedTextBox() or not alive() then attempt = nil; return end
        sendKey()
        if not animHooked then confirmWeave(t) end
    end
end

--------------------------------------------------------------------- melee (animations)

local function facingDeg(cf, pos)
    local look = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
    local to = Vector3.new(pos.X - cf.Position.X, 0, pos.Z - cf.Position.Z)
    if look.Magnitude < 1e-3 or to.Magnitude < 1e-3 then return 0 end
    return math.deg(math.acos(math.clamp(look.Unit:Dot(to.Unit), -1, 1)))
end

sampleUnknownRef = sampleUnknown

-- ---- who is the swing aimed at? ------------------------------------------------------
-- User (2026-09-29): leading an Explorer out of the maze, a mob kept swinging at HIM right in
-- front of you and Auto Weave dodged every swing "for no reason". Melee swings here land on
-- the mob's target, so when something else it could be attacking -- an Explorer (they sit in
-- Monsters tagged like summons), anyone's summon, another player -- is clearly the better
-- target (closer to it and more in front of it than you are), the swing is theirs.
-- Checked every frame up to the hit, so a mob that turns on you is still woven.
local otherVictims, victimsAt = {}, -math.huge
local function refreshVictims()
    local t = now()
    if t - victimsAt < 0.5 then return otherVictims end
    victimsAt = t
    table.clear(otherVictims)
    for _, pl in ipairs(Players:GetPlayers()) do
        local r = pl ~= LP and pl.Character and pl.Character:FindFirstChild("HumanoidRootPart")
        if r then otherVictims[#otherVictims + 1] = { model = pl.Character, root = r } end
    end
    local folder = Workspace:FindFirstChild("Monsters")
    if folder then
        for _, m in ipairs(folder:GetChildren()) do
            if m:IsA("Model") and isSummon(m) then
                local r = m:FindFirstChild("HumanoidRootPart") or m.PrimaryPart
                if r then otherVictims[#otherVictims + 1] = { model = m, root = r } end
            end
        end
    end
    return otherVictims
end

-- -> the model the mob is more likely swinging at than you, or nil
local TARGET_MARGIN = 0.5     -- studs (a degree of facing counts as 0.1 stud); user: never weave swings at summons
local function aimedElsewhere(model, mroot)
    local me = root()
    if not (me and mroot and mroot.Parent) then return nil end
    local cf = mroot.CFrame
    local myScore = (mroot.Position - me.Position).Magnitude + facingDeg(cf, me.Position) * 0.1
    local best, bestScore
    for _, v in ipairs(refreshVictims()) do
        if v.model ~= model and v.root.Parent then
            local hum = v.model:FindFirstChildOfClass("Humanoid")
            if not hum or hum.Health > 0 then
                local d = (mroot.Position - v.root.Position).Magnitude
                if d <= 20 then
                    local sc = d + facingDeg(cf, v.root.Position) * 0.1
                    if not bestScore or sc < bestScore then best, bestScore = v.model, sc end
                end
            end
        end
    end
    if best and bestScore < myScore - TARGET_MARGIN then return best end
    return nil
end

-- Recorded whiff rates (weave pressed for it, no WeaveBuffEvent): Shrouded Apparition (the
-- shadow clones) 3 of 4, Cambion's close swing 127688919744763 26 of 37 -- a whiff costs a
-- ~1.4 s lockout, so these are left alone. (The real Shrouded: 40 caught, 3 whiffed.)
local SKIP_MOBS = { ["Shrouded Apparition"] = true }
-- friendly NPCs (user): Runners fight WITH you -- their swings are at mobs, never at you.
-- Before this, a pack of Runners got weaved and backup-dashed away from all fight long.
local FRIENDLY_NPCS = { Runner = true }
local SKIP_ATTACK_FOR = { ["127688919744763"] = { Cambion = true } }

-- A swing that stops before it lands (the mob died, got stunned, or switched attacks) never
-- hits anyone: mark its planned hit cut so the planner drops it (see plan()).
local function watchSwing(h, model, track, t0, impact)
    h.model = model
    if not track then return end
    local c
    c = track.Stopped:Connect(function()
        if c then c:Disconnect() end
        local len = track.Length
        local reach = (len and len > 0) and math.min(impact, len) or impact
        if now() - t0 < reach - 0.05 then
            h.cut = true
            dlog("CUT %s (swing stopped %.2fs in, before it landed)", h.reason, now() - t0)
        end
    end)
    task.delay(impact + 0.5, function() if c then c:Disconnect() end end)
end

local function onMobAnim(model, mroot, track)
    if not (running and CFG.enabled and CFG.melee) then return end
    if SKIP_MOBS[model.Name] or FRIENDLY_NPCS[model.Name] then return end
    if isSummon(model) and classify(model) == "friendly" then return end
    local anim = track.Animation
    local id = anim and string.match(anim.AnimationId, "%d+")
    if not id then return end
    if SKIP_ATTACK_FOR[id] and SKIP_ATTACK_FOR[id][model.Name] then return end
    local beam = BEAMS[id]
    if beam then
        local r0 = root()
        if r0 and mroot.Parent and (mroot.Position - r0.Position).Magnitude <= beam.range then
            impacts[#impacts + 1] = { t = now() + beam.first, reason = beam.name, kind = "melee", from = mroot.Position,
                                      key = beam.name, unweavable = true, dashDir = beam.dir or "Sideways",
                                      root = mroot, range = beam.range + 20 }
        end
        return
    end
    local volley = VOLLEYS[id]
    if volley then
        local r0 = root()
        if r0 and mroot.Parent and (mroot.Position - r0.Position).Magnitude <= volley.range
           and facingDeg(mroot.CFrame, r0.Position) <= volley.facing then
            local t0 = now()
            for i, dt in ipairs(volley.times) do
                want(t0 + dt, string.format("%s volley %d/%d", model.Name, i, #volley.times), "land", mroot.Position, id)
                local h = impacts[#impacts]
                h.root, h.range = mroot, volley.range + 15
                h.cond = function() return myHorizontalSpeed() < volley.stillBelow end
            end
        end
        return
    end
    local windup = WINDUPS[id]
    if windup then
        local r0 = root()
        if r0 and mroot.Parent then
            local d = (mroot.Position - r0.Position).Magnitude
            if d <= windup.range then
                local t0 = now()
                want(t0 + windup.delay + d / windup.speed, model.Name .. " dash (wind-up)", "melee", mroot.Position,
                    "rush:" .. model.Name)
                -- hand it to the rush tracker: once the dash is actually moving, it keeps this
                -- arrival time current instead of queueing a second one
                rushImpact[model] = impacts[#impacts]
                rushQueued[model] = t0 + windup.delay
                impacts[#impacts].root, impacts[#impacts].range = mroot, windup.range + 15   -- dropped if it dies
            end
        end
        return
    end
    local rhythm = RHYTHM[id]
    if rhythm then
        local r0 = root()
        local t0 = now()
        local prev = lastShot[model]
        lastShot[model] = t0
        if not (r0 and mroot.Parent) then return end
        local d = (mroot.Position - r0.Position).Magnitude
        if d > rhythm.range or facingDeg(mroot.CFrame, r0.Position) > rhythm.facing then return end
        if not prev or t0 - prev > rhythm.burst * 3 then
            -- first shot of a burst: the second one follows, and the next burst after the cycle
            want(t0 + rhythm.burst + rhythm.hit, model.Name .. " beam (2nd of burst)", "melee", mroot.Position, id)
            want(t0 + rhythm.cycle + rhythm.hit, model.Name .. " beam (next burst)", "melee", mroot.Position, id)
            impacts[#impacts].root, impacts[#impacts].range = mroot, rhythm.range
        end
        return
    end
    local jumpAtk = JUMP_ATTACKS[id]
    if jumpAtk then
        -- the slam's lunge (up to ~200 stud/s) read as "rushing through you" -> stray weaves
        -- that ate the cooldown (user: "sometimes it starts to weave it randomly")
        local last = 0
        for _, dt in ipairs(jumpAtk.impacts) do last = math.max(last, dt) end
        for _, dt in ipairs(jumpAtk.thenDash or {}) do last = math.max(last, dt) end
        channelUntil[model] = math.max(channelUntil[model] or 0, now() + last + 0.4)
        local r0 = root()
        if r0 and mroot.Parent and (mroot.Position - r0.Position).Magnitude <= jumpAtk.range then
            for i, dt in ipairs(jumpAtk.impacts) do
                want(now() + dt, string.format("%s %d/%d", jumpAtk.name, i, #jumpAtk.impacts), "melee",
                    mroot.Position, "jump:" .. id)
                impacts[#impacts].jump = true
                impacts[#impacts].double = jumpAtk.double
            end
            -- a follow-up that's dashed (the Bell's ring after its tantrum slams)
            for i, dt in ipairs(jumpAtk.thenDash or {}) do
                impacts[#impacts + 1] = { t = now() + dt, reason = string.format("%s dash %d", jumpAtk.name, i), kind = "melee",
                                          from = mroot.Position, key = "jumpdash:" .. id .. ":" .. i, unweavable = true,
                                          dashDir = "setting" }
            end
            -- a follow-up that only distance escapes (the Bell's ring): dash away again and
            -- again, each dash as soon as the last one's cooldown is over, until you're clear
            local esc = jumpAtk.thenEscape
            if esc then
                local t0e = now()
                local clear = math.max(esc.clear, DASH.reach[id] or 0)
                DASH.flee = { root = mroot, from = t0e + esc.from, till = t0e + esc.till, clear = clear, name = esc.name }
                -- and walk out of it for the whole move (pushed like the Wound's punches)
                if CFG.escapePush then
                    DASH.escapes[#DASH.escapes + 1] = { root = mroot, till = t0e + esc.till, id = id, clear = clear }
                end
                dlog("ESCAPE %s: %.0f studs away, reach %.0f", esc.name, (mroot.Position - r0.Position).Magnitude, clear)
            end
            -- a follow-up in the same anim that's weaved, not jumped (Smelter vertical)
            for i, dt in ipairs(jumpAtk.thenWeave or {}) do
                want(now() + dt, string.format("%s follow-up %d", jumpAtk.name, i), "melee",
                    mroot.Position, "jumpweave:" .. id)
            end
        end
        return
    end
    local dashAtk = DASH_ATTACKS[id]
    if dashAtk then
        local r0 = root()
        if r0 and mroot.Parent and (mroot.Position - r0.Position).Magnitude <= dashAtk.range then
            for i, dt in ipairs(dashAtk.impacts or { dashAtk.impact }) do
                impacts[#impacts + 1] = { t = now() + dt, reason = dashAtk.impacts and (dashAtk.name .. " hit " .. i) or dashAtk.name,
                                          kind = "melee", from = mroot.Position, key = "dash:" .. id .. ":" .. i,
                                          unweavable = true, dashDir = "setting" }
            end
        end
        return
    end
    local channel = CHANNELS[id]
    if channel then
        -- keep the rush tracker off this mob for the whole channel, from ANY distance
        -- (a Minotaur charging from 30 studs is still an unweavable charge, not a rush to weave)
        channelUntil[model] = now() + math.max(3.2, channel.duration or 0)
        local r0 = root()
        local reach = channel.escape and math.max(channel.escape, DASH.reach[id] or 0)
        if reach and CFG.escapePush and r0 and mroot.Parent then
            -- get out of its reach for the whole move (pushed like the rot pillar, pillarStep)
            DASH.escapes[#DASH.escapes + 1] = { root = mroot, till = now() + (channel.duration or 3), id = id, clear = reach,
                                                band = channel.edgeBand }
            dlog("ESCAPE %s: %.0f studs away, reach %.0f", channel.name, (mroot.Position - r0.Position).Magnitude, reach)
        end
        if r0 and mroot.Parent and (mroot.Position - r0.Position).Magnitude <= math.max(channel.range, (reach or 0) - 5) then
            -- get-away moves (user): the Enchanted Sword first, launched straight away from it
            if channel.sword and useSword(channel.name, mroot.Position) then
                -- the sword alone doesn't get you out of range (user): follow it with one
                -- dash away as the launch finishes
                impacts[#impacts + 1] = { t = now() + 0.35 + DASH.lead, reason = channel.name .. " (dash after sword)",
                                          kind = "melee", from = mroot.Position, key = channel.name,
                                          unweavable = true, dashDir = "Away from the attack" }
                return
            end
            -- jump over the opening punch first (double jump ready), dashes start before landing
            local dashStart = 0
            if channel.jumpFirst and doubleJumpReady() then
                want(now() + channel.jumpFirst, channel.name .. " (jump over)", "melee", mroot.Position, "jump:" .. id)
                impacts[#impacts].jump = true
                impacts[#impacts].double = true   -- the tantrum's opening: double jump, then dash away
                dashStart = channel.dashAt or 0
            end
            impacts[#impacts + 1] = { t = now() + dashStart + DASH.lead, reason = channel.name, kind = "melee",
                                      from = mroot.Position, key = channel.name, unweavable = true,
                                      dashDir = channel.dir or "Away from the attack" }
            for k = 2, channel.dashes or 1 do
                -- follow-up dash as soon as the dash cooldown allows, still away from it
                impacts[#impacts + 1] = { t = now() + dashStart + DASH.lead + (k - 1) * (DASH.cooldown + 0.07),
                                          reason = channel.name .. " (dash " .. k .. ")", kind = "melee",
                                          from = mroot.Position, key = channel.name, unweavable = true,
                                          dashDir = "Away from the attack" }
            end
            for _, dt in ipairs(channel.strikes or {}) do
                want(now() + dt, channel.name .. " strike", "melee", mroot.Position, id)
                impacts[#impacts].root, impacts[#impacts].range = mroot, 20   -- dropped once you're away
            end
        end
        return
    end
    local ranged = RANGED[id]
    local impact = extra[id] or ATTACKS[id] or (not NEVER_LEARN[id] and learnedAttacks[id]) or (ranged and ranged.impact)
    if not impact then
        -- unknown: remember it in case it hits you (learning), if it looks like an attack
        local pr = track.Priority
        if not (track.Looped and (pr == Enum.AnimationPriority.Core or pr == Enum.AnimationPriority.Idle
                or pr == Enum.AnimationPriority.Movement)) then
            local r0 = root()
            if r0 and mroot.Parent and (mroot.Position - r0.Position).Magnitude <= 15
               and facingDeg(mroot.CFrame, r0.Position) <= 80 then
                unknownSeen[#unknownSeen + 1] = { id = id, t = now(), root = mroot, label = model.Name }
                attackPlays[id] = (attackPlays[id] or 0) + 1
                if #unknownSeen > 30 then table.remove(unknownSeen, 1) end
            end
        end
        return
    end
    local r = root()
    if not r or not mroot.Parent then return end
    local range = ranged and ranged.range or ATTACK_RANGE[id] or CFG.meleeRange
    if (mroot.Position - r.Position).Magnitude > range then return end
    if not NO_FACING[id] and facingDeg(mroot.CFrame, r.Position) > (ranged and ranged.facing or CFG.meleeFacing) then return end
    local t0 = now()
    if ranged and ranged.perStud then
        impact = impact + (mroot.Position - r.Position).Magnitude * ranged.perStud
    end
    want(t0 + impact, string.format("%s %s %s (+%.2fs)", model.Name, ranged and "shot" or "swing", id, impact),
        ranged and ranged.kind or "melee", mroot.Position, id)
    -- its lunge IS this attack: the rush tracker weaving the lunge too burned the cooldown right
    -- before the real hit (Wound punches, 2026-09-27: 7 hits during "rushes")
    channelUntil[model] = math.max(channelUntil[model] or 0, t0 + impact + 0.15)
    -- if you've moved out of its reach by the time it lands, the swing whiffs -- and so would
    -- a weave (1.4 s lockout). The planner drops hits whose attacker is out of range.
    impacts[#impacts].root, impacts[#impacts].range = mroot, range + 3
    -- ...or whose swing never lands: 17 recorded sessions (reach_report.py, 2026-09-29) had 830
    -- whiffed weaves, and 257 were on mobs that DIED mid-swing (mostly to your own hits) plus
    -- 186 whose swing anim was cut off before the weave went out. Distance barely mattered:
    -- most whiffs were 0-7 studs out. So each melee hit keeps its swing + mob, and is dropped
    -- the moment the swing stops early or the mob dies.
    watchSwing(impacts[#impacts], model, track, t0, impact)
    local stillBeyond = STILL_ONLY_BEYOND[id]
    local stillOnly = stillBeyond and (mroot.Position - r.Position).Magnitude > stillBeyond
    local hh = impacts[#impacts]
    -- REACH (user 2026-09-29: "weaving air"): clean recorded hits of the shared swing landed
    -- within 8.3 studs 90% of the time (246 hits, p95 11 = lag/lunges). Swings without their
    -- own ATTACK_RANGE (those lunge in) are only woven while the mob will actually be within
    -- reach when it lands: live distance minus how fast it's closing on you x time left.
    local useReach = not ranged and not ATTACK_RANGE[id]
    hh.cond = function()
        if stillOnly and myHorizontalSpeed() >= 8 then return false end
        if useReach and CFG.swingReach < 30 then
            local me = root()
            if me and mroot.Parent then
                local to = me.Position - mroot.Position
                local d = Vector3.new(to.X, 0, to.Z).Magnitude
                local rel = mroot.AssemblyLinearVelocity - me.AssemblyLinearVelocity
                local closing = d > 0.1 and Vector3.new(rel.X, 0, rel.Z):Dot(Vector3.new(to.X, 0, to.Z).Unit) or 0
                local left = math.max(0, hh.t - now())
                local atHit = math.max(0, d - math.max(0, closing) * left)
                if atHit > CFG.swingReach then
                    if not hh.reachLogged then
                        hh.reachLogged = true
                        dlog("REACH %s (%.1f studs at impact > %.1f)", hh.reason, atHit, CFG.swingReach)
                    end
                    return false
                end
            end
        end
        local other = CFG.targetCheck and aimedElsewhere(model, mroot)
        if other then
            if not hh.elseLogged then hh.elseLogged = true; dlog("ELSEWHERE %s (aimed at %s)", hh.reason, other.Name) end
            return false
        end
        return true
    end
    for _, extraHit in ipairs(EXTRA_HITS[id] or {}) do
        want(t0 + extraHit, string.format("%s %s hit 2 (+%.2fs)", model.Name, id, extraHit), "melee", mroot.Position, id)
    end
    -- its next swing can't land before this (the mob's attack rhythm)
    preds[model] = { t = t0 + (REATTACK[id] or 1.28) + impact, root = mroot,
                     kind = ranged and ranged.kind or "melee", range = range + 6 }
end

-- ---- death blasts --------------------------------------------------------------------
-- Bloated Hivelings and Dissonants blow up the moment they die (DeathExplosionHitbox
-- 0.01-0.08 s after death: nothing to react to before it) and leave a blast zone that
-- ticks (Bloated 18 dmg ~0.5 s after, Dissonant 5 dmg every ~0.5 s). Unweavable -> the
-- instant one dies within reach of its blast, dash AWAY from the corpse.
-- Reach = half the blast cube + your body: 17-stud cube -> 11, Dissonant Brute 34 -> 19.
local SLAMMERS = { "Festering Wound" }
local SLAM_RADIUS = 40
local slamQueued = setmetatable({}, { __mode = "k" })

local function isSlammer(name)
    for _, n in ipairs(SLAMMERS) do if string.find(name, n, 1, true) then return true end end
    return false
end

local function deathBlastReach(name)
    -- a cube's corners reach further than its sides: half-width x ~1.3 + your body
    if string.find(name, "Dissonant Brute", 1, true) then return 24 end
    if string.find(name, "Bloated Hiveling", 1, true) or string.find(name, "Dissonant", 1, true) then return 13 end
    return nil
end

local function onMobDied(model, mroot)
    if not (running and CFG.enabled) then return end
    local reach = deathBlastReach(model.Name)
    local r = root()
    if not (reach and r and mroot) then return end
    if (mroot.Position - r.Position).Magnitude > reach then return end
    local h = { t = now() + DASH.lead, reason = model.Name .. " death blast", kind = "melee",
                from = mroot.Position, key = "death blast", unweavable = true }
    dlog("DEATH %s at %.1f studs", model.Name, (mroot.Position - r.Position).Magnitude)
    -- already dashed for its predicted death (or just dashed): nothing more to do
    if (dashes[#dashes] or -math.huge) > now() - 0.5 then return end
    -- no waiting in line: drop any weave being retried and dash right now; the hit stays
    -- queued so the planner keeps trying if this frame can't
    if attempt and not attempt.dash then attempt = nil end
    impacts[#impacts + 1] = h
    tryDash(now(), h, true)
end

-- 2. PREDICT the death. The blast knocks you down and stuns you (Ragdolled, StunUntil,
-- StunAllowsWeave=false) the instant it dies, so reacting is always too late -- but a dash
-- that is ALREADY up when it dies blocks all of it (recorded). So: watch its health; once
-- the next hit will probably kill it, predict when that hit lands from the rhythm of the
-- damage it's been taking (your swings, your poison ticks, your summons) and dash just
-- before.
local function watchForDeath(model, hum, mroot)
    local drops, lastHp, queued = {}, hum.Health, nil
    return hum.HealthChanged:Connect(function(hp)
        local t = now()
        local d = lastHp - hp
        lastHp = hp
        if d <= 0 or hp <= 0 then return end
        drops[#drops + 1] = { t = t, d = d }
        if #drops > 6 then table.remove(drops, 1) end
        if not (running and CFG.enabled and CFG.dash) then return end
        local reach = deathBlastReach(model.Name)
        local r = root()
        if not (reach and r and mroot.Parent) or (mroot.Position - r.Position).Magnitude > reach + 4 then return end
        -- typical hit size and spacing
        local sizes, gaps = {}, {}
        for i, x in ipairs(drops) do
            sizes[#sizes + 1] = x.d
            if i > 1 then gaps[#gaps + 1] = x.t - drops[i - 1].t end
        end
        table.sort(sizes); table.sort(gaps)
        local typical = sizes[math.ceil(#sizes / 2)]
        if hp > typical * 1.15 then return end                 -- not one hit from death yet
        local gap = #gaps > 0 and gaps[math.ceil(#gaps / 2)] or nil
        local predicted = t + ((gap and gap < 1.2) and gap or 0.15)
        if queued and queued.t > t then
            queued.t = predicted                                -- keep the guess current
            return
        end
        queued = { t = predicted, reason = model.Name .. " about to die (blast)", kind = "melee",
                   from = mroot.Position, key = "death blast", unweavable = true,
                   root = mroot, range = reach + 8 }
        impacts[#impacts + 1] = queued
        dlog("PREDEATH %s hp %.0f (hits ~%.0f every %s) -> dash for ~%.2f s", model.Name, hp, typical,
            gap and string.format("%.2f s", gap) or "?", predicted - t)
    end)
end

local function hookMob(model)
    if mobConns[model] or not model:IsA("Model") then return end
    -- summons are hooked too: an enemy player's (or a mob's) summon attacks like any mob.
    -- Yours / your party's are filtered per attack in onMobAnim (ownership can change).
    if model == LP.Character or Players:GetPlayerFromCharacter(model) then return end
    if FRIENDLY_NPCS[model.Name] then return end
    local hum = model:FindFirstChildOfClass("Humanoid")
    local mroot = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
    local animator = hum and model:FindFirstChildWhichIsA("Animator", true)
    if not (hum and mroot) then return end                 -- retried on the next scan
    if not animator and not isSlammer(model.Name) then return end
    local list = {}
    mobConns[model] = list
    mobRoots[model] = mroot
    if animator then list[#list + 1] = animator.AnimationPlayed:Connect(function(tr)
        DASH.owner = model
        local n0 = #impacts
        local ok, err = pcall(onMobAnim, model, mroot, tr)
        DASH.owner = nil
        -- hits it queued without an owner (timed dash attacks): still remember who to face
        for i = n0 + 1, #impacts do
            if not impacts[i].owner then impacts[i].faceRoot = mroot end
        end
        if not ok and CFG.verbose then log.warn("[Weave] anim: " .. tostring(err)) end
    end) end
    if deathBlastReach(model.Name) then
        list[#list + 1] = watchForDeath(model, hum, mroot)
        local fired = false
        local function died()
            if fired then return end
            fired = true
            pcall(onMobDied, model, mroot)
        end
        list[#list + 1] = hum.Died:Connect(died)
        list[#list + 1] = hum.HealthChanged:Connect(function(v) if v <= 0 then died() end end)
        list[#list + 1] = model:GetAttributeChangedSignal("MobDead"):Connect(function()
            if model:GetAttribute("MobDead") then died() end
        end)
    end
    list[#list + 1] = model.AncestryChanged:Connect(function(_, p)
        if p then return end
        for _, c in ipairs(list) do c:Disconnect() end
        mobConns[model] = nil
    end)
end

local function scanMobs()
    local folder = Workspace:FindFirstChild("Monsters")
    if folder then
        for _, m in ipairs(folder:GetChildren()) do pcall(hookMob, m) end
    end
    -- bosses may live outside the Monsters folder
    for _, m in ipairs(Workspace:GetChildren()) do
        -- (also any "The ..." boss parked outside Monsters, e.g. The Bell -- unconfirmed where it lives)
        if m:IsA("Model") and (isSlammer(m.Name) or (string.sub(m.Name, 1, 4) == "The "
           and m:FindFirstChildOfClass("Humanoid"))) then pcall(hookMob, m) end
    end
end

--------------------------------------------------------------------- projectiles + hitboxes

local function insideHumanoidModel(part)
    local m = part:FindFirstAncestorOfClass("Model")
    while m do
        if m:FindFirstChildOfClass("Humanoid") then return m end
        m = m:FindFirstAncestorOfClass("Model")
    end
    return nil
end

local function coversMe(part, pos, pad)
    local rel = part.CFrame:PointToObjectSpace(pos)
    local h = part.Size * 0.5
    return math.abs(rel.X) <= h.X + pad and math.abs(rel.Y) <= h.Y + pad and math.abs(rel.Z) <= h.Z + pad
end

-- ---- is it mine? ------------------------------------------------------------
-- Your own abilities reuse the same part names as mob attacks (your Enchanted Sword dash
-- vs the Enchanted Sword mob's Bladey, class dashes like Ice Surge), so names alone can't
-- tell them apart. A part is treated as YOURS when any of these hold:
--   * it appeared near you within MY_ACTION_WINDOW of one of your key presses
--   * it carries an owner tag pointing at you (attribute / ObjectValue / StringValue)
--   * it spawned closer to a player or a summon than to any mob (projectiles fly from their owner)
local MY_ACTION_WINDOW = 0.6   -- after an ability key
local M1_WINDOW        = 0.25  -- M1 is spammed in fights: a short window so enemy AoE still counts
local MY_ACTION_RANGE  = 25
local myActionAt = -math.huge   -- end of the current "this is probably mine" window
-- movement / camera keys are held all fight long and never spawn anything
local NOT_ABILITY = {}
for _, k in ipairs({ "W", "A", "S", "D", "Space", "LeftShift", "RightShift", "LeftControl", "Up", "Down",
                     "Left", "Right", "Tab", "Slash", "Escape", "I", "O" }) do
    NOT_ABILITY[Enum.KeyCode[k]] = true
end

local function taggedMine(inst)
    local char = LP.Character
    local name, uid = LP.Name, tostring(LP.UserId)
    for _, v in pairs(inst:GetAttributes()) do
        local sv = tostring(v)
        if sv == name or sv == uid then return true end
    end
    for _, c in ipairs(inst:GetChildren()) do
        if c:IsA("ObjectValue") and (c.Value == LP or (char and c.Value == char)) then return true end
        if c:IsA("StringValue") and (c.Value == name or c.Value == uid) then return true end
        if (c:IsA("IntValue") or c:IsA("NumberValue")) and c.Value == LP.UserId then return true end
    end
    return false
end

-- ---- friend or foe -------------------------------------------------------
-- Party members carry the same StringValue Team as you (and so do their summons), people
-- on Pantheon's friends list count as friendly too. Every other player is hostile.
local function teamOf(model)
    local v = model and model:FindFirstChild("Team")
    return (v and v:IsA("StringValue")) and v.Value or nil
end

-- Safe zones: the server announces zone changes with NotifyCardEvent(title, text, kind, n,
-- "combat-zone"): "Safe Zone" (other players cannot hurt you), "PVP Zone", "PVP Friendly
-- Zone" (PvP on, nothing counts). In a Safe Zone other players and their summons are
-- harmless, so they're not dodged. Only zone CHANGES are announced, so the last one is kept
-- in getgenv() and survives Pantheon re-executes (until you rejoin).
local GENV = (getgenv and getgenv()) or _G
local zone = GENV.PantheonVeilZone

-- The safe zone is the Glade in the middle of the map (user). Zone cards only arrive on a
-- border crossing -- spawning inside the Glade never sends one -- so the Glade's own area
-- is used too: the biggest map object named like "Glade" gives a box; inside it = safe.
local gladeBox = nil        -- { cf, size } (flat XZ test)
local gladeSearched = false
local function findGlade()
    gladeSearched = true
    local best, bestArea
    local roots = { Workspace:FindFirstChild("Map"), Workspace }
    for _, rootObj in ipairs(roots) do
        if rootObj then
            for _, d in ipairs(rootObj:GetDescendants()) do
                if (d:IsA("Model") or d:IsA("Folder") or d:IsA("BasePart"))
                   and string.find(string.lower(d.Name), "glade", 1, true) then
                    local ok, cf, size = pcall(function()
                        if d:IsA("BasePart") then return d.CFrame, d.Size end
                        if d:IsA("Model") then return d:GetBoundingBox() end
                        local parts = {}   -- folder: measure its parts
                        for _, x in ipairs(d:GetDescendants()) do if x:IsA("BasePart") then parts[#parts + 1] = x end end
                        if #parts == 0 then return nil end
                        local lo, hi = parts[1].Position, parts[1].Position
                        for _, x in ipairs(parts) do
                            lo = Vector3.new(math.min(lo.X, x.Position.X), math.min(lo.Y, x.Position.Y), math.min(lo.Z, x.Position.Z))
                            hi = Vector3.new(math.max(hi.X, x.Position.X), math.max(hi.Y, x.Position.Y), math.max(hi.Z, x.Position.Z))
                        end
                        return CFrame.new((lo + hi) / 2), hi - lo
                    end)
                    if ok and cf and size and size.X > 40 and size.Z > 40 then
                        local area = size.X * size.Z
                        if not bestArea or area > bestArea then best, bestArea = { cf = cf, size = size, name = d:GetFullName() }, area end
                    end
                end
            end
        end
        if best then break end
    end
    gladeBox = best
    if best then
        dlog("GLADE %s centre %.0f,%.0f size %.0fx%.0f", best.name, best.cf.X, best.cf.Z, best.size.X, best.size.Z)
    else
        dlog("GLADE not found (only zone cards will tell safe zones)")
    end
end

local function insideGlade()
    if not gladeSearched then pcall(findGlade) end
    local r = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
    if not (gladeBox and r) then return false end
    local rel = gladeBox.cf:PointToObjectSpace(r.Position)
    return math.abs(rel.X) <= gladeBox.size.X / 2 and math.abs(rel.Z) <= gladeBox.size.Z / 2
end

local function inSafeZone()
    if zone == "PVP Zone" or zone == "PVP Friendly Zone" then
        -- a PvP card arrived after the last safe one; the Glade box still wins while inside it
        return insideGlade()
    end
    return zone == "Safe Zone" or insideGlade()
end

local function hostilePlayer(pl)
    if not pl or pl == LP then return false end
    if not CFG.pvp then return false end
    if inSafeZone() then return false end
    local okF, friendly = pcall(state.isFriendly, pl)
    if okF and friendly then return false end
    local mine, theirs = teamOf(LP.Character), teamOf(pl.Character)
    if mine and theirs and mine == theirs then return false end
    return true
end

-- "friendly" (you, party, friends, their summons), "hostile" (other players + their
-- summons) or "mob"
function classify(model)
    local pl = Players:GetPlayerFromCharacter(model)
    if pl then return hostilePlayer(pl) and "hostile" or "friendly" end
    if isSummon(model) then
        local mine = teamOf(LP.Character)
        local theirs = teamOf(model)
        if mine and theirs and mine == theirs then return "friendly" end
        -- owner = a player in the server, read from the model name / PlayerID / Team values
        local owner
        for _, key in ipairs({ model.Name, (model:FindFirstChild("PlayerID") or {}).Value,
                               theirs }) do
            local id = tonumber(key)
            owner = owner or (id and Players:GetPlayerByUserId(id))
        end
        if owner == LP then return "friendly" end
        if owner then return hostilePlayer(owner) and "hostile" or "friendly" end
        return "mob"        -- no player owns it: a mob's minion
    end
    return "mob"
end

local function isFriendlyModel(model) return classify(model) == "friendly" end

-- what is nearest to this point: "mob", "hostile" (enemy player / their summon) or "friendly"
-- notMe: leave yourself out (for attacks you can't cast, e.g. an Imp fireball at point blank)
-- Also returns the distance: a projectile starts at its caster's hand, so something that
-- appeared far from every mob (chest debris flying out, map props) was nobody's attack.
local LAUNCH_REACH = 15
local function nearestSource(pos, notMe)
    local best, bestD = "friendly", math.huge
    for _, pl in ipairs(Players:GetPlayers()) do
        local c = (not notMe or pl ~= LP) and pl.Character
        local r = c and c:FindFirstChild("HumanoidRootPart")
        if r then
            local d = (r.Position - pos).Magnitude
            if d < bestD then best, bestD = hostilePlayer(pl) and "hostile" or "friendly", d end
        end
    end
    local folder = Workspace:FindFirstChild("Monsters")
    if folder then
        for _, m in ipairs(folder:GetChildren()) do
            local r = m:FindFirstChild("HumanoidRootPart")
            if r then
                local d = (r.Position - pos).Magnitude
                if d < bestD then best, bestD = classify(m), d end
            end
        end
    end
    return best, bestD
end

local function isMine(part, rec)
    if taggedMine(part) or (part.Parent and part.Parent ~= Workspace and taggedMine(part.Parent)) then return true end
    local r = root()
    if r and rec.first <= myActionAt
       and (part.Position - r.Position).Magnitude <= MY_ACTION_RANGE then
        return true
    end
    return false
end

local OWN_RADIUS = 7   -- parts spawning closer than this to you are treated as yours


-- ---- The Puppeteer's bombs ------------------------------------------------------
-- Recorded (12 min Puppeteer fight): a thrown "Bomb" (2x2x2, big ones 8x8x8) sits on a
-- FIXED fuse -- 150 of 173 blew 4.0-4.1 s after spawning. BombExplosionHitbox (17-stud
-- cube; GiantExplosionHitbox 60 for the big ones) appears ~0.15 s after the bomb vanishes
-- and the damage lands on that same frame, so reacting to the explosion is always too late.
-- The fuse is the tell: when it's about to go off and you're inside its blast, weave.
local BOMB_FUSE = 3.93        -- spawn -> explosion appears (damage shows ~0.1 s later, at 4.03)
local BOMB_RADIUS = 10.5      -- 17-stud cube = 8.5 half-width, + your body + slack
local GIANT_RADIUS = 32       -- 60-stud cube
local bombs = {}              -- part -> { spawn, giant, queued }

local function trackBomb(part)
    bombs[part] = { spawn = now(), giant = math.max(part.Size.X, part.Size.Y, part.Size.Z) >= 5, queued = false }
    local ac
    ac = part.AncestryChanged:Connect(function(_, parent)
        if parent then return end
        ac:Disconnect()
        local b = bombs[part]
        bombs[part] = nil
        -- went off early (or late): the blast lands ~0.15 s after the bomb vanishes
        if b and not b.queued and running and CFG.enabled and CFG.hitboxes then
            local r = root()
            local radius = b.giant and GIANT_RADIUS or BOMB_RADIUS
            if r and (part.Position - r.Position).Magnitude <= radius then
                want(now() + 0.15, "bomb went off", "land", part.Position, b.giant and "Giant bomb" or "Bomb")
            end
        end
    end)
    conns[#conns + 1] = ac
end

local function stepBombs(t, me)
    for part, b in pairs(bombs) do
        if not b.queued then
            local impact = b.spawn + BOMB_FUSE
            -- decide at press time, from where you are THEN (you might walk out of it)
            if impact - t <= leadNow() + 0.05 and impact > t then
                local radius = b.giant and GIANT_RADIUS or BOMB_RADIUS
                local d = (part.Position - me).Magnitude
                if d <= radius then
                    b.queued = true
                    want(impact, string.format("%sbomb fuse (%.0f studs)", b.giant and "giant " or "", d), "land", part.Position,
                        b.giant and "Giant bomb" or "Bomb")
                end
            elseif t > impact + 1 then
                b.queued = true   -- a long-fuse bomb: only the "went off" fallback is left
            end
        end
    end
end

local looked, lookedAt = 0, 0
local WORLD_FOLDERS = { "Systems", "Map", "Drops" }   -- chests, props, traps, loot

local function inWorldFolder(part)
    for _, n in ipairs(WORLD_FOLDERS) do
        local f = Workspace:FindFirstChild(n)
        if f and part:IsDescendantOf(f) then return true end
    end
    return false
end

-- the user's own Shatterpoint rapier: only an enemy player's counts
-- (Vine = the user's class dash, Vine Rush: every dash -- including Auto Weave's own -- throws
-- vine parts that fly at nearby targets, and they were being woven: a wasted weave + lockout)
local MY_WEAPON_PARTS = { ShatterStab = true, ShatterProjectile = true, Vine = true }

local BELL_BLAST_REACH = 11   -- 17-stud blast: half-width + your body
local STAR_CONTACT = 4     -- studs, star centre to yours at contact (4-stud ball + your body)
local STAR_ARMED   = 3.2   -- s after spawning a star can go off (fights 2-3: 3.2-5.9, bulk 4.25-5.0)
local STAR_BLAST   = 13    -- studs: a blast hit you from 13.6 (fight 3); 26+ never did

local function onPart(part)
    if not (running and CFG.enabled) or not part:IsA("BasePart") then return end
    if Weave._bombSeen then Weave._bombSeen(part) end
    if IGNORE_PARTS[part.Name] then return end
    if inWorldFolder(part) then return end
    local char = LP.Character
    if char and part:IsDescendantOf(char) then return end
    if part.Name == "BellLaserBlast" then
        -- The Bell's eye laser (fight 2, 2026-09-29): a BellEyeBeam flies at ~700-1000 stud/s and
        -- a 17-stud BellLaserBlast appears where it lands ~0.2 s later; the damage (22) comes
        -- ~0.17-0.2 s AFTER the blast shows up (hits at 0.38-0.41 after the beam), so unlike
        -- most explosions this one can be woven on sight. Blasts 3-9 studs away hit, 26+ didn't.
        task.defer(function()
            local r = root()
            if not (r and part.Parent) then return end
            local d = (part.Position - r.Position).Magnitude
            if d <= BELL_BLAST_REACH then
                want(now() + 0.17, string.format("Bell laser blast (%.1f studs)", d), "land", part.Position, "BellLaserBlast")
            end
        end)
        return
    end
    if part.Name == "WhiteStarProjectile" then
        -- The Bell's white stars (user 2026-09-29: "homing projectiles that explode on contact,
        -- they need to be dashed"). A volley of ~5 drifts in and they go off together (66 +
        -- 270 killed you), the damage landing as the star vanishes -- before its 17-stud
        -- WhiteStarExplosionHitbox even appears. They spawn 25-40 studs from the Bell, so the
        -- "who launched it" check never trusted them: followed every frame instead, and a dash
        -- (i-frames) goes out just before one touches you.
        tracked[part] = { first = now(), pos = part.Position, t = now(), fired = false, checked = true, star = true }
        return
    end
    if part.Name == "RotOrb" then
        -- Festering Wound gas ball: ragdolls you on contact; a dash through it avoids that
        -- (user). Followed every frame; a dash goes out just before it touches you.
        tracked[part] = { first = now(), pos = part.Position, t = now(), fired = false, checked = true, rotorb = true }
        DASH.orbs[#DASH.orbs + 1] = part
        return
    end
    -- Turret Golem laser (user: the laser itself isn't the damage, the explosion where it lands
    -- is, and it goes off almost as soon as the laser lands). Recorded on 29 lasers: the
    -- 12x1x1 LaserProjectile lives ~0.05 s, an Explosion (16-17 wide) appears at +0.2 s and
    -- the 25-35 dmg lands +0.35-0.43 s after the laser spawned -- whenever the laser was
    -- within ~12 studs of you (none of the 15-24 stud ones hit). Too short-lived to track,
    -- so it's timed from the spawn.
    if part.Name == "LaserProjectile" and CFG.projectiles then
        local r = root()
        if r then
            local axis = part.CFrame.RightVector * (part.Size.X / 2)
            local a, b = part.Position - axis, part.Position + axis
            local ab = b - a
            local u = ab.Magnitude > 0 and math.clamp((r.Position - a):Dot(ab) / ab:Dot(ab), 0, 1) or 0.5
            local near = (a + ab * u - r.Position).Magnitude
            if near <= GOLEM_LASER.reach or (part.Position - r.Position).Magnitude <= GOLEM_LASER.centre then
                want(now() + GOLEM_LASER.impact, "Turret Golem laser explosion", "land", part.Position, "LaserProjectile")
                dlog("GOLEMLASER %.1f studs from you -> weave at +%.2f", near, GOLEM_LASER.impact)
            end
        end
        return
    end
    if part.Name == "Bomb" and CFG.hitboxes then
        -- thrown bombs start at the boss, never on you: no rate limit, no ownership guess
        local r = root()
        if r and (part.Position - r.Position).Magnitude > OWN_RADIUS then trackBomb(part) end
        return
    end
    local t = now()
    if t - lookedAt >= 1 then looked, lookedAt = 0, t end
    looked += 1
    if looked > 150 and not TIMED_PROJ[part.Name] and not REFLEX[part.Name] and part.Name ~= "Main" then return end
    -- inside you / party / friends / their summons: never. Inside a mob or an enemy player
    -- only named hostile parts count (limbs, accessories and tools are not attacks)
    local owner = insideHumanoidModel(part)
    if owner and (isFriendlyModel(owner) or not HOSTILE_PARTS[part.Name]) then return end
    local r = root()
    if not r or (part.Position - r.Position).Magnitude > 250 then return end
    tracked[part] = { first = t, pos = part.Position, t = t, fired = false }
end

-- per frame: projectile ETA and hitbox coverage for tracked parts, then due weaves
-- ---- mobs rushing through you ---------------------------------------------------------
-- Enchanted Sword's second attack is a dash straight through you at ~100 stud/s (its
-- afterimage trail closes 32 -> 24 -> 14 -> 8 -> 3 studs, then the hit): 5 of its 8 hits
-- in a recorded fight. Any mob flying at you faster than RUSH_SPEED on a line that passes
-- within RUSH_MISS studs is timed like a projectile: the weave lands as it passes through.
local RUSH_SPEED = 40
local RUSH_MISS = 6
-- Big mobs hit you with their BODY: the Festering Wound's rushes stop with his centre
-- ~14-15 studs from you, so "centre passes within 6 studs" never fired for him. Each mob's
-- own size (half its widest horizontal extent) is added to the reach, and the arrival time
-- is to its edge, not its centre.
local mobRadius = setmetatable({}, { __mode = "k" })
local function radiusOf(model)
    local r = mobRadius[model]
    if r then return r end
    local ok, size = pcall(function() return model:GetExtentsSize() end)
    r = (ok and size) and math.clamp(math.max(size.X, size.Z) / 2, 1, 25) or 2
    mobRadius[model] = r
    return r
end

-- ---- slam-downs ------------------------------------------------------------------
-- A boss that leaps and slams down: while its root is falling fast near you, time its
-- landing from height + fall speed (h = v t + g t^2 / 2) and double jump for it.
-- Festering Wound (user): slams are unweavable AND undashable.

local slamRay = RaycastParams.new()
slamRay.FilterType = Enum.RaycastFilterType.Exclude

local function stepSlams(t, me)
    for model, mroot in pairs(mobRoots) do
        if mroot.Parent and isSlammer(model.Name) then
            local pos, v = mroot.Position, mroot.AssemblyLinearVelocity
            local flat = Vector3.new(pos.X - me.X, 0, pos.Z - me.Z).Magnitude
            if v.Y < -20 and flat <= SLAM_RADIUS then
                slamRay.FilterDescendantsInstances = { model, LP.Character }
                local hit = Workspace:Raycast(pos, Vector3.new(0, -300, 0), slamRay)
                local h = hit and (pos.Y - hit.Position.Y - 3) or 0
                local g = Workspace.Gravity
                local vy = -v.Y
                local tland = h > 0 and (-vy + math.sqrt(vy * vy + 2 * g * h)) / g or 0
                local q = slamQueued[model]
                if q and q.t > t then
                    q.t = t + tland                       -- keep it current as it falls
                elseif tland <= 1.2 then
                    want(t + tland, model.Name .. " slam-down", "melee", pos, "slam")
                    local imp = impacts[#impacts]
                    imp.jump = true
                    imp.double = true                     -- Wound slam-downs: double jump (user)
                    slamQueued[model] = imp
                    dlog("SLAM %s falling %.0f stud/s, %.0f studs up, lands in %.2f", model.Name, vy, h, tland)
                end
            end
        end
    end
end

-- mobs whose fast movement is never a weavable rush (user: the Minotaur's charge is not
-- weavable; its swing is timed from its anim)
local NO_RUSH = { Minotaur = true, ["The Bell"] = true }   -- the Bell's lunges are its timed attacks

-- YOUR velocity matters as much as the mob's (user 2026-09-29: "rush attacks are still
-- inaccurate as hell, especially if I'm moving"): arrival time and "does it pass through me"
-- were computed as if you stood still, so running away made rushes look early and strafing
-- made them look like misses/hits they weren't. Everything below uses the mob's velocity
-- RELATIVE to you (horizontal: rushes run along the ground).
local function stepRushes(t, me, myVel)
    if not CFG.melee then return end
    local myFlat = Vector3.new(myVel.X, 0, myVel.Z)
    for model, mroot in pairs(mobRoots) do
        if NO_RUSH[model.Name] then continue end
        local fresh = t - (rushQueued[model] or -math.huge) <= 0.8
        if mroot.Parent and not (channelUntil[model] and t < channelUntil[model]) then
            local pos = mroot.Position
            local rel = me - pos
            if rel.Magnitude < 70 then
                local mobVel = mroot.AssemblyLinearVelocity
                local mobSpeed = mobVel.Magnitude          -- is IT rushing (its own speed)
                local vel = mobVel - myFlat                -- how it moves relative to you
                local speed = vel.Magnitude
                -- braking (user 2026-09-27: "rushes from a distance, we heavily mistime the weave"):
                -- a mob that rushes in from far SLOWS DOWN before it strikes, so constant-speed ETAs
                -- fired 0.44-1.04 s early (10 of 22 misses) and 41 weaves whiffed on mobs that
                -- stopped short. Track how fast its closing speed changes (smoothed) and plan with it.
                local closingNow = rel.Magnitude > 0.5 and vel:Dot(rel.Unit) or 0
                local rv = DASH.rushVel[model]
                local accel = 0
                if rv and t - rv.t > 0.005 and t - rv.t < 0.3 then
                    accel = rv.a * 0.6 + ((closingNow - rv.c) / (t - rv.t)) * 0.4
                end
                DASH.rushVel[model] = { c = closingNow, t = t, a = accel }
                local braking = accel < -30 and closingNow > 0
                if mobSpeed >= RUSH_SPEED and speed > 1 and rel.Magnitude > 0.5 and mobVel:Dot(rel.Unit) >= RUSH_SPEED * 0.8
                   and closingNow > 5 then
                    local reach = RUSH_MISS + radiusOf(model)
                    local dir = vel / speed
                    local along = rel:Dot(dir)                     -- studs until its centre is abreast of you
                    local miss = (rel - dir * along).Magnitude     -- how far its centre line passes from you
                    -- time until its BODY reaches you (edge of the reach sphere), not its centre
                    local eta = miss <= reach and (along - math.sqrt(math.max(reach * reach - miss * miss, 0))) / speed or -1
                    if eta < 0 and miss <= reach and along > 0 then eta = 0.02 end   -- already touching
                    local stopsShort = false
                    if braking and eta > 0.02 then
                        -- gap to cover = eta * speed; with deceleration a: gap = c t + a t^2 / 2
                        local gap, c, a = eta * speed, closingNow, accel
                        if c * c / (2 * -a) < gap then
                            stopsShort = true                       -- it stops before it gets to you
                        else
                            eta = (-c + math.sqrt(math.max(c * c + 2 * a * gap, 0))) / a
                        end
                    end
                    -- you see mobs ~a ping + interpolation late; the server hits on ITS position,
                    -- so arrival is earlier than it looks (rush weaves that went out and still got
                    -- hit, 2026-09-27: 8 of ~20)
                    if eta > 0.02 then eta = math.max(0.02, eta - (pingExtra() + 0.06)) end
                    if stopsShort then
                        local h = rushImpact[model]
                        if h and h.rushLive and h.t > t + 0.05 and not (attempt and not attempt.dash) then
                            for i, x in ipairs(impacts) do if x == h then table.remove(impacts, i); break end end
                            rushImpact[model] = nil
                            dlog("CANCEL %s braking, stops short", model.Name)
                        end
                    elseif eta >= 0 and eta <= 0.7 and miss <= reach and classify(model) ~= "friendly" then
                        local h = rushImpact[model]
                        if h and h.t > t then
                            -- same rush still coming (any age now, not just 0.8 s): keep its arrival
                            -- current as it speeds up or brakes
                            h.t = t + eta
                        elseif not fresh or not h or h.t <= t - 0.05 then
                            -- a NEW rush -- including one right after the last passed you
                            -- (the Festering Wound rushes back to back)
                            rushQueued[model] = t
                            want(t + eta, string.format("%s rushing through you (%.0f stud/s, %.0f relative)", model.Name, mobSpeed, speed),
                                "melee", pos, "rush:" .. model.Name)
                            rushImpact[model] = impacts[#impacts]
                            impacts[#impacts].rushLive = true
                            DASH.own(impacts[#impacts], model)
                        end
                    end
                end
                -- it stopped short (or turned away) before reaching you: drop the weave that
                -- hasn't gone out yet -- a whiff locks weaving ~1.4 s, right before its next rush
                local h = rushImpact[model]
                local closing = rel.Magnitude > 0.5 and vel:Dot(rel.Unit) or 0
                if h and h.rushLive and h.t > t + 0.05 and (mobSpeed < RUSH_SPEED * 0.5 or closing < 10)
                   and not (attempt and not attempt.dash) then
                    for i, x in ipairs(impacts) do
                        if x == h then table.remove(impacts, i); break end
                    end
                    rushImpact[model] = nil
                    dlog("CANCEL %s stopped short", model.Name)
                end
            end
        end
    end
end

local function step()
    if not (running and CFG.enabled) then return end
    local t = now()
    local r = root()
    if r then
        local me = r.Position
        local myVel = r.AssemblyLinearVelocity
        stepBombs(t, me)
        stepRushes(t, me, myVel)
        stepSlams(t, me)
        for part, rec in pairs(tracked) do
            local age = t - rec.first
            -- (gas balls live 6-9 s and home in slowly: tracked up to 12 s)
            if not part.Parent or (age > 4 and not ((rec.rotorb or rec.star) and age < 12)) or rec.fired then
                tracked[part] = nil
            elseif not rec.checked then
                -- a frame late on purpose: parts get moved into place after being parented
                rec.checked = true
                -- Only parts that provably come from an ENEMY are trusted: inside a mob / enemy
                -- player model, or spawned away from you and nearest a mob or an enemy player
                -- (or their summon). Anything that spawns on you (your dashes, your weapon, your
                -- banners) or next to a party member is never a trigger.
                local inside = insideHumanoidModel(part)
                local src = inside and classify(inside)
                -- timed projectiles spawn at the caster's hand: a close Imp is still a mob
                local timed = timedFor(part)
                if not src and ((part.Position - me).Magnitude >= OWN_RADIUS or timed) then
                    local srcD
                    src, srcD = nearestSource(part.Position, timed ~= nil)
                    if srcD and srcD > LAUNCH_REACH then src = nil end   -- nobody launched it
                end
                rec.pvp = (src == "hostile")
                if REFLEX[part.Name] and not isMine(part, rec) and coversMe(part, me, 1.5) then
                    rec.fired = true
                    reflex(t, part.Name)
                    timed = nil
                end
                if timed and CFG.projectiles and (src == "mob" or src == "hostile") then
                    local d = (part.Position - me).Magnitude
                    -- keep tracking it: if it DOES visibly fly on your client, the projectile
                    -- branch below takes over with an exact ETA
                    rec.timed = true
                    if timed.proximity then
                        rec.proximity = true
                        rec.fallbackAt = rec.first + timed.hold + d / timed.speed
                    elseif d <= POINT_BLANK then
                        -- too close to track (it lands ~0.1 s after launching): timed guess,
                        -- which the trajectory below still refines or cancels
                        want(rec.first + timed.hold + d / timed.speed, string.format("%s point blank (%.0f studs)", part.Name, d),
                            "land", part.Position, part.Name)
                        rec.impact = impacts[#impacts]
                    end
                    -- anything further: decided purely from its trajectory once it flies
                elseif isMine(part, rec) or (src ~= "mob" and src ~= "hostile") then
                    rec.fired = true   -- ignore it for good
                    if CFG.verbose then log.info("[Weave] ignoring own/friendly part " .. part.Name) end
                end
                rec.pos, rec.t = part.Position, t
            else
                local pos = part.Position
                local dt = t - rec.t
                if dt > 0 then
                    local vel = (pos - rec.pos) / dt
                    rec.pos, rec.t = pos, t
                    local speed = vel.Magnitude
                    if rec.rotorb then
                        local gap = (pos - me).Magnitude - 3   -- orb radius + your body
                        local closing = rec.lastGap and (rec.lastGap - gap) / dt or 0
                        rec.lastGap = gap
                        -- "Jump + dash into it": when it's within orbDashAt (ground distance -- they
                        -- hover), jump, point the camera straight at it and dash at it
                        local flat = Vector3.new(pos.X - me.X, 0, pos.Z - me.Z).Magnitude
                        -- only a real gas ball: slow (they drift/home at ~30), actually near in
                        -- 3D, not flying away. Fast "RotOrb" parts shooting off at 250-330 stud/s
                        -- 80-230 studs up (the laser phase) passed the ground-distance check and
                        -- got dashed at (user 2026-09-28: "weird dash like they're a green orb")
                        local realOrb = speed <= 80 and gap <= 18 and closing > -15
                        if CFG.orbMode == "Jump + dash into it" and CFG.dash and realOrb and flat <= DASH.orbDashAt
                           and now() - (DASH.orbDashedAt or -math.huge) > 1.0 and stamina() >= DASH.cost
                           and not attempt and alive() and not UIS:GetFocusedTextBox() then
                            rec.fired = true
                            DASH.orbDashedAt = t
                            dlog("ROTORB %.1f studs across (%.1f 3D), closing %.0f -> jump + dash into it", flat, gap, closing)
                            task.spawn(function()
                                lastInject = now()
                                pcall(function() VIM:SendKeyEvent(true, Enum.KeyCode.Space, false, game) end)
                                task.wait(0.05)
                                pcall(function() VIM:SendKeyEvent(false, Enum.KeyCode.Space, false, game) end)
                                task.wait(0.1)
                                if not part.Parent then return end
                                local cam = Workspace.CurrentCamera
                                if cam then pcall(function() cam.CFrame = CFrame.lookAt(cam.CFrame.Position, part.Position) end) end
                                sendDash(part.Position, "Toward the attack")
                            end)
                        end
                    elseif rec.star then
                        -- fight 2 (2026-09-29): 722 STAR triggers -- a star is THROWN out at 150-300
                        -- stud/s before it slows and drifts in, and that launch read as "about to
                        -- hit" from 90 studs (dashes while he was only summoning them). Now: ignored
                        -- for its first 0.9 s and whenever it moves > 70 stud/s. Then two triggers:
                        --  contact -- it drifts into you (dash just before it touches)
                        --  fuse    -- most go off ~4.3 s after spawning (3.2-5.8); the 17-stud blast
                        --             only hurt within ~10 studs, so a star still that close at 3.9 s
                        --             gets a dash timed over the detonation
                        local d = (pos - me).Magnitude
                        local gap = d - STAR_CONTACT
                        local closing = rec.lastGap and (rec.lastGap - gap) / dt or 0
                        rec.lastGap = gap
                        local launching = age < 0.9 or speed > 70
                        if launching then
                            rec.closing = nil
                        else
                            rec.closing = rec.closing and (rec.closing * 0.5 + closing * 0.5) or closing
                        end
                        local c = rec.closing or 0
                        local h = rec.impact
                        local when, why
                        if not launching and gap <= 12 then
                            local eta = gap <= 0.5 and 0.02 or (c > 2 and gap / c or math.huge)
                            -- (never closer than 0.15 s out: a dash planned for sooner can't be scheduled)
                            if eta <= 0.5 then when, why = t + math.max(eta, 0.15), string.format("white star touching in %.2fs (%.1f studs)", eta, gap) end
                        end
                        -- (fight 3: 84 stars went off 3.26-5.92 s after spawning, bulk 4.25-5.0, and the
                        -- one that started the death combo hit from 13.6 studs at age 3.6 -- no single
                        -- fuse moment a 0.7 s dash could sit on) -> from STAR_ARMED s on, a star within
                        -- STAR_BLAST studs gets a dash AWAY from it now: out of the blast + i-frames
                        if not when and age >= STAR_ARMED and d <= STAR_BLAST then
                            -- (t + 0.05 was unschedulable: tryDash's window closes DASH.from before the
                            -- hit, so all 33 of these in fight 5 were silently dropped)
                            when, why = t + 0.25, string.format("white star armed %.1fs, %.1f studs -> dash away", age, d)
                        end
                        -- a dash for this star already went out and it's still hanging around you:
                        -- allow another once that dash's i-frames are over
                        if h and h.t < t - 0.8 then rec.impact = nil; h = nil end
                        if when then
                            if h and h.t > t then
                                if when < h.t then h.t = when end
                            elseif not h then
                                impacts[#impacts + 1] = { t = when, reason = why, kind = "melee", from = pos, key = "WhiteStar",
                                                          unweavable = true, dashDir = "Away from the attack" }
                                rec.impact = impacts[#impacts]
                                dlog("STAR %s", why)
                            end
                        elseif h and h.t > t + 0.05 and d > STAR_BLAST + 4 and not attempt then
                            for i2, x in ipairs(impacts) do if x == h then table.remove(impacts, i2); break end end
                            rec.impact = nil
                            dlog("CANCEL white star drifted off (%.1f studs)", d)
                        end
                    elseif rec.proximity then
                        -- follow it in: weave just before it reaches you
                        local gap = (pos - me).Magnitude - HELLFIRE_CONTACT
                        local closing = rec.lastGap and (rec.lastGap - gap) / dt or 0
                        rec.lastGap = gap
                        if speed > 3 then rec.moving = true end
                        if rec.moving then
                            local trigger = math.max(HELLFIRE_CLOSE, closing * WINDOWS.land.lead)
                            if gap <= trigger then
                                rec.fired = true
                                local eta = closing > 1 and math.max(gap, 0) / closing or 0
                                want(t + math.max(eta, WINDOWS.land.lead), string.format("%s %.1f studs away", part.Name, gap),
                                    "land", pos, "Hellfire")
                            end
                        elseif rec.fallbackAt and age > 0.6 and t >= rec.fallbackAt - 0.4 then
                            -- (age > 0.6: give it time to start flying before assuming it never will)
                            -- never seen moving: fall back on the flight-time guess
                            rec.fired = true
                            want(rec.fallbackAt, part.Name .. " (flight-time guess)", "land", pos, "Hellfire")
                        end
                    elseif CFG.projectiles and speed > 15 and age > 0.03 and not PROJ_IGNORE[part.Name]
                       and not (MY_WEAPON_PARTS[part.Name] and not rec.pvp) then
                        -- TRAJECTORY: every frame, where is it heading and when does it get here.
                        -- On course -> a weave is queued and its time kept current (homing);
                        -- veers off before the weave goes out -> cancelled (a whiff costs ~1.4 s).
                        -- relative to YOU: a projectile you're running from arrives later, one
                        -- you strafe out of the line of passes wide (user: "if I'm moving during
                        -- any projectile it's inaccurate" -- the old math froze you in place)
                        local rel = me - pos
                        local rvel = vel - myVel
                        local rs2 = rvel:Dot(rvel)
                        local eta = rs2 > 1 and rel:Dot(rvel) / rs2 or -1
                        local reach = CFG.projMiss + math.max(part.Size.X, part.Size.Y, part.Size.Z) * 0.5
                        local miss = eta > 0 and (rel - rvel * eta).Magnitude or math.huge
                        local h = rec.impact
                        if eta > 0 and eta <= 0.8 and miss <= reach then
                            if h and h.t > t then
                                h.t = t + eta
                            elseif h == nil then   -- (false = cancelled once, never re-queued)
                                want(t + eta, string.format("projectile %s eta %.2fs miss %.1f", part.Name, eta, miss),
                                    "land", pos, part.Name)
                                rec.impact = impacts[#impacts]
                            end
                        elseif h and h.t > t + 0.02 and miss > reach * 1.6 then
                            for i, x in ipairs(impacts) do
                                if x == h then table.remove(impacts, i); break end
                            end
                            if CFG.verbose then log.info("[Weave] " .. part.Name .. " veered off, weave cancelled") end
                            dlog("CANCEL %s veered off", part.Name)
                            rec.impact = false   -- don't re-queue this one
                        end
                    elseif CFG.hitboxes and rec.pvp and speed <= 15 and coversMe(part, me, 1.5) then
                        -- enemy PLAYERS' AoE only (their hitboxes can have any name)
                        rec.fired = true
                        want(t + CFG.hitboxDelay, "enemy player hitbox " .. part.Name, "land", part.Position, "player:" .. part.Name)
                    end
                end
            end
        end
    end

    plan(t)
end

--------------------------------------------------------------------- lifecycle

-- ---- rot pillar (Festering Wound BigBeam) ------------------------------------------------
-- Tell: a star sparkle on YOU (IndicatorAttachment + "Star" on your Torso). The beam
-- (_TNBossFX.BigBeam, a 14-wide x 96-tall Hitbox, 20-wide FX ring) spawns 0.63-0.70 s
-- later and ticks 10.5 dmg every ~0.1 s from ~0.45 s after it spawns for ~1 s.
-- It does NOT land where you were at the marker: it aims ~0.33 s before it spawns (running
-- at 25 it landed 7.6-8.2 studs behind you, at 29-31 9.5-10 -- both = 0.33 s). So sliding
-- on the marker only moved the target (user: "sorta worked but not as intended"). Instead,
-- once the beam itself spawns (its position is known then, ~0.45 s before the first tick),
-- push straight out of it, and keep pushing while you're inside any live one.
-- Centre = the 20-wide ground ring (BigBeam.FX), NOT BigBeam.Hitbox: in the live fight the
-- Hitbox read 0.0-2.5 studs from you while the ring (where the damage went) was 7-13 away,
-- so pushing "out of the Hitbox" shoved you back into the ring (died to it).
-- Gas balls (RotOrb, CFG.orbMode "Push away") use the same push: kept DASH.orbReach studs away (ground
-- distance, learned from their hits) until they pop.
local PILLAR = { clear = 12.5, speed = 48 }
local pillars = {}               -- live BigBeam ground rings
local pillarLogAt = 0

local function flatDist(a, b) return Vector3.new(a.X - b.X, 0, a.Z - b.Z) end

local function pillarStep(dt)
    local usePillars = CFG.pillarDodge and #pillars > 0
    local useOrbs = CFG.orbMode == "Push away" and #DASH.orbs > 0
    local useEscapes = #DASH.escapes > 0
    if not (CFG.enabled and (usePillars or useOrbs or useEscapes)) then return end
    local r = root()
    if not r then return end
    local push, worst = Vector3.zero, 0
    for i = #DASH.escapes, 1, -1 do
        local e = DASH.escapes[i]
        if not e.root.Parent or now() > e.till then
            table.remove(DASH.escapes, i)
        else
            local off = flatDist(r.Position, e.root.Position)
            local depth = e.clear - off.Magnitude
            if depth > 0 and (not e.band or depth <= e.band) then
                local d = off.Magnitude > 0.3 and off.Unit or -Vector3.new(r.CFrame.LookVector.X, 0, r.CFrame.LookVector.Z).Unit
                push += d * depth
                worst = math.max(worst, depth)
            end
        end
    end
    for i = #DASH.orbs, 1, -1 do
        local orb = DASH.orbs[i]
        if not orb.Parent then
            table.remove(DASH.orbs, i)
        elseif useOrbs then
            -- GROUND distance: they hover above you, and 3D distance let them ragdoll you from
            -- 9+ studs with the push never starting (fight 2026-09-27: 7 of 29 orbs)
            local off = flatDist(r.Position, orb.Position)
            local depth = DASH.orbReach - off.Magnitude
            -- not the fast laser-phase "RotOrb"s flying overhead (see the jump + dash trigger)
            local slowNear = orb.AssemblyLinearVelocity.Magnitude <= 80
                             and (orb.Position - r.Position).Magnitude <= DASH.orbReach + 8
            if depth > 0 and slowNear then
                local d = off.Magnitude > 0.3 and off.Unit or nil
                if not d then                                  -- right above you: straight back
                    local lv = r.CFrame.LookVector
                    d = -Vector3.new(lv.X, 0, lv.Z).Unit
                end
                push += d * depth
                worst = math.max(worst, depth)
            end
        end
    end
    if not usePillars then table.clear(pillars) end
    for i = #pillars, 1, -1 do
        local hb = pillars[i]
        if not hb.Parent then
            table.remove(pillars, i)
        else
            local off = flatDist(r.Position, hb.Position)
            local depth = PILLAR.clear - off.Magnitude
            if depth > 0 then
                local d = off.Magnitude > 0.3 and off.Unit or nil
                if not d then                                  -- dead centre: straight back
                    local lv = r.CFrame.LookVector
                    d = -Vector3.new(lv.X, 0, lv.Z).Unit
                end
                push += d * depth
                worst = math.max(worst, depth)
            end
        end
    end
    if worst <= 0 or push.Magnitude < 0.01 then return end
    if now() - (pillarLogAt or 0) > 0.2 then
        pillarLogAt = now()
        dlog("PUSH inside a pillar / gas ball by %.1f -> pushing", worst)
    end
    local dir = push.Unit
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { LP.Character }
    params.RespectCanCollide = true
    local stepLen = math.min(PILLAR.speed * dt, worst + 0.3)
    -- a wall that way: slide along it instead (try 45/90 deg either side)
    for _, deg in ipairs({ 0, 45, -45, 90, -90 }) do
        local d = (CFrame.Angles(0, math.rad(deg), 0) * CFrame.new(Vector3.zero, dir)).LookVector
        d = Vector3.new(d.X, 0, d.Z).Unit
        if not Workspace:Raycast(r.Position, d * (stepLen + 1.5), params) then
            pcall(function() r.CFrame = r.CFrame + d * stepLen end)
            return
        end
    end
end

local function onPillarPart(part)
    if not (part.Name == "FX" and part.Parent and part.Parent.Name == "BigBeam") then return end
    pillars[#pillars + 1] = part
    local r = root()
    local hb = part.Parent:FindFirstChild("Hitbox")
    dlog("PILLAR ring %.1f studs from you (hitbox %.1f)", r and flatDist(r.Position, part.Position).Magnitude or -1,
        (r and hb) and flatDist(r.Position, hb.Position).Magnitude or -1)
    if CFG.verbose then log.info("[Weave] rot pillar -> moving out") end
end

-- ---- pushing bombs away ---------------------------------------------------------------
-- (user 2026-09-27: "I want it to push the bombs away") The Crowned Nothing's real bomb is a
-- plain UNANCHORED, colliding 1x1x1 Part straight in Workspace ("WhiteOrbBomb"): thrown at
-- ~20-27 stud/s, lands, pops ~1.52 s after spawning (WhiteOrbExplosionHitbox). The 2.5 glowing
-- one in _TNBossFX is an anchored visual and is left alone. A loose part near you is usually
-- simulated by YOUR client (network ownership), and then its velocity is yours to set and the
-- server sees it move. If the server kept ownership the shove only happens on your screen --
-- BOMBPUSH logs owner=true/false (isnetworkowner) so one fight tells which it is.
do
    -- (user: "flat out worked ... clean" -> "do that with the smiley bombs too") The smiley bombs
    -- are "Bomb" MeshParts, loose + unanchored like the orb: Workspace.PuppeteerBomb (1.6),
    -- Workspace.PuppeteerGiantBomb (8 -- 32-stud blast, so a wider push), Workspace.ThrownBomb
    -- (Clowns). The Bomb a Clown is still HOLDING lives in Monsters.Clown and is left alone.
    -- (user 2026-09-29: "the push doesn't work against smiley bombs, they have some form of AI
    -- on them which makes them jump" -- their own hopping overrides the shove. Only AI-less loose
    -- parts can be pushed, so the smiley bombs are off the list; their fuse weave still applies.
    -- WhiteOrbBomb stays: the Crowned Nothing's AND The Bell's orbs -- pushed whenever you own them.)
    local BOMB_NAMES = { WhiteOrbBomb = 18 }
    local BOMB_MODELS = {}
    local PUSH = { speed = 85, lift = 30, every = 0.08, bombs = {}, logged = setmetatable({}, { __mode = "k" }) }

    function Weave._bombSeen(part)
        if part.Anchored then return end
        local radius = BOMB_NAMES[part.Name]
        if not radius and part.Name == "Bomb" then
            local m = part.Parent
            radius = m and BOMB_MODELS[m.Name]
            -- (loose "Bomb" models = smiley bombs: AI-driven, not pushable)
        end
        if radius then PUSH.bombs[#PUSH.bombs + 1] = { part = part, at = 0, radius = radius } end
    end

    function Weave._bombPushStep()
        if not (CFG.enabled and CFG.bombPush) or #PUSH.bombs == 0 then return end
        local r = root()
        if not r then return end
        local t = now()
        for i = #PUSH.bombs, 1, -1 do
            local b = PUSH.bombs[i]
            local part = b.part
            if not part.Parent or part.Anchored then
                table.remove(PUSH.bombs, i)
            elseif t - b.at >= PUSH.every then
                local off = Vector3.new(part.Position.X - r.Position.X, 0, part.Position.Z - r.Position.Z)
                if off.Magnitude < b.radius then
                    b.at = t
                    local dir = off.Magnitude > 0.2 and off.Unit or -Vector3.new(r.CFrame.LookVector.X, 0, r.CFrame.LookVector.Z).Unit
                    pcall(function() part.AssemblyLinearVelocity = dir * PUSH.speed + Vector3.new(0, PUSH.lift, 0) end)
                    if not PUSH.logged[part] then
                        PUSH.logged[part] = true
                        local owner = "?"
                        if isnetworkowner then
                            local ok, v = pcall(isnetworkowner, part)
                            owner = ok and tostring(v) or "err"
                        end
                        dlog("BOMBPUSH %s %.1f studs away, owner=%s", part.Name, off.Magnitude, owner)
                    end
                end
            end
        end
    end
end

-- ---- PvP: enemy players' attacks -----------------------------------------------------
-- (user 2026-09-27: "auto weave doesn't work well in pvp") Only mobs' animations were ever
-- watched, so a player's swings never triggered anything (only their projectiles/hitboxes).
-- Player moves are NOT mob moves (other weapons, other timings -- user), so they get their OWN
-- table, learned from hits you take: a hostile player (hostilePlayer: not party / friend /
-- safe zone) within learnRange starting an Action anim is a candidate; a >=5 dmg hit
-- 0.1-1.5 s later nothing else explains is a sample; 3 samples within 0.15 s (and a hit on
-- >= 30% of its plays near you) -> learned, saved in veil.auto_weave.learned_pvp.
-- A do-block on purpose: this chunk is at Luau's 200 top-level-local limit.
do
    local PVP = { learnRange = 18, range = 16, facing = 100, learned = {}, samples = {},
                  plays = {}, seen = {}, hooked = {}, persist = nil }
    -- Core is NOT skipped: players' M1 combo swings play at Core priority (fight 2026-09-27);
    -- looped tracks (walk / idle) are still dropped
    local SKIP_PRIO = { [Enum.AnimationPriority.Idle] = true, [Enum.AnimationPriority.Movement] = true }
    -- Players on different weapons share attack anims with different timings (117662409096966:
    -- 0.59 / 0.74 / 0.83 across a lightning and a rot weapon) -> learn per anim @ held tool.
    local function weaponOf(char)
        local tool = char and char:FindFirstChildOfClass("Tool")
        return tool and tool.Name or "none"
    end

    local function save()
        if not PVP.persist then return end
        local parts = {}
        for id, sec in pairs(PVP.learned) do parts[#parts + 1] = id .. "=" .. string.format("%.2f", sec) end
        pcall(PVP.persist.set, "veil.auto_weave.learned_pvp", table.concat(parts, ","))
    end

    local function onPlayerAnim(pl, proot, track)
        if not (running and CFG.enabled and CFG.melee and CFG.pvp) then return end
        if track.Looped or SKIP_PRIO[track.Priority] then return end
        if not hostilePlayer(pl) then return end
        local anim = track.Animation
        local aid = anim and string.match(anim.AnimationId, "%d+")
        local r = root()
        if not (aid and r and proot.Parent) then return end
        local id = aid .. "@" .. weaponOf(pl.Character)
        local d = (proot.Position - r.Position).Magnitude
        local impact = PVP.learned[id]
        if impact then
            if d > PVP.range or facingDeg(proot.CFrame, r.Position) > PVP.facing then return end
            want(now() + impact, string.format("%s (player) %s (+%.2fs)", pl.Name, id, impact),
                "melee", proot.Position, "pvp:" .. id)
            impacts[#impacts].root, impacts[#impacts].range = proot, PVP.range + 3
        elseif d <= PVP.learnRange then
            PVP.seen[#PVP.seen + 1] = { id = id, t = now(), root = proot, label = pl.Name }
            PVP.plays[id] = (PVP.plays[id] or 0) + 1
            if #PVP.seen > 30 then table.remove(PVP.seen, 1) end
        end
    end

    function Weave._pvpHit(tHit)
        local r = root()
        if not r then return end
        local best, bestD
        for i = #PVP.seen, 1, -1 do
            local u = PVP.seen[i]
            local dt = tHit - u.t
            if dt > 1.5 then
                table.remove(PVP.seen, i)
            elseif dt >= 0.1 and u.root.Parent then
                local d = (u.root.Position - r.Position).Magnitude
                if not bestD or d < bestD then best, bestD = u, d end
            end
        end
        if not best or bestD > PVP.learnRange then return end
        local list = PVP.samples[best.id] or {}
        PVP.samples[best.id] = list
        list[#list + 1] = tHit - best.t
        dlog("PVPSAMPLE %s %s %.2f (%d)", best.label, best.id, tHit - best.t, #list)
        if #list >= 3 and #list / math.max(PVP.plays[best.id] or 1, 1) >= 0.3 then
            table.sort(list)
            for i = 1, #list - 2 do
                if list[i + 2] - list[i] <= 0.15 then
                    PVP.learned[best.id] = list[i + 1]
                    log.info(string.format("[Weave] learned PLAYER attack %s (%s): hits %.2f s after it starts",
                        best.id, best.label, list[i + 1]))
                    dlog("LEARN pvp %s %s %.2f", best.id, best.label, list[i + 1])
                    PVP.samples[best.id] = nil
                    save()
                    break
                end
            end
        end
    end

    local function hookPlayer(pl)
        local char = pl.Character
        if not char or PVP.hooked[char] then return end
        local hum = char:FindFirstChildOfClass("Humanoid")
        local proot = char:FindFirstChild("HumanoidRootPart")
        local animator = hum and hum:FindFirstChildOfClass("Animator")
        if not (animator and proot) then return end          -- retried on the next scan
        local list = {}
        PVP.hooked[char] = list
        list[#list + 1] = animator.AnimationPlayed:Connect(function(tr)
            local ok, err = pcall(onPlayerAnim, pl, proot, tr)
            if not ok and CFG.verbose then log.warn("[Weave] player anim: " .. tostring(err)) end
        end)
        list[#list + 1] = char.AncestryChanged:Connect(function(_, p)
            if p then return end
            for _, c in ipairs(list) do c:Disconnect() end
            PVP.hooked[char] = nil
        end)
    end

    function Weave._pvpScan()
        for _, pl in ipairs(Players:GetPlayers()) do
            if pl ~= LP then pcall(hookPlayer, pl) end
        end
    end

    function Weave._pvpStop()
        for _, list in pairs(PVP.hooked) do
            for _, c in ipairs(list) do pcall(function() c:Disconnect() end) end
        end
        table.clear(PVP.hooked)
        table.clear(PVP.seen)
    end

    function Weave._pvpLoad(persist)
        PVP.persist = persist
        local ok, v = pcall(function() return persist.get("veil.auto_weave.learned_pvp") end)
        if ok and type(v) == "string" then
            for id, sec in string.gmatch(v, "([^,=]+)=([%d%.]+)") do PVP.learned[id] = tonumber(sec) end
        end
    end
end

function Weave.start()
    if running then return end
    running = true
    task.spawn(function()
        local RS = game:GetService("ReplicatedStorage")
        local re = RS:FindFirstChild("WeaveBuffEvent", true) or RS:WaitForChild("Remotes", 10)
        if re and not re:IsA("RemoteEvent") then re = re:FindFirstChild("WeaveBuffEvent", true) end
        if re and re:IsA("RemoteEvent") and running then
            local card = RS:FindFirstChild("NotifyCardEvent", true)
            if card and card:IsA("RemoteEvent") then
                conns[#conns + 1] = card.OnClientEvent:Connect(function(title, _, _, _, tag)
                    if tag == "combat-zone" and type(title) == "string" then
                        zone = title
                        GENV.PantheonVeilZone = title
                        dlog("ZONE %s", title)
                        if CFG.verbose then log.info("[Weave] zone: " .. title) end
                    end
                end)
            end
            local cd = RS:FindFirstChild("AbilityCooldownEvent", true)
            if cd and cd:IsA("RemoteEvent") then
                conns[#conns + 1] = cd.OnClientEvent:Connect(function(name, info)
                    if name ~= "Double Jump" or type(info) ~= "table" then return end
                    local ok, sn = pcall(function() return Workspace:GetServerTimeNow() end)
                    local st, dur = tonumber(info.startTime), tonumber(info.duration) or 2
                    local left = (ok and st) and (st + dur - sn) or dur
                    djUntil = now() + math.clamp(left, 0, 5)
                    dlog("DJCD %.2f s", left)
                end)
            end
            conns[#conns + 1] = re.OnClientEvent:Connect(function(stacks)
                if tonumber(stacks) and tonumber(stacks) > 0 then lastCatch = now() end
                dlog("BUFF %s", tostring(stacks))
            end)
        end
    end)
    conns[#conns + 1] = RunService.Heartbeat:Connect(function()
        local ok, err = pcall(step)
        if not ok and CFG.verbose then log.warn("[Weave] step: " .. tostring(err)) end
    end)
    -- your own actions = key presses. Not your animations: every M1 swing plays one, and
    -- that would blank out enemy AoE for the whole fight. The weave key itself is skipped
    -- (our own presses would otherwise hide the hit we are dodging).
    conns[#conns + 1] = UIS.InputBegan:Connect(function(input)
        local ut = input.UserInputType
        if ut == Enum.UserInputType.Keyboard and (input.KeyCode == CFG.key or NOT_ABILITY[input.KeyCode]) then return end
        if ut == Enum.UserInputType.Keyboard or ut == Enum.UserInputType.MouseButton2 then
            myActionAt = math.max(myActionAt, now() + MY_ACTION_WINDOW)
        elseif ut == Enum.UserInputType.MouseButton1 then
            myActionAt = math.max(myActionAt, now() + M1_WINDOW)
        end
    end)
    -- your weave animation = proof the weave actually happened
    local function hookMyAnimator(char)
        local hum = char:WaitForChild("Humanoid", 10)
        local animator = hum and hum:WaitForChild("Animator", 10)
        if not (animator and running) then return end
        animHooked = true
        conns[#conns + 1] = animator.AnimationPlayed:Connect(function(tr)
            local a = tr.Animation
            local n = (a and a.Name ~= "Animation" and a.Name) or tr.Name
            if string.find(n, "Weave") then confirmWeave(now()) end
        end)
        local lastHp = hum.Health
        conns[#conns + 1] = hum.HealthChanged:Connect(function(v)
            if v < lastHp then onMyDamage(lastHp - v) end
            lastHp = v
        end)
        conns[#conns + 1] = char:GetAttributeChangedSignal("DodgeUntil"):Connect(function()
            local untilT = char:GetAttribute("DodgeUntil")
            if untilT == nil then return end
            confirmDash(now())
            -- measure THIS player's dash i-frames (gear changes them: the user's Evasion Scarf
            -- gives ~0.44 s; a base dash is shorter) and plan with the measured length
            local ok, serverNow = pcall(function() return Workspace:GetServerTimeNow() end)
            if ok and type(untilT) == "number" then
                local len = untilT - serverNow
                if len > 0.1 and len < 2 then
                    DASH.to = math.clamp(len - 0.04, 0.15, 1.5)
                    DASH.lead = math.clamp(DASH.to / 2, 0.1, 0.5)
                    dlog("DASHLEN i-frames %.2f s -> window %.2f, lead %.2f", len, DASH.to, DASH.lead)
                    -- a strafe dash: keep Rotation Lock on the attacker until this dash ends
                    if DASH.strafing then
                        DASH.strafeFaceEnd = math.max(DASH.strafeFaceEnd or 0, now() + len + 0.05)
                        pcall(function()
                            aimState.strafeFaceUntil = math.max(aimState.strafeFaceUntil or 0, os.clock() + len + 0.05)
                            aimState.dashBodyUntil = math.max(aimState.dashBodyUntil or 0, os.clock() + len + 0.05)
                        end)
                        dlog("STRAFELOCK facing held %.2f s (whole dash)", len + 0.05)
                    end
                end
            end
        end)
    end
    if LP.Character then task.spawn(hookMyAnimator, LP.Character) end
    conns[#conns + 1] = LP.CharacterAdded:Connect(function(c)
        animHooked = false
        task.spawn(hookMyAnimator, c)
    end)
    conns[#conns + 1] = Workspace.DescendantAdded:Connect(function(d)
        if d:IsA("BasePart") then pcall(onPart, d); pcall(onPillarPart, d) end
    end)
    conns[#conns + 1] = RunService.Heartbeat:Connect(function(dt)
        pcall(pillarStep, dt)
        if Weave._bombPushStep then pcall(Weave._bombPushStep) end
    end)
    local folder = Workspace:FindFirstChild("Monsters")
    if folder then
        conns[#conns + 1] = folder.ChildAdded:Connect(function(m)
            task.delay(0.2, function() pcall(hookMob, m) end)
        end)
    end
    task.spawn(function()
        while running do
            pcall(scanMobs)
            pcall(Weave._pvpScan)
            pcall(dlogFlush)
            task.wait(1)
        end
        pcall(dlogFlush)
    end)
    log.info("[Weave] started")
end

function Weave.stop()
    running = false
    table.clear(pillars)
    table.clear(DASH.orbs)
    table.clear(DASH.escapes)
    DASH.flee = nil
    guardM1(false)
    pcall(Weave._pvpStop)
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)
    for _, list in pairs(mobConns) do
        for _, c in ipairs(list) do pcall(function() c:Disconnect() end) end
    end
    table.clear(mobConns)
    table.clear(impacts)
    table.clear(bombs)
    table.clear(preds)
    table.clear(done)
    table.clear(unknownSeen)
    table.clear(watching)
    table.clear(dashes)
    attempt = nil
    animHooked = false
    table.clear(tracked)
end

local function parseExtra(text)
    table.clear(extra)
    for id, secs in string.gmatch(text or "", "(%d+)%s*=%s*([%d%.]+)") do
        extra[id] = tonumber(secs)
    end
end

-- Feature definition for the Veil menu (veil.lua adds it to its container).
function Weave.feature()
    return {
        id          = "veil.auto_weave",
        name        = "Auto Weave",
        description = "Presses your weave key so the weave is already active when a hit lands (it dodges everything landing while it's active). Melee swings are timed from the mob's attack animation, projectiles a mob launches are tracked until they're about to reach you (Imp fireballs are timed from when they appear), and the Puppeteer's bombs from their 4 s fuse. Explosions themselves are ignored: their damage lands on the frame they appear, too late to react to. Plans around the ~0.5 s cooldown so staggered hits from several mobs get covered, and retries while you're busy or stunned. Never reacts to your own or your party's stuff; players outside your party count as enemies. Raise 'Press before impact' if hits land right after a weave, lower it if they land before it. SETTINGS: Press before impact = how early a weave goes out (raise if hits land right after it, lower if before). Dash unweavables = dash attacks a weave can't stop (learned in play, or listed under Unweavables). Backup dash = also dash when a weave is on cooldown, only while a spare dash's worth of stamina is left. Boss first = while a boss is attacking you (not just nearby), its attacks come first: a small mob's hit is let through when weaving or dashing it could leave you without a weave or dash for the boss's. Unweavables = extra attacks to always dash (anim ids, or Bomb / Giant bomb / Hellfire / ImpFireball). Dash direction = where a dash goes when you aren't holding a movement key; Around the enemy = dash sideways along a circle around the attacker while your character stays turned to face it (get-away moves still dash away). Stamina reserve = stamina Auto Weave leaves for you. Enemy players = players outside your party (and their summons) count as enemies. Bombs & player AoE = Puppeteer bomb fuses and enemy players' area attacks. Player AoE delay = how long an enemy player's AoE takes to land after it appears. Extra attacks = add attack timings by hand as animId=seconds. Enchanted Sword mobility = for get-away moves (e.g. the Festering Wound's rapid ground punches) swap to your Enchanted Sword (if you own one), face away from the boss, launch, and swap back; it has no i-frames, so it never replaces a dash. Reflex weave = weave the moment an explosion lands on you (tested: usually too late). Console log = print every weave and its reason to the console (a decision log is always written to workspace/Veil_Combat).",
        default     = false,
        onToggle    = function(v)
            CFG.enabled = v and true or false
            if CFG.enabled then Weave.start() else Weave.stop() end
        end,
        settings = {
            { type = "dropdown", name = "Weave key", key = "key", options = { "F", "Q", "E", "R", "G", "V", "C" },
              default = "F",
              onChange = function(v) CFG.key = Enum.KeyCode[v] or Enum.KeyCode.F end },
            { type = "slider", name = "Press before impact (s)", key = "lead", min = 0.1, max = 0.45, step = 0.01,
              default = 0.25, onChange = function(v) CFG.lead = v end },
            { type = "toggle", name = "Dash unweavables", key = "dash", default = true,
              onChange = function(v) CFG.dash = v and true or false end },
            { type = "toggle", name = "Backup dash", key = "dash_backup",
              default = true, onChange = function(v) CFG.dashBackup = v and true or false end },
            { type = "slider", name = "Tank hits before dashing", key = "tank_hits", min = 0, max = 10, step = 1,
              default = 5, onChange = function(v) CFG.tankHits = v end },
            { type = "toggle", name = "Boss first", key = "boss_focus", default = true,
              onChange = function(v) CFG.bossFocus = v and true or false end },
            { type = "textbox", name = "Unweavables", key = "unweavable",
              placeholder = "Bomb, 107426583476702", default = "",
              onChange = function(v) parseUnweavable(v) end },
            { type = "toggle", name = "Enchanted Sword mobility", key = "sword_mobility", default = false,
              onChange = function(v) CFG.swordMobility = v and true or false end },
            { type = "dropdown", name = "Dash key", key = "dash_key", options = { "Q", "E", "R", "F", "G", "LeftControl" },
              default = "Q", onChange = function(v) CFG.dashKey = Enum.KeyCode[v] or Enum.KeyCode.Q end },
            { type = "dropdown", name = "Dash direction", key = "dash_dir",
              options = { "Away from the attack", "Sideways", "Around the enemy", "Where you're moving only" },
              default = "Away from the attack", onChange = function(v) CFG.dashDir = v end },
            { type = "slider", name = "Stamina reserve", key = "dash_reserve", min = 0, max = 100, step = 5,
              default = 0, onChange = function(v) CFG.dashReserve = v end },
            { type = "toggle", name = "Melee swings", key = "melee", default = true,
              onChange = function(v) CFG.melee = v and true or false end },
            { type = "slider", name = "Melee range (studs)", key = "melee_range", min = 6, max = 25, step = 1,
              default = 15, onChange = function(v) CFG.meleeRange = v end },
            { type = "slider", name = "Swing reach (studs)", key = "swing_reach", min = 5, max = 30, step = 0.5,
              default = 9, onChange = function(v) CFG.swingReach = v end },
            { type = "toggle", name = "Ignore swings at others", key = "target_check", default = true,
              onChange = function(v) CFG.targetCheck = v and true or false end },
            { type = "toggle", name = "Projectiles", key = "projectiles", default = true,
              onChange = function(v) CFG.projectiles = v and true or false end },
            { type = "toggle", name = "Enemy players", key = "pvp", default = true,
              onChange = function(v) CFG.pvp = v and true or false end },
            { type = "toggle", name = "Bombs & player AoE", key = "hitboxes", default = true,
              onChange = function(v) CFG.hitboxes = v and true or false end },
            { type = "slider", name = "Player AoE delay (s)", key = "hitbox_delay", min = 0, max = 1, step = 0.05,
              default = 0.3, onChange = function(v) CFG.hitboxDelay = v end },
            { type = "textbox", name = "Extra attacks", key = "extra",
              placeholder = "117802002100480=0.74", default = "",
              onChange = function(v) parseExtra(v) end },
            { type = "toggle", name = "Dodge rot pillars", key = "pillar_dodge", default = true,
              onChange = function(v) CFG.pillarDodge = v and true or false end },
            { type = "dropdown", name = "Jump over slams with", key = "jump_style", options = { "Single jump", "Double jump" },
              default = "Single jump", onChange = function(v) CFG.jumpStyle = v end },
            { type = "toggle", name = "Get out of range of ground punches", key = "escape_push", default = true,
              onChange = function(v) CFG.escapePush = v and true or false end },
            { type = "toggle", name = "Push bombs away", key = "bomb_push", default = true,
              onChange = function(v) CFG.bombPush = v and true or false end },
            { type = "dropdown", name = "Gas balls", key = "orb_mode", options = { "Jump + dash into it", "Push away", "Off" },
              default = "Jump + dash into it", onChange = function(v)
                  if v == "Dash + pull in" then v = "Jump + dash into it" end   -- saved by the old build
                  CFG.orbMode = v
              end },
            { type = "toggle", name = "Reflex weave", key = "reflex", default = false,
              onChange = function(v) CFG.reflex = v and true or false end },
            { type = "button", name = "Forget learned attacks",
              onClick = function()
                  table.clear(learnedAttacks); table.clear(attackSamples); table.clear(attackPlays)
                  table.clear(learned); table.clear(verdict)
                  saveLearned()
                  log.info("[Weave] learned attacks / unweavables cleared")
              end },
            { type = "toggle", name = "Console log", key = "verbose", default = false,
              onChange = function(v) CFG.verbose = v and true or false end },
        },
    }
end

-- textbox values are not replayed at boot by feature.lua, so load the saved one here
function Weave.loadSaved(persist)
    persistRef = persist
    local okL, l = pcall(function() return persist.get("veil.auto_weave.learned_attacks") end)
    if okL and type(l) == "string" then
        for id, sec in string.gmatch(l, "(%d+)=([%d%.]+)") do
            if not NEVER_LEARN[id] then learnedAttacks[id] = tonumber(sec) end
        end
        saveLearned()   -- drops blacklisted entries from the saved list too
    end
    pcall(Weave._pvpLoad, persist)
    local okO, orr = pcall(function() return persist.get("veil.auto_weave.orb_reach") end)
    if okO and tonumber(orr) then DASH.orbReach = math.max(12, tonumber(orr)) end
    local okR, rr = pcall(function() return persist.get("veil.auto_weave.escape_reach") end)
    if okR and type(rr) == "string" then
        for id, n in string.gmatch(rr, "(%d+)=([%d%.]+)") do DASH.reach[id] = tonumber(n) end
    end
    local okU, u = pcall(function() return persist.get("veil.auto_weave.unweavable") end)
    if okU and type(u) == "string" then parseUnweavable(u) end
    local ok, v = pcall(function() return persist.get("veil.auto_weave.extra") end)
    if ok and type(v) == "string" then parseExtra(v) end
end

return Weave
