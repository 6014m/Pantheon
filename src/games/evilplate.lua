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
    returnDelay = 0.7,              -- s before passing back (immunity buffer + not-instant)
}
local enabled = false
local pending = nil   -- { tool=, giver=, at= }
local conns   = {}    -- live connections; torn down in destroy()

local function track(c) conns[#conns + 1] = c; return c end
local function teardownConns()
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    conns = {}
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

-- nearest living other players (closest = most likely just touched us to pass it)
local function rankByDistance()
    local mr, list = myRoot(), {}
    if not mr then return list end
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP and p.Character then
            local r   = rootOf(p.Character)
            local hum = p.Character:FindFirstChildOfClass("Humanoid")
            if r and (not hum or hum.Health > 0) then
                list[#list + 1] = { player = p, dist = (r.Position - mr.Position).Magnitude }
            end
        end
    end
    table.sort(list, function(a, b) return a.dist < b.dist end)
    return list
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

-- the instant a HotPotatoBomb appears on us
local function onReceive(tool)
    if not enabled then return end
    if pending and pending.tool == tool then return end
    dumpTool(tool)

    local giver = giverFromTool(tool)
    local ranking = rankByDistance()
    if not giver and ranking[1] then giver = ranking[1].player end

    -- mark pending BEFORE equipping: equip reparents the Tool (Backpack->Character),
    -- which fires Character.ChildAdded and re-enters onReceive; the pending guard at
    -- the top dedupes that re-entry so we don't process the same bomb twice.
    pending = { tool = tool, giver = giver, at = os.clock() }
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

local function bindCharacter(char)
    if not char then return end
    bindContainer(char)
    task.defer(scan, char)
end

-- drain pending returns from Heartbeat -- NEVER task.wait inside the receive
-- signal callback on Wave (coroutine may not resume); queue + drain here instead.
local function onHeartbeat()
    if not pending then return end
    if (os.clock() - pending.at) < CFG.returnDelay then return end
    local job = pending; pending = nil
    if not enabled then return end

    local char = LP.Character
    local bp   = LP:FindFirstChildOfClass("Backpack")
    local have = job.tool and (job.tool.Parent == char or job.tool.Parent == bp)
    if not have then log.info("[evilplate] no longer holding bomb (already passed?)"); return end
    if not (job.giver and job.giver.Character) then log.info("[evilplate] giver gone, cannot return"); return end

    if attemptReturn(job.tool, job.giver) then
        notify.success(("Returned bomb to %s"):format(job.giver.Name), 4)
        log.info("[evilplate] returned to " .. job.giver.Name .. " (if it didn't move, pass = RemoteEvent)")
    else
        notify.warn("Bomb return failed (see console)")
        log.warn("[evilplate] return failed")
    end
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

    local box = container.new(window.parent(), "Evil Plate")
    box:add(feature.declare({
        id          = "evilplate.hotpotato_return",
        name        = "Hot Potato Auto-Return",
        description = "When you're passed the HotPotatoBomb, automatically passes it back to whoever gave it to you. Picks the giver from a reference on the bomb if one exists, else the nearest player at the instant you received it (whoever touched you). Equips the bomb and fakes its Touched back at them after a short delay (to clear receive-immunity). If the bomb doesn't actually leave you, the game passes via a RemoteEvent instead -- say so and it gets switched.",
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

    log.info("[evilplate] module registered -- Hot Potato Auto-Return")
end

-- Called by init.lua shutdown (Auto Re-Execute / re-execute). register() reruns on
-- every boot, so every connection it made must be undone here or they stack across
-- teleports (see feedback_pantheon_reexec_leaks). The feature row + its keybind are
-- torn down by window/keybinds.destroy; the connections + module state are ours.
function EVILPLATE.destroy()
    enabled = false
    pending = nil
    teardownConns()
end

registry.register(EVILPLATE_IDS, EVILPLATE)

return EVILPLATE
