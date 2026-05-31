-- Target picking. Ports LockOnTargetingModule. Pure -- does not mutate aim state.
--
-- Returns TWO values: the target and its type ("player" or "npc"). Players are
-- always considered; NPCs (any model with a Humanoid that isn't a player) are
-- only considered when state.botMode ("Bot Mode") is on. Lock-On / Rotation Lock
-- / Highlight all branch on target_type, so an NPC target works the same as a
-- player one.

local state = require("modules.aim.state")

local Players   = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Targeting = {}

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

    local ignoreList = { Players.LocalPlayer.Character }
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Blacklist
    params.FilterDescendantsInstances = ignoreList

    while true do
        local result = Workspace:Raycast(origin, direction, params)
        if not result then return true end

        local hit = result.Instance
        if hit:IsDescendantOf(char) then return true end

        if hit:IsA("BasePart") and (hit.Transparency or 0) > 0.4 and not hit.CanCollide then
            table.insert(ignoreList, hit)
            params.FilterDescendantsInstances = ignoreList
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
                out[#out + 1] = model
            end
        end
    end
    npcList = out
    return npcList
end

-- Returns (target, targetType). target is a Player when targetType=="player" and
-- the NPC's Model when targetType=="npc". `exclude` (a Player or a Model) is
-- skipped -- used by Swap Target to cycle to the next-best.
function Targeting.getBestTarget(exclude)
    local localPlayer = Players.LocalPlayer
    local myRoot = rootOf(localPlayer.Character)
    if not myRoot then return nil end

    local visCheck = state.visibilityCheckEnabled
    local best, bestType, bestDist = nil, nil, math.huge

    -- Cheap distance gate FIRST, then the expensive front/alive/visibility checks
    -- (visibility raycasts were the crowded-server hitch). Anyone farther than the
    -- current best can't win; if the closest fails a check we fall through to the
    -- next, so "closest visible" semantics hold across players AND npcs.
    local function consider(target, ttype, char)
        if not char or target == exclude then return end
        local root = rootOf(char)
        if not root then return end
        local dist = (root.Position - myRoot.Position).Magnitude
        if state.rangeLimit > 0 and dist > state.rangeLimit then return end
        if dist >= bestDist then return end
        if isInFront(root) and isAlive(char) and (not visCheck or isVisibleChar(char)) then
            best, bestType, bestDist = target, ttype, dist
        end
    end

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= localPlayer and not state.isFriendly(plr) then
            consider(plr, "player", plr.Character)
        end
    end

    if state.botMode then
        for _, model in ipairs(getNpcs()) do
            consider(model, "npc", model)
        end
    end

    return best, bestType
end

return Targeting
