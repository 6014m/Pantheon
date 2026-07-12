-- Gakuran (PlaceId 128736949265057, GameId 9199655655) combat integration.
--
-- Registered into the game registry; its container only appears when you're in
-- Gakuran (init.lua calls registry.current().register() gated on PlaceId/GameId),
-- so none of this runs -- or costs perf -- in any other game.
--
-- Ported from the standalone [Spec] Gakuran Combat script. Watches nearby enemies'
-- animations and reacts: incoming M1 -> hold F (perfect block), incoming heavy (M2)
-- -> tap Q (dodge). Plus grip-spam (auto M1 while you grip), guard-break (M1 into a
-- blocker -> R heavy), and click-cancel (don't punch into a charging heavy).
-- Inputs: M1=LClick, heavy=R, block=F(hold), dodge=Q, blink=RClick. EHit/M2Success/
-- Guardbreak are hit-REACTIONS (not triggers) -- including them made it react to your
-- own landed hits.
--
-- REACH: flat. Trigger distance is stableHeight x 2.6 (the confirmed-correct value).
-- The old per-size Auto-Reach learner is gone. Range still scales with the opponent's
-- body size (bigger enemy -> bigger reach) via their measured height; 2.6 is fixed.
--
-- HIT TIMING is size-aware. Small players swing faster, so the same anim lands sooner
-- in wall-clock. We read the LIVE AnimationTrack (TimePosition / Speed) for the exact
-- time-to-impact; when the game does NOT scale the track Speed by size (Speed ~= 1) we
-- fold in a body-size correction so a small attacker still gets a shorter windup. See
-- scheduleReaction. Optional Marker Hit Timing (game:GetObjects) refines the exact
-- contact frame when the executor allows it -- but NOTHING here depends on GetObjects.
--
-- LEARNING (executor-native, no GetObjects):
--   * Unknown attack anims are classified from the LIVE track LENGTH -- short -> M1,
--     unknown attacks default to M1 (parry) and only DODGE a confirmed heavy (static DB
--     or an asset name that says M2/heavy), so basic M1s never get mis-dodged.
--   * A DAMAGE-DRIVEN RECLASSIFIER watches for damage/block-hits: any correctable enemy anim
--     that plays and is then followed (within confirmWindow) by us taking a hit while it was
--     in range is blamed and (re)classified an attack. Getting hit is ground truth, so this
--     runs even off your locked target and regardless of the parry facing/reach gates. Unknown
--     ids learn on the FIRST hit; an anim MIS-FILED as movement noise (a dash/idle whose real
--     hit only shows up once you stop dodging it) is overridden only after CORRECT_HITS hits,
--     so a coincidental dash/emote can't be flipped. A length gate keeps long idles/emotes out.
--   * Anims you've already LOGGED are prefetched through the name-scan at register and
--     classified by their real asset name -- never force-parried.
--   Learned classes persist to disk + settings and are announced.
--
-- CARRY: "Carrying" (71363952449940) plays on BOTH the carrier AND the person being
-- carried -- it is NOT a grip. It lives in CARRY_SELF, never triggers grip-spam, and
-- while it's active grip-spam is force-stopped. Only the real Grip (108723830385066)
-- spams M1.

local registry   = require("games.registry")
local window     = require("ui.window")
local container  = require("ui.container")
local feature    = require("ui.feature")
local components = require("ui.components")
local persist    = require("core.persist")
local log        = require("core.log")
local notify     = require("ui.notify")
local aimState   = require("modules.aim.state")   -- Target Select target

local Players     = game:GetService("Players")
local UIS         = game:GetService("UserInputService")
local RS          = game:GetService("RunService")
local CAS         = game:GetService("ContextActionService")
local VIM         = game:GetService("VirtualInputManager")
local HttpService = game:GetService("HttpService")
local LP          = Players.LocalPlayer

local GKN_IDS    = { 9199655655, 128736949265057 }   -- GameId first, then the known PlaceId
local NEW_FILE   = "gakuran_new_anims.json"
local LEARN_FILE = "gakuran_learned_anims.json"       -- persisted auto-classifications
local CLASS_VER  = 2   -- bump to invalidate old learned classifications (length-era heavies)
local CORRECT_HITS = 2 -- damage confirmations needed to reclassify a MIS-FILED non-attack (dash/noise) as an attack
local BLOCK_KEY, DODGE_KEY, HEAVY_KEY = Enum.KeyCode.F, Enum.KeyCode.Q, Enum.KeyCode.R
local REACH      = 2.6   -- flat reach multiplier (x stableHeight). No longer tunable/learned.

local GKN = {}

----------------------------------------------------------------- settings (persisted)
local CFG = {   -- numeric tunables
    windup = 0.33, perfectLead = 0.07, holdTime = 0.35,
    heavyWindup = 0.50, dodgeLead = 0.05, chargeWindow = 0.60,
    -- Click Cancel: how long after an enemy STARTS an attack we keep withholding your
    -- M1 so you never swing into their hit (and trade). Heavies get +0.4s on top since
    -- they land later. Covers the whole windup so your auto-parry can do its job.
    cancelWindow = 0.55,
    -- Hit priority: after YOU land an M1 the opponent is in hitstun and can't touch you
    -- until they parry/dash/heavy out. For this long (refreshed each hit) we STOP Click
    -- Cancel and auto-parry against that opponent so you keep your combo going instead of
    -- withholding your M1 / parrying their stun. Ends early if they block, dash, or heavy.
    priorityWindow = 0.55,
    -- Damage-driven reclassifier: how far back a landed/blocked hit looks for the enemy anim
    -- that caused it. Widen for slow heavies -- the anim that hit you may be up to this long
    -- before the HP drop. (Was a hard-coded 0.9s; heavies land later than that.)
    confirmWindow = 1.3,
    -- when an anim has no usable hit marker: fraction of the swing that elapses
    -- before the hit lands (fallback only; marker timing is exact)
    hitFrac = 0.5,
    -- grip M1 spam fires spamBurst full clicks EVERY frame (Heartbeat-driven) so
    -- the stream is continuous with no gaps; raise it for more clicks per frame. Bumped up
    -- so a grip can't slip -- at ~60fps this is spamBurst*60 clicks/sec.
    spamBurst = 24,
}
local S = {     -- feature toggles
    armed = true, parry = true, dodge = true, gripSpam = true,
    guardBreak = true, clickCancel = true, logNew = false,
    -- time parries off each attacker's real AnimationTrack (per-style / per-attack
    -- swing speed) instead of one flat windup
    readAnim = true,
    -- pre-scan each attack's keyframe markers for the EXACT hit time (optional; needs
    -- a working game:GetObjects). Falls back to hitFrac when unavailable.
    markerTiming = true,
    -- learn unknown attack anims from live length + hit-confirmation and persist them
    autoClass = true,
    -- closed-loop tuner: watch whether parries/dodges actually connect and adjust the
    -- lead + block-hold PER OPPONENT (and auto-derive the heavy-length split from real
    -- anim lengths) so timing dials itself in to whoever you're fighting.
    autoTune = true,
    -- verbose per-reaction logging (kind, height, size scale, live speed, computed wait)
    debug = false,
    -- Only parry/log/learn the Target Select target's attacks (no misfires from other
    -- nearby players). Needs Target Select engaged on someone.
    targetOnly = true,
    -- Even with Target Only on, still parry/dodge attacks from players you're NOT locked onto
    -- when they're a genuine threat (facing you, in range, a known/confirmed attack) -- so a
    -- 3rd party can't free-hit you mid-fight. Target Only still governs logging/learn noise.
    guardThirdParty = true,
}
local FACING_DOT = 0.15

----------------------------------------------------------------- anim DBs (static, confirmed)
local M1_PARRY = {
    ["134707728784991"]=true,["113403744416180"]=true,["112448114445008"]=true,["84015695249789"]=true,
    ["95267170062803"]=true,["95363684987743"]=true,["139875456638239"]=true,["133112087379005"]=true,
    ["73977397773505"]=true,["140559915903523"]=true,["82475370801539"]=true,["82164598010704"]=true,
    ["97280263199117"]=true,["136563726541554"]=true,["127253080182564"]=true,["85098647244472"]=true,
    ["95359912376713"]=true,["127631232991111"]=true,["71447243477669"]=true,["73898520591442"]=true,
    ["82516160136439"]=true,["110796329013101"]=true,["95399554089638"]=true,["79161155390140"]=true,
    ["77957614227468"]=true,["105109868069470"]=true,["86918714359440"]=true,["111317285324171"]=true,
    ["87171697393871"]=true,["140530278540076"]=true,["73865503612362"]=true,["75692393601509"]=true,
    ["135304344348112"]=true,["136278929175728"]=true,["73329541283787"]=true,["83785650808219"]=true,
    ["132178222366446"]=true,["128114472490928"]=true,["138624221040888"]=true,["103849336431154"]=true,
}
local HEAVY_DODGE = {
    ["89985804943092"]=true,["128479795877497"]=true,["103379337847201"]=true,["114254289386168"]=true,
    ["137330597899886"]=true,["103814914375577"]=true,["74345026218889"]=true,["130884585830171"]=true,
    ["101188641038819"]=true,["116328113967477"]=true,["134616225320869"]=true,
}
local REACTIONS = {   -- hit-reactions/results: known but NEVER trigger
    ["110944743758456"]=true,["76237453354893"]=true,["71328060282201"]=true,["90161235331608"]=true,
    ["92721542799601"]=true,["128122532583491"]=true,["112324027284107"]=true,["114428811318993"]=true,
    ["84132789609149"]=true,["114022632969886"]=true,["73180081197317"]=true,["75644992544295"]=true,
    ["121770461688707"]=true,
}
local ENEMY_BLOCK = {
    ["119223912453789"]=true,["132763223227151"]=true,["134852521037165"]=true,["138017825490326"]=true,
    ["140108556120577"]=true,["71737326453540"]=true,["76143419310137"]=true,["87009475658015"]=true,
}
-- The real Grip only: YOU gripping a downed enemy -> spamming M1 is the whole point.
local GRIP_SELF  = { ["108723830385066"]=true }
-- "Carrying" plays on BOTH the carrier AND the person being carried. NOT a grip; never
-- spams and force-stops grip-spam while active. (Fix for M1 firing while carrying/carried.)
local CARRY_SELF = { ["71363952449940"]=true }
-- Anims that play on YOU when a hit lands on your block -> a damage/hit signal used by
-- the confirmation learner.
local BLOCKHIT   = { ["134852521037165"]=true, ["138017825490326"]=true, ["76143419310137"]=true }
-- Dashes: an opponent dashing ENDS our hit priority over them (they escaped the combo).
local DASH = {
    ["94307187478472"]=true, ["127932830797262"]=true, ["113277528668896"]=true, ["131740405511777"]=true,
}
-- Catalogued NON-attacks that kept surfacing in the "new anim" log. Folded into KNOWN so
-- they never re-flag or get misclassified. (verified against gakuran_anims_classified.json)
local IGNORE_NOISE = {
    ["94307187478472"]=true,   -- DashRight
    ["127932830797262"]=true,  -- DashFront
    ["113277528668896"]=true,  -- DashBack
    ["131740405511777"]=true,  -- DashLeft
    ["111739374926782"]=true,  -- MaleRun
    ["116895075223460"]=true,  -- Capoeira Idle
    ["81977030245036"]=true,   -- Capoeira Walk
    ["102823909334302"]=true,  -- Parryer (enemy perfect block)
}
-- Defensive anims: a blocking/parrying enemy is REACTING to us, not attacking. They must NEVER
-- become a parry target -- not via a stale learned entry, not via the reclassifier. Covers the
-- ENEMY_BLOCK set plus the enemy perfect-block "Parryer" (which lives in IGNORE_NOISE). This is
-- the hard guard: after an enemy parry they often counter and hit you inside the confirm window,
-- so the reclassifier could otherwise blame the PARRY for that damage and start parrying blocks.
local DEFENSE = { ["102823909334302"]=true }   -- Parryer (enemy perfect block)
for id in pairs(ENEMY_BLOCK) do DEFENSE[id] = true end

local KNOWN = { ["180435571"]=true }
for _, t in ipairs({ M1_PARRY, HEAVY_DODGE, ENEMY_BLOCK, GRIP_SELF, CARRY_SELF, REACTIONS, IGNORE_NOISE }) do
    for id in pairs(t) do KNOWN[id] = true end
end

-- Anim ids you've LOGGED (gakuran_new_anims.json) that aren't in the static DB. Prefetched
-- through the background name-scan at register so they get classified (m1 / heavy / reaction
-- / ignore) by their real asset name -- NOT force-parried, so a logged block/dash can't turn
-- into a bogus parry target.
local SEED_LOGGED = {
    "113331696487725","134623519349383","83491849294956","89420531853362","83730275893449",
    "106980660082799","91352556581859","104407197874289","90752347516770","108045962864902",
    "85823794654077",
}

----------------------------------------------------------------- runtime state
local conns = {}
local function track(c) conns[#conns + 1] = c; return c end
local watched, charging, blocking, lastReact = {}, {}, {}, {}
local threats = {}   -- attacker -> expiry tick, for Click Cancel (any incoming attack)
local activePolls = {}   -- live per-attack timing polls (Heartbeat conns), cleaned on fire/destroy
local priority = {}  -- opponent -> expiry tick while WE have hit priority on them (hitstun)
local lastMyM1 = 0   -- tick of the last M1 you actually threw (to attribute damage to you)
local gripping, carried, spamActive, blockActive, casBound = false, false, false, false, false
local gripConn = nil   -- Heartbeat driving the grip click stream (nil while idle)
local sizeCache = setmetatable({}, { __mode = "k" })   -- char -> stable height (weak; GCs with the char)
local counts = { parry = 0, dodge = 0, gbreak = 0, learned = 0 }
local newData, seenNew = {}, {}
local lastTiming = { src = "-", sec = 0 }   -- for the status label: how the last reaction was timed
-- Learned, persisted classifications. learnedClass[id] = "m1" | "heavy" | "reaction" | "ignore"
local learnedClass = {}
-- Per-anim exact hit time (seconds, anim-local) from keyframe markers, or false when
-- scanned with no usable marker. Declared here so the classifier can read it too.
local hitTimeCache = {}
-- Damage-driven reclassifier state. recentAnim[plr] = the last correctable enemy anim they
-- played { id, t, len, role, facing, inReach }; when we then take/absorb a hit we blame the
-- most recent in-reach one and (re)classify it as an attack. correctHits[id] counts how many
-- times a MIS-FILED non-attack has preceded our damage, so a real dash/emote can't be flipped
-- to an attack by one coincidence -- it needs CORRECT_HITS confirmations.
local recentAnim, correctHits = {}, {}

-- Auto-Tune state. tune[name] = per-opponent { lead, dlead, hold, miss, ok } that the
-- outcome feedback nudges. pendingParry[name] tracks an in-flight parry/dodge so a
-- following hit (or clean pass) can score it.
local tune, pendingParry = {}, {}

----------------------------------------------------------------- helpers
local REF_HEIGHT = 5.0     -- a normal R6/R15 rig is ~5 studs tall

local function myRoot()
    local c = LP.Character
    return c and c:FindFirstChild("HumanoidRootPart"), c and c:FindFirstChildOfClass("Humanoid")
end
local function idNum(s) return s and s:match("(%d+)$") end
local function ping() local ok, p = pcall(function() return LP:GetNetworkPing() end) return ok and p or 0 end
local function distOf(plr)
    local mh = myRoot(); local ac = plr.Character; local h = ac and ac:FindFirstChild("HumanoidRootPart")
    if mh and h then return (mh.Position - h.Position).Magnitude end
    return nil
end
local function heightOf(plr)
    local c = plr.Character; if not c then return REF_HEIGHT end
    local ok, sz = pcall(function() return c:GetExtentsSize() end)
    return (ok and sz and sz.Y > 0) and sz.Y or REF_HEIGHT
end
-- GetExtentsSize() flexes with pose; measure once per character life (weak-keyed).
local function stableHeight(plr)
    local c = plr.Character; if not c then return REF_HEIGHT end
    local h = sizeCache[c]
    if not h then h = heightOf(plr); sizeCache[c] = h end
    return h
end
-- Flat trigger distance for this opponent: body height x the fixed 2.6 reach.
local function effRange(plr) return stableHeight(plr) * REACH end
-- Swing speed scales with body size (smaller = faster = shorter windup); scale the
-- time-to-impact by attacker height vs a normal rig (~5 studs). Clamped.
local function sizeScale(plr) return math.clamp(stableHeight(plr) / REF_HEIGHT, 0.3, 2.0) end
local function trackLen(trk)
    if not trk then return 0 end
    local ok, l = pcall(function() return trk.Length end)
    return (ok and type(l) == "number") and l or 0
end

-- Fresh block-start per hit: release+re-press so each hit opens its own perfect-block
-- window. A generation token makes sure only the latest hold's release timer fires.
local blockGen = 0
local function doBlock(dur)
    blockGen = blockGen + 1
    local myGen = blockGen
    if blockActive then VIM:SendKeyEvent(false, BLOCK_KEY, false, game) end
    VIM:SendKeyEvent(true, BLOCK_KEY, false, game)
    blockActive = true
    task.delay(dur, function()
        if blockGen == myGen then VIM:SendKeyEvent(false, BLOCK_KEY, false, game); blockActive = false end
    end)
end
local function tapKey(key)
    VIM:SendKeyEvent(true, key, false, game)
    task.delay(0.04, function() VIM:SendKeyEvent(false, key, false, game) end)
end
local function clickBurst(n)
    lastMyM1 = tick()   -- grip-spam clicks are your M1s too (for hit-priority attribution)
    local m = UIS:GetMouseLocation()
    local x, y = m.X, m.Y
    for _ = 1, n do
        VIM:SendMouseButtonEvent(x, y, 0, true,  game, 0)
        VIM:SendMouseButtonEvent(x, y, 0, false, game, 0)
    end
end

-- Click Cancel threat tracking. noteThreat() marks that an attacker just STARTED an
-- attack (any kind); the mark lasts through the windup so we withhold your M1 until
-- their hit has come and gone. anyIncoming() is true while a live threat is still
-- aimed at you and in range -- ANY attack, not just heavies, so plain M1 trades are
-- withheld too (the whole point of "never get hit").
local function noteThreat(attacker, kind)
    local w = (kind == "heavy") and (CFG.cancelWindow + 0.40) or CFG.cancelWindow
    threats[attacker] = tick() + w
end
-- True while WE have hit priority over this opponent (we just damaged them; they're in
-- hitstun and can't touch us until they escape). Used to back off Click Cancel + auto-parry.
local function hasPriority(plr)
    local e = priority[plr]
    if not e then return false end
    if tick() < e then return true end
    priority[plr] = nil
    return false
end
local function anyIncoming()
    local mh = myRoot(); if not mh then return false end
    local now = tick()
    for plr, exp in pairs(threats) do
        if exp > now then
            -- a player we're comboing (we have priority on) can't threaten us -> ignore them
            local ac = plr.Character; local h = ac and ac:FindFirstChild("HumanoidRootPart")
            if h and not hasPriority(plr) then
                local delta = mh.Position - h.Position
                -- their attack only threatens us if they're close enough AND facing us
                if delta.Magnitude <= effRange(plr) + 3 and h.CFrame.LookVector:Dot(delta.Unit) >= FACING_DOT then
                    return true
                end
            end
        else threats[plr] = nil end
    end
    return false
end
local function frontBlocker()
    local mh = myRoot(); if not mh then return nil end
    local best, bestD
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP and blocking[plr] then
            local ac = plr.Character; local h = ac and ac:FindFirstChild("HumanoidRootPart")
            if h then
                local delta = h.Position - mh.Position; local d = delta.Magnitude
                if d <= effRange(plr) and mh.CFrame.LookVector:Dot(delta.Unit) > 0.3 and (not bestD or d < bestD) then
                    best, bestD = plr, d
                end
            end
        end
    end
    return best
end

----------------------------------------------------------------- classification (executor-native)
local function saveLearned()
    local json = HttpService:JSONEncode(learnedClass)
    persist.set("gakuran.learned", json)
    if writefile then pcall(function() writefile(LEARN_FILE, json) end) end
end
-- Commit a learned class for an id. Recomputes the learned count, persists, announces.
local function commitClass(id, cls, src, announce)
    if not id or KNOWN[id] then return end
    if learnedClass[id] == cls then return end
    local isNew = learnedClass[id] == nil
    learnedClass[id] = cls
    if isNew then counts.learned = counts.learned + 1 end
    saveLearned()
    log.info(("[gakuran] learned %s -> %s (via %s)"):format(id, cls, src))
    if announce and (cls == "m1" or cls == "heavy") then
        pcall(function() notify.info(("Gakuran: learned %s -> %s"):format(id, cls), 5) end)
    end
end
-- Parry-biased default. We ONLY ever dodge a CONFIRMED heavy (in the static HEAVY_DODGE
-- DB, or a name that literally says M2/heavy -- see classFromName). Every other attack,
-- known or not, parries. Mis-dodging an M1 is the worst outcome (you eat the whole combo),
-- so anything ambiguous defaults to a parry; real heavies get flipped to dodge by name.
local function guessKind() return "m1" end

-- Effective attack kind: static DB first, then learned. Returns "m1" | "heavy" | nil.
local function kindOf(id)
    if DEFENSE[id] then return nil end   -- a block/parry is never an attack, whatever a stale learned entry says
    if M1_PARRY[id]    or learnedClass[id] == "m1"    then return "m1" end
    if HEAVY_DODGE[id] or learnedClass[id] == "heavy" then return "heavy" end
    return nil
end

-- An anim that landed a hit should look like an attack, not an idle/emote: readable length in
-- a swing-ish window (unreadable length 0 is allowed -- the track may not be readable yet).
local function attackShaped(len) return len == 0 or (len >= 0.2 and len <= 2.2) end
-- Role of an id for the damage-driven reclassifier:
--   nil       -> already a known/learned attack, or a definite non-attack (reaction/block/grip/
--                carry) we must NEVER turn into a parry target.
--   "unknown" -> never-seen id: one landed hit is enough to learn it as an attack.
--   "noise"   -> currently MIS-FILED as movement (dash/run/idle noise): needs CORRECT_HITS
--                landed hits before we override the label, so a coincidence can't flip it.
local function correctRole(id)
    if DEFENSE[id] then return nil end                       -- block/parry: never learnable as an attack
    if kindOf(id) then return nil end
    if learnedClass[id] == "reaction" then return nil end    -- learned as a hit-result -> never an attack
    if learnedClass[id] == "ignore"   then return "noise" end -- name-scan called it movement: correct only on repeat hits
    if not KNOWN[id] then return "unknown" end
    if REACTIONS[id] or ENEMY_BLOCK[id] or GRIP_SELF[id] or CARRY_SELF[id] then return nil end
    return "noise"
end
-- Record a correctable enemy anim so a following hit can blame it. Decoupled from Target Only
-- and from the parry facing/reach gates: taking a hit is ground truth, so we learn from whoever
-- actually connected -- locked target or not. Geometry is stored as metadata, weighed on blame.
local function noteCandidate(plr, id, trk)
    if not S.autoClass then return end
    local role = correctRole(id)
    if not role then return end
    local mh = myRoot(); local ac = plr.Character; local ah = ac and ac:FindFirstChild("HumanoidRootPart")
    if not mh or not ah then return end
    local delta = mh.Position - ah.Position
    recentAnim[plr] = {
        id = id, t = tick(), len = trackLen(trk), role = role,
        facing  = ah.CFrame.LookVector:Dot(delta.Unit) >= FACING_DOT,
        inReach = delta.Magnitude <= effRange(plr),
    }
end

-- HIT CONFIRMATION / CORRECTION: called when WE take damage or a hit lands on our block.
-- Blame the most recent in-reach, attack-shaped enemy anim and (re)classify it as an attack so
-- it gets parried next time. Unknown ids learn on the FIRST hit; ids currently mis-filed as
-- movement noise are only overridden after CORRECT_HITS hits (guards against coincidence).
local function confirmFromDamage()
    if not (S.autoClass and S.armed) then return end
    local now = tick(); local best
    for plr, info in pairs(recentAnim) do
        if now - info.t <= CFG.confirmWindow then
            if info.inReach and attackShaped(info.len) and (not best or info.t > best.t) then best = info end
        else recentAnim[plr] = nil end
    end
    if not best or kindOf(best.id) then return end
    if best.role == "unknown" then
        commitClass(best.id, guessKind(best.id), "hit-confirm", true)
    elseif best.role == "noise" and best.facing then
        correctHits[best.id] = (correctHits[best.id] or 0) + 1
        if correctHits[best.id] >= CORRECT_HITS and learnedClass[best.id] ~= "m1" then
            local wasNew = learnedClass[best.id] == nil
            learnedClass[best.id] = "m1"; if wasNew then counts.learned = counts.learned + 1 end
            saveLearned()
            log.info(("[gakuran] corrected %s (mis-filed non-attack) -> m1 after %d hits"):format(best.id, CORRECT_HITS))
            pcall(function() notify.info(("Gakuran: corrected %s -> attack"):format(best.id), 5) end)
        end
    end
end

----------------------------------------------------------------- auto-tune (per-opponent, feedback-driven)
-- Bounded so the tuner can only ever drift a little from the good defaults; it presses
-- a touch earlier and holds a touch longer when parries are getting beaten, and relaxes
-- back once they land clean. Direction is deliberately conservative (getting hit -> more
-- lead + hold) because the outcome signal is binary; the bounds stop it from running off.
local TUNE = { leadStep = 0.008, holdStep = 0.02, leadMax = 0.20, holdMax = 0.60, holdMin = 0.25 }
local function tuneFor(name)
    local t = tune[name]
    if not t then
        t = { lead = CFG.perfectLead, dlead = CFG.dodgeLead, hold = CFG.holdTime, miss = 0, ok = 0 }
        tune[name] = t
    end
    return t
end
-- A scheduled parry/dodge got beaten (health drop = hard, block-hit = soft): nudge tighter.
local function tuneMiss(name, kind, hard)
    if not S.autoTune or not name then return end
    local t = tuneFor(name); t.miss = t.miss + 1
    local m = hard and 2 or 1
    if kind == "heavy" then
        t.dlead = math.clamp(t.dlead + TUNE.leadStep * m, 0, TUNE.leadMax)
    else
        t.lead = math.clamp(t.lead + TUNE.leadStep * m, 0, TUNE.leadMax)
        t.hold = math.clamp(t.hold + TUNE.holdStep * m, TUNE.holdMin, TUNE.holdMax)
    end
    if S.debug then log.info(("[gakuran] tune %s MISS(%s) lead=%.3f hold=%.3f dlead=%.3f"):format(name, kind, t.lead, t.hold, t.dlead)) end
end
-- A parry/dodge window passed with no hit: count the win and relax hold toward default.
local function tuneOk(name, kind)
    if not S.autoTune or not name then return end
    local t = tuneFor(name); t.ok = t.ok + 1
    t.hold = t.hold + (CFG.holdTime - t.hold) * 0.08
end
-- Record an in-flight reaction so a following hit / clean pass can score it.
local function markReaction(name, kind, hold)
    if not S.autoTune or not name then return end
    pendingParry[name] = { t = tick(), kind = kind }
    task.delay((hold or CFG.holdTime) + 0.35, function()
        local pp = pendingParry[name]
        if pp and not pp.scored then tuneOk(name, kind) end
        if pp then pendingParry[name] = nil end
    end)
end
-- We took a hit: blame the most recent in-flight reaction and tune it tighter.
local function registerHit(hard)
    if not S.autoTune then return end
    local now = tick(); local bestName, bestT
    for name, pp in pairs(pendingParry) do
        if now - pp.t <= 0.6 then if not bestT or pp.t > bestT then bestName, bestT = name, pp.t end
        elseif now - pp.t > 1.5 then pendingParry[name] = nil end
    end
    if bestName then local pp = pendingParry[bestName]; pp.scored = true; tuneMiss(bestName, pp.kind, hard) end
end
----------------------------------------------------------------- GetObjects scan (background refinement)
-- The live-length learner classifies INSTANTLY. This slow, async game:GetObjects pass
-- runs in the background to (a) pull the exact hit-frame marker for timing and (b) read
-- the asset name and CORRECT the fast length guess when the name is unambiguous (e.g. a
-- long "...4thM1" that length mistook for a heavy, or a logged id that's really a dash).
-- Nothing blocks on it; if GetObjects is unavailable it just no-ops. (hitTimeCache is
-- declared up in the runtime-state block so the classifier can read it.)
local scanning = {}
local HIT_MARKER_HINTS = { "hit", "attack", "damage", "swing", "cast", "contact", "impact", "active" }
local function looksLikeHit(name)
    local n = string.lower(name or "")
    for _, frag in ipairs(HIT_MARKER_HINTS) do if string.find(n, frag, 1, true) then return true end end
    return false
end
-- Confident class from an asset name; nil when the name says nothing useful.
local function classFromName(name)
    local nm = string.lower(name or "")
    if nm == "" or nm == "keyframesequence" or nm == "animation" then return nil end
    if nm:find("m2") or nm:find("heavy") or nm:find("charge") or nm:find("strong") or nm:find("smash") or nm:find("slam") then return "heavy" end
    if nm:find("ehit") or nm:find("guardbreak") or nm:find("success") or nm:find("blockhit")
       or nm:find("parry") or nm:find("stun") or nm:find("react") then return "reaction" end
    -- Attack words are checked BEFORE movement words, so a name with BOTH (e.g. "DashPunch",
    -- "SprintKick", "RunningSlash") stays an ATTACK instead of being filed as movement. An attack
    -- that whiffs or that we parry deals no damage but is still an attack -- its name must never
    -- demote it. Only a name with a pure-movement word and NO attack word becomes "ignore".
    if nm:find("m1") or nm:find("punch") or nm:find("kick") or nm:find("attack") or nm:find("combo")
       or nm:find("slash") or nm:find("swing") or nm:find("strike") or nm:find("claw") or nm:find("jab")
       or nm:find("hook") or nm:find("uppercut")
       or nm:find("1st") or nm:find("2nd") or nm:find("3rd") or nm:find("4th") then return "m1" end
    if nm:find("dash") or nm:find("run") or nm:find("walk") or nm:find("idle") or nm:find("sprint")
       or nm:find("jump") or nm:find("carry") or nm:find("grip") or nm:find("emote") then return "ignore" end
    return nil
end
local function scanAnim(id)
    if not id or not (S.markerTiming or S.autoClass) then return end
    if hitTimeCache[id] ~= nil or scanning[id] then return end
    if type(game.GetObjects) ~= "function" then hitTimeCache[id] = false; return end
    scanning[id] = true
    task.spawn(function()
        local ok, objs = pcall(function() return game:GetObjects("rbxassetid://" .. id) end)
        scanning[id] = nil
        if not ok or type(objs) ~= "table" or not objs[1] then hitTimeCache[id] = false; return end
        local root = objs[1]
        local nm; pcall(function() nm = root.Name end)
        local markers = {}
        pcall(function()
            for _, inst in ipairs(root:GetDescendants()) do
                if inst:IsA("KeyframeMarker") then
                    local kf = inst.Parent
                    if kf and kf:IsA("Keyframe") then markers[#markers + 1] = { name = inst.Name, t = kf.Time } end
                end
            end
        end)
        pcall(function() root:Destroy() end)
        local chosen
        for _, mk in ipairs(markers) do
            if looksLikeHit(mk.name) and (not chosen or mk.t < chosen.t) then chosen = mk end
        end
        if not chosen then for _, mk in ipairs(markers) do if not chosen or mk.t > chosen.t then chosen = mk end end end
        hitTimeCache[id] = (chosen and chosen.t and chosen.t > 0) and chosen.t or false
        -- name-based correction only: flip to heavy / reaction / ignore when the asset
        -- name is unambiguous. Marker hit TIME is NOT used to call heavy -- it overlaps M1
        -- too much and was mis-dodging basic M1s.
        if S.autoClass and not KNOWN[id] then
            local nc = classFromName(nm)
            local cur = learnedClass[id]
            -- A landed hit is ground truth; a name is a guess. NEVER let the name-scan demote a
            -- PROVEN attack (already m1/heavy, e.g. damage-confirmed) down to a non-attack -- no
            -- damage from a whiff or a successful parry does not mean it stopped being an attack.
            -- Name may still refine m1<->heavy and classify things we haven't proven yet.
            local demotes = (nc == "ignore" or nc == "reaction") and (cur == "m1" or cur == "heavy")
            if nc and cur ~= nc and not demotes then
                commitClass(id, nc, "name", cur == nil)   -- announce only if brand-new
            elseif demotes then
                log.info(("[gakuran] name-scan wanted %s -> %s, but it's a PROVEN attack -> keeping"):format(id, nc))
            end
        end
    end)
end

----------------------------------------------------------------- react
local function isTarget(plr) return aimState.target_type == "player" and aimState.target == plr end

-- Schedule the timed block/dodge. Instead of computing the wait ONCE (one frame in) and
-- firing on a fixed task.delay, we POLL the live AnimationTrack every frame and fire the
-- instant the real time-to-impact drops within lead+ping. Reading TimePosition/Speed each
-- frame is what makes small/fast attackers accurate: their higher swing Speed (and any
-- mid-swing AdjustSpeed ramp) is tracked live, with no stale one-frame-old estimate that
-- drifts. When the game leaves Speed ~= 1 (didn't speed the track up for a small rig) we
-- fold in the body-size scale so a small attacker still gets a shorter windup. Falls back
-- to a fixed windup x size when the track can't be read or Read Anim Speed is off.
local function scheduleReaction(plr, trk, id, kind, fallbackWindup, leadOffset, fire)
    local function debugLog(src, wait, extra)
        if S.debug then
            log.info(("[gakuran] time %s %s %s h=%.1f ss=%.2f %s wait=%.3f")
                :format(id, kind, src, stableHeight(plr), sizeScale(plr), extra or "", wait))
        end
    end
    local function fallback()
        local wait = math.max(fallbackWindup * sizeScale(plr) - leadOffset - ping(), 0)
        lastTiming = { src = "flat", sec = wait }
        debugLog("flat", wait, "")
        task.delay(wait, fire)
    end
    if not (S.readAnim and trk) then return fallback() end

    local fired, started = false, tick()
    local conn
    local function stop()
        if conn then activePolls[conn] = nil; pcall(function() conn:Disconnect() end); conn = nil end
    end
    conn = RS.Heartbeat:Connect(function()
        if fired then return end
        if tick() - started > 2 then fired = true; stop(); return end   -- safety: never poll forever
        local ok,  len = pcall(function() return trk.Length end)
        local sok, spd = pcall(function() return trk.Speed end)
        local pok, pos = pcall(function() return trk.TimePosition end)
        if not (ok and sok and pok and type(len) == "number" and len > 0.05
                and type(spd) == "number" and spd > 0.01 and type(pos) == "number") then
            -- track not ready yet (or GC'd); fall back to a flat delay if it never comes
            if tick() - started > 0.05 then fired = true; stop(); fallback() end
            return
        end
        local ht = S.markerTiming and hitTimeCache[id]
        local usingMarker = (type(ht) == "number" and ht > 0 and ht <= len + 0.05)
        local hitAt = usingMarker and ht or (len * CFG.hitFrac)
        local remaining = (hitAt - pos) / spd
        if spd > 0.9 and spd < 1.1 then remaining = remaining * sizeScale(plr) end
        if remaining <= leadOffset + ping() or pos >= hitAt + 0.02 then
            fired = true; stop()
            lastTiming = { src = usingMarker and "mark" or "live", sec = math.max(remaining, 0) }
            debugLog(usingMarker and "mark" or "live", math.max(remaining, 0),
                ("spd=%.2f len=%.2f hitAt=%.2f"):format(spd, len, hitAt))
            fire()
        end
    end)
    activePolls[conn] = true
end

local function react(attacker, id, trk)
    if attacker == LP then return end
    -- Target Only restricts reactions to your locked target -- EXCEPT that a 3rd party can hit
    -- you mid-fight, so with Guard 3rd Parties on we still react to anyone. The facing + in-range
    -- + known-attack gates below keep this from misfiring on distant/irrelevant players; only a
    -- real incoming threat gets parried/dodged. Target Only still gates logging + first-learn.
    if S.targetOnly and not isTarget(attacker) and not S.guardThirdParty then return end
    -- We're comboing this person (hit priority) -> they're in hitstun, can't hit us; don't
    -- parry their stun/block. Priority ends when they block/dash/heavy out (cleared below).
    if hasPriority(attacker) then return end
    local mh, hum = myRoot()
    if not mh or not hum or hum.Health <= 0 then return end
    local ac = attacker.Character; local ah = ac and ac:FindFirstChild("HumanoidRootPart")
    if not ah then return end
    local delta = mh.Position - ah.Position
    local dist = delta.Magnitude
    local facing = ah.CFrame.LookVector:Dot(delta.Unit) >= FACING_DOT
    local inReach = dist <= effRange(attacker)

    local kind = kindOf(id)
    if not kind then
        -- Unknown anim: DON'T force-classify it (a logged block/dash would wrongly become
        -- a parry target). Just stash it for the hit-confirmation learner + kick the
        -- background name-scan; it only ever reacts once it's a confirmed attack.
        -- (recording for the damage-driven reclassifier happens in noteCandidate, off the
        -- AnimationPlayed handler -- decoupled from Target Only and the facing/reach gates.)
        if S.autoClass and not KNOWN[id] then scanAnim(id) end
        return
    end

    if not S.armed or not inReach or not facing then return end
    scanAnim(id)   -- warm exact-hit-frame + name correction (async, harmless if unavailable)
    -- Debounce the SAME anim re-firing; different combo ids react immediately.
    local now = tick()
    local lr = lastReact[attacker]
    if lr and lr.id == id and (now - lr.t) < 0.15 then return end
    lastReact[attacker] = { id = id, t = now }

    -- per-opponent tuned lead/hold (falls back to the CFG sliders when Auto-Tune is off)
    local nm = attacker.Name
    local t = S.autoTune and tuneFor(nm) or nil
    local lead  = t and t.lead  or CFG.perfectLead
    local dlead = t and t.dlead or CFG.dodgeLead
    local hold  = t and t.hold  or CFG.holdTime

    if kind == "heavy" then
        if S.dodge then
            scheduleReaction(attacker, trk, id, kind, CFG.heavyWindup, dlead, function()
                tapKey(DODGE_KEY); counts.dodge = counts.dodge + 1; markReaction(nm, kind, 0)
            end)
        end
    elseif S.parry then
        scheduleReaction(attacker, trk, id, kind, CFG.windup, lead, function()
            doBlock(hold); counts.parry = counts.parry + 1; markReaction(nm, kind, hold)
        end)
    end
end

----------------------------------------------------------------- grip spam (carry-aware)
local function stopGripSpam()
    if gripConn then pcall(function() gripConn:Disconnect() end); gripConn = nil end
    spamActive = false
end
local function startGripSpam()
    if spamActive or carried then return end   -- never start while a carry anim is active
    spamActive = true
    gripConn = RS.Heartbeat:Connect(function()
        if not (gripping and S.armed and S.gripSpam) or carried then stopGripSpam(); return end
        -- NOTE: Click Cancel does NOT gate grip spam. Withholding your M1 into an incoming attack
        -- is right for a neutral trade, but during a grip it starves the click stream and the
        -- grip slips -- exactly what we must never allow. Auto-parry still holds F independently,
        -- so you keep blocking the incoming hit AND keep clicking to hold the grip.
        clickBurst(math.max(1, math.floor(CFG.spamBurst)))
    end)
end

----------------------------------------------------------------- animation hooks
local function hookChar(plr, char)
    local hum = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 5)
    local animator = hum and (hum:FindFirstChildOfClass("Animator") or hum:WaitForChild("Animator", 5))
    if not animator or watched[animator] then return end
    watched[animator] = true
    if not sizeCache[char] then sizeCache[char] = heightOf(plr) end
    -- Watch an ENEMY's health: a drop right after one of YOUR M1s means you landed the hit,
    -- so you now have hit priority over them (they're in hitstun). Refreshed each hit.
    if plr ~= LP and hum then
        local last = hum.Health
        track(hum.HealthChanged:Connect(function(h)
            if h < last - 0.01 and (tick() - lastMyM1) <= 0.6 and (not S.targetOnly or isTarget(plr)) then
                priority[plr] = tick() + CFG.priorityWindow
            end
            last = h
        end))
    end
    track(animator.AnimationPlayed:Connect(function(trk)
        local id = idNum(trk.Animation and trk.Animation.AnimationId)
        if not id then return end
        if plr == LP then
            if GRIP_SELF[id] then
                gripping = true; startGripSpam()
                trk.Stopped:Connect(function() gripping = false end)
            elseif CARRY_SELF[id] then
                carried = true; stopGripSpam()          -- carrying or being carried: lock spam out
                trk.Stopped:Connect(function() carried = false end)
            elseif BLOCKHIT[id] then
                confirmFromDamage()                     -- a hit landed on our block -> learn the attacker's anim
                registerHit(false)                      -- blocked but not a perfect parry -> tighten a little
            elseif S.logNew and not KNOWN[id] and not learnedClass[id] then
                log.info(("[gakuran] SELF anim %s"):format(id))   -- helps catch a separate "being carried" id
            end
            return
        end
        if ENEMY_BLOCK[id] then
            blocking[plr] = true
            trk.Stopped:Connect(function() blocking[plr] = nil end)
        end
        local ek = kindOf(id)
        -- Our hit priority over this player ENDS the moment they escape it: a block/parry,
        -- a dash, or a heavy (armor) attack. After that, Click Cancel + auto-parry resume.
        if priority[plr] and (ENEMY_BLOCK[id] or DASH[id] or ek == "heavy") then priority[plr] = nil end
        -- Click Cancel threat: flag ANY attacker's attack (not just the parry target)
        -- so we never M1-trade with someone we're not even parrying.
        if ek then noteThreat(plr, ek) end
        noteCandidate(plr, id, trk)   -- record for the damage-driven reclassifier (learn/correct on hit)
        react(plr, id, trk)
        if S.logNew and (not S.targetOnly or isTarget(plr)) and not KNOWN[id] and not seenNew[id] then
            local d = distOf(plr)
            if d and d <= effRange(plr) + 8 then
                seenNew[id] = true
                newData[#newData + 1] = { id = id, animId = trk.Animation.AnimationId, by = plr.Name, dist = math.floor(d + 0.5) }
                log.info(("[gakuran] NEW anim %s by %s d=%.0f"):format(id, plr.Name, d))
                if writefile then pcall(function() writefile(NEW_FILE, HttpService:JSONEncode(newData)) end) end
            end
        end
    end))
end
local function watch(plr)
    if plr.Character then task.spawn(hookChar, plr, plr.Character) end
    track(plr.CharacterAdded:Connect(function(c) task.wait(0.2); hookChar(plr, c) end))
end
-- Self health watch: any drop is a hit -> confirmation learner.
local function bindSelf(c)
    local hum = c:FindFirstChildOfClass("Humanoid") or c:WaitForChild("Humanoid", 5)
    if not hum then return end
    local last = hum.Health
    track(hum.HealthChanged:Connect(function(h)
        if h < last - 0.01 then confirmFromDamage(); registerHit(true) end   -- took real damage -> tighten harder
        last = h
    end))
end

----------------------------------------------------------------- UI
local statusLbl

local function loadSettings()
    for k in pairs(CFG) do CFG[k] = persist.get("gakuran." .. k, CFG[k]) end
    for k in pairs(S)   do if k ~= "armed" then S[k] = persist.get("gakuran." .. k, S[k]) end end
    local ok, decoded = pcall(function() return HttpService:JSONDecode(persist.get("gakuran.learned", "{}")) end)
    learnedClass = (ok and type(decoded) == "table") and decoded or {}
    if readfile and isfile and pcall(function() return isfile(LEARN_FILE) end) and isfile(LEARN_FILE) then
        pcall(function()
            local fromFile = HttpService:JSONDecode(readfile(LEARN_FILE))
            if type(fromFile) == "table" then for k, v in pairs(fromFile) do learnedClass[k] = learnedClass[k] or v end end
        end)
    end
    -- Wipe classifications learned by an older (buggy) classifier version -- the length-era
    -- run saved a lot of M1s as "heavy", which made this dodge basic M1s. They re-learn fast.
    if tonumber(persist.get("gakuran.classVer", 0)) ~= CLASS_VER then
        learnedClass = {}
        persist.set("gakuran.classVer", CLASS_VER)
        persist.set("gakuran.learned", "{}")
        if writefile then pcall(function() writefile(LEARN_FILE, "{}") end) end
        log.info("[gakuran] classifier upgraded -> cleared stale learned anims")
    end
    -- Scrub any block/parry the reclassifier may have mis-learned as an attack in an earlier
    -- session (blamed for a post-parry counter's damage). The kindOf/correctRole guards stop it
    -- going forward; this cleans what's already persisted so it stops being parried immediately.
    local scrubbed = false
    for id in pairs(DEFENSE) do if learnedClass[id] then learnedClass[id] = nil; scrubbed = true end end
    if scrubbed then saveLearned(); log.info("[gakuran] scrubbed mis-learned block/parry anims from learned DB") end
    local n = 0; for _ in pairs(learnedClass) do n = n + 1 end; counts.learned = n
end

local function subToggle(holder, order, name, key)
    local t = components.Toggle(holder, {
        text = name, default = S[key],
        onChange = function(v) S[key] = v; persist.set("gakuran." .. key, v) end,
    })
    t.frame.LayoutOrder = order
    return t
end
local function tuneSlider(holder, order, name, key, mn, mx, st)
    local sl = components.Slider(holder, {
        text = name, min = mn, max = mx, step = st, default = CFG[key],
        onChange = function(v) CFG[key] = v; persist.set("gakuran." .. key, v) end,
    })
    sl.frame.LayoutOrder = order
    return sl
end

function GKN.register()
    loadSettings()
    pcall(function() notify.success("Gakuran combat loaded", 6) end)
    log.info("Gakuran REGISTER on PlaceId=" .. tostring(game.PlaceId) .. " GameId=" .. tostring(game.GameId))

    -- warm the background name-scan for your logged ids up front so they're classified
    -- accurately before you even see them again (length still classifies on first play)
    if S.autoClass then
        for _, id in ipairs(SEED_LOGGED) do task.spawn(scanAnim, id) end
    end

    local box = container.new(window.parent(), "Gakuran")

    local master
    master = feature.declare({
        id = "gakuran.armed", name = "Combat Enabled",
        description = "Master switch for all Gakuran combat automation. RightShift toggles it in-game. Individual features below still each have their own on/off.",
        default = S.armed, defaultKey = Enum.KeyCode.RightShift,
        onToggle = function(v) S.armed = v and true or false end,
        onKey    = function() if master then master.setEnabled(not S.armed) end end,
    })
    box:add(master.root)

    local holder = Instance.new("Frame")
    holder.Size = UDim2.new(1, 0, 0, 0); holder.AutomaticSize = Enum.AutomaticSize.Y; holder.BackgroundTransparency = 1
    local hl = Instance.new("UIListLayout", holder); hl.SortOrder = Enum.SortOrder.LayoutOrder; hl.Padding = UDim.new(0, 2)

    components.Section(holder, "Features").LayoutOrder = 1
    subToggle(holder, 2, "Auto Parry (F)",      "parry")
    subToggle(holder, 3, "Heavy Dodge (Q)",     "dodge")
    subToggle(holder, 4, "Grip Spam M1",        "gripSpam")
    subToggle(holder, 5, "Guard Break (R)",     "guardBreak")
    subToggle(holder, 6, "Click Cancel",        "clickCancel")
    subToggle(holder, 7, "Read Anim Speed",     "readAnim")
    subToggle(holder, 8, "Marker Hit Timing",   "markerTiming")
    subToggle(holder, 9, "Auto-Learn Anims",    "autoClass")
    subToggle(holder, 10, "Auto-Tune (per opponent)", "autoTune")
    subToggle(holder, 11, "Target Only",        "targetOnly")
    subToggle(holder, 12, "Guard 3rd Parties",  "guardThirdParty")
    subToggle(holder, 13, "Log New Anims",      "logNew")
    subToggle(holder, 14, "Debug Timing",       "debug")

    components.Section(holder, "Tuning").LayoutOrder = 20
    -- With Auto-Tune ON these four are the STARTING point; the tuner adapts them per
    -- opponent from there. With it OFF they're used flat.
    tuneSlider(holder, 21, "Anim Hit Point", "hitFrac",   0.20, 0.90, 0.05)
    tuneSlider(holder, 23, "M1 Windup (fallback)", "windup", 0.10, 0.60, 0.01)
    tuneSlider(holder, 24, "Parry Lead (base)",  "perfectLead", 0.00, 0.25, 0.01)
    tuneSlider(holder, 25, "Block Hold (base)",  "holdTime",    0.10, 0.80, 0.05)
    tuneSlider(holder, 26, "Heavy Windup (fallback)","heavyWindup", 0.20, 0.90, 0.01)
    tuneSlider(holder, 27, "Dodge Lead (base)",  "dodgeLead",   0.00, 0.25, 0.01)
    tuneSlider(holder, 28, "Click Cancel Window", "cancelWindow", 0.20, 1.00, 0.05)
    tuneSlider(holder, 29, "Hit Priority Window", "priorityWindow", 0.20, 1.20, 0.05)
    tuneSlider(holder, 30, "Spam Burst (clicks/frame)","spamBurst", 1, 80, 1)
    tuneSlider(holder, 31, "Learn/Correct Window","confirmWindow", 0.60, 2.00, 0.05)

    local resetBtn = components.Button(holder, { text = "Reset Learned Anims", onClick = function()
        learnedClass = {}; counts.learned = 0; saveLearned()
        pcall(function() notify.success("Gakuran learned anims cleared", 4) end)
    end })
    resetBtn.LayoutOrder = 30

    statusLbl = components.Label(holder, "nearest: -")
    statusLbl.LayoutOrder = 40
    box:add(holder)

    for _, p in ipairs(Players:GetPlayers()) do watch(p) end
    track(Players.PlayerAdded:Connect(watch))
    if LP.Character then bindSelf(LP.Character) end
    track(LP.CharacterAdded:Connect(function(c) task.wait(0.2); bindSelf(c) end))

    pcall(function() CAS:UnbindAction("gkn_m1") end)
    CAS:BindActionAtPriority("gkn_m1", function(_, st)
        if st ~= Enum.UserInputState.Begin or not S.armed then return Enum.ContextActionResult.Pass end
        if gripping then return Enum.ContextActionResult.Pass end   -- our own grip-spam clicks pass through
        if S.clickCancel and anyIncoming() then return Enum.ContextActionResult.Sink end
        if S.guardBreak and frontBlocker() then
            tapKey(HEAVY_KEY); counts.gbreak = counts.gbreak + 1
            return Enum.ContextActionResult.Sink
        end
        lastMyM1 = tick()   -- your M1 is going through -> lets a following enemy-HP drop grant priority
        return Enum.ContextActionResult.Pass
    end, false, 3000, Enum.UserInputType.MouseButton1)
    casBound = true

    local acc = 0
    track(RS.Heartbeat:Connect(function(dt)
        acc = acc + dt; if acc < 0.15 then return end; acc = 0
        if not statusLbl then return end
        local nearest, nPlr
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LP then local d = distOf(plr); if d and (not nearest or d < nearest) then nearest, nPlr = d, plr end end
        end
        local hStr = nPlr and ("d%.1f h%.1f reach%.1f"):format(nearest, stableHeight(nPlr), effRange(nPlr)) or "-"
        local carryStr = carried and " CARRY" or (gripping and " GRIP" or "")
        -- live auto-tuned values for whoever's nearest (or the flat sliders when off)
        local tuneStr
        if S.autoTune and nPlr and tune[nPlr.Name] then
            local tt = tune[nPlr.Name]
            tuneStr = ("lead%.02f hold%.02f m%d/o%d"):format(tt.lead, tt.hold, tt.miss, tt.ok)
        else
            tuneStr = S.autoTune and "tuning…" or "manual"
        end
        statusLbl.Text = ("nearest %s | t:%s %.2fs | %s | P%d D%d B%d | learned:%d%s"):format(
            hStr, lastTiming.src, lastTiming.sec, tuneStr, counts.parry, counts.dodge, counts.gbreak, counts.learned, carryStr)
    end))

    log.info("Gakuran module registered -- flat reach x2.6, size-aware timing, live-length learner, carry-safe grip")
end

function GKN.destroy()
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    conns = {}
    if casBound then pcall(function() CAS:UnbindAction("gkn_m1") end); casBound = false end
    if blockActive then pcall(function() VIM:SendKeyEvent(false, BLOCK_KEY, false, game) end); blockActive = false end
    for c in pairs(activePolls) do pcall(function() c:Disconnect() end) end
    activePolls = {}
    watched, charging, blocking, lastReact = {}, {}, {}, {}
    recentAnim, correctHits = {}, {}
    threats, tune, pendingParry, priority = {}, {}, {}, {}
    gripping, carried = false, false
    if gripConn then pcall(function() gripConn:Disconnect() end); gripConn = nil end
    spamActive = false
    statusLbl = nil
end

registry.register(GKN_IDS, GKN)

return GKN
