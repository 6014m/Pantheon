-- Huss Valley (GameId 10764627709, PlaceId 107535308163741) integration.
--
-- Teams: the game does not tell you who is on which side with Roblox Teams -- every player
-- wears an OUTLINE (a Highlight) in their team's colour (user, 2026-10-03: "teams are decided
-- by the outline color players got; when I'm on red team I want my lockon to focus blue team").
-- So this registers a player filter (state.addPlayerFilter) that hides your own team from
-- Lock-On / Target Select: anyone whose outline is the same colour as yours.
--
-- From the first recording (2026-10-03, Huss_Recon/rec_1003_160229): the outline is a Highlight
-- named "RoleOutline" inside each character -- RED (255,85,85) = Catcher, BLUE (75,170,255) =
-- Runner, GREEN (90,230,145) = a runner the game marks differently mid-round (most likely one
-- who has already made the crossing; unconfirmed), ORANGE (255,202,86) rare, meaning unknown.
-- The game also publishes the roles outright as Player attributes (GameRole, RunState), so the
-- filter goes by role first and falls back to comparing outline hues. Anyone it can't read
-- stays targetable -- a wrong guess can only fail towards "targets everyone", never towards
-- "targets nobody". "Show teams" in the settings prints what it sees.

local Players   = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local registry  = require("games.registry")
local window    = require("ui.window")
local container = require("ui.container")
local feature   = require("ui.feature")
local state     = require("modules.aim.state")
local log       = require("core.log")
local notify    = require("ui.notify")

local HUSS_IDS = { 10764627709, 107535308163741 }
local AUTO = "Auto (the other team)"

local Huss = {}
local CFG = { enabled = true, target = AUTO, useTeams = true, skipSafe = true }

local LP = Players.LocalPlayer
local removeFilter
local hueCache = setmetatable({}, { __mode = "k" })   -- character -> { t, hue }
local stray, strayAt = {}, -math.huge                 -- adornee -> Highlight living outside it
local lastMine = false

-- Pantheon's own target highlight is parented INTO the target's character and named
-- "_<digits>" (modules.aim.highlight) -- it must never be read as a team outline.
local function isOurs(h) return string.match(h.Name, "^_%d+$") ~= nil end

-- Highlights that point at a character from somewhere else (PlayerGui, a workspace folder).
local function refreshStray()
    local now = os.clock()
    if now - strayAt < 2 then return end
    strayAt = now
    table.clear(stray)
    local function take(d)
        if d:IsA("Highlight") and d.Adornee and not isOurs(d) then stray[d.Adornee] = d end
    end
    local pg = LP:FindFirstChildOfClass("PlayerGui")
    if pg then for _, d in ipairs(pg:GetDescendants()) do take(d) end end
    for _, c in ipairs(Workspace:GetChildren()) do
        take(c)
        if c:IsA("Folder") or (c:IsA("Model") and not c:FindFirstChildOfClass("Humanoid")) then
            for _, d in ipairs(c:GetChildren()) do take(d) end
        end
    end
end

local function outlineOf(char)
    local best
    for _, d in ipairs(char:GetDescendants()) do
        if d:IsA("Highlight") and not isOurs(d) then
            if d.Enabled then return d end
            best = best or d
        end
    end
    refreshStray()
    local s = stray[char]
    if s and s.Parent then return s end
    return best
end

-- The team colour as a hue (0-1), or nil when there is no outline / it is white, grey or black.
local function hueOf(char)
    local now = os.clock()
    local c = hueCache[char]
    if c and now - c.t < 0.5 then return c.hue end
    local hue
    local h = outlineOf(char)
    if h then
        local col = h.OutlineTransparency < 1 and h.OutlineColor or h.FillColor
        local hh, s, v = col:ToHSV()
        if s >= 0.2 and v >= 0.15 then hue = hh end
    end
    hueCache[char] = { t = now, hue = hue }
    return hue
end

local function sameHue(a, b)
    local d = math.abs(a - b)
    return math.min(d, 1 - d) < 0.09
end

local function colourName(hue)
    if not hue then return "none" end
    if hue < 0.07 or hue > 0.93 then return "Red" end
    if hue > 0.5 and hue < 0.75 then return "Blue" end
    if hue >= 0.07 and hue < 0.2 then return "Orange/Yellow" end
    if hue >= 0.2 and hue <= 0.5 then return "Green" end
    return "Purple/Pink"
end

-- The game's own role flags (Player attributes, replicated to everyone): GameRole = "Runner" /
-- "Catcher" / "Lobby", RunState = "Waiting" / "Active" / "Caught" / "Lobby".
local function roleOf(plr)
    local r = plr:GetAttribute("GameRole")
    return (r == "Runner" or r == "Catcher") and r or nil
end

-- true = hide this player from targeting
local function playerFilter(plr)
    if not CFG.enabled then return false end
    local char = plr.Character
    if not char then return false end
    local theirs = hueOf(char)
    if CFG.target ~= AUTO then
        -- a fixed colour to hunt: everyone clearly wearing another colour is skipped
        return theirs ~= nil and colourName(theirs) ~= CFG.target
    end
    local myChar = LP.Character
    local mine = myChar and hueOf(myChar)
    if mine ~= lastMine then
        lastMine = mine
        log.info("[Huss] your outline: " .. colourName(mine) .. ", role " .. tostring(LP:GetAttribute("GameRole")))
    end
    -- by role when the game says what everyone is (recorded 2026-10-03): a Catcher hunts Runners
    -- that can still be caught, a Runner watches the Catchers
    local myRole, role = roleOf(LP), roleOf(plr)
    if myRole and role then
        if role == myRole then return true end
        if myRole == "Catcher" then
            local st = plr:GetAttribute("RunState")
            if st == "Caught" or st == "Lobby" then return true end
            if CFG.skipSafe and theirs and colourName(theirs) == "Green" then return true end
        end
        return false
    end
    if myRole and plr:GetAttribute("GameRole") == "Lobby" then return true end   -- not in the round
    if mine and theirs then return sameHue(mine, theirs) end
    -- no outlines to go by: fall back to Roblox Teams if the game happens to set them
    if CFG.useTeams and not mine and not theirs and LP.Team and plr.Team then return plr.Team == LP.Team end
    return false
end

local function showTeams()
    local counts, skipped = {}, 0
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP and plr.Character then
            local n = colourName(hueOf(plr.Character))
            counts[n] = (counts[n] or 0) + 1
            if playerFilter(plr) then skipped += 1 end
        end
    end
    local parts = {}
    for n, c in pairs(counts) do parts[#parts + 1] = n .. " " .. c end
    table.sort(parts)
    local mine = LP.Character and colourName(hueOf(LP.Character)) or "none"
    local text = string.format("You: %s. Others: %s. Lock-On skips %d of them.", mine,
        #parts > 0 and table.concat(parts, ", ") or "nobody in range", skipped)
    log.info("[Huss] " .. text)
    notify.info(text, 8)
end

function Huss.register()
    log.info("Huss Valley module REGISTER on PlaceId=" .. tostring(game.PlaceId) .. " GameId=" .. tostring(game.GameId))

    if removeFilter then removeFilter() end
    removeFilter = state.addPlayerFilter(playerFilter)

    local box = container.new(window.parent(), "Huss Valley")
    box:add(feature.declare({
        id          = "huss.enemy_team_only",
        name        = "Lock-On: enemy team only",
        description = "Keeps Lock-On and Target Select off your own team. Huss Valley marks teams with the outline colour around each player, so anyone outlined in your colour is skipped and the other team is what you lock onto. Players with no outline stay targetable. Use \"Show teams\" to see what colours it's reading.",
        default     = true,
        onToggle    = function(v) CFG.enabled = v and true or false end,
        settings = {
            { type = "dropdown", name = "Target team", key = "target_team", default = AUTO,
              options = { AUTO, "Red", "Blue" },
              onChange = function(v) CFG.target = v or AUTO end },
            { type = "toggle", name = "As Catcher, skip green-outlined runners", key = "skip_safe", default = true,
              onChange = function(v) CFG.skipSafe = v and true or false end },
            { type = "toggle", name = "Use Roblox Teams when nobody has an outline", key = "use_teams", default = true,
              onChange = function(v) CFG.useTeams = v and true or false end },
            { type = "button", name = "Show teams", onClick = showTeams },
        },
    }).root)

    log.info("Huss Valley module registered -- team-aware Lock-On")
end

function Huss.destroy()
    if removeFilter then
        pcall(removeFilter)
        removeFilter = nil
    end
    table.clear(hueCache)
    table.clear(stray)
    lastMine = false
end

registry.register(HUSS_IDS, Huss)

return Huss
