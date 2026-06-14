-- Evil Plate integration.
--
-- Evil Plate is a multi-mode Roblox game; one mode is hot potato: you're handed a
-- Tool named "HotPotatoBomb" and must touch another player to pass it before your
-- timer hits 0 (the holder at 0 dies). This module auto-returns the bomb to whoever
-- passed it to you.
--
-- Feature: Hot Potato Auto-Return -- on receiving the HotPotatoBomb Tool it picks
-- the giver (an explicit reference on the bomb if one exists, else the nearest
-- player at the instant of receipt = whoever just touched you), equips it, and
-- after a short delay (beats receive-immunity) fakes the Handle's Touched back at
-- the giver via firetouchinterest -- the same touch-faking trick IY's handlekill
-- uses. If the bomb DOESN'T move after "returned ...", the game's pass is a
-- RemoteEvent instead -- swap attemptReturn() for that remote (a remote logger
-- will surface it). Detection is name-scoped to "HotPotatoBomb", so the module
-- stays idle in Evil Plate's other modes (the Tool only exists during the hot-
-- potato round) -- no separate round gating needed.
--
-- Feature: Auto Crate -- in Evil Plate's loot rounds, airdrop / supply crates
-- spawn carrying a ProximityPrompt (or ClickDetector) you normally hold E on.
-- This fires that prompt for you the instant a crate appears (workspace
-- DescendantAdded) and on a Heartbeat sweep, for anything in workspace (or
-- workspace.ActiveEvents) whose name contains airdrop / crate / supply and is
-- within click distance. Ported from the [Spec]evil_plate_crate standalone.

local registry  = require("games.registry")
local window    = require("ui.window")
local container = require("ui.container")
local feature   = require("ui.feature")
local log       = require("core.log")
local notify    = require("ui.notify")

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local LP         = Players.LocalPlayer

-- GameId first (covers every place / VIP server), then the root PlaceId. Resolved
-- from the game URL roblox.com/games/100337093788565 (= PlaceId) -> universeId via
-- apis.roblox.com/universes/v1/places/<placeId>/universe.
local EVILPLATE_IDS = { 9324081218, 100337093788565 }   -- { GameId, PlaceId } -- Evil Plate

local EVILPLATE = {}

local CFG = {
    toolName    = "hotpotatobomb",  -- lowercased substring of the Tool name to match
    returnDelay = 0.7,              -- s before passing back / between retries (immunity buffer + not-instant)
    lobbyTeam   = "lobby",          -- lowercased substring of the team name meaning "out of the round";
                                    -- if the giver is on it (or just joined it) we stop retrying and hold
    touchTries  = 2,                -- firetouchinterest attempts before escalating to the teleport method
    giverMemory = 1.5,              -- s: how recently someone must have TOUCHED us to count as the giver.
                                    -- A pass IS a touch (captured at touch time), so a giver who instantly
                                    -- sprints off is still identified -- distance-at-receipt would miss them.
    giverRadius = 30,               -- FALLBACK when no recent touch was seen (touch didn't fire / raced after
                                    -- the bomb appeared): accept the nearest player within this many studs as
                                    -- the giver. Generous (a just-passed giver may have already fled a bit).
                                    -- The teleport stays gated by teleportMaxDist, so a far fallback giver
                                    -- only gets the subtle firetouch, never an obvious yank.
    teleportMaxDist = 18,           -- only ESCALATE to the teleport-onto-handle method if the giver is within
                                    -- this many studs -- yanking a far player onto your hand reads as lag.
                                    -- Beyond it we keep using the subtler firetouchinterest.
    maxHold     = 4,                -- s: give up retrying after this long. Stops a never-leaves-inventory
                                    -- pass (RemoteEvent game) from teleporting a now-STALE giver round
                                    -- after round -- the "potato teleports to people from old rounds" bug.
}
-- Auto Crate config -- clickRange gates how far a crate prompt may be (studs)
-- before we fire it, so we don't pop crates other players are already on.
local CRATE = {
    clickRange = 60,
}
-- Anti Plate Slip config
local SLIP = {
    platesName = "Plates",   -- workspace.<this> = the folder holding the plates
    edgeMargin = 0,          -- studs kept from the plate edge (0 = stand at the very edge; HRP center can
                             -- reach the edge). Raise it to keep more of you on the plate.
    flingSpeed = 45,         -- horizontal speed above which we STOP clamping (a wind fling carries you off)
    rayDown    = 10,         -- downward raycast length to find the plate under you
}
local enabled      = false   -- Hot Potato Auto-Return gate
local crateEnabled = false   -- Auto Crate gate
local slipEnabled  = false   -- Anti Plate Slip gate
local pending = nil   -- { tool=, giver=, at=, lobby=, teamConn= }
local conns   = {}    -- live connections; torn down in destroy()

local function track(c) conns[#conns + 1] = c; return c end
local function teardownConns()
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    conns = {}
end

-- clear the in-flight return job, disconnecting its per-bomb giver-team watcher
local function clearPending()
    if pending and pending.teamConn then pcall(function() pending.teamConn:Disconnect() end) end
    pending = nil
end

-- ---- helpers (ported from the [Spec] standalone prototype) ----

local function rootOf(char)
    if not char then return nil end
    return char:FindFirstChild("HumanoidRootPart")
        or char:FindFirstChild("Torso")
        or char:FindFirstChild("UpperTorso")
        or char:FindFirstChildWhichIsA("BasePart")
end
local function myRoot() return rootOf(LP.Character) end

local function getHandle(tool)
    local h = tool:FindFirstChild("Handle")
    if h and h:IsA("BasePart") then return h end
    for _, d in ipairs(tool:GetDescendants()) do
        if d:IsA("BasePart") then return d end
    end
    return nil
end

local function nameMatches(name)
    return type(name) == "string" and name:lower():find(CFG.toolName, 1, true) ~= nil
end

-- Who last physically TOUCHED our character, captured at touch time. A pass is a
-- touch, so this identifies the giver reliably even when they immediately sprint
-- away -- unlike "nearest player at receipt", which misses them (they're already
-- far by the time the Tool's ChildAdded fires). Set by hookTouch, read by onReceive.
local recentToucher = nil   -- { player =, at = }

local function playerFromPart(part)
    local cur = part
    while cur do
        local p = Players:GetPlayerFromCharacter(cur)
        if p then return p end
        cur = cur.Parent
    end
    return nil
end

-- our distance to a player's root (for the cosmetic teleport gate); huge if unknown
local function distTo(plr)
    local mr = myRoot()
    local tr = plr and plr.Character and rootOf(plr.Character)
    if not (mr and tr) then return math.huge end
    return (tr.Position - mr.Position).Magnitude
end

-- nearest living other player + distance (fallback giver when no touch was seen)
local function nearestPlayer()
    local best, bestD, mr = nil, math.huge, myRoot()
    if not mr then return nil, math.huge end
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP and p.Character then
            local r   = rootOf(p.Character)
            local hum = p.Character:FindFirstChildOfClass("Humanoid")
            if r and (not hum or hum.Health > 0) then
                local d = (r.Position - mr.Position).Magnitude
                if d < bestD then best, bestD = p, d end
            end
        end
    end
    return best, bestD
end

-- explicit giver reference stored on the bomb (attribute or value object), if any
local GIVER_KEYS = { "last", "prev", "from", "giver", "owner", "holder", "thrower", "sender" }
local function keyHit(s)
    s = s:lower()
    for _, w in ipairs(GIVER_KEYS) do if s:find(w, 1, true) then return true end end
    return false
end
local function giverFromTool(tool)
    local ok, attrs = pcall(function() return tool:GetAttributes() end)
    if ok and attrs then
        for k, v in pairs(attrs) do
            if keyHit(tostring(k)) then
                log.info(("[evilplate] bomb @%s = %s (possible giver ref)"):format(tostring(k), tostring(v)))
                if type(v) == "string" then local p = Players:FindFirstChild(v); if p then return p end
                elseif type(v) == "number" then local p = Players:GetPlayerByUserId(v); if p then return p end end
            end
        end
    end
    for _, d in ipairs(tool:GetDescendants()) do
        if keyHit(d.Name) then
            if d:IsA("ObjectValue") and d.Value then
                local pl = (d.Value:IsA("Player") and d.Value) or Players:GetPlayerFromCharacter(d.Value)
                if pl then return pl end
            elseif d:IsA("StringValue") then
                local p = Players:FindFirstChild(d.Value); if p then return p end
            elseif d:IsA("IntValue") or d:IsA("NumberValue") then
                local p = Players:GetPlayerByUserId(d.Value); if p then return p end
            end
        end
    end
    return nil
end

-- one-time structure dump per receive -- console only, our live-verify aid
local function dumpTool(tool)
    log.info("[evilplate] ===== HotPotatoBomb dump =====")
    log.info(("[evilplate] Name=%s Class=%s Path=%s"):format(tool.Name, tool.ClassName, tool:GetFullName()))
    local ok, attrs = pcall(function() return tool:GetAttributes() end)
    if ok and attrs then for k, v in pairs(attrs) do log.info(("[evilplate]   @%s = %s"):format(tostring(k), tostring(v))) end end
    for _, d in ipairs(tool:GetChildren()) do log.info(("[evilplate]   child: %s (%s)"):format(d.Name, d.ClassName)) end
    local h = getHandle(tool)
    if h then
        local ti = h:FindFirstChild("TouchInterest")
        log.info(("[evilplate]   Handle=%s TouchInterest=%s CanTouch=%s"):format(
            h.Name, ti and "YES (firetouchinterest viable)" or "none (pass may be a RemoteEvent)", tostring(h.CanTouch)))
    else
        log.info("[evilplate]   NO Handle/BasePart (RequiresHandle=false? pass likely a RemoteEvent)")
    end
end

local function equip(tool)
    local char = LP.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    if hum and tool.Parent ~= char then pcall(function() hum:EquipTool(tool) end) end
end

-- fake Touched: try handle->giver and ourRoot->giver (no-op where no TouchInterest)
local function attemptReturn(tool, giver)
    if type(firetouchinterest) ~= "function" then
        log.warn("[evilplate] firetouchinterest unavailable in this executor"); return false
    end
    local theirRoot = rootOf(giver.Character)
    if not theirRoot then return false end
    local sources, fired = {}, false
    local h = getHandle(tool); if h then sources[#sources + 1] = h end
    local mr = myRoot();        if mr then sources[#sources + 1] = mr end
    for _, s in ipairs(sources) do
        pcall(function()
            firetouchinterest(s, theirRoot, 0)  -- begin
            firetouchinterest(s, theirRoot, 1)  -- end
            fired = true
        end)
    end
    return fired
end

-- escalation when firetouchinterest keeps leaving us holding the bomb: locally
-- teleport the giver's character onto the bomb's Handle so a REAL (not faked) Touch
-- fires. It's a client-side CFrame write -- the server snaps the giver back on its
-- next replication -- so it's only as reliable as the game trusting client touches;
-- we fire firetouchinterest in the same frame too, to cover both paths. (NOTE: live-
-- unverified -- if this still doesn't pass it, the game's pass is a RemoteEvent.)
local function attemptTeleportReturn(tool, giver)
    local handle    = getHandle(tool)
    local theirRoot = rootOf(giver.Character)
    if not (handle and theirRoot) then return false end
    pcall(function() theirRoot.CFrame = handle.CFrame end)
    if type(firetouchinterest) == "function" then
        pcall(function()
            firetouchinterest(handle, theirRoot, 0)
            firetouchinterest(handle, theirRoot, 1)
        end)
    end
    return true
end

-- the giver being on the Lobby team means they're dead / spectating ("just joined
-- that team" once they die at 0) -- there's no point bouncing the bomb back to them,
-- so we stop retrying and hold it. Substring + lower() match (team names can vary).
local function inLobby(plr)
    local t = plr and plr.Team
    return t ~= nil and type(t.Name) == "string"
        and t.Name:lower():find(CFG.lobbyTeam, 1, true) ~= nil
end

-- the instant a HotPotatoBomb appears on us
local function onReceive(tool)
    if not enabled then return end
    if pending and pending.tool == tool then return end
    if pending then clearPending() end   -- a new bomb supersedes any in-flight return job
    dumpTool(tool)

    -- Giver = an explicit ref on the bomb, else whoever just TOUCHED us (the pass).
    -- We do NOT guess by who's nearest at receipt: the giver sprints off the instant
    -- they pass, so they're usually already far by the time the Tool appears -- a
    -- distance guess would miss real passes AND, if forced, fling the bomb at someone
    -- now far (looks like lag). No recent toucher = we STARTED the round holding it
    -- -> don't auto-pass.
    local giver = giverFromTool(tool)
    -- preferred: whoever just TOUCHED us (the pass), captured at touch time
    if not giver and recentToucher and (os.clock() - recentToucher.at) <= CFG.giverMemory then
        local p = recentToucher.player
        if p and p.Parent and p ~= LP then giver = p end
    end
    -- fallback: no touch seen (touch didn't fire / raced after the bomb appeared, or
    -- the pass is a RemoteEvent) -> nearest player within giverRadius. The teleport is
    -- still distance-gated, so a far fallback giver only gets the subtle firetouch.
    if not giver then
        local p, d = nearestPlayer()
        if p and d <= CFG.giverRadius then giver = p end
    end
    if not giver then
        log.info("[evilplate] no toucher and nobody within giverRadius -- started with it? not auto-passing")
        notify.info("HotPotatoBomb received (no giver to return to)", 3)
        return
    end

    -- mark pending BEFORE equipping: equip reparents the Tool (Backpack->Character),
    -- which fires Character.ChildAdded and re-enters onReceive; the pending guard at
    -- the top dedupes that re-entry so we don't process the same bomb twice.
    local now = os.clock()
    pending = { tool = tool, giver = giver, at = now, born = now, lobby = false, attempts = 0, method = "touch" }
    -- watch the giver's team: if they join Lobby ("just joined that team") mid-return,
    -- latch it sticky so we stop even if they later bounce back out of the lobby.
    pending.lobby = inLobby(giver)
    -- pcall: a Player always has GetPropertyChangedSignal in real Roblox, but never
    -- let a quirk here abort the receive (pending is already set above).
    pcall(function()
        pending.teamConn = giver:GetPropertyChangedSignal("Team"):Connect(function()
            if pending and pending.giver == giver and inLobby(giver) then
                pending.lobby = true
            end
        end)
    end)
    equip(tool)  -- Handle must be in workspace for the Touched to register
    notify.info(("HotPotatoBomb received -> returning to %s"):format(giver and giver.Name or "?"), 4)
end

local function scan(c)
    if not c then return end
    for _, d in ipairs(c:GetChildren()) do
        if d:IsA("Tool") and nameMatches(d.Name) then onReceive(d) end
    end
end

local function bindContainer(c)
    if not c then return end
    track(c.ChildAdded:Connect(function(d)
        if d:IsA("Tool") and nameMatches(d.Name) then onReceive(d) end
    end))
end

-- record the last OTHER player whose body touched ours, captured at touch time so
-- onReceive can pick the real giver (see recentToucher). Re-hooked per character.
local function hookTouch(char)
    local hrp = rootOf(char)
    if not hrp then return end
    track(hrp.Touched:Connect(function(hit)
        local p = playerFromPart(hit)
        if p and p ~= LP then recentToucher = { player = p, at = os.clock() } end
    end))
end

local function bindCharacter(char)
    if not char then return end
    bindContainer(char)
    hookTouch(char)
    task.defer(scan, char)
end

-- ---- Auto Crate (airdrop / supply / loot-crate opener) ----

local CRATE_WORDS = { "airdrop", "crate", "supply" }
local function crateNameHit(s)
    s = s:lower()
    for _, w in ipairs(CRATE_WORDS) do if s:find(w, 1, true) then return true end end
    return false
end

-- true if `inst` sits under a workspace child named like a crate (used by the
-- reactive DescendantAdded path, where we only have the new prompt itself)
local function isCrateDescendant(inst)
    local cur = inst.Parent
    while cur and cur ~= workspace do
        if crateNameHit(cur.Name) then return true end
        cur = cur.Parent
    end
    return false
end

-- fire one ProximityPrompt / ClickDetector, range-gated to CRATE.clickRange
local function fireCratePrompt(inst)
    if not crateEnabled then return end
    local root = myRoot()
    if not root then return end
    local adornee = inst.Parent
    local inRange = true
    if adornee and adornee:IsA("BasePart") then
        inRange = (adornee.Position - root.Position).Magnitude <= CRATE.clickRange
    end
    if not inRange then return end
    if inst:IsA("ProximityPrompt") and type(fireproximityprompt) == "function" then
        pcall(fireproximityprompt, inst, inst.HoldDuration + 0.1)
        pcall(fireproximityprompt, inst, 0)
    elseif inst:IsA("ClickDetector") and type(fireclickdetector) == "function" then
        pcall(fireclickdetector, inst)
    end
end

-- sweep workspace (+ ActiveEvents) for crate containers and fire their prompts
local function crateScan()
    if not crateEnabled then return end
    if not myRoot() then return end
    local containers = { workspace }
    local ae = workspace:FindFirstChild("ActiveEvents")
    if ae then containers[#containers + 1] = ae end
    for _, c in ipairs(containers) do
        for _, child in ipairs(c:GetChildren()) do
            if crateNameHit(child.Name) then
                for _, desc in ipairs(child:GetDescendants()) do
                    if desc:IsA("ProximityPrompt") or desc:IsA("ClickDetector") then
                        fireCratePrompt(desc)
                    end
                end
            end
        end
    end
end

-- ---- Anti Plate Slip ----
-- Keep the player from walking/sliding off the plate they're standing on. Clamps
-- X/Z to the plate's top surface ONLY while grounded on a workspace.Plates child and
-- not moving fast -- so jumping plate-to-plate and being flung (wind event) are free.

-- the plate (a workspace.Plates child) directly under the player, or nil
local function currentPlate()
    local hrp = myRoot(); if not hrp then return nil end
    local plates = workspace:FindFirstChild(SLIP.platesName); if not plates then return nil end
    local ok, res = pcall(function()
        local rp = RaycastParams.new()
        rp.FilterType = Enum.RaycastFilterType.Include
        rp.FilterDescendantsInstances = { plates }
        return workspace:Raycast(hrp.Position, Vector3.new(0, -SLIP.rayDown, 0), rp)
    end)
    return (ok and res and res.Instance) or nil
end

local AIRBORNE = {
    [Enum.HumanoidStateType.Jumping] = true, [Enum.HumanoidStateType.Freefall] = true,
    [Enum.HumanoidStateType.Flying] = true, [Enum.HumanoidStateType.FallingDown] = true,
    [Enum.HumanoidStateType.Ragdoll] = true, [Enum.HumanoidStateType.PlatformStanding] = true,
}
local heldPlate = nil   -- the plate we're currently locking to (kept across edge ray-misses)
local function antiSlipStep()
    local hrp = myRoot(); if not hrp then heldPlate = nil; return end
    local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
    if not hum then heldPlate = nil; return end
    -- airborne (jumped / falling / flung) -> release, so you can leave the plate
    local ok, st = pcall(function() return hum:GetState() end)
    if ok and AIRBORNE[st] then heldPlate = nil; return end
    -- moving fast (e.g. a wind fling) -> let it carry you off
    local vel = hrp.AssemblyLinearVelocity or hrp.Velocity
    if vel and (vel.X * vel.X + vel.Z * vel.Z) > (SLIP.flingSpeed * SLIP.flingSpeed) then heldPlate = nil; return end
    -- the plate under us; if the down-ray just misses (we're parked right at the edge),
    -- keep the last plate so the lock doesn't flicker off.
    local plate = currentPlate() or heldPlate
    if not plate or not plate.Parent then heldPlate = nil; return end
    heldPlate = plate
    -- clamp in the plate's LOCAL space so rotated plates still work
    local lp = plate.CFrame:PointToObjectSpace(hrp.Position)
    local hx = math.max(0, plate.Size.X / 2 - SLIP.edgeMargin)
    local hz = math.max(0, plate.Size.Z / 2 - SLIP.edgeMargin)
    local clx, clz = math.clamp(lp.X, -hx, hx), math.clamp(lp.Z, -hz, hz)
    if clx ~= lp.X or clz ~= lp.Z then
        local world = plate.CFrame:PointToWorldSpace(Vector3.new(clx, lp.Y, clz))
        hrp.CFrame = CFrame.new(world) * (hrp.CFrame - hrp.CFrame.Position)
    end
end

-- drain pending returns from Heartbeat -- NEVER task.wait inside the receive
-- signal callback on Wave (coroutine may not resume); queue + drain here instead.
-- The same Heartbeat also drives the Auto Crate sweep + Anti Plate Slip.
local function onHeartbeat()
    if crateEnabled then crateScan() end
    if slipEnabled then antiSlipStep() end
    if not pending then return end
    if not enabled then clearPending(); return end

    local job  = pending
    local char = LP.Character
    local bp   = LP:FindFirstChildOfClass("Backpack")

    -- success / done: keep retrying ONLY until the bomb actually leaves our inventory
    local have = job.tool and (job.tool.Parent == char or job.tool.Parent == bp)
    if not have then
        notify.success("Bomb passed -- left your inventory", 3)
        log.info("[evilplate] bomb left inventory -- done")
        clearPending(); return
    end

    -- held too long: the giver ref is stale (the pass is probably a RemoteEvent so
    -- the bomb never leaves us). Stop -- otherwise we'd keep teleporting a giver
    -- from an old round onto the handle forever (the obvious "potato jumps to people
    -- from previous rounds" tell).
    if (os.clock() - (job.born or 0)) > CFG.maxHold then
        log.info("[evilplate] held > maxHold -- giving up (stale giver / RemoteEvent pass)")
        clearPending(); return
    end

    -- giver left the game entirely: nothing to return to, stop and hold
    if not job.giver or job.giver.Parent == nil then
        log.info("[evilplate] giver left game -- stop retrying, holding bomb")
        clearPending(); return
    end

    -- giver is on (or just joined) the Lobby team -> stop retrying and hold the bomb
    if job.lobby or inLobby(job.giver) then
        notify.warn(("Giver %s in Lobby -- holding bomb"):format(job.giver.Name))
        log.info("[evilplate] giver on Lobby team -- stop retrying, holding bomb")
        clearPending(); return
    end

    -- throttle retries to returnDelay (beats receive-immunity; no per-frame spam)
    if (os.clock() - job.at) < CFG.returnDelay then return end
    -- giver mid-respawn (no character right now): wait, don't give up
    if not job.giver.Character then job.at = os.clock(); return end

    -- escalate: firetouchinterest tried touchTries times and we STILL hold the bomb ->
    -- mark for the teleport-onto-handle method to force a real touch
    if job.method == "touch" and job.attempts >= CFG.touchTries then
        job.method = "teleport"
        log.info("[evilplate] escalating to teleport-onto-handle for " .. job.giver.Name)
    end

    -- Only actually teleport when the giver is close enough that pulling them onto
    -- the handle reads as a normal contact pass. If they've fled, stay on the subtle
    -- firetouch -- a long-range yank would look like lag.
    local ok, used
    if job.method == "teleport" and distTo(job.giver) <= CFG.teleportMaxDist then
        used = "teleport"; ok = attemptTeleportReturn(job.tool, job.giver)
    else
        used = "touch";    ok = attemptReturn(job.tool, job.giver)
    end
    job.attempts = job.attempts + 1
    if ok then
        log.info(("[evilplate] %s attempt -> %s (if bomb stays, pass = RemoteEvent)"):format(used, job.giver.Name))
    else
        log.warn("[evilplate] " .. used .. " attempt failed (giver root missing?)")
    end
    job.at = os.clock()  -- schedule next retry; loop continues until the bomb leaves inventory
end

function EVILPLATE.register()
    local buildTag = tostring(rawget(_G, "PANTHEON_BUILD") or "?")
    pcall(function() notify.success("Evil Plate registered (build " .. buildTag .. ")", 6) end)
    log.info("[evilplate] register on PlaceId=" .. tostring(game.PlaceId) .. " GameId=" .. tostring(game.GameId))

    -- detection: backpack + character (rebind on respawn / backpack rebuild). Wired
    -- once at register; onReceive/onHeartbeat gate on `enabled`. destroy() unwires.
    bindContainer(LP:FindFirstChildOfClass("Backpack"))
    track(LP.ChildAdded:Connect(function(c) if c:IsA("Backpack") then bindContainer(c) end end))
    bindCharacter(LP.Character)
    track(LP.CharacterAdded:Connect(bindCharacter))
    track(RunService.Heartbeat:Connect(onHeartbeat))

    -- instant crate reaction: fire any prompt/detector that spawns inside a crate
    -- (the Heartbeat sweep is the fallback for ones present before we connected)
    track(workspace.DescendantAdded:Connect(function(desc)
        if not crateEnabled then return end
        if (desc:IsA("ProximityPrompt") or desc:IsA("ClickDetector")) and isCrateDescendant(desc) then
            task.defer(fireCratePrompt, desc)
        end
    end))

    local box = container.new(window.parent(), "Evil Plate")
    box:add(feature.declare({
        id          = "evilplate.hotpotato_return",
        name        = "Hot Potato Auto-Return",
        description = "When you're passed the HotPotatoBomb, automatically passes it back to whoever gave it to you. Picks the giver from a reference on the bomb if one exists, else the nearest player at the instant you received it (whoever touched you). Equips the bomb and fakes its Touched back at them, retrying every \"Return delay\" seconds until the bomb actually leaves your inventory. If firetouchinterest doesn't pass it after a couple tries, it escalates to teleporting the giver onto the bomb's Handle to force a real touch. Stops (and just holds the bomb) if the giver moves to the Lobby team -- i.e. they died / left the round -- or leaves the game. If the bomb never leaves you even after the teleport method, the game passes via a RemoteEvent instead -- say so and it gets switched.",
        default     = false,
        onToggle    = function(v)
            enabled = v and true or false
            -- enabling mid-hold: re-scan so a bomb you're already holding returns too
            if enabled then
                task.defer(function()
                    scan(LP.Character)
                    scan(LP:FindFirstChildOfClass("Backpack"))
                end)
            end
        end,
        settings    = {
            { type = "slider", name = "Return delay (s)", key = "delay",
              min = 0, max = 2, step = 0.05, default = CFG.returnDelay,
              onChange = function(v) CFG.returnDelay = v end },
        },
    }).root)

    box:add(feature.declare({
        id          = "evilplate.auto_crate",
        name        = "Auto Crate",
        description = "Auto-opens airdrop / supply crates. Instantly fires the ProximityPrompt (or ClickDetector) on anything in workspace -- or workspace.ActiveEvents -- whose name contains \"airdrop\", \"crate\" or \"supply\", the moment it spawns and on a continuous sweep. Only fires prompts within the click distance below, so crates other players are already opening across the map are left alone.",
        default     = false,
        onToggle    = function(v) crateEnabled = v and true or false end,
        settings    = {
            { type = "slider", name = "Click distance (studs)", key = "click_range",
              min = 5, max = 100, step = 1, default = CRATE.clickRange,
              onChange = function(v) CRATE.clickRange = v end },
        },
    }).root)

    box:add(feature.declare({
        id          = "evilplate.anti_plate_slip",
        name        = "Anti Plate Slip",
        description = "Locks you onto whatever plate (workspace.Plates child) you're standing on so you can't accidentally walk or slide off the edge -- it clamps you to the plate's surface. The only ways off are JUMPING (you go airborne so the clamp releases -- jump freely plate to plate) or being FLUNG by an outside force like the wind event (high speed also releases the clamp). Does nothing while you're off the plates.",
        default     = false,
        onToggle    = function(v) slipEnabled = v and true or false end,
        settings    = {
            { type = "slider", name = "Edge margin (studs)", key = "edge_margin",
              min = 0, max = 6, step = 0.5, default = SLIP.edgeMargin,
              onChange = function(v) SLIP.edgeMargin = v end },
            { type = "slider", name = "Fling release speed", key = "fling_speed",
              min = 20, max = 100, step = 1, default = SLIP.flingSpeed,
              onChange = function(v) SLIP.flingSpeed = v end },
        },
    }).root)

    log.info("[evilplate] module registered -- Hot Potato Auto-Return + Auto Crate + Anti Plate Slip")
end

-- Called by init.lua shutdown (Auto Re-Execute / re-execute). register() reruns on
-- every boot, so every connection it made must be undone here or they stack across
-- teleports (see feedback_pantheon_reexec_leaks). The feature row + its keybind are
-- torn down by window/keybinds.destroy; the connections + module state are ours.
function EVILPLATE.destroy()
    enabled      = false
    crateEnabled = false
    slipEnabled  = false
    clearPending()
    teardownConns()
end

registry.register(EVILPLATE_IDS, EVILPLATE)

return EVILPLATE
