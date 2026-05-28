-- Target picking. Ports LockOnTargetingModule. Pure — does not mutate aim state.

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

local function isVisible(plr)
    local char = plr.Character
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
            -- Punch through transparent non-colliding parts (glass, decorative)
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

function Targeting.getBestTarget(exclude)
    local localPlayer = Players.LocalPlayer
    local myRoot = rootOf(localPlayer.Character)
    if not myRoot then return nil end

    local visCheck = state.visibilityCheckEnabled
    local closestPlr, closestDist = nil, math.huge

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= localPlayer and plr ~= exclude and not state.isFriendly(plr) then
            local char = plr.Character
            local root = rootOf(char)
            if root then
                -- Cheap distance gate FIRST: skip anyone out of range or farther
                -- than the best candidate so far. Only then run the expensive
                -- front/alive/visibility checks (visibility raycasts per player
                -- were the crowded-server hitch). A player farther than the
                -- current closest can't win regardless of those checks, and if
                -- the closest-by-distance fails visibility we still fall through
                -- to the next, so "closest visible" semantics are preserved.
                local dist = (root.Position - myRoot.Position).Magnitude
                if (state.rangeLimit <= 0 or dist <= state.rangeLimit) and dist < closestDist then
                    if isInFront(root) and isAlive(char) and (not visCheck or isVisible(plr)) then
                        closestDist = dist
                        closestPlr  = plr
                    end
                end
            end
        end
    end
    return closestPlr
end

return Targeting
