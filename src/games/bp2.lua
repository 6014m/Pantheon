-- Breaking Point 2 (GameId 2499076778, PlaceId 6648893133) integration.
--
-- Silent Aim for thrown knives, built from the 2026-10-04 throw recon (BP2_Recon/
-- recon_1004_184857.txt). How BP2 throws work, recorded live:
--
--     Workspace.<you>.Blade.RemoteEvent:FireServer(
--         "release", 1, <server time>, false,
--         <origin V3>,            -- arg 5: where the knife leaves you
--         <TARGET V3>,            -- arg 6: where you aimed -- the server builds the
--                                 --        knife's trajectory from this (confirmed by
--                                 --        the incoming "tknife" events, whose `target`
--                                 --        matches and drives the visible flight)
--         { [playerName] = V3 },  -- arg 7: everyone's positions (client lag report)
--         <attackID hex>, true)
--
-- The aim rewrites ONLY arg 6, to the chosen body part of the enemy nearest your real
-- aim point -- your own crosshair, camera and local knife visual stay untouched. The
-- cycle is deliberately imperfect so it reads as a good player, not an aimbot
-- (user spec): throws 1 and 2 of each cycle land only on a coin flip (a landed throw
-- is another coin flip between Head and Torso), throw 3 always lands. A failed roll
-- passes your real throw through -- a natural miss. Throws with nobody near your aim
-- point don't count toward the cycle (walls, warm-ups).
--
-- Team modes: a player on YOUR team (both Team set, you not Neutral) is never a
-- target; FFA rounds have Team nil all around, so everyone counts. Dead players and
-- spawn-protected ones (ForceField) are skipped.
--
-- The namecall hook is log-proven safe here: the recon ran the same hook through 10
-- live throws without a hiccup. It survives re-exec via a getgenv guard (the handler
-- swaps, the hook installs once).

local registry  = require("games.registry")
local window    = require("ui.window")
local container = require("ui.container")
local feature   = require("ui.feature")
local log       = require("core.log")
local notify    = require("ui.notify")

local Players = game:GetService("Players")
local LP      = Players.LocalPlayer

local BP2_IDS = { 2499076778, 6648893133 }   -- { GameId, PlaceId }

local BP2 = {}

local CFG = {
    enabled    = false,
    landChance = 50,    -- % for throws 1-2 of the cycle
    headChance = 50,    -- % Head vs Torso when a throw lands
    snapRange  = 60,    -- studs from your real aim point an enemy may be "snapped" from
    toasts     = true,
    dryRun     = false, -- log the decisions but never rewrite (diagnosis)
}
local shot = 0          -- position in the 3-throw cycle (advances only on counted throws)

-- NOTHING inside the hook may yield or touch UI: the handler runs in the middle of the
-- game's own FireServer call, where a yield (notify tweens, file writes) is an error that
-- kills the throw ("flat out breaks my knife", 2026-10-04). Toasts and the aim log are
-- queued here and flushed from a deferred thread instead.
local logq = {}
local logAll = ""   -- writefile fallback keeps the whole log in memory
local function qlog(msg, toastIt)
    logq[#logq + 1] = { msg = msg, toast = toastIt and CFG.toasts }
    task.defer(function()
        for _, e in ipairs(logq) do
            log.info("[bp2] " .. e.msg)
            local line = string.format("%.3f %s\n", os.clock(), e.msg)
            local wrote = false
            if type(appendfile) == "function" then
                wrote = pcall(appendfile, "Pantheon/bp2_aim.log", line)
            end
            if not wrote and type(writefile) == "function" then
                logAll = logAll .. line
                pcall(writefile, "Pantheon/bp2_aim.log", logAll)
            end
            if e.toast then pcall(function() notify.info("[BP2 Aim] " .. e.msg, 3) end) end
        end
        table.clear(logq)
    end)
end

-- an enemy worth a knife: alive, parts present, not my teammate, not spawn-protected
local function validVictim(plr)
    if plr == LP then return nil end
    if LP.Team ~= nil and not LP.Neutral and plr.Team == LP.Team then return nil end
    local char = plr.Character
    if not char then return nil end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return nil end
    if char:FindFirstChildOfClass("ForceField") then return nil end
    local head, torso = char:FindFirstChild("Head"), char:FindFirstChild("Torso")
    if not (head or torso) then return nil end
    return head, torso
end

-- the enemy nearest your REAL aim point (so the snap goes to whoever you meant)
local function pickVictim(aimPoint)
    local bestHead, bestTorso, bestDist = nil, nil, CFG.snapRange
    for _, plr in ipairs(Players:GetPlayers()) do
        local head, torso = validVictim(plr)
        if head or torso then
            local ref = torso or head
            local d = (ref.Position - aimPoint).Magnitude
            if d < bestDist then
                bestHead, bestTorso, bestDist = head, torso, d
            end
        end
    end
    return bestHead, bestTorso
end

-- the exact arg shape of a real throw, from the recon (recon_1004_184857.txt):
--   "release", number, number, boolean, Vector3, Vector3, table, string, boolean
-- ANY other "release" (quick throws, charge cancels, other knives' variants we never
-- recorded) passes through untouched -- rewriting an unknown shape is how throws break.
local SHAPE = { "string", "number", "number", "boolean", "Vector3", "Vector3", "table", "string", "boolean" }
local function matchesShape(args)
    if args.n ~= #SHAPE then return false end
    for i, want in ipairs(SHAPE) do
        if typeof(args[i]) ~= want then return false end
    end
    return true
end

-- The hook handler: gets the release's packed args, returns rewritten args (a table
-- from table.pack) to fire instead, or nil to pass the throw through untouched.
-- Runs inside the game's FireServer call: no yields, no UI, no file writes in here.
local function onRelease(remote, args)
    if not CFG.enabled then return nil end
    if game.GameId ~= 2499076778 and game.PlaceId ~= 6648893133 then return nil end
    local char = LP.Character
    if not (char and remote:IsDescendantOf(char)) then return nil end   -- someone else's Blade
    if not matchesShape(args) then
        local shape = {}
        for i = 1, args.n do shape[i] = typeof(args[i]) end
        qlog("release with unrecorded shape (" .. table.concat(shape, ",") .. ") -- passed through")
        return nil
    end

    local head, torso = pickVictim(args[6])
    if not (head or torso) then
        qlog("throw: nobody within " .. CFG.snapRange .. " studs of your aim -- not counted")
        return nil
    end

    shot = shot % 3 + 1
    local lands = shot == 3 or (math.random() * 100 < CFG.landChance)
    if not lands then
        qlog("throw " .. shot .. ": natural miss", true)
        return nil
    end
    local part
    if head and torso then
        part = (math.random() * 100 < CFG.headChance) and head or torso
    else
        part = head or torso
    end
    local verdict = "throw " .. shot .. ": " .. (part.Name == "Head" and "HEADSHOT" or "body")
        .. " -> " .. (part.Parent and part.Parent.Name or "?")
    if CFG.dryRun then
        qlog(verdict .. " (DRY RUN -- not rewritten)", true)
        return nil
    end
    args[6] = part.Position
    qlog(verdict, true)
    return args
end

-- install once per genv; the handler lives in getgenv so a re-exec swaps behaviour
-- without stacking hooks (same pattern as the combat recorder)
local function installHook()
    local G = (getgenv and getgenv()) or _G
    G.BP2_SA = onRelease
    if G.BP2_SA_hooked then return true end
    if not (hookmetamethod and getnamecallmethod) then
        log.info("[bp2] executor lacks hookmetamethod -- Silent Aim unavailable")
        return false
    end
    G.BP2_SA_hooked = true
    local old
    old = hookmetamethod(game, "__namecall", function(self, ...)
        local h = G.BP2_SA
        if h and (...) == "release" and getnamecallmethod() == "FireServer" then
            local ok, newArgs = pcall(h, self, table.pack(...))
            if ok and newArgs then
                return old(self, table.unpack(newArgs, 1, newArgs.n))
            elseif not ok then
                -- a handler bug must never cost a throw: remember the error, fire untouched
                G.BP2_SA_err = tostring(newArgs)
                task.defer(function()
                    pcall(function() log.info("[bp2] handler error: " .. tostring(G.BP2_SA_err)) end)
                end)
            end
        end
        return old(self, ...)
    end)
    return true
end

function BP2.register()
    log.info("[bp2] register on PlaceId=" .. tostring(game.PlaceId)
        .. " GameId=" .. tostring(game.GameId))
    local hooked = installHook()
    -- the log's first line proves WHICH build ran (stale-cache tests have no line)
    qlog("registered, build " .. tostring(rawget(_G, "PANTHEON_BUILD") or "?")
        .. ", hooked=" .. tostring(hooked))

    local box = container.new(window.parent(), "Breaking Point 2")
    box:add(feature.declare({
        id          = "bp2.silent_aim",
        name        = "Silent Aim (thrown knives)",
        description = "Rewrites each knife throw's aim point on its way to the server -- your crosshair, camera and own-screen knife never move. Deliberately imperfect so it reads as skill: throws 1 and 2 of every cycle land on a coin flip (the land chance slider), a landed throw picks Head or Torso by the headshot slider, and throw 3 always lands. A failed roll is your real throw -- a natural miss. The victim is the living enemy nearest to where you actually aimed (within the snap range); teammates in team modes, dead players and spawn-protected players are never picked, and a throw with nobody near your aim (a wall, a warm-up) doesn't advance the cycle.",
        default     = false,
        onToggle    = function(v)
            CFG.enabled = v and hooked or false
            shot = 0
            if v and not hooked then
                pcall(function() notify.warn("BP2 Silent Aim: executor lacks hookmetamethod", 6) end)
            end
        end,
        settings = {
            { type = "slider", name = "Land chance, throws 1-2 (%)", key = "landChance", min = 0, max = 100,
              step = 5, default = 50, onChange = function(v) CFG.landChance = v end },
            { type = "slider", name = "Headshot chance (%)", key = "headChance", min = 0, max = 100,
              step = 5, default = 50, onChange = function(v) CFG.headChance = v end },
            { type = "slider", name = "Snap range around your aim (studs)", key = "snapRange", min = 10, max = 150,
              step = 5, default = 60, onChange = function(v) CFG.snapRange = v end },
            { type = "toggle", name = "Roll toasts", key = "toasts", default = true,
              onChange = function(v) CFG.toasts = v and true or false end },
            { type = "toggle", name = "Dry run (log only, never rewrite)", key = "dryRun", default = false,
              onChange = function(v) CFG.dryRun = v and true or false end },
        },
    }).root)

    log.info("[bp2] Breaking Point 2 module registered")
end

function BP2.destroy()
    CFG.enabled = false
    local G = (getgenv and getgenv()) or _G
    G.BP2_SA = nil   -- the installed hook stays (can't unhook) but goes inert
end

registry.register(BP2_IDS, BP2)

return BP2
