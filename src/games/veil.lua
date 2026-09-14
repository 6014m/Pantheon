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
}

-- Weak keys: despawned models drop out on their own.
local seenAt      = setmetatable({}, { __mode = "k" })   -- model -> { pos, moved }
local promptCache = setmetatable({}, { __mode = "k" })   -- model -> { has, t }
local removeFilter

local function isMonster(model)
    local folder = Workspace:FindFirstChild("Monsters")
    return folder ~= nil and model:IsDescendantOf(folder)
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
        description = "Stops Bot Mode from locking onto things that aren't enemies. Skips the Runner NPCs (anything named \"Runner\") and NPCs that don't move -- anything that hasn't moved since Pantheon first saw it, anchored NPCs, and NPCs you can talk to. Anything that starts moving counts as a target from then on, and mobs in the game's Monsters folder are always targets.",
        default     = true,
        onToggle    = function(v) CFG.enabled = v and true or false end,
        settings = {
            { type = "toggle", name = "Skip Runners", key = "skip_runners", default = true,
              onChange = function(v) CFG.skipRunners = v and true or false end },
            { type = "toggle", name = "Skip NPCs that don't move", key = "skip_still", default = true,
              onChange = function(v) CFG.skipStill = v and true or false end },
            { type = "slider", name = "Movement to count as a mob (studs)", key = "move_distance",
              min = 0.5, max = 10, step = 0.5, default = 1.5,
              onChange = function(v) CFG.moveDistance = v end },
        },
    }).root)

    log.info("The Veil module registered -- Bot Mode enemies-only filter")
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
end

registry.register(VEIL_IDS, Veil)

return Veil
