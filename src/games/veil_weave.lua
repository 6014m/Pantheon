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

local CFG = {
    enabled      = false,
    key          = Enum.KeyCode.F,
    lead         = 0.25,    -- press this long before impact (measured sweet spot at 46 ms ping)
    basePing     = 0.046,   -- ping the lead was measured at; extra ping adds to the lead
    cooldown     = 0.5,     -- presses closer than this are ignored by the game
    meleeRange   = 12,      -- mob must be this close when its swing starts
    meleeFacing  = 80,      -- and facing within this many degrees of you
    melee        = true,
    projectiles  = true,
    projMiss     = 4,       -- a projectile passing closer than this counts as a hit
    hitboxes     = true,
    hitboxDelay  = 0.3,     -- static AoE hitboxes: seconds after they cover you before weaving
    pvp          = true,
    reflex       = true,    -- weave the moment a mob explosion lands on you, if nothing else is planned    -- other players outside your party (and their summons) are enemies
    verbose      = false,   -- print every weave and its reason to the console
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
}
local extra = {}   -- user-added "id=seconds" pairs from the settings textbox

-- aimed ranged attacks timed from the shooting animation: hit lands `impact` s after it
-- starts, from any distance up to `range`, only when the shooter is aiming at you
local RANGED = {
    -- Cambion's shot: 9.2 dmg ~0.43 s after the anim starts at 19-62 studs alike (practically
    -- hitscan); fires in bursts ~0.52 s apart
    ["103401623213387"] = { impact = 0.43, range = 80, facing = 20 },
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
local TIMED_PROJ = {
    ImpFireball = { hold = 0.12, speed = 59, maxDist = 34 },
}
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

local function confirmWeave(t)
    done[#done + 1] = t
    if #done > 8 then table.remove(done, 1) end
    if attempt then
        weaves += 1
        if CFG.verbose then
            log.info(string.format("[Weave] #%d %s (%.0f ms after first press)", weaves, attempt.reason,
                (t - attempt.started) * 1000))
        end
        attempt = nil
    end
end

-- ---- weave windows ----------------------------------------------------------
-- WHEN a weave has to start depends on how the hit arrives. Measured over every recorded
-- weave (sessions 2-6) against the moment the damage landed:
--   melee swing / aimed shot  start 0.14-0.36 s before the hit  (at 0.25: 1 hit in 172)
--   landing (fireball, bomb,  start 0.02-0.21 s before it lands (0 hits in 59 fireballs,
--   explosion, projectile)    1 in 27 explosions) -- basically "the moment it lands"
-- Weaving earlier than the window gets you hit (the weave is over before the hit lands).
local WINDOWS = {
    melee = { from = 0.14, to = 0.36, lead = 0.25 },
    land  = { from = 0.02, to = 0.21, lead = 0.10 },
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
}

local function covered(h)
    for _, p in ipairs(done) do if coversHit(p, h) then return true end end
    return false
end

-- handled = a weave covers it, or the one being pressed right now will
local function handled(h)
    if covered(h) then return true end
    return attempt ~= nil and coversHit(attempt.started, h)
end

-- kind: "melee" (timed from an animation) or "land" (projectile / bomb / explosion)
local function want(impact, reason, kind)
    impacts[#impacts + 1] = { t = impact, reason = reason, kind = kind or "melee" }
end

local function reflex(t, reason)
    if attempt or not CFG.reflex then return end
    local lastDone = done[#done] or -math.huge
    if t < lastDone + CFG.cooldown then return end
    for _, h in ipairs(impacts) do
        if h.t - t < 0.9 and not covered(h) then return end   -- the planner has something coming
    end
    if UIS:GetFocusedTextBox() or not alive() then return end
    attempt = { started = t, lastPress = t, deadline = t + 0.12, reason = "reflex: " .. reason }
    sendKey()
    if not animHooked then confirmWeave(t) end
end

local function plan(t)
    -- drop past and covered hits
    for i = #impacts, 1, -1 do
        local h = impacts[i]
        if h.t < t - 0.05 or covered(h) then table.remove(impacts, i) end
    end
    if attempt then
        if t > attempt.deadline then
            if CFG.verbose then log.info("[Weave] game refused every press (busy / stun / cooldown): " .. attempt.reason) end
            attempt = nil
        elseif t - attempt.lastPress >= RETRY then
            attempt.lastPress = t
            sendKey()
        end
        return
    end
    local open = {}
    for _, h in ipairs(impacts) do
        if not handled(h) then open[#open + 1] = h end
    end
    if #open == 0 then return end
    table.sort(open, function(a, b) return a.t < b.t end)

    local lastDone = done[#done] or -math.huge
    local cdEnd = lastDone + CFG.cooldown
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
        if math.max(nlo, earliest) <= nhi - 0.025 then
            lo, hi, idealSum, n = nlo, nhi, idealSum + i2, i
        else
            break
        end
    end
    local loNow = math.max(lo, earliest)
    if loNow > hi then
        -- can't make even the first one (cooldown / too late): undodgeable, drop it
        if CFG.verbose then log.info("[Weave] can't cover: " .. open[1].reason) end
        for i, h in ipairs(impacts) do if h == open[1] then table.remove(impacts, i); break end end
        return
    end
    local target = math.clamp(idealSum / n, loNow, hi)

    -- be ready for the next hit after this group: known, or a nearby mob's predicted attack
    local nextHit = open[n + 1]
    local me = root()
    for model, pr in pairs(preds) do
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

local function onMobAnim(model, mroot, track)
    if not (running and CFG.enabled and CFG.melee) then return end
    if isSummon(model) and classify(model) == "friendly" then return end
    local anim = track.Animation
    local id = anim and string.match(anim.AnimationId, "%d+")
    if not id then return end
    local ranged = RANGED[id]
    local impact = extra[id] or ATTACKS[id] or (ranged and ranged.impact)
    if not impact then return end
    local r = root()
    if not r or not mroot.Parent then return end
    local range = ranged and ranged.range or CFG.meleeRange
    if (mroot.Position - r.Position).Magnitude > range then return end
    if facingDeg(mroot.CFrame, r.Position) > (ranged and ranged.facing or CFG.meleeFacing) then return end
    local t0 = now()
    want(t0 + impact, string.format("%s %s %s (+%.2fs)", model.Name, ranged and "shot" or "swing", id, impact), "melee")
    -- its next swing can't land before this (the mob's attack rhythm)
    preds[model] = { t = t0 + (REATTACK[id] or 1.28) + impact, root = mroot, kind = "melee", range = range + 6 }
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
    list[#list + 1] = animator.AnimationPlayed:Connect(function(tr)
        local ok, err = pcall(onMobAnim, model, mroot, tr)
        if not ok and CFG.verbose then log.warn("[Weave] anim: " .. tostring(err)) end
    end)
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
local function nearestSource(pos)
    local best, bestD = "friendly", math.huge
    for _, pl in ipairs(Players:GetPlayers()) do
        local c = pl.Character
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
    return best
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
local BOMB_FUSE = 4.03        -- spawn -> damage (fit to the 17 fuse hits: -0.1 s vs the 4.12 lifetime)
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
                want(now() + 0.15, "bomb went off", "land")
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
                    want(impact, string.format("%sbomb fuse (%.0f studs)", b.giant and "giant " or "", d), "land")
                end
            elseif t > impact + 1 then
                b.queued = true   -- a long-fuse bomb: only the "went off" fallback is left
            end
        end
    end
end

local looked, lookedAt = 0, 0
local function onPart(part)
    if not (running and CFG.enabled) or not part:IsA("BasePart") then return end
    if IGNORE_PARTS[part.Name] then return end
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
    if looked > 150 and not TIMED_PROJ[part.Name] and not REFLEX[part.Name] then return end
    -- inside you / party / friends / their summons: never. Inside a mob or an enemy player
    -- only named hostile parts count (limbs, accessories and tools are not attacks)
    local owner = insideHumanoidModel(part)
    if owner and (isFriendlyModel(owner) or not HOSTILE_PARTS[part.Name]) then return end
    local r = root()
    if not r or (part.Position - r.Position).Magnitude > 250 then return end
    tracked[part] = { first = t, pos = part.Position, t = t, fired = false }
end

-- per frame: projectile ETA and hitbox coverage for tracked parts, then due weaves
local function step()
    if not (running and CFG.enabled) then return end
    local t = now()
    local r = root()
    if r then
        local me = r.Position
        stepBombs(t, me)
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
                if not src and ((part.Position - me).Magnitude >= OWN_RADIUS or TIMED_PROJ[part.Name]) then
                    src = nearestSource(part.Position)
                end
                rec.pvp = (src == "hostile")
                local timed = TIMED_PROJ[part.Name]
                if REFLEX[part.Name] and not isMine(part, rec) and coversMe(part, me, 1.5) then
                    rec.fired = true
                    reflex(t, part.Name)
                    timed = nil
                end
                if timed and CFG.projectiles and (src == "mob" or src == "hostile") and not isMine(part, rec) then
                    local d = (part.Position - me).Magnitude
                    rec.fired = true
                    if d <= timed.maxDist then
                        want(rec.first + timed.hold + d / timed.speed, string.format("%s (%.0f studs)", part.Name, d), "land")
                    end
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
                    if CFG.projectiles and speed > 15 and age > 0.03 and not PROJ_IGNORE[part.Name] then
                        local rel = me - pos
                        local eta = rel:Dot(vel) / (speed * speed)
                        if eta > 0 then
                            local miss = (rel - vel * eta).Magnitude
                            if miss <= CFG.projMiss + math.max(part.Size.X, part.Size.Y, part.Size.Z) * 0.5
                               and eta <= 0.8 then
                                rec.fired = true
                                want(t + eta, string.format("projectile %s eta %.2fs miss %.1f", part.Name, eta, miss), "land")
                            end
                        end
                    elseif CFG.hitboxes and rec.pvp and speed <= 15 and coversMe(part, me, 1.5) then
                        -- enemy PLAYERS' AoE only (their hitboxes can have any name)
                        rec.fired = true
                        want(t + CFG.hitboxDelay, "enemy player hitbox " .. part.Name, "land")
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
            task.wait(1)
        end
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
        description = "Presses your weave key so the weave is already active when a hit lands (it dodges everything landing while it's active). Melee swings are timed from the mob's attack animation, projectiles a mob launches are tracked until they're about to reach you (Imp fireballs are timed from when they appear), and the Puppeteer's bombs from their 4 s fuse. Explosions themselves are ignored: their damage lands on the frame they appear, too late to react to. Plans around the ~0.5 s cooldown so staggered hits from several mobs get covered, and retries while you're busy or stunned. Never reacts to your own or your party's stuff; players outside your party count as enemies. Raise 'Press before impact' if hits land right after a weave, lower it if they land before it.",
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
            { type = "toggle", name = "Melee swings", key = "melee", default = true,
              onChange = function(v) CFG.melee = v and true or false end },
            { type = "slider", name = "Melee range (studs)", key = "melee_range", min = 6, max = 25, step = 1,
              default = 12, onChange = function(v) CFG.meleeRange = v end },
            { type = "toggle", name = "Projectiles", key = "projectiles", default = true,
              onChange = function(v) CFG.projectiles = v and true or false end },
            { type = "toggle", name = "React to players outside your party", key = "pvp", default = true,
              onChange = function(v) CFG.pvp = v and true or false end },
            { type = "toggle", name = "Bombs + enemy players' AoE", key = "hitboxes", default = true,
              onChange = function(v) CFG.hitboxes = v and true or false end },
            { type = "slider", name = "Enemy player AoE: lands this long after it appears (s)", key = "hitbox_delay", min = 0, max = 1, step = 0.05,
              default = 0.3, onChange = function(v) CFG.hitboxDelay = v end },
            { type = "textbox", name = "Extra attacks (animId=seconds, ...)", key = "extra",
              placeholder = "117802002100480=0.74", default = "",
              onChange = function(v) parseExtra(v) end },
            { type = "toggle", name = "Reflex weave when an explosion lands on you", key = "reflex", default = true,
              onChange = function(v) CFG.reflex = v and true or false end },
            { type = "toggle", name = "Log every weave to console", key = "verbose", default = false,
              onChange = function(v) CFG.verbose = v and true or false end },
        },
    }
end

-- textbox values are not replayed at boot by feature.lua, so load the saved one here
function Weave.loadSaved(persist)
    local ok, v = pcall(function() return persist.get("veil.auto_weave.extra") end)
    if ok and type(v) == "string" then parseExtra(v) end
end

return Weave
