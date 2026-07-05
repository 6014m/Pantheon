-- Gakuran (PlaceId 128736949265057, GameId 9199655655) combat integration.
--
-- Registered into the game registry; its container only appears when you're in
-- Gakuran (init.lua calls registry.current().register() gated on PlaceId/GameId),
-- so none of this runs -- or costs perf -- in any other game.
--
-- Ported from the standalone [Spec] Gakuran Combat script. Watches nearby enemies'
-- animations and reacts: incoming M1 -> hold F (perfect block), incoming heavy (M2)
-- -> tap Q (dodge). Plus grip-spam (auto M1 while you grip), guard-break (M1 into a
-- blocker -> R heavy), click-cancel (don't punch into a charging heavy), and a
-- per-size auto-reach learner that keeps a separate learned trigger distance for
-- each opponent size (a single shared reach broke whenever you switched sizes).
-- Inputs: M1=LClick, heavy=R, block=F(hold), dodge=Q, blink=RClick. EHit/M2Success/
-- Guardbreak are hit-REACTIONS (not triggers) -- including them made it react to your
-- own landed hits.

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

local GKN_IDS  = { 9199655655, 128736949265057 }   -- GameId first, then the known PlaceId
local NEW_FILE = "gakuran_new_anims.json"
local BLOCK_KEY, DODGE_KEY, HEAVY_KEY = Enum.KeyCode.F, Enum.KeyCode.Q, Enum.KeyCode.R

local GKN = {}

----------------------------------------------------------------- settings (persisted)
local CFG = {   -- numeric tunables, default reach locked to 2.6 (confirmed correct)
    reach = 2.6, windup = 0.33, perfectLead = 0.07, holdTime = 0.35,
    heavyWindup = 0.50, dodgeLead = 0.05, chargeWindow = 0.60,
    -- when reading anim speed: fraction of the swing that elapses before the hit lands
    hitFrac = 0.5,
    -- grip M1 spam fires spamBurst full clicks EVERY frame (Heartbeat-driven) so
    -- the stream is continuous with no gaps; raise it for more clicks per frame.
    spamBurst = 12,
}
local S = {     -- feature toggles
    armed = true, parry = true, dodge = true, gripSpam = true,
    guardBreak = true, clickCancel = true, autoReach = true, logNew = false,
    -- time parries off each attacker's real AnimationTrack (per-style / per-attack
    -- swing speed) instead of one flat windup
    readAnim = true,
    -- Only parry/log the Target Select target's attacks (no misfires from other
    -- nearby players). Needs Target Select engaged on someone.
    targetOnly = true,
}
local FACING_DOT = 0.15

----------------------------------------------------------------- anim DBs
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
local GRIP_SELF = { ["108723830385066"]=true, ["71363952449940"]=true }
local BLOCKHIT  = { ["134852521037165"]=true, ["138017825490326"]=true, ["76143419310137"]=true }
-- Catalogued NON-attacks that kept surfacing in the "new anim" log (dashes,
-- run/walk, idle stances, enemy perfect-block). They're not triggers and never
-- will be, so fold them into KNOWN to stop them re-flagging and burying a
-- genuinely new attack in noise. (verified against gakuran_anims_classified.json)
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
for _, t in ipairs({ M1_PARRY, HEAVY_DODGE, ENEMY_BLOCK, GRIP_SELF, REACTIONS, IGNORE_NOISE }) do
    for id in pairs(t) do KNOWN[id] = true end
end

----------------------------------------------------------------- runtime state
local conns = {}
local function track(c) conns[#conns + 1] = c; return c end
local watched, charging, blocking, lastReact, pendingAtk = {}, {}, {}, {}, {}
local gripping, spamActive, blockActive, casBound = false, false, false, false
local gripConn = nil   -- Heartbeat driving the grip click stream (nil while idle)
-- Learned trigger distances, BUCKETED BY OPPONENT SIZE. A single shared reach
-- value got dragged around every time you switched between a big and a small
-- opponent; instead each size bucket keeps its own preset so they never fight
-- each other. presets["<bucket>"] = { dist = <smoothed connect distance>, n, height }.
local presets = {}
local sizeCache = setmetatable({}, { __mode = "k" })   -- char -> stable height (weak; GCs with the char)
local counts = { parry = 0, dodge = 0, gbreak = 0 }
local newData, seenNew = {}, {}

----------------------------------------------------------------- helpers
local REF_HEIGHT = 5.0     -- a normal R6 rig is ~5 studs tall
local MARGIN     = 1.12    -- trigger a hair past the measured connect distance
local BUCKET     = 1.0     -- size-bucket granularity in studs (one preset learned per bucket)

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

-- GetExtentsSize() flexes with the current animation pose, which would make a
-- character hop between size buckets mid-fight. Measure once per character life
-- (weak-keyed cache, seeded at hook time while they're idle) so a size stays put.
local function stableHeight(plr)
    local c = plr.Character; if not c then return REF_HEIGHT end
    local h = sizeCache[c]
    if not h then h = heightOf(plr); sizeCache[c] = h end
    return h
end
local function bucketIndex(h) return math.floor(h / BUCKET + 0.5) end

-- Trigger distance for THIS specific opponent. With Auto Reach on we use the
-- learned preset for their size bucket; for a size we haven't calibrated yet we
-- scale the nearest calibrated bucket by height, and with no presets at all we
-- fall back to the plain height x reach slider (== the original behaviour).
-- Auto Reach off is always pure manual height x reach.
local function presetDist(plr)
    local h = stableHeight(plr)
    if not S.autoReach then return h * CFG.reach end
    local bi = bucketIndex(h)
    local p = presets[tostring(bi)]
    if p and p.n > 0 then return p.dist * MARGIN end
    local best, bd
    for k, pp in pairs(presets) do
        if pp.n and pp.n > 0 then
            local dd = math.abs((tonumber(k) or bi) - bi)
            if not bd or dd < bd then best, bd = pp, dd end
        end
    end
    if best and best.height and best.height > 0 then return best.dist * MARGIN * (h / best.height) end
    return h * CFG.reach
end
local function effRange(plr) return presetDist(plr) end   -- learned, per-opponent-size

-- Swing speed scales with body size (smaller = faster swing = shorter windup),
-- so scale the time-to-impact by attacker height vs a normal R6 (~5 studs).
-- Clamped so extreme sizes can't produce absurd timings. CFG.windup / heavyWindup
-- are the values at normal size; this stretches/shrinks them per attacker.
local function sizeScale(plr) return math.clamp(stableHeight(plr) / REF_HEIGHT, 0.3, 2.0) end

-- Fresh block-start per hit: if a prior hold is still active (fast combo), release
-- and immediately re-press so each hit opens its own perfect-block window. A
-- generation token makes sure only the latest hold's release timer fires, so an
-- earlier timer can't drop the block we just re-pressed for a newer hit.
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
-- Fire n full down/up left-clicks at the current cursor. The mouse location is
-- read once and reused so a large per-frame burst stays cheap.
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

----------------------------------------------------------------- auto-reach learner (per-size presets)
local function mostRecentAttacker()
    local now = tick(); local best, bt
    for plr, info in pairs(pendingAtk) do
        if now - info.t <= 0.8 and (not bt or info.t > bt) then best, bt = plr, info.t end
    end
    return best
end
local function savePresets()
    -- Store as a JSON STRING, not the live table: persist.set dedups by ==, and a
    -- table mutated in place keeps the same reference so the save would be skipped.
    persist.set("gakuran.presets", HttpService:JSONEncode(presets))
end
-- Called when an attack actually LANDS on us (health drop / block-hit): record how
-- far the attacker was into THAT attacker's size bucket. Climb fast toward hits
-- that out-ranged the bucket (we must extend to catch them next time), relax slowly
-- toward shorter ones. Only the matching bucket moves, so other sizes are untouched.
local function sampleConnect(plr)
    if not S.autoReach or not plr then return end
    local d, h = distOf(plr), stableHeight(plr)
    if not d or h <= 0 then return end
    if d < h or d > h * 6 then return end            -- ignore nonsense samples (connect ratio 1..6)
    local key = tostring(bucketIndex(h))
    local p = presets[key]
    if not p then p = { dist = d, n = 0, height = h }; presets[key] = p end
    if d > p.dist then p.dist = p.dist + (d - p.dist) * 0.5
    else               p.dist = p.dist + (d - p.dist) * 0.05 end
    p.height = p.height + (h - p.height) * 0.2       -- track the bucket's real average height
    p.n = p.n + 1
    savePresets()
end

----------------------------------------------------------------- react + grip spam
-- true when this player is the current Target Select target
local function isTarget(plr) return aimState.target_type == "player" and aimState.target == plr end

-- Schedule the timed block/dodge for an incoming attack. With Read Anim Speed on
-- we wait ONE frame (task.defer) so a play-then-AdjustSpeed has settled -- small
-- players are just fast swingers via a higher AnimationTrack speed -- then read
-- the LIVE playhead (TimePosition) for the exact wall-clock time left until the
-- hit, which also cancels out detection/signal lag. Falls back to the fixed
-- windup x body-size scale when the track can't be read or the toggle's off.
local function scheduleReaction(plr, trk, fallbackWindup, leadOffset, fire)
    local function fallback()
        task.delay(math.max(fallbackWindup * sizeScale(plr) - leadOffset - ping(), 0), fire)
    end
    if not (S.readAnim and trk) then return fallback() end
    task.defer(function()
        local ok,  len = pcall(function() return trk.Length end)
        local sok, spd = pcall(function() return trk.Speed end)
        local pok, pos = pcall(function() return trk.TimePosition end)
        if ok and sok and pok and type(len) == "number" and len > 0.05
           and type(spd) == "number" and spd > 0.01 and type(pos) == "number" then
            local remaining = math.max(len * CFG.hitFrac - pos, 0) / spd
            task.delay(math.max(remaining - leadOffset - ping(), 0), fire)
        else
            fallback()
        end
    end)
end

local function react(attacker, id, trk)
    if attacker == LP then return end
    if S.targetOnly and not isTarget(attacker) then return end   -- only the Target Select target
    local heavy, m1 = HEAVY_DODGE[id], M1_PARRY[id]
    if not heavy and not m1 then return end
    local mh, hum = myRoot()
    if not mh or not hum or hum.Health <= 0 then return end
    local ac = attacker.Character; local ah = ac and ac:FindFirstChild("HumanoidRootPart")
    if not ah then return end
    local delta = mh.Position - ah.Position
    local dist = delta.Magnitude
    local facing = ah.CFrame.LookVector:Dot(delta.Unit) >= FACING_DOT
    if facing and dist <= 45 then pendingAtk[attacker] = { t = tick() } end
    if not S.armed or dist > effRange(attacker) or not facing then return end
    -- Debounce the SAME anim re-firing, but let different combo hits (different
    -- ids) react immediately -- a small/fast player's hits come <0.15s apart, so
    -- a per-attacker debounce was skipping their 2nd/3rd hit.
    local now = tick()
    local lr = lastReact[attacker]
    if lr and lr.id == id and (now - lr.t) < 0.15 then return end
    lastReact[attacker] = { id = id, t = now }

    if heavy then
        charging[attacker] = now + CFG.chargeWindow
        if S.dodge then
            scheduleReaction(attacker, trk, CFG.heavyWindup, CFG.dodgeLead, function()
                tapKey(DODGE_KEY); counts.dodge = counts.dodge + 1
            end)
        end
    elseif S.parry then
        scheduleReaction(attacker, trk, CFG.windup, CFG.perfectLead, function()
            doBlock(CFG.holdTime); counts.parry = counts.parry + 1
        end)
    end
end

-- Grip M1 spam. Driven off Heartbeat so it's a continuous, gap-free stream: the
-- old task.wait loop was throttled by its interval AND jittered whenever the
-- scheduler ran long. Every frame we fire spamBurst full clicks (raise Spam Burst
-- for more "sets" per frame). Only alive while actually gripping -- the connection
-- is dropped the instant the grip ends, so there's zero idle per-frame cost.
local function stopGripSpam()
    if gripConn then pcall(function() gripConn:Disconnect() end); gripConn = nil end
    spamActive = false
end
local function startGripSpam()
    if spamActive then return end
    spamActive = true
    gripConn = RS.Heartbeat:Connect(function()
        if not (gripping and S.armed and S.gripSpam) then stopGripSpam(); return end
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
    -- seed the stable-height cache now, while they're (usually) idle, so a size
    -- bucket isn't first measured from a mid-swing pose
    if not sizeCache[char] then sizeCache[char] = heightOf(plr) end
    track(animator.AnimationPlayed:Connect(function(trk)
        local id = idNum(trk.Animation and trk.Animation.AnimationId)
        if not id then return end
        if plr == LP then
            if GRIP_SELF[id] then
                gripping = true; startGripSpam()
                trk.Stopped:Connect(function() gripping = false end)
            end
            if BLOCKHIT[id] then sampleConnect(mostRecentAttacker()) end
            return
        end
        if ENEMY_BLOCK[id] then
            blocking[plr] = true
            trk.Stopped:Connect(function() blocking[plr] = nil end)
        end
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
local function bindSelf(c)
    local hum = c:FindFirstChildOfClass("Humanoid") or c:WaitForChild("Humanoid", 5)
    if not hum then return end
    local last = hum.Health
    track(hum.HealthChanged:Connect(function(h)
        if h < last - 0.01 then sampleConnect(mostRecentAttacker()) end
        last = h
    end))
end

----------------------------------------------------------------- UI
local statusLbl, reachSlider

local function loadSettings()
    for k in pairs(CFG) do CFG[k] = persist.get("gakuran." .. k, CFG[k]) end
    -- 'armed' is owned by the master feature (feature.lua persists it under
    -- "gakuran.armed.enabled" and calls onToggle on boot), so skip it here.
    for k in pairs(S)   do if k ~= "armed" then S[k] = persist.get("gakuran." .. k, S[k]) end end
    -- learned per-size reach presets (stored as a JSON string; see savePresets)
    local ok, decoded = pcall(function() return HttpService:JSONDecode(persist.get("gakuran.presets", "{}")) end)
    presets = (ok and type(decoded) == "table") and decoded or {}
    for k, p in pairs(presets) do
        if type(p) ~= "table" then presets[k] = nil
        else p.dist = tonumber(p.dist) or 0; p.n = tonumber(p.n) or 0
             p.height = tonumber(p.height) or (tonumber(k) or REF_HEIGHT) end
    end
end

local function subToggle(holder, order, name, key, desc)
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

    -- feature toggles + tuning sliders in one holder
    local holder = Instance.new("Frame")
    holder.Size = UDim2.new(1, 0, 0, 0); holder.AutomaticSize = Enum.AutomaticSize.Y; holder.BackgroundTransparency = 1
    local hl = Instance.new("UIListLayout", holder); hl.SortOrder = Enum.SortOrder.LayoutOrder; hl.Padding = UDim.new(0, 2)

    components.Section(holder, "Features").LayoutOrder = 1
    subToggle(holder, 2, "Auto Parry (F)",   "parry")
    subToggle(holder, 3, "Heavy Dodge (Q)",  "dodge")
    subToggle(holder, 4, "Grip Spam M1",     "gripSpam")
    subToggle(holder, 5, "Guard Break (R)",  "guardBreak")
    subToggle(holder, 6, "Click Cancel",     "clickCancel")
    subToggle(holder, 7, "Auto Reach (learn per size)", "autoReach")
    subToggle(holder, 8, "Read Anim Speed",  "readAnim")
    subToggle(holder, 9, "Target Only",      "targetOnly")
    subToggle(holder, 10, "Log New Anims",   "logNew")

    components.Section(holder, "Tuning").LayoutOrder = 20
    reachSlider = tuneSlider(holder, 21, "Reach x (default / unlearned)", "reach", 0.5, 5.0, 0.1)
    tuneSlider(holder, 22, "Anim Hit Point", "hitFrac",   0.20, 0.90, 0.05)
    tuneSlider(holder, 23, "M1 Windup (fallback)", "windup", 0.10, 0.60, 0.01)
    tuneSlider(holder, 24, "Parry Lead",  "perfectLead", 0.00, 0.25, 0.01)
    tuneSlider(holder, 25, "Block Hold",  "holdTime",    0.10, 0.80, 0.05)
    tuneSlider(holder, 26, "Heavy Windup (fallback)","heavyWindup", 0.20, 0.90, 0.01)
    tuneSlider(holder, 27, "Dodge Lead",  "dodgeLead",   0.00, 0.25, 0.01)
    tuneSlider(holder, 28, "Spam Burst (clicks/frame)","spamBurst", 1, 40, 1)

    local resetBtn = components.Button(holder, { text = "Reset Learned Reach", onClick = function()
        presets = {}
        savePresets()
        pcall(function() notify.success("Gakuran reach presets cleared", 4) end)
    end })
    resetBtn.LayoutOrder = 30

    statusLbl = components.Label(holder, "nearest: -")
    statusLbl.LayoutOrder = 40
    box:add(holder)

    -- wire animation watchers
    for _, p in ipairs(Players:GetPlayers()) do watch(p) end
    track(Players.PlayerAdded:Connect(watch))
    if LP.Character then bindSelf(LP.Character) end
    track(LP.CharacterAdded:Connect(function(c) task.wait(0.2); bindSelf(c) end))

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
        local nPresets = 0; for _ in pairs(presets) do nPresets = nPresets + 1 end
        local hStr = nPlr and ("d%.1f h%.1f reach%.1f"):format(nearest, stableHeight(nPlr), effRange(nPlr)) or "-"
        local mode = S.autoReach and ("learned:" .. nPresets .. " sizes") or ("manual x" .. string.format("%.2f", CFG.reach))
        statusLbl.Text = ("nearest %s | %s | P%d D%d B%d"):format(hStr, mode, counts.parry, counts.dodge, counts.gbreak)
    end))

    log.info("Gakuran module registered -- combat panel + auto-reach")
end

-- re-execute teardown: disconnect everything we hooked and undo shared changes.
function GKN.destroy()
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    conns = {}
    if casBound then pcall(function() CAS:UnbindAction("gkn_m1") end); casBound = false end
    if blockActive then pcall(function() VIM:SendKeyEvent(false, BLOCK_KEY, false, game) end); blockActive = false end
    watched, charging, blocking, lastReact, pendingAtk = {}, {}, {}, {}, {}
    gripping = false
    if gripConn then pcall(function() gripConn:Disconnect() end); gripConn = nil end
    spamActive = false
    statusLbl, reachSlider = nil, nil
end

registry.register(GKN_IDS, GKN)

return GKN
