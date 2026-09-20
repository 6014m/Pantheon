-- The Veil (PlaceId 125503525638054, GameId 7970033072) integration.
--
-- Bot Mode fix: Bot Mode kept locking onto things that aren't enemies -- the
-- "Runner" NPCs and the townsfolk who just stand there (trainers, shopkeepers,
-- quest givers). This registers a Bot Mode NPC filter (state.addNpcFilter) that
-- hides them:
--   * Runners: any model named exactly "Runner".
--   * NPCs that don't move: a model that hasn't moved since Pantheon first saw it
--     (anchored roots never do), or one carrying a talk prompt (ProximityPrompt /
--     ClickDetector). The moment a model moves it counts as a live mob for good.
--     Anything inside workspace.Monsters (the game's mob folder) is never hidden
--     by this rule, so an idle mob is still a target.
--   * Summons: The Veil parents them in workspace.Monsters next to real mobs, so
--     Bot Mode happily locked onto your own Wraith. A summon is unmistakable once
--     you know where to look (dumped live, 2026-09-19):
--         Workspace.Monsters.11289857265        <- the MODEL NAME is the owner's UserId
--           StringValue PlayerID = 11289857265  <- owner again
--           StringValue Team     = 11289857265  <- your character carries the same Team value
--           BillboardGui SummonNameGui -> "Sable_SevenFold's Wraith"
--           attributes MobType = Wraith
--     The generic state.summonOwner() never found this: its OWNER_KEYS list holds
--     Owner / Creator / Summoner / ..., and deliberately not PlayerID, which in other
--     games is the player a mob is chasing. So ownership is read here instead.
--   * Loot: dropped outfits in workspace.Drops carry a Humanoid with ~1e26 health,
--     which made them targets too.

local Players   = game:GetService("Players")

local registry  = require("games.registry")
local window    = require("ui.window")
local container = require("ui.container")
local feature   = require("ui.feature")
local state     = require("modules.aim.state")
local log       = require("core.log")

local Workspace = game:GetService("Workspace")

-- GameId first (read from the client log: game_join_loadtime universeid), then the place
local VEIL_IDS = { 7970033072, 125503525638054 }

local Veil = {}

local CFG = {
    enabled       = true,
    skipRunners   = true,
    skipStill     = true,
    moveDistance  = 1.5,   -- studs a model must move from where it was first seen to count as moving
    moveSpeed     = 2,     -- or this root velocity (stud/s) seen at any refresh
    promptRecheck = 5,     -- seconds between talk-prompt rescans per model
    summonRecheck = 3,     -- seconds between summon-ownership rescans per model
    skipSummons    = true,   -- your summons, friendlies' and teammates'
    skipAllSummons = false,  -- every player's summons, friendly or not
    skipDrops      = true,   -- loot models in workspace.Drops (they carry a Humanoid)
}

-- Weak keys: despawned models drop out on their own.
local seenAt      = setmetatable({}, { __mode = "k" })   -- model -> { pos, moved }
local promptCache = setmetatable({}, { __mode = "k" })   -- model -> { has, t }
local summonCache = setmetatable({}, { __mode = "k" })   -- model -> { owner, isSummon, t }
local removeFilter

local function isMonster(model)
    local folder = Workspace:FindFirstChild("Monsters")
    return folder ~= nil and model:IsDescendantOf(folder)
end

local function isDrop(model)
    local folder = Workspace:FindFirstChild("Drops")
    return folder ~= nil and model:IsDescendantOf(folder)
end

-- ---- summons -------------------------------------------------------------
-- A model only counts as a summon when it says so: either it carries the game's
-- SummonNameGui ("<owner>'s Wraith"), or its own name is a UserId belonging to
-- someone in the server. Both are things a real mob never has, so a mob that
-- happens to store a PlayerID (whoever it is chasing) is never mistaken for a pet.
local function stringChild(model, name)
    local v = model:FindFirstChild(name)
    return (v and v:IsA("StringValue")) and v.Value or nil
end

local function playerFromId(id)
    local n = tonumber(id)
    return n and Players:GetPlayerByUserId(n) or nil
end

local function summonNameGui(model)
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("BillboardGui") and d.Name == "SummonNameGui" then return d end
    end
    return nil
end

-- Returns (owner, isSummon). Cached per model for CFG.summonRecheck seconds: the
-- Bot Mode NPC scan runs every 0.5 s and the GUI check walks descendants.
local function summonOwner(model)
    local now = os.clock()
    local c = summonCache[model]
    if c and now - c.t < CFG.summonRecheck then return c.owner, c.isSummon end

    local owner, isSummon = nil, false
    local byName = playerFromId(model.Name)          -- Workspace.Monsters.<UserId>
    local gui = summonNameGui(model)
    if byName or gui then
        isSummon = true
        owner = byName or playerFromId(stringChild(model, "PlayerID"))
                       or playerFromId(stringChild(model, "Team"))
        if not owner and gui then                    -- fall back to "<name>'s Wraith"
            local label = gui:FindFirstChildWhichIsA("TextLabel", true)
            local who = label and label.Text and string.match(label.Text, "^(.-)'s ")
            if who then
                for _, plr in ipairs(Players:GetPlayers()) do
                    if plr.Name == who or plr.DisplayName == who then owner = plr; break end
                end
            end
        end
    end
    summonCache[model] = { owner = owner, isSummon = isSummon, t = now }
    return owner, isSummon
end

-- Your character carries StringValue Team = your UserId, and so does every summon
-- fighting for your side, so a party member's pet reads as friendly too.
local function myTeam()
    local char = Players.LocalPlayer.Character
    return char and stringChild(char, "Team") or nil
end

local function isFriendlySummon(model)
    local owner, isSummon = summonOwner(model)
    if not isSummon then return false end
    if CFG.skipAllSummons then return true end
    if not owner then return false end
    if owner == Players.LocalPlayer or state.isFriendly(owner) then return true end
    local mine = myTeam()
    return mine ~= nil and stringChild(model, "Team") == mine
end

-- True until the model is seen moving (Bot Mode refreshes its NPC list every 0.5 s,
-- which is when this runs).
local function neverMoved(model)
    local root = model:FindFirstChild("HumanoidRootPart")
    if not root then return false end
    local rec = seenAt[model]
    if not rec then
        rec = { pos = root.Position, moved = false }
        seenAt[model] = rec
    end
    if rec.moved then return false end
    if root.Anchored then return true end
    if root.AssemblyLinearVelocity.Magnitude > CFG.moveSpeed
       or (root.Position - rec.pos).Magnitude > CFG.moveDistance then
        rec.moved = true
        return false
    end
    return true
end

local function hasTalkPrompt(model)
    local now = os.clock()
    local c = promptCache[model]
    if c and now - c.t < CFG.promptRecheck then return c.has end
    local has = false
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("ProximityPrompt") or d:IsA("ClickDetector") then has = true; break end
    end
    promptCache[model] = { has = has, t = now }
    return has
end

-- Bot Mode NPC filter: true = hide this model from targeting.
local function npcFilter(model)
    if not CFG.enabled then return false end
    if CFG.skipDrops and isDrop(model) then return true end
    if (CFG.skipSummons or CFG.skipAllSummons) and isFriendlySummon(model) then return true end
    if CFG.skipRunners and model.Name == "Runner" then return true end
    if CFG.skipStill and not isMonster(model) then
        if neverMoved(model) or hasTalkPrompt(model) then return true end
    end
    return false
end

function Veil.register()
    log.info("The Veil module REGISTER on PlaceId=" .. tostring(game.PlaceId) .. " GameId=" .. tostring(game.GameId))

    if removeFilter then removeFilter() end
    removeFilter = state.addNpcFilter(npcFilter)

    local box = container.new(window.parent(), "The Veil")
    box:add(feature.declare({
        id          = "veil.bot_filter",
        name        = "Bot Mode: enemies only",
        description = "Stops Bot Mode from locking onto things that aren't enemies. Skips summons (The Veil parks them in the Monsters folder next to real mobs), dropped loot (it carries a Humanoid), the Runner NPCs (anything named \"Runner\") and NPCs that don't move -- anything that hasn't moved since Pantheon first saw it, anchored NPCs, and NPCs you can talk to. Anything that starts moving counts as a target from then on, and mobs in the game's Monsters folder are always targets.",
        default     = true,
        onToggle    = function(v) CFG.enabled = v and true or false end,
        settings = {
            { type = "toggle", name = "Skip your + friendlies' summons", key = "skip_summons", default = true,
              onChange = function(v) CFG.skipSummons = v and true or false end },
            { type = "toggle", name = "Skip EVERY player's summons", key = "skip_all_summons", default = false,
              onChange = function(v) CFG.skipAllSummons = v and true or false end },
            { type = "toggle", name = "Skip dropped loot", key = "skip_drops", default = true,
              onChange = function(v) CFG.skipDrops = v and true or false end },
            { type = "toggle", name = "Skip Runners", key = "skip_runners", default = true,
              onChange = function(v) CFG.skipRunners = v and true or false end },
            { type = "toggle", name = "Skip NPCs that don't move", key = "skip_still", default = true,
              onChange = function(v) CFG.skipStill = v and true or false end },
            { type = "slider", name = "Movement to count as a mob (studs)", key = "move_distance",
              min = 0.5, max = 10, step = 0.5, default = 1.5,
              onChange = function(v) CFG.moveDistance = v end },
        },
    }).root)

    log.info("The Veil module registered -- Bot Mode filter: summons, loot, Runners, idle NPCs")
end

-- Called by init.lua's shutdown (re-execute / Auto Re-Execute): drop the filter so
-- it doesn't stack across boots or linger in another game.
function Veil.destroy()
    if removeFilter then
        pcall(removeFilter)
        removeFilter = nil
    end
    table.clear(seenAt)
    table.clear(promptCache)
    table.clear(summonCache)
end

registry.register(VEIL_IDS, Veil)

return Veil
