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

local log = require("core.log")

local LP = Players.LocalPlayer

local Weave = {}

local CFG = {
    enabled      = false,
    key          = Enum.KeyCode.F,
    lead         = 0.25,    -- press this long before impact (measured sweet spot at 46 ms ping)
    basePing     = 0.046,   -- ping the lead was measured at; extra ping adds to the lead
    cooldown     = 0.5,     -- presses closer than this are ignored by the game
    iframeFrom   = 0.10,    -- a press covers hits landing from +0.10 ...
    iframeTo     = 0.40,    -- ... to +0.40 s after it
    meleeRange   = 12,      -- mob must be this close when its swing starts
    meleeFacing  = 80,      -- and facing within this many degrees of you
    melee        = true,
    projectiles  = true,
    projMiss     = 4,       -- a projectile passing closer than this counts as a hit
    anyProj      = false,   -- also weave unknown fast parts (off: pickups home in on you too)
    hitboxes     = true,
    hitboxDelay  = 0.3,     -- static AoE hitboxes: seconds after they cover you before weaving
    verbose      = false,   -- print every weave and its reason to the console
}

-- attack animation -> seconds from anim start to damage (median of clean hits on you)
local ATTACKS = {
    ["107426583476702"] = 0.58,  -- shared swing: Skeleton, Armored Skeleton, Wraith, Hivelings, Alien...
    ["110285618672790"] = 0.57,  -- Ancient Bones
    ["102522251341739"] = 0.65,  -- Ancient Bones
    ["116165199693856"] = 0.34,  -- Shrouded
    ["84146368125308"]  = 0.57,  -- Clown
    ["85194526199823"]  = 0.33,  -- Imp
    ["127688919744763"] = 0.50,  -- Runner
    ["74743744689930"]  = 0.65,  -- Runner
}
local extra = {}   -- user-added "id=seconds" pairs from the settings textbox

-- enemy AoE / hitbox parts that covered you before damage landed
local HOSTILE_PARTS = {
    DeathExplosionHitbox = true, PoisonSmoke = true, IceSurge = true, LightningStrike = true,
    Bladey = true, Blade = true, BlackFlash = true, BlackSpikePart = true, Spike = true,
    ShatterProjectile = true, GreenBeam = true, SentryLaser = true,
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
local pending = {}         -- scheduled weaves: { at, reason }
local presses = {}         -- recent press times (os.clock)
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

--------------------------------------------------------------------- pressing

local function press(reason)
    if UIS:GetFocusedTextBox() or not alive() then return end
    local t = now()
    presses[#presses + 1] = t
    if #presses > 8 then table.remove(presses, 1) end
    weaves += 1
    pcall(function() VIM:SendKeyEvent(true, CFG.key, false, game) end)
    task.delay(0.03, function() pcall(function() VIM:SendKeyEvent(false, CFG.key, false, game) end) end)
    if CFG.verbose then log.info(string.format("[Weave] #%d %s", weaves, reason)) end
end

-- would a press at time p (already made or scheduled) cover an impact at time i?
local function covers(p, i) return i - p >= CFG.iframeFrom and i - p <= CFG.iframeTo end

-- Plan a weave for a hit expected at `impact` (os.clock time).
local function want(impact, reason)
    for _, p in ipairs(presses) do if covers(p, impact) then return end end
    for _, s in ipairs(pending) do if covers(s.at, impact) then return end end
    local at = impact - leadNow()
    -- respect the game's cooldown: push later if we can still cover the hit, else give up
    local last = presses[#presses] or -math.huge
    for _, s in ipairs(pending) do last = math.max(last, s.at) end
    if at < last + CFG.cooldown then
        at = last + CFG.cooldown
        if impact - at < CFG.iframeFrom then return end
    end
    pending[#pending + 1] = { at = math.max(at, now()), reason = reason }
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
    local anim = track.Animation
    local id = anim and string.match(anim.AnimationId, "%d+")
    local impact = id and (extra[id] or ATTACKS[id])
    if not impact then return end
    local r = root()
    if not r or not mroot.Parent then return end
    if (mroot.Position - r.Position).Magnitude > CFG.meleeRange then return end
    if facingDeg(mroot.CFrame, r.Position) > CFG.meleeFacing then return end
    local t0 = now()
    want(t0 + impact, string.format("%s swing %s (+%.2fs)", model.Name, id, impact))
end

local function hookMob(model)
    if mobConns[model] or not model:IsA("Model") then return end
    if model == LP.Character or Players:GetPlayerFromCharacter(model) or isSummon(model) then return end
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

local looked, lookedAt = 0, 0
local function onPart(part)
    if not (running and CFG.enabled) or not part:IsA("BasePart") then return end
    if IGNORE_PARTS[part.Name] then return end
    local char = LP.Character
    if char and part:IsDescendantOf(char) then return end
    local t = now()
    if t - lookedAt >= 1 then looked, lookedAt = 0, t end
    looked += 1
    if looked > 150 then return end
    -- mob limbs / accessories: only named hostile parts count inside a character model
    if insideHumanoidModel(part) and not HOSTILE_PARTS[part.Name] then return end
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
        for part, rec in pairs(tracked) do
            local age = t - rec.first
            if not part.Parent or age > 4 or rec.fired then
                tracked[part] = nil
            else
                local pos = part.Position
                local dt = t - rec.t
                if dt > 0 then
                    local vel = (pos - rec.pos) / dt
                    rec.pos, rec.t = pos, t
                    local speed = vel.Magnitude
                    if CFG.projectiles and speed > 15 and age > 0.03
                       and (CFG.anyProj or HOSTILE_PARTS[part.Name]) then
                        local rel = me - pos
                        local eta = rel:Dot(vel) / (speed * speed)
                        if eta > 0 then
                            local miss = (rel - vel * eta).Magnitude
                            if miss <= CFG.projMiss + math.max(part.Size.X, part.Size.Y, part.Size.Z) * 0.5
                               and eta <= leadNow() + 0.05 then
                                rec.fired = true
                                want(t + eta, string.format("projectile %s eta %.2fs miss %.1f", part.Name, eta, miss))
                            end
                        end
                    elseif CFG.hitboxes and HOSTILE_PARTS[part.Name] and speed <= 15 and coversMe(part, me, 1.5) then
                        rec.fired = true
                        want(t + CFG.hitboxDelay + leadNow(), "hitbox " .. part.Name)
                    end
                end
            end
        end
    end

    for i = #pending, 1, -1 do
        local s = pending[i]
        if t >= s.at then
            table.remove(pending, i)
            press(s.reason)
        end
    end
end

--------------------------------------------------------------------- lifecycle

function Weave.start()
    if running then return end
    running = true
    conns[#conns + 1] = RunService.Heartbeat:Connect(function()
        local ok, err = pcall(step)
        if not ok and CFG.verbose then log.warn("[Weave] step: " .. tostring(err)) end
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
    table.clear(pending)
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
        description = "Presses your weave key so its i-frames cover incoming hits. Melee swings are timed from the mob's attack animation (the game's melee has no visible hitbox), known enemy projectiles are tracked until they are about to reach you, and enemy AoE hitboxes that cover you trigger a weave too. Your own Aegis Banner / flower / summon effects are ignored. Respects the ~0.5 s weave cooldown and skips a weave when one already covers the hit. Timings come from recorded fights at ~46 ms ping; raise 'Press before impact' if hits still land right after the weave, lower it if they land before it.",
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
            { type = "toggle", name = "Unknown projectiles too", key = "any_proj", default = false,
              onChange = function(v) CFG.anyProj = v and true or false end },
            { type = "toggle", name = "Enemy AoE hitboxes", key = "hitboxes", default = true,
              onChange = function(v) CFG.hitboxes = v and true or false end },
            { type = "slider", name = "AoE: wait before weaving (s)", key = "hitbox_delay", min = 0, max = 1, step = 0.05,
              default = 0.3, onChange = function(v) CFG.hitboxDelay = v end },
            { type = "textbox", name = "Extra attacks (animId=seconds, ...)", key = "extra",
              placeholder = "117802002100480=0.74", default = "",
              onChange = function(v) parseExtra(v) end },
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
