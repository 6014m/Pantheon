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
    meleeRange   = 12,      -- mob must be this close when its swing starts
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
    dashDir      = "Away from the attack",
}

-- attack animation -> seconds from anim start to damage (median of clean hits on you)
local ATTACKS = {
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
    ["120338508145604"] = 0.42,  -- Cursed Hammer smash, 1st hit (2nd below)
    ["115142136659049"] = 1.03,  -- Starving Warrior lunging slash (1.02-1.05, 32 dmg, from 11-19 studs)
    ["91438445642768"]  = 0.56,  -- Gigazapper zap (0.55 / 0.57 / 0.55, 27.6 dmg) -- Martian Saucer add
    ["91414483216673"]  = 0.50,  -- Gigazapper second attack (1 sample)
    ["123223658247605"] = 0.72,  -- Turret Golem up close (0.69 / 0.75, 25 dmg); from range it fires a
                                 -- LaserProjectile, which the trajectory tracker handles
}

-- attacks that land more than once: extra hits (seconds after the anim starts)
local EXTRA_HITS = {
    ["120338508145604"] = { 0.90 },   -- Cursed Hammer smash lands twice (0.42, 0.90)
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
    ["117802002100480"] = 18,    -- Minotaur swing starts 11-14 studs out, closing ~15 stud/s
    ["131201775492062"] = 20,    -- Enchanted Sword slash reached 19 studs
    ["120338508145604"] = 14,    -- Cursed Hammer smash lunges in (closing ~15 stud/s)
    ["115142136659049"] = 21,    -- Starving Warrior slash reached 19 studs
    ["123223658247605"] = 14,    -- Turret Golem close-range hit (beyond this it's the laser)
    ["102522251341739"] = 90,    -- Ancient Bones spike erupts under you ~0.65 s later, even from 57-85 studs
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
local NEVER_LEARN = { ["110431028319368"] = true }
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
    -- Cursed Hammer leap slam: starts ~28 studs out, its smash hitbox appears ~1.54 s later
    -- (1 recorded sample -- a first guess)
    ["136161739984425"] = { impact = 1.54, range = 35, facing = 30, kind = "land" },
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

local function weaveReadyAt(t)
    local last = done[#done]
    if not last then return -math.huge end
    if lastCatch >= last - 0.05 then return last + CFG.cooldown end   -- caught: short cooldown
    if t < last + 0.55 then return last + CFG.cooldown end            -- verdict still pending
    return last + WHIFF_LOCK                                           -- whiffed: locked out
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
local DASH = { from = 0.05, to = 0.40, lead = 0.20, cost = 50, cooldown = 0.45, afterWeave = 0.25 }
local dashes = {}          -- confirmed dash start times
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

-- Dash direction: if you're already holding a movement key, the dash goes where you're
-- going. Otherwise hold the camera-relative key pointing away from the attack (or sideways
-- to it) for the press.
local function dashKeyFor(threat, mode)
    for _, k in ipairs(MOVE_KEYS) do
        if UIS:IsKeyDown(k) then return nil end
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
    local f = Vector3.new(cam.CFrame.LookVector.X, 0, cam.CFrame.LookVector.Z)
    local rt = Vector3.new(cam.CFrame.RightVector.X, 0, cam.CFrame.RightVector.Z)
    local df, dr = away:Dot(f.Unit), away:Dot(rt.Unit)
    if math.abs(df) >= math.abs(dr) then
        return df > 0 and Enum.KeyCode.W or Enum.KeyCode.S
    end
    return dr > 0 and Enum.KeyCode.D or Enum.KeyCode.A
end

local function sendDash(threat, mode)
    local dir = dashKeyFor(threat, mode)
    lastInject = now()
    pcall(function()
        if dir then VIM:SendKeyEvent(true, dir, false, game) end
        VIM:SendKeyEvent(true, CFG.dashKey, false, game)
    end)
    task.delay(0.08, function()
        pcall(function()
            VIM:SendKeyEvent(false, CFG.dashKey, false, game)
            if dir then VIM:SendKeyEvent(false, dir, false, game) end
        end)
    end)
end

local function confirmDash(t)
    dashes[#dashes + 1] = t
    if #dashes > 8 then table.remove(dashes, 1) end
    if attempt and attempt.dash then
        weaves += 1
        if CFG.verbose then log.info(string.format("[Weave] #%d DASH %s", weaves, attempt.reason)) end
        dlog("DASH %s dir=%s", attempt.reason, tostring(attempt.dashDir or CFG.dashDir))
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
    local explained = false
    for _, h in ipairs(impacts) do
        if math.abs(h.t - t) <= 0.3 then explained = true; break end
    end
    for _, w in ipairs(watching) do   -- a known, weaved hit that got through
        if math.abs(w.t - t) <= 0.3 then explained = true; break end
    end
    if not explained and sampleUnknownRef then pcall(sampleUnknownRef, t) end
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

local function covered(h)
    if not (h.unweavable or isUnweavable(h.key)) then
        for _, p in ipairs(done) do if coversHit(p, h) then return true end end
    end
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
    if attempt.dash then return dashCovers(attempt.started, h) end
    return not (h.unweavable or isUnweavable(h.key)) and coversHit(attempt.started, h)
end

-- kind: "melee" (timed from an animation) or "land" (projectile / bomb / explosion)
local function want(impact, reason, kind, from, key)
    impacts[#impacts + 1] = { t = impact, reason = reason, kind = kind or "melee", from = from, key = key }
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
    local st = stamina()
    if st < DASH.cost + CFG.dashReserve + (primary and 0 or DASH.cost) then
        if primary then dlog("NODASH %s (stamina %.0f)", h.reason, st) end
        return false
    end
    local pe = pingExtra()
    local earliest = math.max(t, (dashes[#dashes] or -math.huge) + DASH.cooldown,
                              (done[#done] or -math.huge) + DASH.afterWeave)
    -- (a dash is exactly what covers a hit that lands in a whiff lockout)
    local lo, hi = h.t - DASH.to - pe, h.t - DASH.from - pe
    local loNow = math.max(lo, earliest)
    if loNow > hi then return false end
    if t >= math.clamp(h.t - DASH.lead - pe, loNow, hi) then
        if UIS:GetFocusedTextBox() or not alive() then return false end
        attempt = { started = t, lastPress = t, deadline = hi, reason = h.reason, dash = true, from = h.from,
                    dashDir = h.dashDir }
        dlog("PRESS dash for %s (hit in %.2f, stamina %.0f)", h.reason, h.t - t, stamina())
        sendDash(h.from, h.dashDir)
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

local function plan(t)
    settleWatching(t)
    -- drop past and covered hits
    local me = root()
    for i = #impacts, 1, -1 do
        local h = impacts[i]
        local gone = h.root and (not h.root.Parent or not me or (h.root.Position - me.Position).Magnitude > h.range)
        if h.t < t - 0.05 or gone or covered(h) then table.remove(impacts, i) end
    end
    if attempt then
        if t > attempt.deadline then
            if CFG.verbose then log.info("[Weave] game refused every press (busy / stun / cooldown): " .. attempt.reason) end
            dlog("REFUSED %s %s", attempt.dash and "dash" or "weave", attempt.reason)
            attempt = nil
        elseif t - attempt.lastPress >= RETRY then
            attempt.lastPress = t
            if attempt.dash then sendDash(attempt.from, attempt.dashDir) else sendKey() end
        end
        return
    end
    local open = {}
    for _, h in ipairs(impacts) do
        if not handled(h) and (not h.cond or h.cond()) then open[#open + 1] = h end
    end
    if #open == 0 then return end
    table.sort(open, function(a, b) return a.t < b.t end)

    -- unweavable: dash it (if even a dash can't, a weave is still better than nothing)
    for _, h in ipairs(open) do
        if (h.unweavable or isUnweavable(h.key)) and h.t - t < 0.6 then
            if tryDash(t, h, true) then return end
            if h.unweavable then
                -- a channel (Minotaur charge) with no dash available: a weave is useless, drop it
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

-- Recorded whiff rates (weave pressed for it, no WeaveBuffEvent): Shrouded Apparition (the
-- shadow clones) 3 of 4, Cambion's close swing 127688919744763 26 of 37 -- a whiff costs a
-- ~1.4 s lockout, so these are left alone. (The real Shrouded: 40 caught, 3 whiffed.)
local SKIP_MOBS = { ["Shrouded Apparition"] = true }
local SKIP_ATTACK_FOR = { ["127688919744763"] = { Cambion = true } }

local function onMobAnim(model, mroot, track)
    if not (running and CFG.enabled and CFG.melee) then return end
    if SKIP_MOBS[model.Name] then return end
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
    local channel = CHANNELS[id]
    if channel then
        local r0 = root()
        if r0 and mroot.Parent and (mroot.Position - r0.Position).Magnitude <= channel.range then
            -- an unweavable hit "now": the planner dashes it straight away, away from the mob
            channelUntil[model] = now() + 3.2
            impacts[#impacts + 1] = { t = now() + DASH.lead, reason = channel.name, kind = "melee",
                                      from = mroot.Position, key = channel.name, unweavable = true }
        end
        return
    end
    local ranged = RANGED[id]
    local impact = extra[id] or ATTACKS[id] or learnedAttacks[id] or (ranged and ranged.impact)
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
    -- if you've moved out of its reach by the time it lands, the swing whiffs -- and so would
    -- a weave (1.4 s lockout). The planner drops hits whose attacker is out of range.
    impacts[#impacts].root, impacts[#impacts].range = mroot, range + 3
    local stillBeyond = STILL_ONLY_BEYOND[id]
    if stillBeyond and (mroot.Position - r.Position).Magnitude > stillBeyond then
        impacts[#impacts].cond = function() return myHorizontalSpeed() < 8 end
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
    -- no waiting in line: drop any weave being retried and dash right now
    if attempt and not attempt.dash then attempt = nil end
    if not tryDash(now(), h, true) then
        impacts[#impacts + 1] = h   -- dash on cooldown: the planner retries it for the next moments
    end
end

local function hookMob(model)
    if mobConns[model] or not model:IsA("Model") then return end
    -- summons are hooked too: an enemy player's (or a mob's) summon attacks like any mob.
    -- Yours / your party's are filtered per attack in onMobAnim (ownership can change).
    if model == LP.Character or Players:GetPlayerFromCharacter(model) then return end
    local hum = model:FindFirstChildOfClass("Humanoid")
    local mroot = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
    local animator = hum and model:FindFirstChildWhichIsA("Animator", true)
    if not (hum and mroot and animator) then return end   -- retried on the next scan
    local list = {}
    mobConns[model] = list
    mobRoots[model] = mroot
    list[#list + 1] = animator.AnimationPlayed:Connect(function(tr)
        local ok, err = pcall(onMobAnim, model, mroot, tr)
        if not ok and CFG.verbose then log.warn("[Weave] anim: " .. tostring(err)) end
    end)
    if deathBlastReach(model.Name) then
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
    if not folder then return end
    for _, m in ipairs(folder:GetChildren()) do pcall(hookMob, m) end
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

local function hostilePlayer(pl)
    if not pl or pl == LP then return false end
    if not CFG.pvp then return false end
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
local MY_WEAPON_PARTS = { ShatterStab = true, ShatterProjectile = true }

local function onPart(part)
    if not (running and CFG.enabled) or not part:IsA("BasePart") then return end
    if IGNORE_PARTS[part.Name] then return end
    if inWorldFolder(part) then return end
    local char = LP.Character
    if char and part:IsDescendantOf(char) then return end
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

local function stepRushes(t, me)
    if not CFG.melee then return end
    for model, mroot in pairs(mobRoots) do
        local fresh = t - (rushQueued[model] or -math.huge) <= 0.8
        if mroot.Parent and not (channelUntil[model] and t < channelUntil[model]) then
            local pos = mroot.Position
            local rel = me - pos
            if rel.Magnitude < 70 then
                local vel = mroot.AssemblyLinearVelocity
                local speed = vel.Magnitude
                if speed >= RUSH_SPEED and rel.Magnitude > 0.5 and vel:Dot(rel.Unit) >= RUSH_SPEED * 0.8 then
                    local eta = rel:Dot(vel) / (speed * speed)
                    local miss = (rel - vel * eta).Magnitude
                    if eta > 0 and eta <= 0.7 and miss <= RUSH_MISS and classify(model) ~= "friendly" then
                        local h = rushImpact[model]
                        if fresh and h and h.t > t then
                            -- same rush, still accelerating: keep the arrival time current
                            h.t = t + eta
                        elseif not fresh then
                            rushQueued[model] = t
                            want(t + eta, string.format("%s rushing through you (%.0f stud/s)", model.Name, speed),
                                "melee", pos, "rush:" .. model.Name)
                            rushImpact[model] = impacts[#impacts]
                        end
                    end
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
        stepBombs(t, me)
        stepRushes(t, me)
        for part, rec in pairs(tracked) do
            local age = t - rec.first
            if not part.Parent or age > 4 or rec.fired then
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
                    if rec.proximity then
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
                        local rel = me - pos
                        local eta = rel:Dot(vel) / (speed * speed)
                        local reach = CFG.projMiss + math.max(part.Size.X, part.Size.Y, part.Size.Z) * 0.5
                        local miss = eta > 0 and (rel - vel * eta).Magnitude or math.huge
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

function Weave.start()
    if running then return end
    running = true
    task.spawn(function()
        local RS = game:GetService("ReplicatedStorage")
        local re = RS:FindFirstChild("WeaveBuffEvent", true) or RS:WaitForChild("Remotes", 10)
        if re and not re:IsA("RemoteEvent") then re = re:FindFirstChild("WeaveBuffEvent", true) end
        if re and re:IsA("RemoteEvent") and running then
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
        -- our own injected dash (Q + direction) isn't you using an ability
        if ut == Enum.UserInputType.Keyboard and input.KeyCode == CFG.dashKey and now() - lastInject < 0.15 then return end
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
            if char:GetAttribute("DodgeUntil") ~= nil then confirmDash(now()) end
        end)
    end
    if LP.Character then task.spawn(hookMyAnimator, LP.Character) end
    conns[#conns + 1] = LP.CharacterAdded:Connect(function(c)
        animHooked = false
        task.spawn(hookMyAnimator, c)
    end)
    conns[#conns + 1] = Workspace.DescendantAdded:Connect(function(d)
        if d:IsA("BasePart") then pcall(onPart, d) end
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
            pcall(dlogFlush)
            task.wait(1)
        end
        pcall(dlogFlush)
    end)
    log.info("[Weave] started")
end

function Weave.stop()
    running = false
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
        description = "Presses your weave key so the weave is already active when a hit lands (it dodges everything landing while it's active). Melee swings are timed from the mob's attack animation, projectiles a mob launches are tracked until they're about to reach you (Imp fireballs are timed from when they appear), and the Puppeteer's bombs from their 4 s fuse. Explosions themselves are ignored: their damage lands on the frame they appear, too late to react to. Plans around the ~0.5 s cooldown so staggered hits from several mobs get covered, and retries while you're busy or stunned. Never reacts to your own or your party's stuff; players outside your party count as enemies. Raise 'Press before impact' if hits land right after a weave, lower it if they land before it. SETTINGS: Press before impact = how early a weave goes out (raise if hits land right after it, lower if before). Dash unweavables = dash attacks a weave can't stop (learned in play, or listed under Unweavables). Backup dash = also dash when a weave is on cooldown, only while a spare dash's worth of stamina is left. Unweavables = extra attacks to always dash (anim ids, or Bomb / Giant bomb / Hellfire / ImpFireball). Dash direction = where a dash goes when you aren't holding a movement key. Stamina reserve = stamina Auto Weave leaves for you. Enemy players = players outside your party (and their summons) count as enemies. Bombs & player AoE = Puppeteer bomb fuses and enemy players' area attacks. Player AoE delay = how long an enemy player's AoE takes to land after it appears. Extra attacks = add attack timings by hand as animId=seconds. Reflex weave = weave the moment an explosion lands on you (tested: usually too late). Console log = print every weave and its reason to the console (a decision log is always written to workspace/Veil_Combat).",
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
            { type = "textbox", name = "Unweavables", key = "unweavable",
              placeholder = "Bomb, 107426583476702", default = "",
              onChange = function(v) parseUnweavable(v) end },
            { type = "dropdown", name = "Dash key", key = "dash_key", options = { "Q", "E", "R", "F", "G", "LeftControl" },
              default = "Q", onChange = function(v) CFG.dashKey = Enum.KeyCode[v] or Enum.KeyCode.Q end },
            { type = "dropdown", name = "Dash direction", key = "dash_dir",
              options = { "Away from the attack", "Sideways", "Where you're moving only" },
              default = "Away from the attack", onChange = function(v) CFG.dashDir = v end },
            { type = "slider", name = "Stamina reserve", key = "dash_reserve", min = 0, max = 100, step = 5,
              default = 0, onChange = function(v) CFG.dashReserve = v end },
            { type = "toggle", name = "Melee swings", key = "melee", default = true,
              onChange = function(v) CFG.melee = v and true or false end },
            { type = "slider", name = "Melee range (studs)", key = "melee_range", min = 6, max = 25, step = 1,
              default = 12, onChange = function(v) CFG.meleeRange = v end },
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
    local okU, u = pcall(function() return persist.get("veil.auto_weave.unweavable") end)
    if okU and type(u) == "string" then parseUnweavable(u) end
    local ok, v = pcall(function() return persist.get("veil.auto_weave.extra") end)
    if ok and type(v) == "string" then parseExtra(v) end
end

return Weave
