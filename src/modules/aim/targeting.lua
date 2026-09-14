-- Target picking. Ports LockOnTargetingModule. Pure -- does not mutate aim state.
--
-- Returns TWO values: the target and its type ("player" or "npc"). Players are
-- always considered; NPCs (any model with a Humanoid that isn't a player) are
-- only considered when state.botMode ("Bot Mode") is on. Lock-On / Rotation Lock
-- / Highlight all branch on target_type, so an NPC target works the same as a
-- player one.

local state = require("modules.aim.state")

local Players    = game:GetService("Players")
local Workspace  = game:GetService("Workspace")
local UIS        = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local Targeting = {}

-- Reused across isVisibleChar calls so the per-candidate visibility raycast
-- (Target Select runs getBestTarget at 30Hz x N players when the visibility check
-- is on) doesn't allocate a fresh RaycastParams + ignore table every time.
local visParams = RaycastParams.new()
visParams.FilterType = Enum.RaycastFilterType.Blacklist
local visIgnore = {}

local function rootOf(char)
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function isInFront(root)
    if not state.realisticEnabled then return true end
    local cam = Workspace.CurrentCamera
    if not cam then return true end
    local camCF = cam.CFrame
    local toTarget = root.Position - camCF.Position
    local mag = toTarget.Magnitude
    if mag <= 0.01 then return false end
    return (toTarget / mag):Dot(camCF.LookVector) >= math.cos(math.rad(60))
end

local function isAlive(char)
    if not char then return false end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return false end
    if state.checkHealthEnabled then
        if hum.Health <= 0 then return false end
        if char:FindFirstChildOfClass("ForceField") then return false end
    end
    return true
end

-- Line-of-sight check for a character (player OR npc). Punches through transparent
-- non-colliding parts (glass / decorative) the same way the original did.
local function isVisibleChar(char)
    local root = rootOf(char)
    if not root then return false end
    local cam = Workspace.CurrentCamera
    if not cam then return true end

    local origin = cam.CFrame.Position
    local direction = root.Position - origin
    if direction.Magnitude <= 0.01 then return true end

    table.clear(visIgnore)
    visIgnore[1] = Players.LocalPlayer.Character
    visParams.FilterDescendantsInstances = visIgnore

    while true do
        local result = Workspace:Raycast(origin, direction, visParams)
        if not result then return true end

        local hit = result.Instance
        if hit:IsDescendantOf(char) then return true end

        if hit:IsA("BasePart") and (hit.Transparency or 0) > 0.4 and not hit.CanCollide then
            visIgnore[#visIgnore + 1] = hit
            visParams.FilterDescendantsInstances = visIgnore
            local dirUnit = direction.Unit
            origin = result.Position + dirUnit * 0.05
            direction = root.Position - origin
            if direction.Magnitude <= 0.01 then return true end
        else
            return false
        end
    end
end

-- NPC list cache. Walking workspace:GetDescendants() every getBestTarget() call
-- (Target Select recomputes at 30 Hz) would be brutal in a big place, so we cache
-- the living-NPC models and refresh on a 0.5s throttle. Only built while Bot Mode
-- is on. A "real" NPC = a model with a Humanoid + HumanoidRootPart that no player
-- owns and isn't us (HRP required so Lock-On / Rotation Lock can actually aim).
-- Game modules can hide NPCs from Bot Mode with state.addNpcFilter (e.g. The Veil
-- skips its Runners and townsfolk); filters run here, once per refresh.
local npcList, npcStamp = {}, 0
local NPC_REFRESH = 0.5
local function getNpcs()
    local now = os.clock()
    if (now - npcStamp) <= NPC_REFRESH and npcStamp ~= 0 then return npcList end
    npcStamp = now
    local out, seen = {}, {}
    local myChar = Players.LocalPlayer.Character
    for _, d in ipairs(Workspace:GetDescendants()) do
        if d:IsA("Humanoid") then
            local model = d.Parent
            if model and not seen[model] and model ~= myChar
               and model:FindFirstChild("HumanoidRootPart")
               and not Players:GetPlayerFromCharacter(model) then
                seen[model] = true
                if not state.isNpcExcluded(model) then
                    out[#out + 1] = model
                end
            end
        end
    end
    npcList = out
    return npcList
end

-- Per-call context shared by getBestTarget and getRankedTargets.
-- Cursor mode: score candidates by SCREEN distance to the mouse instead of
-- world distance. GetMouseLocation includes the topbar inset; WorldToViewport
-- excludes it, so align by subtracting the inset once here.
local function buildContext()
    local myRoot = rootOf(Players.LocalPlayer.Character)
    if not myRoot then return nil end
    local ctx = {
        myRoot     = myRoot,
        visCheck   = state.visibilityCheckEnabled,
        cursorMode = state.cursorTarget,
        cam        = Workspace.CurrentCamera,
    }
    if ctx.cursorMode and ctx.cam then
        local m = UIS:GetMouseLocation()
        local inset = GuiService:GetGuiInset()
        ctx.mouse = Vector2.new(m.X, m.Y - inset.Y)
    end
    return ctx
end

-- The cheap part of a candidate's evaluation: its score (lower = better) and root,
-- or nil when it's out of range / behind the camera in cursor mode. rangeLimit
-- always uses WORLD distance regardless of mode.
local function scoreOf(ctx, char)
    local root = rootOf(char)
    if not root then return nil end
    local worldDist = (root.Position - ctx.myRoot.Position).Magnitude
    if state.rangeLimit > 0 and worldDist > state.rangeLimit then return nil end
    if ctx.cursorMode and ctx.mouse and ctx.cam then
        local vp = ctx.cam:WorldToViewportPoint(root.Position)
        if vp.Z <= 0 then return nil end   -- behind the camera
        return (Vector2.new(vp.X, vp.Y) - ctx.mouse).Magnitude, root
    end
    return worldDist, root
end

-- The expensive part: front / alive / visibility (visibility raycasts were the
-- crowded-server hitch, so callers run this only after the score gate).
local function passesChecks(ctx, char, root)
    return isInFront(root) and isAlive(char) and (not ctx.visCheck or isVisibleChar(char))
end

local function eachCandidate(fn)
    local localPlayer = Players.LocalPlayer
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= localPlayer and not state.isFriendly(plr) then
            fn(plr, "player", plr.Character)
        end
    end
    if state.botMode then
        for _, model in ipairs(getNpcs()) do
            fn(model, "npc", model)
        end
    end
end

-- Returns (target, targetType). target is a Player when targetType=="player" and
-- the NPC's Model when targetType=="npc". `exclude` (a Player or a Model) is
-- skipped -- used by Swap Target to cycle to the next-best.
function Targeting.getBestTarget(exclude)
    local ctx = buildContext()
    if not ctx then return nil end
    local best, bestType, bestScore = nil, nil, math.huge

    -- Cheap gate FIRST, then the expensive checks. Anyone with a worse score than
    -- the current best can't win; if the best fails a check we fall through to the
    -- next, so "closest visible" semantics hold across players AND npcs.
    eachCandidate(function(target, ttype, char)
        if not char or target == exclude then return end
        local score, root = scoreOf(ctx, char)
        if not score or score >= bestScore then return end
        if passesChecks(ctx, char, root) then
            best, bestType, bestScore = target, ttype, score
        end
    end)

    return best, bestType
end

-- Every valid target, best first: { { target, type, score }, ... }. Same scoring
-- and checks as getBestTarget. Used by the scroll-wheel swap to step through
-- targets in order (called per wheel notch, not per frame).
function Targeting.getRankedTargets()
    local ctx = buildContext()
    if not ctx then return {} end
    local list = {}
    eachCandidate(function(target, ttype, char)
        if not char then return end
        local score, root = scoreOf(ctx, char)
        if score and passesChecks(ctx, char, root) then
            list[#list + 1] = { target = target, type = ttype, score = score }
        end
    end)
    table.sort(list, function(a, b) return a.score < b.score end)
    return list
end

return Targeting
