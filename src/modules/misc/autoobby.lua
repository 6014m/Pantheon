-- Auto Obby: a custom node-graph A* pathfinder for obbies (architecture from the
-- user's ObbyPathfinder v1.0), adapted to the Pantheon / Wave-executor reality:
--   * grounded checks use Humanoid:GetState (Wave's FloorMaterial lies, returns Air)
--   * movement is velocity-driven with airborne horizontal carry (Humanoid:Move/MoveTo
--     get zeroed because Wave can't disable the default controls; a plain jump has no
--     horizontal velocity so it drops into the gap)
--   * every world ray goes through rayCollide so non-collidable parts (invisible zone
--     walls) are ignored (RaycastParams.RespectCanCollide isn't honored on Wave)
--   * the A* path is drawn as projected 2D dots in gethui (no workspace debug parts)
--
-- Pipeline: SCAN parts in the char<->goal region -> sample standable NODES on top
-- surfaces -> connect them with WALK/JUMP/CLIMB EDGES using real jump physics -> A*
-- with hazard-weighted costs -> EXECUTOR walks/jumps/climbs the path, timing jumps at
-- platform edges, detecting stuck states and replanning.

local feature = require("ui.feature")
local notify  = require("ui.notify")
local log     = require("core.log")
local env     = require("core.env")

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace  = workspace

local AutoObby = {}
local LP = Players.LocalPlayer
local ZERO  = Vector3.new(0, 0, 0)
local XAXIS = Vector3.new(1, 0, 0)
local ZAXIS = Vector3.new(0, 0, 1)
local YAXIS = Vector3.new(0, 1, 0)

-- live state + tunables (cog settings push into here)
local s = {
    active = false, avoidDamage = true, speedMult = 1.0, jumpSafety = 0.85,
    goal = nil, path = nil, pathIndex = 2, targetPoint = nil, jumpRequested = false,
    busy = false, stallSince = 0, lastReplan = 0, lastProgressT = 0, lastDistGoal = math.huge, lastStuck = 0,
    ctrlOn = true, controls = nil, mouse = nil,
    ctrlLoop = nil, moveConn = nil, markConn = nil, clickConn = nil,
}

local Cfg = {
    GridSpacing = 3, MaxSlopeAngle = 50, MinSurfaceSize = 1.5, AgentRadius = 2, AgentHeight = 5.2,
    ScanPadding = 45, MaxScanParts = 6000,
    StepHeight = 2.2, MaxDropHeight = 38,
    NearHazardPenalty = 4, NearHazardRadius = 3, HazardPenalty = math.huge,
    WaypointReachDist = 2.4, JumpLandDist = 3.5, JumpEdgeLead = 2.0,
    StuckTime = 2.0, StuckProgressEps = 0.75, ReplanInterval = 0.4, ReachGoalDist = 4,
}

local GROUNDED = {
    [Enum.HumanoidStateType.Running] = true, [Enum.HumanoidStateType.RunningNoPhysics] = true,
    [Enum.HumanoidStateType.Landed] = true, [Enum.HumanoidStateType.GettingUp] = true,
}

-- ---- utilities ---------------------------------------------------------------
local function rig()
    local c = LP.Character
    if not c then return nil end
    local hum  = c:FindFirstChildOfClass("Humanoid")
    local root = c:FindFirstChild("HumanoidRootPart")
    if not hum or not root or hum.Health <= 0 then return nil end
    return c, hum, root
end
local function flat(v) return Vector3.new(v.X, 0, v.Z) end

local function getJumpPhysics(hum)
    local g = Workspace.Gravity
    local jv = hum.UseJumpPower and hum.JumpPower or math.sqrt(2 * g * math.max(hum.JumpHeight, 0))
    local airFlat = (2 * jv) / g
    return {
        gravity = g, jumpVel = jv, jumpHeight = (jv * jv) / (2 * g),
        walkSpeed = hum.WalkSpeed * s.speedMult,
        maxJumpDist = hum.WalkSpeed * s.speedMult * airFlat * s.jumpSafety,
    }
end
-- airborne time to land at deltaY (negative = below); larger root of deltaY = v*t - 0.5g*t^2
local function airTimeForDeltaY(phys, deltaY)
    local disc = phys.jumpVel * phys.jumpVel - 2 * phys.gravity * deltaY
    if disc < 0 then return nil end
    return (phys.jumpVel + math.sqrt(disc)) / phys.gravity
end

local KILL_NAMES = { "kill", "lava", "damage", "death", "hurt", "spike", "acid", "poison", "void", "trap", "hazard", "deadly", "saw", "laser" }
local function isHazard(part)
    if not s.avoidDamage then return false end
    local ln = part.Name:lower()
    for _, pat in ipairs(KILL_NAMES) do if ln:find(pat, 1, true) then return true end end
    local ok, c = pcall(function() return part.Color end)
    if not ok or not c then return false end
    if part.Material == Enum.Material.CrackedLava then return true end
    if part.Material == Enum.Material.Neon and c.R > 0.7 and c.G < 0.4 and c.B < 0.4 then return true end
    return c.R > 0.62 and c.G < 0.32 and c.B < 0.32
end
local function isClimbable(part)
    if part:IsA("TrussPart") then return true end
    local ln = part.Name:lower()
    return ln:find("ladder", 1, true) ~= nil or ln:find("climb", 1, true) ~= nil
end

-- ---- raycast through non-collidable parts ------------------------------------
local rp = RaycastParams.new()
rp.FilterType = Enum.RaycastFilterType.Exclude
rp.IgnoreWater = true
pcall(function() rp.RespectCanCollide = true end)
local rpIgnore = {}
local function rayCollide(origin, dir)
    rpIgnore[1] = LP.Character
    for i = #rpIgnore, 2, -1 do rpIgnore[i] = nil end
    rp.FilterDescendantsInstances = rpIgnore
    local mag = dir.Magnitude
    if mag < 1e-4 then return nil end
    local unit, o, remaining = dir / mag, origin, mag
    for _ = 1, 8 do
        local rc = Workspace:Raycast(o, unit * remaining, rp)
        if not rc then return nil end
        if rc.Instance.CanCollide ~= false then return rc end
        rpIgnore[#rpIgnore + 1] = rc.Instance
        rp.FilterDescendantsInstances = rpIgnore
        remaining = remaining - (rc.Position - o).Magnitude - 0.05
        if remaining <= 0 then return nil end
        o = rc.Position + unit * 0.05
    end
    return nil
end

-- ---- default-controls toggle + body rotation ---------------------------------
local function getControls()
    if s.controls ~= nil then return s.controls end
    s.controls = false
    pcall(function()
        local ps = LP:FindFirstChild("PlayerScripts") or LP:WaitForChild("PlayerScripts", 2)
        local pm = ps and (ps:FindFirstChild("PlayerModule") or ps:WaitForChild("PlayerModule", 2))
        if pm then s.controls = require(pm):GetControls() end
    end)
    return s.controls
end
local function setControls(on)
    if s.ctrlOn == on then return end
    s.ctrlOn = on
    local c = getControls()
    if c then pcall(function() if on then c:Enable() else c:Disable() end end) end
end
local rot = { att = nil, align = nil, owned = false }
local function faceDir(hrp, hum, dir)
    dir = flat(dir)
    if dir.Magnitude < 1e-3 then return end
    if not (rot.att and rot.att.Parent) then
        rot.att = Instance.new("Attachment"); rot.att.Name = "PantheonObbyAtt"; rot.att.Parent = hrp
    end
    if not (rot.align and rot.align.Parent) then
        rot.align = Instance.new("AlignOrientation")
        rot.align.Name = "PantheonObbyAlign"; rot.align.Mode = Enum.OrientationAlignmentMode.OneAttachment
        rot.align.Attachment0 = rot.att; rot.align.RigidityEnabled = true
        rot.align.Responsiveness = 200; rot.align.MaxTorque = math.huge; rot.align.Parent = hrp
    end
    rot.align.Enabled = true
    rot.align.CFrame = CFrame.lookAt(ZERO, dir.Unit)
    if hum then hum.AutoRotate = false end
    rot.owned = true
end
local function releaseRot(hum)
    if rot.align then rot.align.Enabled = false end
    if rot.owned and hum then pcall(function() hum.AutoRotate = true end) end
    rot.owned = false
end
local function destroyRot()
    if rot.align then pcall(function() rot.align:Destroy() end); rot.align = nil end
    if rot.att   then pcall(function() rot.att:Destroy()   end); rot.att   = nil end
    rot.owned = false
end

-- ===== 1. SCANNER =============================================================
local function scanParts(fromPos, toPos)
    local minV = Vector3.new(math.min(fromPos.X, toPos.X), math.min(fromPos.Y, toPos.Y), math.min(fromPos.Z, toPos.Z)) - Vector3.new(1,1,1) * Cfg.ScanPadding
    local maxV = Vector3.new(math.max(fromPos.X, toPos.X), math.max(fromPos.Y, toPos.Y), math.max(fromPos.Z, toPos.Z)) + Vector3.new(1,1,1) * Cfg.ScanPadding
    local center, size = (minV + maxV) / 2, (maxV - minV)
    local op = OverlapParams.new()
    op.FilterType = Enum.RaycastFilterType.Exclude
    op.FilterDescendantsInstances = { LP.Character }
    op.MaxParts = Cfg.MaxScanParts
    local parts = Workspace:GetPartBoundsInBox(CFrame.new(center), size, op)

    local walkable, hazards, climbables = {}, {}, {}
    for _, part in ipairs(parts) do
        if part:IsA("BasePart") and not part:IsA("Terrain") then
            if isHazard(part) then
                hazards[#hazards + 1] = part
            elseif isClimbable(part) then
                climbables[#climbables + 1] = part
            elseif part.CanCollide and part.Transparency < 1 then
                local sz = part.Size
                if sz.X >= Cfg.MinSurfaceSize and sz.Z >= Cfg.MinSurfaceSize then
                    walkable[#walkable + 1] = part
                end
            end
        end
    end
    return walkable, hazards, climbables
end

-- ===== 2. NODEGRAPH ===========================================================
local function validateNode(pos)
    if rayCollide(pos + Vector3.new(0, 0.5, 0), Vector3.new(0, Cfg.AgentHeight, 0)) then return false end
    for _, dir in ipairs({ XAXIS, -XAXIS, ZAXIS, -ZAXIS }) do
        if rayCollide(pos + Vector3.new(0, 1.5, 0), dir * Cfg.AgentRadius) then return false end
    end
    return true
end
local function hazardScoreFor(pos, hazards)
    for _, hz in ipairs(hazards) do
        local lp = hz.CFrame:PointToObjectSpace(pos)
        local half = hz.Size / 2
        local clamped = Vector3.new(math.clamp(lp.X, -half.X, half.X), math.clamp(lp.Y, -half.Y, half.Y), math.clamp(lp.Z, -half.Z, half.Z))
        local dist = (lp - clamped).Magnitude
        if dist < 0.5 then return Cfg.HazardPenalty end
        if dist < Cfg.NearHazardRadius then return Cfg.NearHazardPenalty end
    end
    return 1
end
local function buildNodes(walkableParts, hazards, climbables)
    local nodes = {}
    for _, part in ipairs(walkableParts) do
        local upDot = part.CFrame.UpVector:Dot(YAXIS)
        local tilted = math.deg(math.acos(math.clamp(math.abs(upDot), 0, 1)))
        if tilted <= Cfg.MaxSlopeAngle then
            local sz = part.Size
            local stepsX = math.max(1, math.floor(sz.X / Cfg.GridSpacing))
            local stepsZ = math.max(1, math.floor(sz.Z / Cfg.GridSpacing))
            for ix = 0, stepsX do
                for iz = 0, stepsZ do
                    local lx = math.clamp(-sz.X/2 + (sz.X / stepsX) * ix, -sz.X/2 + 0.5, sz.X/2 - 0.5)
                    local lz = math.clamp(-sz.Z/2 + (sz.Z / stepsZ) * iz, -sz.Z/2 + 0.5, sz.Z/2 - 0.5)
                    local worldTop = part.CFrame:PointToWorldSpace(Vector3.new(lx, sz.Y/2, lz))
                    local hit = rayCollide(worldTop + Vector3.new(0, 2, 0), Vector3.new(0, -4, 0))
                    if hit and hit.Instance == part then
                        local pos = hit.Position + Vector3.new(0, 0.1, 0)
                        if validateNode(pos) then
                            local score = hazardScoreFor(pos, hazards)
                            if score ~= Cfg.HazardPenalty then
                                nodes[#nodes + 1] = { pos = pos, part = part,
                                    relCF = part.CFrame:PointToObjectSpace(pos), edges = {}, hazardScore = score }
                            end
                        end
                    end
                end
            end
        end
    end
    for _, truss in ipairs(climbables) do
        local topPos = truss.Position + Vector3.new(0, truss.Size.Y/2 + 0.2, 0)
        local botPos = truss.Position + Vector3.new(0, -truss.Size.Y/2 + 0.2, 0)
        local topNode = { pos = topPos, part = truss, relCF = truss.CFrame:PointToObjectSpace(topPos), edges = {}, hazardScore = 1, climb = true }
        local botNode = { pos = botPos, part = truss, relCF = truss.CFrame:PointToObjectSpace(botPos), edges = {}, hazardScore = 1, climb = true }
        local cost = (topPos - botPos).Magnitude * 1.5
        topNode.edges[1] = { to = botNode, type = "CLIMB", cost = cost }
        botNode.edges[1] = { to = topNode, type = "CLIMB", cost = cost }
        nodes[#nodes + 1] = topNode; nodes[#nodes + 1] = botNode
    end
    return nodes
end

-- ===== 3. EDGEBUILDER =========================================================
local function buildSpatialHash(nodes, cell)
    local hash = {}
    for _, n in ipairs(nodes) do
        local k = math.floor(n.pos.X/cell) .. "," .. math.floor(n.pos.Y/cell) .. "," .. math.floor(n.pos.Z/cell)
        hash[k] = hash[k] or {}
        hash[k][#hash[k] + 1] = n
    end
    return function(pos, radius)
        local out, r = {}, math.ceil(radius / cell)
        local cx, cy, cz = math.floor(pos.X/cell), math.floor(pos.Y/cell), math.floor(pos.Z/cell)
        for x = cx-r, cx+r do for y = cy-r, cy+r do for z = cz-r, cz+r do
            local b = hash[x .. "," .. y .. "," .. z]
            if b then for _, n in ipairs(b) do out[#out + 1] = n end end
        end end end
        return out
    end
end
local function jumpArcClear(fromPos, toPos, phys)
    local t = airTimeForDeltaY(phys, toPos.Y - fromPos.Y)
    if not t then return false end
    local flatv = Vector3.new(toPos.X - fromPos.X, 0, toPos.Z - fromPos.Z)
    local prev = fromPos + Vector3.new(0, 1.5, 0)
    for i = 1, 6 do
        local frac = i / 6
        local time = t * frac
        local y = fromPos.Y + phys.jumpVel * time - 0.5 * phys.gravity * time * time
        local pt = fromPos + flatv * frac
        pt = Vector3.new(pt.X, y + 1.5, pt.Z)
        local res = rayCollide(prev, pt - prev)
        if res and frac <= 0.8 then return false end   -- allow grazing the destination near the end
        prev = pt
    end
    return true
end
local function walkClear(fromPos, toPos)
    local dir = toPos - fromPos
    if Vector3.new(dir.X, 0, dir.Z).Magnitude < 0.01 then return true end
    if rayCollide(fromPos + Vector3.new(0, 1.2, 0), dir) then return false end
    if rayCollide(fromPos + Vector3.new(0, Cfg.AgentHeight - 0.5, 0), dir) then return false end
    local mid = fromPos:Lerp(toPos, 0.5)
    return rayCollide(mid + Vector3.new(0, 1, 0), Vector3.new(0, -(Cfg.StepHeight + 2.5), 0)) ~= nil
end
local function buildEdges(nodes, phys)
    local maxReach = math.max(phys.maxJumpDist, Cfg.GridSpacing * 1.6)
    local neighbors = buildSpatialHash(nodes, math.max(4, Cfg.GridSpacing))
    for _, a in ipairs(nodes) do
        for _, b in ipairs(neighbors(a.pos, maxReach + 2)) do
            if a ~= b then
                local delta = b.pos - a.pos
                local flatDist = Vector3.new(delta.X, 0, delta.Z).Magnitude
                local dy = delta.Y
                local added = false
                if flatDist <= Cfg.GridSpacing * 1.6 and math.abs(dy) <= Cfg.StepHeight and walkClear(a.pos, b.pos) then
                    a.edges[#a.edges + 1] = { to = b, type = "WALK", cost = delta.Magnitude * a.hazardScore }
                    added = true
                end
                if not added and dy <= phys.jumpHeight - 0.4 and dy >= -Cfg.MaxDropHeight
                   and flatDist <= phys.maxJumpDist and flatDist > 1 then
                    local t = airTimeForDeltaY(phys, dy)
                    if t and flatDist / t <= phys.walkSpeed * 1.05 and jumpArcClear(a.pos, b.pos, phys) then
                        a.edges[#a.edges + 1] = { to = b, type = "JUMP", cost = (delta.Magnitude * 1.4 + 2) * a.hazardScore, airTime = t }
                    end
                end
            end
        end
    end
end

-- ===== 4. A* ==================================================================
local function findNearestNode(nodes, pos, maxDist)
    local best, bestD = nil, maxDist or math.huge
    for _, n in ipairs(nodes) do
        local d = (n.pos - pos).Magnitude
        if d < bestD then best, bestD = n, d end
    end
    return best
end
local Heap = {} ; Heap.__index = Heap
function Heap.new() return setmetatable({ items = {}, n = 0 }, Heap) end
function Heap:push(item, pri)
    self.n = self.n + 1
    self.items[self.n] = { item = item, pri = pri }
    local i = self.n
    while i > 1 do
        local p = math.floor(i / 2)
        if self.items[p].pri <= self.items[i].pri then break end
        self.items[p], self.items[i] = self.items[i], self.items[p]
        i = p
    end
end
function Heap:pop()
    if self.n == 0 then return nil end
    local top = self.items[1]
    self.items[1] = self.items[self.n]; self.items[self.n] = nil; self.n = self.n - 1
    local i = 1
    while true do
        local l, r, sm = i*2, i*2+1, i
        if l <= self.n and self.items[l].pri < self.items[sm].pri then sm = l end
        if r <= self.n and self.items[r].pri < self.items[sm].pri then sm = r end
        if sm == i then break end
        self.items[sm], self.items[i] = self.items[i], self.items[sm]
        i = sm
    end
    return top.item
end
local function aStar(startNode, goalNode)
    local open = Heap.new()
    local gScore, cameFrom, cameEdge, closed = {}, {}, {}, {}
    gScore[startNode] = 0
    open:push(startNode, (startNode.pos - goalNode.pos).Magnitude)
    local found = false
    while true do
        local current = open:pop()
        if not current then break end
        if current == goalNode then found = true; break end
        if not closed[current] then
            closed[current] = true
            for _, edge in ipairs(current.edges) do
                local nb = edge.to
                if not closed[nb] then
                    local tentative = gScore[current] + edge.cost
                    if tentative < (gScore[nb] or math.huge) then
                        gScore[nb] = tentative; cameFrom[nb] = current; cameEdge[nb] = edge
                        open:push(nb, tentative + (nb.pos - goalNode.pos).Magnitude)
                    end
                end
            end
        end
    end
    if not found then return nil end
    local path, cur = {}, goalNode
    while cur do
        table.insert(path, 1, { node = cur, edgeIn = cameEdge[cur] })
        cur = cameFrom[cur]
    end
    return path
end

-- full plan: scan -> nodes -> edges -> A*
local function planPath(fromPos, goalPos, hum)
    local phys = getJumpPhysics(hum)
    local walkable, hazards, climbables = scanParts(fromPos, goalPos)
    local nodes = buildNodes(walkable, hazards, climbables)
    if #nodes == 0 then return nil end
    buildEdges(nodes, phys)
    local startNode = findNearestNode(nodes, fromPos - Vector3.new(0, 2.5, 0), 12)
    local goalNode  = findNearestNode(nodes, goalPos, 14)
    if not startNode or not goalNode then return nil end
    return aStar(startNode, goalNode)
end

-- world position of a node, tracking moving platforms
local function nodeWorldPos(node)
    if node.part and node.part.Parent then
        local ok, moving = pcall(function() return (not node.part.Anchored) or node.part.AssemblyLinearVelocity.Magnitude > 0.1 end)
        if ok and moving then
            local ok2, wp = pcall(function() return node.part.CFrame:PointToWorldSpace(node.relCF) end)
            if ok2 then return wp end
        end
    end
    return node.pos
end

-- ===== 5. EXECUTOR ============================================================
-- per-frame mover (velocity-driven; carries horizontal velocity through jumps)
local function applyMovement()
    if not s.active or s.busy then return end
    local tp = s.targetPoint
    if not tp then return end
    local _, hum, hrp = rig()
    if not (hrp and hum) then return end
    local d = flat(tp - hrp.Position)
    if d.Magnitude < 0.4 then return end
    d = d.Unit
    faceDir(hrp, hum, d)
    local v = hrp.AssemblyLinearVelocity
    local want = hum.WalkSpeed * s.speedMult
    if want <= 0 then want = 16 end
    if GROUNDED[hum:GetState()] then
        hum:MoveTo(hrp.Position + d * 8)
        local horiz = math.sqrt(v.X * v.X + v.Z * v.Z)
        if horiz < want * 0.3 then
            if s.stallSince == 0 then s.stallSince = os.clock() end
            if os.clock() - s.stallSince > 0.3 then
                hrp.AssemblyLinearVelocity = Vector3.new(d.X * want, v.Y, d.Z * want)
            end
        else s.stallSince = 0 end
    else
        s.stallSince = 0
        hrp.AssemblyLinearVelocity = Vector3.new(d.X * want, v.Y, d.Z * want)
        hum:MoveTo(hrp.Position + d * 8)
    end
end

local function doReplan(hrp, hum, reason)
    if os.clock() - s.lastReplan < Cfg.ReplanInterval then return end
    s.lastReplan = os.clock()
    s.path = planPath(hrp.Position, s.goal, hum)
    s.pathIndex = 2
    s.jumpRequested = false
    if not s.path then
        if os.clock() - s.lastStuck > 4 then
            s.lastStuck = os.clock()
            notify.warn("Auto Obby: no path found (" .. reason .. ")")
        end
    end
end

local function stepNav()
    local _, hum, hrp = rig()
    if not (hrp and hum) then s.targetPoint = nil; setControls(true); releaseRot(nil); return end
    if not s.goal then s.targetPoint, s.path, s.stallSince = nil, nil, 0; setControls(true); releaseRot(hum); return end

    local distGoal = (hrp.Position - s.goal).Magnitude
    if distGoal < Cfg.ReachGoalDist then
        s.goal, s.targetPoint, s.path = nil, nil, nil
        setControls(true); releaseRot(hum); notify.success("Auto Obby: reached the goal"); return
    end
    setControls(false)
    if s.busy then return end

    if not s.path then doReplan(hrp, hum, "initial") end

    -- stuck detection: making progress toward the goal?
    if os.clock() - s.lastProgressT >= Cfg.StuckTime then
        if s.lastDistGoal - distGoal < Cfg.StuckProgressEps then
            if GROUNDED[hum:GetState()] then hum.Jump = true end
            doReplan(hrp, hum, "stuck")
        end
        s.lastDistGoal = distGoal
        s.lastProgressT = os.clock()
    end

    if not s.path or not s.path[s.pathIndex] then doReplan(hrp, hum, "empty"); return end

    local step = s.path[s.pathIndex]
    local targetPos = nodeWorldPos(step.node)
    local edgeType  = step.edgeIn and step.edgeIn.type or "WALK"
    local flatDist  = flat(targetPos - hrp.Position).Magnitude

    -- arrival
    local arrived
    if edgeType == "JUMP" then
        arrived = flatDist < Cfg.JumpLandDist and GROUNDED[hum:GetState()]
            and math.abs(targetPos.Y - (hrp.Position.Y - 2.5)) < 3.5
    elseif edgeType == "CLIMB" then
        arrived = (hrp.Position - targetPos).Magnitude < 3.5
    else
        arrived = flatDist < Cfg.WaypointReachDist
    end
    if arrived then
        s.pathIndex = s.pathIndex + 1
        s.jumpRequested = false
        if not s.path[s.pathIndex] then s.targetPoint = nil; return end
        step = s.path[s.pathIndex]
        targetPos = nodeWorldPos(step.node)
        edgeType = step.edgeIn and step.edgeIn.type or "WALK"
        flatDist = flat(targetPos - hrp.Position).Magnitude   -- recompute for the new target
    end

    s.targetPoint = targetPos   -- the mover steers/carries toward this

    -- jump timing for JUMP edges: take off right at the platform edge
    if edgeType == "JUMP" and not s.jumpRequested and GROUNDED[hum:GetState()] then
        local md = flat(targetPos - hrp.Position)
        local dir = md.Magnitude > 0.01 and md.Unit or ZERO
        -- probe a little ahead: no ground within a step-height below = an edge/gap (catches
        -- edges that still have a lower floor under them, which a long down-ray would miss)
        local probe = hrp.Position + dir * Cfg.JumpEdgeLead
        local edgeAhead = rayCollide(probe + Vector3.new(0, 0.5, 0), Vector3.new(0, -(Cfg.StepHeight + 1.5), 0)) == nil
        local targetAbove = targetPos.Y > hrp.Position.Y + 0.5
        if edgeAhead or (targetAbove and flatDist < 7) then
            hum.Jump = true
            s.jumpRequested = true
        end
    elseif edgeType == "CLIMB" then
        s.targetPoint = nil   -- climbing: drive directly here (don't velocity-fight the truss)
        hum:MoveTo(Vector3.new(targetPos.X, hrp.Position.Y, targetPos.Z))
        if hum:GetState() == Enum.HumanoidStateType.Climbing then hum:Move((targetPos - hrp.Position).Unit) end
    end
end

local function startControl()
    if s.ctrlLoop then return end
    s.ctrlLoop = task.spawn(function()
        while s.active do
            local ok, err = pcall(stepNav)
            if not ok then log.warn("autoobby nav: " .. tostring(err)) end
            task.wait(0.05)
        end
        s.ctrlLoop = nil
    end)
end

-- ===== MARKERS (2D projected) =================================================
local mk = { gui = nil, preview = nil, placed = nil, label = nil, dots = {} }
local function ensureMarkers()
    if mk.gui and mk.gui.Parent then return end
    local sg = Instance.new("ScreenGui")
    sg.Name = "_" .. tostring(math.random(100000, 999999))
    sg.ResetOnSpawn = false; sg.IgnoreGuiInset = false; sg.DisplayOrder = 50
    sg.Parent = env.guiParent(); env.protectGui(sg)
    mk.dots = {}
    for i = 1, 40 do
        local dt = Instance.new("Frame")
        dt.Size = UDim2.fromOffset(7, 7); dt.AnchorPoint = Vector2.new(0.5, 0.5)
        dt.BackgroundColor3 = Color3.fromRGB(120, 220, 255); dt.BackgroundTransparency = 0.2
        dt.BorderSizePixel = 0; dt.Visible = false; dt.Parent = sg
        Instance.new("UICorner", dt).CornerRadius = UDim.new(1, 0)
        mk.dots[i] = dt
    end
    local pv = Instance.new("Frame")
    pv.Size = UDim2.fromOffset(26, 26); pv.AnchorPoint = Vector2.new(0.5, 0.5)
    pv.BackgroundTransparency = 1; pv.Visible = false; pv.Parent = sg
    Instance.new("UICorner", pv).CornerRadius = UDim.new(1, 0)
    local pvs = Instance.new("UIStroke", pv); pvs.Color = Color3.fromRGB(120, 220, 255); pvs.Thickness = 2; pvs.Transparency = 0.1
    local pl = Instance.new("Frame")
    pl.Size = UDim2.fromOffset(18, 18); pl.AnchorPoint = Vector2.new(0.5, 0.5); pl.Rotation = 45
    pl.BackgroundColor3 = Color3.fromRGB(87, 242, 135); pl.BorderSizePixel = 0; pl.Visible = false; pl.Parent = sg
    Instance.new("UIStroke", pl).Color = Color3.fromRGB(255, 255, 255)
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.fromOffset(120, 16); lbl.AnchorPoint = Vector2.new(0.5, 1); lbl.Position = UDim2.fromOffset(0, -16)
    lbl.BackgroundTransparency = 1; lbl.Font = Enum.Font.GothamBold; lbl.TextSize = 12
    lbl.TextColor3 = Color3.fromRGB(87, 242, 135); lbl.TextStrokeTransparency = 0.4; lbl.Text = "GOAL"; lbl.Rotation = -45; lbl.Parent = pl
    mk.gui, mk.preview, mk.placed, mk.label = sg, pv, pl, lbl
end
local function cursorWorld()
    local m = s.mouse
    if m and m.Target and m.Target.Parent then return m.Hit.Position end
    return nil
end
local function project(cam, world, frame)
    local vp = cam:WorldToViewportPoint(world)
    if vp.Z > 0 then frame.Visible = true; frame.Position = UDim2.fromOffset(vp.X, vp.Y); return true end
    frame.Visible = false; return false
end
local function updateMarkers()
    local cam = Workspace.CurrentCamera
    if not (cam and mk.gui) then return end
    local cw = cursorWorld()
    if cw then project(cam, cw, mk.preview) else mk.preview.Visible = false end
    if s.goal then
        if project(cam, s.goal, mk.placed) then
            local _, _, hrp = rig()
            if hrp then mk.label.Text = ("GOAL  %d"):format(math.floor(flat(s.goal - hrp.Position).Magnitude)) end
        end
    else mk.placed.Visible = false end
    for i, dt in ipairs(mk.dots) do
        local step = s.path and s.path[i]
        if step and i >= (s.pathIndex - 1) then
            local et = step.edgeIn and step.edgeIn.type
            dt.BackgroundColor3 = (et == "JUMP" and Color3.fromRGB(255, 200, 0))
                or (et == "CLIMB" and Color3.fromRGB(120, 170, 255)) or Color3.fromRGB(120, 220, 255)
            project(cam, nodeWorldPos(step.node), dt)
        else dt.Visible = false end
    end
end
local function hideMarkers()
    if mk.preview then mk.preview.Visible = false end
    if mk.placed  then mk.placed.Visible  = false end
    for _, dt in ipairs(mk.dots) do dt.Visible = false end
end
local function destroyMarkers()
    if mk.gui then pcall(function() mk.gui:Destroy() end) end
    mk.gui, mk.preview, mk.placed, mk.label, mk.dots = nil, nil, nil, nil, {}
end

-- ===== click to set the destination ==========================================
local function onInput(input, gpe)
    if gpe then return end
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
    local cw = cursorWorld()
    if cw then s.goal, s.path, s.lastReplan = cw, nil, 0; notify.info("Auto Obby: destination set") end
end

-- ===== lifecycle =============================================================
local function setActive(v)
    v = v and true or false
    if s.active == v then return end
    s.active = v
    if v then
        s.mouse = s.mouse or LP:GetMouse()
        pcall(function() s.mouse.TargetFilter = LP.Character end)
        s.targetPoint, s.path, s.lastProgressT, s.lastDistGoal = nil, nil, os.clock(), math.huge
        ensureMarkers()
        if not s.clickConn then s.clickConn = game:GetService("UserInputService").InputBegan:Connect(onInput) end
        if not s.markConn  then s.markConn  = RunService.RenderStepped:Connect(updateMarkers) end
        if not s.moveConn  then s.moveConn  = RunService.Heartbeat:Connect(applyMovement) end
        startControl()
        notify.success("Auto Obby ON -- click a destination (A* pathfinder)")
    else
        s.goal, s.targetPoint, s.path = nil, nil, nil
        for _, k in ipairs({ "clickConn", "markConn", "moveConn" }) do
            if s[k] then s[k]:Disconnect(); s[k] = nil end
        end
        hideMarkers()
        local _, hum = rig()
        releaseRot(hum); setControls(true)
        if hum then pcall(function() hum:Move(ZERO, false) end) end
    end
end

function AutoObby.register(box)
    box:add(feature.declare({
        id          = "misc.autoobby",
        name        = "Auto Obby",
        description = "A* obby pathfinder. Engage with the keybind, a preview reticle follows your cursor, click a destination -- it scans the area, builds a node graph of standable surfaces, connects them with WALK / JUMP / CLIMB edges using real jump physics, runs A* (avoiding kill blocks), and walks/jumps/climbs the route (drawn as dots: blue=walk, yellow=jump). It only plans jumps your character can make, carries horizontal velocity through each jump so it clears gaps, tracks moving platforms, and replans when stuck. Drives the body by velocity (works under the executor), ignores non-collidable parts, leaves your own movement alone when idle. Speed % and Jump reach % tune it.",
        default     = false,
        defaultKey  = Enum.KeyCode.G,
        onToggle    = setActive,
        settings    = {
            { type = "toggle", name = "Avoid damage blocks", key = "avoid", default = true,
              onChange = function(v) s.avoidDamage = v end },
            { type = "slider", name = "Speed %", key = "speed", min = 50, max = 200, step = 10, default = 100,
              onChange = function(v) s.speedMult = (v or 100) / 100 end },
            { type = "slider", name = "Jump reach %", key = "reach", min = 50, max = 100, step = 5, default = 85,
              onChange = function(v) s.jumpSafety = (v or 85) / 100 end },
        },
    }).root)
    log.info("Auto Obby feature registered")
end

function AutoObby.destroy()
    s.active = false
    for _, k in ipairs({ "clickConn", "markConn", "moveConn" }) do
        if s[k] then pcall(function() s[k]:Disconnect() end); s[k] = nil end
    end
    local _, hum = rig()
    releaseRot(hum); destroyRot(); destroyMarkers(); setControls(true)
    s.goal, s.targetPoint, s.path = nil, nil, nil
end

AutoObby._diag = { isHazard = isHazard, getJumpPhysics = getJumpPhysics, airTimeForDeltaY = airTimeForDeltaY,
                   rayCollide = rayCollide, aStar = aStar, Heap = Heap, findNearestNode = findNearestNode }

return AutoObby
