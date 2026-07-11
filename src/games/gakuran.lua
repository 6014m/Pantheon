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
-- The old per-size Auto-Reach learner is gone -- it dragged the range around and was
-- more trouble than it was worth. Range still scales with the opponent's body size
-- (bigger enemy -> bigger reach) via their measured height; the 2.6 multiplier is fixed.
--
-- HIT TIMING is size-aware. Small players swing faster, so the same anim lands sooner
-- in wall-clock. We read the LIVE AnimationTrack (TimePosition / Speed) for the exact
-- time-to-impact -- which already bakes in size when the game speeds the track up for
-- small rigs -- and we pull the anim's real keyframe HIT marker for the exact contact
-- frame. When the game does NOT scale the track speed by size, we fold in a body-size
-- correction so a small attacker still gets a shorter windup. See scheduleReaction.
--
-- AUTO-CLASSIFY: any attack anim we don't recognise (including the ones you've logged)
-- gets pulled via game:GetObjects, read for its name + hit marker + length, and sorted
-- into m1 / heavy / reaction / ignore. Learned classes persist to disk and are announced
-- so you can sanity-check them. Unknown-with-no-hit-marker defaults to IGNORE (never
-- triggers) so a stray dash/emote can't cause a bad block.
--
-- CARRY: "Carrying" (71363952449940) plays on BOTH the carrier and the person being
-- carried -- it is NOT a grip. It lives in CARRY_SELF now, never triggers grip-spam,
-- and while it's active grip-spam is force-stopped. Only the real Grip (108723830385066)
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

local GKN_IDS   = { 9199655655, 128736949265057 }   -- GameId first, then the known PlaceId
local NEW_FILE  = "gakuran_new_anims.json"
local LEARN_FILE = "gakuran_learned_anims.json"      -- persisted auto-classifications
local BLOCK_KEY, DODGE_KEY, HEAVY_KEY = Enum.KeyCode.F, Enum.KeyCode.Q, Enum.KeyCode.R
local REACH     = 2.6   -- flat reach multiplier (x stableHeight). No longer tunable/learned.

local GKN = {}

----------------------------------------------------------------- settings (persisted)
local CFG = {   -- numeric tunables
    windup = 0.33, perfectLead = 0.07, holdTime = 0.35,
    heavyWindup = 0.50, dodgeLead = 0.05, chargeWindow = 0.60,
    -- when an anim has no usable hit marker: fraction of the swing that elapses
    -- before the hit lands (fallback only; marker timing is exact)
    hitFrac = 0.5,
    -- grip M1 spam fires spamBurst full clicks EVERY frame (Heartbeat-driven) so
    -- the stream is continuous with no gaps; raise it for more clicks per frame.
    spamBurst = 12,
}
local S = {     -- feature toggles
    armed = true, parry = true, dodge = true, gripSpam = true,
    guardBreak = true, clickCancel = true, logNew = false,
    -- time parries off each attacker's real AnimationTrack (per-style / per-attack
    -- swing speed) instead of one flat windup
    readAnim = true,
    -- pre-scan each attack's keyframe markers for the EXACT hit time (per-attack)
    -- instead of the flat hitFrac guess. Falls back to hitFrac when there's no marker.
    markerTiming = true,
    -- auto-classify unknown attack anims (name + marker + length) into the live DB
    -- and persist them, so anything you fight/log gets covered automatically.
    autoClass = true,
    -- Only parry/log the Target Select target's attacks (no misfires from other
    -- nearby players). Needs Target Select engaged on someone.
    targetOnly = true,
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
-- "Carrying" plays on BOTH the carrier AND the person being carried. It is NOT a grip.
-- While it's active we suppress grip-spam entirely. (This is the fix for M1 firing while
-- you carry someone or are being carried.)
local CARRY_SELF = { ["71363952449940"]=true }
-- Catalogued NON-attacks that kept surfacing in the "new anim" log (dashes, run/walk,
-- idle stances, enemy perfect-block). Folded into KNOWN so they don't re-flag and bury a
-- genuinely new attack. (verified against gakuran_anims_classified.json)
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
local KNOWN = { ["180435571"]=true }
for _, t in ipairs({ M1_PARRY, HEAVY_DODGE, ENEMY_BLOCK, GRIP_SELF, CARRY_SELF, REACTIONS, IGNORE_NOISE }) do
    for id in pairs(t) do KNOWN[id] = true end
end

-- Anim ids you've logged (gakuran_new_anims.json) that aren't classified yet. Seeded into
-- the classifier on register so they get pulled + sorted automatically -- "make sure we
-- have em all". Anything the classifier can't confidently call becomes IGNORE (safe).
local SEED_LOGGED = {
    "113331696487725","134623519349383","83491849294956","89420531853362","83730275893449",
    "106980660082799","91352556581859","104407197874289","90752347516770","108045962864902",
    "85823794654077",
}

----------------------------------------------------------------- runtime state
local conns = {}
local function track(c) conns[#conns + 1] = c; return c end
local watched, charging, blocking, lastReact = {}, {}, {}, {}
local gripping, carried, spamActive, blockActive, casBound = false, false, false, false, false
local gripConn = nil   -- Heartbeat driving the grip click stream (nil while idle)
local sizeCache = setmetatable({}, { __mode = "k" })   -- char -> stable height (weak; GCs with the char)
local counts = { parry = 0, dodge = 0, gbreak = 0 }
local newData, seenNew = {}, {}
local lastTiming = { src = "-", sec = 0 }   -- for the status label: how the last reaction was timed

-- Learned, persisted classifications for anims not in the static DBs.
--   learnedClass[id] = "m1" | "heavy" | "reaction" | "ignore"
local learnedClass = {}

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
-- GetExtentsSize() flexes with the current pose. Measure once per character life
-- (weak-keyed, seeded at hook time while they're idle) so a size stays put.
local function stableHeight(plr)
    local c = plr.Character; if not c then return REF_HEIGHT end
    local h = sizeCache[c]
    if not h then h = heightOf(plr); sizeCache[c] = h end
    return h
end

-- Flat trigger distance for this opponent: their body height x the fixed 2.6 reach.
local function effRange(plr) return stableHeight(plr) * REACH end

-- Swing speed scales with body size (smaller = faster swing = shorter windup), so
-- scale the time-to-impact by attacker height vs a normal rig (~5 studs). Clamped so
-- extreme sizes can't produce absurd timings.
local function sizeScale(plr) return math.clamp(stableHeight(plr) / REF_HEIGHT, 0.3, 2.0) end

-- Fresh block-start per hit: if a prior hold is still active (fast combo), release and
-- immediately re-press so each hit opens its own perfect-block window. A generation
-- token makes sure only the latest hold's release timer fires.
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
-- Fire n full down/up left-clicks at the current cursor. The mouse location is read
-- once and reused so a large per-frame burst stays cheap.
local function clickBurst(n)
    local m = UIS:GetMouseLocation()
    local x, y = m.X, m.Y
    for _ = 1, n do
        VIM:SendMouseButtonEvent(x, y, 0, true,  game, 0)
        VIM:SendMouseButtonEvent(x, y, 0, false, game, 0)
    end
end

local function anyEnemyCharging()
    local now = tick()
    for plr, exp in pairs(charging) do
        if exp > now then
            local d = distOf(plr); if d and d <= effRange(plr) then return true end
        else charging[plr] = nil end
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

----------------------------------------------------------------- anim scan (hit time + auto-classify)
-- One game:GetObjects pull per anim, cached, feeding BOTH the exact hit time and the
-- auto-classifier. animMeta[id] = { hit=<sec|false>, len=<sec>, name=<string> }.
local animMeta, scanning = {}, {}
local hitTimeCache = {}   -- id -> <sec> | false (no marker) | nil (unscanned); read by scheduleReaction
-- marker name fragments that denote the damage/contact frame (case-insensitive)
local HIT_MARKER_HINTS = { "hit", "attack", "damage", "swing", "cast", "contact", "impact", "active" }
local function looksLikeHit(name)
    local n = string.lower(name or "")
    for _, frag in ipairs(HIT_MARKER_HINTS) do if string.find(n, frag, 1, true) then return true end end
    return false
end

local function scanAnim(id, onDone)
    if not id then return end
    if animMeta[id] then if onDone then onDone(animMeta[id]) end return end
    if scanning[id] then return end
    if type(game.GetObjects) ~= "function" then
        animMeta[id] = { hit = false }; hitTimeCache[id] = false
        if onDone then onDone(animMeta[id]) end
        return
    end
    scanning[id] = true
    task.spawn(function()
        local ok, objs = pcall(function() return game:GetObjects("rbxassetid://" .. id) end)
        scanning[id] = nil
        local meta = { hit = false, len = 0, name = "" }
        if ok and type(objs) == "table" and objs[1] then
            local root = objs[1]
            pcall(function() meta.name = root.Name or "" end)
            local markers = {}
            pcall(function()
                for _, inst in ipairs(root:GetDescendants()) do
                    if inst:IsA("Keyframe") then
                        if inst.Time > meta.len then meta.len = inst.Time end
                    elseif inst:IsA("KeyframeMarker") then
                        local kf = inst.Parent
                        if kf and kf:IsA("Keyframe") then markers[#markers + 1] = { name = inst.Name, t = kf.Time } end
                    end
                end
            end)
            pcall(function() root:Destroy() end)
            -- prefer the earliest hit-ish marker; else the last marker in the swing
            local chosen
            for _, mk in ipairs(markers) do
                if looksLikeHit(mk.name) and (not chosen or mk.t < chosen.t) then chosen = mk end
            end
            if not chosen then
                for _, mk in ipairs(markers) do if not chosen or mk.t > chosen.t then chosen = mk end end
            end
            meta.hit = (chosen and chosen.t and chosen.t > 0) and chosen.t or false
            meta.markers = markers
        end
        animMeta[id] = meta
        hitTimeCache[id] = meta.hit
        if onDone then onDone(meta) end
    end)
end
-- back-compat name used by the reaction scheduler: just warm the cache
local function learnHitTime(id)
    if S.markerTiming then scanAnim(id) end
end

----------------------------------------------------------------- auto-classifier
local function saveLearned()
    local json = HttpService:JSONEncode(learnedClass)
    persist.set("gakuran.learned", json)
    if writefile then pcall(function() writefile(LEARN_FILE, json) end) end
end

-- Decide a class from the scanned metadata. Name first (dev-named assets often carry the
-- move, e.g. "Karate.M2"); else fall back to hit-marker presence + length. Ambiguous with
-- no hit marker -> "ignore" so we never trigger on a dash/emote we misread.
local function classifyMeta(meta)
    local nm = string.lower(meta.name or "")
    if nm ~= "" and nm ~= "keyframesequence" and nm ~= "animation" then
        if nm:find("m2") or nm:find("heavy") or nm:find("charge") or nm:find("strong") or nm:find("smash") then return "heavy" end
        if nm:find("ehit") or nm:find("guardbreak") or nm:find("success") or nm:find("blockhit")
           or nm:find("parry") or nm:find("stun") or nm:find("react") then return "reaction" end
        if nm:find("dash") or nm:find("run") or nm:find("walk") or nm:find("idle") or nm:find("sprint")
           or nm:find("jump") or nm:find("carry") or nm:find("grip") or nm:find("emote") then return "ignore" end
        if nm:find("m1") or nm:find("punch") or nm:find("kick") or nm:find("attack") or nm:find("combo")
           or nm:find("1st") or nm:find("2nd") or nm:find("3rd") or nm:find("4th") then return "m1" end
    end
    if type(meta.hit) == "number" then
        return (meta.len and meta.len >= 0.8) and "heavy" or "m1"   -- has a real contact frame -> it's an attack
    end
    return "ignore"
end

-- Classify one unknown id (async). announce=true -> notify on a fresh learning.
local function classify(id, announce)
    if not id or KNOWN[id] or learnedClass[id] then return end
    scanAnim(id, function(meta)
        if learnedClass[id] then return end                 -- lost a race
        local cls = classifyMeta(meta)
        learnedClass[id] = cls
        saveLearned()
        local label = (meta.name ~= "" and meta.name) or "?"
        log.info(("[gakuran] classified %s (%s, len=%.2f hit=%s) -> %s")
            :format(id, label, meta.len or 0, tostring(meta.hit), cls))
        if announce and (cls == "m1" or cls == "heavy") then
            pcall(function() notify.info(("Gakuran: learned %s -> %s (%s)"):format(id, cls, label), 5) end)
        end
    end)
end

-- Effective attack kind: static DB first, then learned. Returns "m1" | "heavy" | nil.
local function kindOf(id)
    if M1_PARRY[id]    or learnedClass[id] == "m1"    then return "m1" end
    if HEAVY_DODGE[id] or learnedClass[id] == "heavy" then return "heavy" end
    return nil
end

----------------------------------------------------------------- react
-- true when this player is the current Target Select target
local function isTarget(plr) return aimState.target_type == "player" and aimState.target == plr end

-- Schedule the timed block/dodge for an incoming attack. With Read Anim Speed on we wait
-- ONE frame (task.defer) so a play-then-AdjustSpeed has settled -- small players are just
-- fast swingers via a higher track Speed -- then read the LIVE playhead for the exact
-- wall-clock time to the hit (this also cancels detection/signal lag). If the game does
-- NOT scale Speed by size (Speed ~= 1), we fold in a body-size correction so a small
-- attacker still gets a shorter windup. Falls back to fixed windup x size when the track
-- can't be read or the toggle's off.
local function scheduleReaction(plr, trk, id, fallbackWindup, leadOffset, fire)
    local function fallback()
        local wait = math.max(fallbackWindup * sizeScale(plr) - leadOffset - ping(), 0)
        lastTiming = { src = "flat", sec = wait }
        task.delay(wait, fire)
    end
    if not (S.readAnim and trk) then return fallback() end
    task.defer(function()
        local ok,  len = pcall(function() return trk.Length end)
        local sok, spd = pcall(function() return trk.Speed end)
        local pok, pos = pcall(function() return trk.TimePosition end)
        if ok and sok and pok and type(len) == "number" and len > 0.05
           and type(spd) == "number" and spd > 0.01 and type(pos) == "number" then
            -- exact learned hit time for this anim if we have one, else the flat guess
            local ht = S.markerTiming and hitTimeCache[id]
            local usingMarker = (type(ht) == "number" and ht > 0 and ht <= len + 0.05)
            local hitAt = usingMarker and ht or (len * CFG.hitFrac)
            local remaining = math.max(hitAt - pos, 0) / spd
            -- size differentiation: if the game left Speed ~= 1 (didn't speed the track up
            -- for a small rig), inject the body-size scale ourselves so small = sooner.
            if spd > 0.9 and spd < 1.1 then remaining = remaining * sizeScale(plr) end
            local wait = math.max(remaining - leadOffset - ping(), 0)
            lastTiming = { src = usingMarker and "mark" or "live", sec = wait }
            task.delay(wait, fire)
        else
            fallback()
        end
    end)
end

local function react(attacker, id, trk)
    if attacker == LP then return end
    if S.targetOnly and not isTarget(attacker) then return end   -- only the Target Select target
    local kind = kindOf(id)
    if not kind then return end
    learnHitTime(id)   -- warm the exact-hit-time cache once per attack anim (async)
    local mh, hum = myRoot()
    if not mh or not hum or hum.Health <= 0 then return end
    local ac = attacker.Character; local ah = ac and ac:FindFirstChild("HumanoidRootPart")
    if not ah then return end
    local delta = mh.Position - ah.Position
    local dist = delta.Magnitude
    local facing = ah.CFrame.LookVector:Dot(delta.Unit) >= FACING_DOT
    if not S.armed or dist > effRange(attacker) or not facing then return end
    -- Debounce the SAME anim re-firing, but let different combo hits (different ids)
    -- react immediately -- a small/fast player's hits come <0.15s apart.
    local now = tick()
    local lr = lastReact[attacker]
    if lr and lr.id == id and (now - lr.t) < 0.15 then return end
    lastReact[attacker] = { id = id, t = now }

    if kind == "heavy" then
        charging[attacker] = now + CFG.chargeWindow
        if S.dodge then
            scheduleReaction(attacker, trk, id, CFG.heavyWindup, CFG.dodgeLead, function()
                tapKey(DODGE_KEY); counts.dodge = counts.dodge + 1
            end)
        end
    elseif S.parry then
        scheduleReaction(attacker, trk, id, CFG.windup, CFG.perfectLead, function()
            doBlock(CFG.holdTime); counts.parry = counts.parry + 1
        end)
    end
end

----------------------------------------------------------------- grip spam (carry-aware)
-- Driven off Heartbeat so it's a continuous, gap-free stream. Only alive while actually
-- gripping AND not carrying/being carried -- the connection is dropped the instant either
-- condition fails, so there's zero idle per-frame cost.
local function stopGripSpam()
    if gripConn then pcall(function() gripConn:Disconnect() end); gripConn = nil end
    spamActive = false
end
local function startGripSpam()
    if spamActive or carried then return end   -- never start while a carry anim is active
    spamActive = true
    gripConn = RS.Heartbeat:Connect(function()
        if not (gripping and S.armed and S.gripSpam) or carried then stopGripSpam(); return end
        if S.clickCancel and anyEnemyCharging() then return end   -- withhold M1 into a charging heavy
        clickBurst(math.max(1, math.floor(CFG.spamBurst)))
    end)
end

----------------------------------------------------------------- animation hooks
local function hookChar(plr, char)
    local hum = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 5)
    local animator = hum and (hum:FindFirstChildOfClass("Animator") or hum:WaitForChild("Animator", 5))
    if not animator or watched[animator] then return end
    watched[animator] = true
    -- seed the stable-height cache now, while they're (usually) idle
    if not sizeCache[char] then sizeCache[char] = heightOf(plr) end
    track(animator.AnimationPlayed:Connect(function(trk)
        local id = idNum(trk.Animation and trk.Animation.AnimationId)
        if not id then return end
        if plr == LP then
            if GRIP_SELF[id] then
                gripping = true; startGripSpam()
                trk.Stopped:Connect(function() gripping = false end)
            elseif CARRY_SELF[id] then
                -- carrying someone OR being carried: kill any spam and lock it out
                carried = true; stopGripSpam()
                trk.Stopped:Connect(function() carried = false end)
            elseif S.logNew and not KNOWN[id] and not learnedClass[id] then
                -- surface unknown SELF anims so a separate "being carried" id can be caught
                log.info(("[gakuran] SELF anim %s"):format(id))
            end
            return
        end
        if ENEMY_BLOCK[id] then
            blocking[plr] = true
            trk.Stopped:Connect(function() blocking[plr] = nil end)
        end
        react(plr, id, trk)
        -- learn/classify unknown attacker anims we see in combat (in range, facing-ish)
        if S.autoClass and not KNOWN[id] and not learnedClass[id]
           and (not S.targetOnly or isTarget(plr)) then
            local d = distOf(plr)
            if d and d <= effRange(plr) + 8 then classify(id, true) end
        end
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

----------------------------------------------------------------- UI
local statusLbl

local function loadSettings()
    for k in pairs(CFG) do CFG[k] = persist.get("gakuran." .. k, CFG[k]) end
    -- 'armed' is owned by the master feature (feature.lua persists it under
    -- "gakuran.armed.enabled" and calls onToggle on boot), so skip it here.
    for k in pairs(S)   do if k ~= "armed" then S[k] = persist.get("gakuran." .. k, S[k]) end end
    -- learned classifications: persisted string first, then merge the on-disk file
    local ok, decoded = pcall(function() return HttpService:JSONDecode(persist.get("gakuran.learned", "{}")) end)
    learnedClass = (ok and type(decoded) == "table") and decoded or {}
    if readfile and isfile and pcall(function() return isfile(LEARN_FILE) end) and isfile(LEARN_FILE) then
        pcall(function()
            local fromFile = HttpService:JSONDecode(readfile(LEARN_FILE))
            if type(fromFile) == "table" then for k, v in pairs(fromFile) do learnedClass[k] = learnedClass[k] or v end end
        end)
    end
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

    -- pull + classify any logged-but-unclassified anims up front ("have em all")
    if S.autoClass then
        for _, id in ipairs(SEED_LOGGED) do task.spawn(classify, id, false) end
    end

    local box = container.new(window.parent(), "Gakuran")

    -- master enable (+ RightShift to arm/disarm)
    local master
    master = feature.declare({
        id = "gakuran.armed", name = "Combat Enabled",
        description = "Master switch for all Gakuran combat automation. RightShift toggles it in-game. Individual features below still each have their own on/off.",
        default = S.armed, defaultKey = Enum.KeyCode.RightShift,
        onToggle = function(v) S.armed = v and true or false end,   -- feature.lua persists this toggle
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
    subToggle(holder, 9, "Auto-Classify Anims", "autoClass")
    subToggle(holder, 10, "Target Only",        "targetOnly")
    subToggle(holder, 11, "Log New Anims",      "logNew")

    components.Section(holder, "Tuning").LayoutOrder = 20
    tuneSlider(holder, 21, "Anim Hit Point", "hitFrac",   0.20, 0.90, 0.05)
    tuneSlider(holder, 22, "M1 Windup (fallback)", "windup", 0.10, 0.60, 0.01)
    tuneSlider(holder, 23, "Parry Lead",  "perfectLead", 0.00, 0.25, 0.01)
    tuneSlider(holder, 24, "Block Hold",  "holdTime",    0.10, 0.80, 0.05)
    tuneSlider(holder, 25, "Heavy Windup (fallback)","heavyWindup", 0.20, 0.90, 0.01)
    tuneSlider(holder, 26, "Dodge Lead",  "dodgeLead",   0.00, 0.25, 0.01)
    tuneSlider(holder, 27, "Spam Burst (clicks/frame)","spamBurst", 1, 40, 1)

    statusLbl = components.Label(holder, "nearest: -")
    statusLbl.LayoutOrder = 40
    box:add(holder)

    -- wire animation watchers
    for _, p in ipairs(Players:GetPlayers()) do watch(p) end
    track(Players.PlayerAdded:Connect(watch))

    -- manual M1 interception (guard-break + click-cancel)
    pcall(function() CAS:UnbindAction("gkn_m1") end)
    CAS:BindActionAtPriority("gkn_m1", function(_, st)
        if st ~= Enum.UserInputState.Begin or not S.armed then return Enum.ContextActionResult.Pass end
        if gripping then return Enum.ContextActionResult.Pass end   -- our own grip-spam clicks pass straight through
        if S.clickCancel and anyEnemyCharging() then return Enum.ContextActionResult.Sink end
        if S.guardBreak and frontBlocker() then
            tapKey(HEAVY_KEY); counts.gbreak = counts.gbreak + 1
            return Enum.ContextActionResult.Sink
        end
        return Enum.ContextActionResult.Pass
    end, false, 3000, Enum.UserInputType.MouseButton1)
    casBound = true

    -- live status
    local acc = 0
    track(RS.Heartbeat:Connect(function(dt)
        acc = acc + dt; if acc < 0.15 then return end; acc = 0
        if not statusLbl then return end
        local nearest, nPlr
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LP then local d = distOf(plr); if d and (not nearest or d < nearest) then nearest, nPlr = d, plr end end
        end
        local nLearned = 0; for _ in pairs(learnedClass) do nLearned = nLearned + 1 end
        local hStr = nPlr and ("d%.1f h%.1f reach%.1f"):format(nearest, stableHeight(nPlr), effRange(nPlr)) or "-"
        local carryStr = carried and " CARRY" or (gripping and " GRIP" or "")
        statusLbl.Text = ("nearest %s | x%.1f | t:%s %.2fs | P%d D%d B%d | learned:%d%s"):format(
            hStr, REACH, lastTiming.src, lastTiming.sec, counts.parry, counts.dodge, counts.gbreak, nLearned, carryStr)
    end))

    log.info("Gakuran module registered -- flat reach x2.6, size-aware timing, carry-safe grip")
end

-- re-execute teardown: disconnect everything we hooked and undo shared changes.
function GKN.destroy()
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    conns = {}
    if casBound then pcall(function() CAS:UnbindAction("gkn_m1") end); casBound = false end
    if blockActive then pcall(function() VIM:SendKeyEvent(false, BLOCK_KEY, false, game) end); blockActive = false end
    watched, charging, blocking, lastReact = {}, {}, {}, {}
    gripping, carried = false, false
    if gripConn then pcall(function() gripConn:Disconnect() end); gripConn = nil end
    spamActive = false
    statusLbl = nil
end

registry.register(GKN_IDS, GKN)

return GKN
