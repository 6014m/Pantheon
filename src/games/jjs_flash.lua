-- JJS: Flash Strike. On any attack input (M1 / 1-4 / R) glide to just in front of whoever
-- you're looking at, facing them; the moment that attack lands (their HP drops) glide through
-- to their far side, still facing them. JJS's hit-line VFX reads as "already cut". The glide
-- is a short CFrame lerp (same CFrame-move Blink uses in JJS, no velocity tricks).
--
-- Targeting: whoever is nearest your camera's look direction within range, with a bonus for
-- anyone you've traded damage with in the last few seconds. Terrain: if the far side is inside
-- a wall, use the side instead.
--
-- shortcut: moves in on PRESS, not on the learned hit frame (no per-move timing DB on this PC);
-- upgrade when the Attack Logger's hit-frame data is rebuilt.

local Players    = game:GetService("Players")
local UIS        = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace  = game:GetService("Workspace")
local PathfindingService = game:GetService("PathfindingService")

local LP = Players.LocalPlayer

local Flash = {}
local CFG = { enabled = false, reach = 4.5, range = 250, through = true, exit = 17 }

local ATTACK_KEYS = { [Enum.KeyCode.One] = true, [Enum.KeyCode.Two] = true, [Enum.KeyCode.Three] = true,
                      [Enum.KeyCode.Four] = true, [Enum.KeyCode.R] = true }
local HIT_WINDOW, RECENT = 1.5, 6

local conns, hpConn, engaged = {}, nil, nil
local recent = {}      -- char -> os.clock() of the last damage traded with them
local generation = 0   -- bumps on stop; an in-flight glide checks it
local moving = false

local function flat(v) return Vector3.new(v.X, 0, v.Z) end
local function rootOf(c) return c and c:FindFirstChild("HumanoidRootPart") end
local function alive(c)
    local h = c and c:FindFirstChildOfClass("Humanoid")
    return h ~= nil and h.Health > 0 and rootOf(c) ~= nil
end

local function candidates()
    local folder = Workspace:FindFirstChild("Characters")
    if folder then return folder:GetChildren() end
    local out = {}
    for _, p in ipairs(Players:GetPlayers()) do out[#out + 1] = p.Character end
    return out
end

-- Nearest to the camera's look direction (cosine), recent-damage bonus, within range.
function Flash.pick(myPos, look, now)
    local best, bestScore = nil, -math.huge
    for _, c in ipairs(candidates()) do
        if c and c ~= LP.Character and alive(c) then
            local d = rootOf(c).Position - myPos
            if d.Magnitude <= CFG.range and d.Magnitude > 0.1 then
                local score = look:Dot(d.Unit) + ((now - (recent[c] or -1e9)) < RECENT and 0.35 or 0)
                if score > bestScore then best, bestScore = c, score end
            end
        end
    end
    return best
end

-- Standing spot `reach` studs from the target along dir (flat), facing them, at their height.
function Flash.spot(tPos, dir, reach)
    local f = flat(dir)
    f = f.Magnitude > 0.01 and f.Unit or Vector3.new(0, 0, 1)
    local pos = tPos + f * reach
    return CFrame.lookAt(pos, Vector3.new(tPos.X, pos.Y, tPos.Z))
end

local STEP = 2    -- studs per physics frame along the route (same pace as Blink Push mode)
local HOLD = 0.6  -- s to keep tracking the stand-off spot after arriving, so the hit frame still connects

-- Terrain. A landing spot is open when the ray target->spot is clear (not inside a wall) and no solid
-- part overlaps the landing box. The route to it is the straight line when clear, else a navmesh path
-- (PathfindingService). Angles around the target are tried preferred-first until one is open + reachable.
local ANGLES = { 0, 45, -45, 90, -90, 135, -135, 180 }
local faceChar -- the current target (assigned by faceFor below)
local function excl(tChar)
    local rp = RaycastParams.new(); rp.FilterType = Enum.RaycastFilterType.Exclude; rp.FilterDescendantsInstances = { tChar, LP.Character }
    local op = OverlapParams.new(); op.FilterType = Enum.RaycastFilterType.Exclude; op.FilterDescendantsInstances = { tChar, LP.Character }
    return rp, op
end
local function openSpot(tChar, cf, rp, op)
    local tp = rootOf(tChar).Position
    if Workspace:Raycast(tp, cf.Position - tp, rp) then return false end
    for _, part in ipairs(Workspace:GetPartBoundsInBox(cf, Vector3.new(2, 4, 2), op)) do
        if part.CanCollide then return false end
    end
    return true
end
local function route(from, pos, rp)
    if not Workspace:Raycast(from, pos - from, rp) then return { pos } end
    local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true, WaypointSpacing = 4 })
    local ok = pcall(path.ComputeAsync, path, from, pos)
    if not (ok and path.Status == Enum.PathStatus.Success) then return nil end
    local pts = {}
    for _, wp in ipairs(path:GetWaypoints()) do pts[#pts + 1] = wp.Position + Vector3.new(0, 2.5, 0) end -- waypoints sit on the floor
    pts[#pts + 1] = pos
    return pts
end
-- returns dir, waypoint list (last point = the spot) or nil when nothing around the target is reachable
local function plan(tChar, dir, dist)
    local me, tRoot = rootOf(LP.Character), rootOf(tChar)
    if not (me and tRoot) then return nil end
    local rp, op = excl(tChar)
    local tries = 0
    for _, deg in ipairs(ANGLES) do
        local d = CFrame.Angles(0, math.rad(deg), 0) * flat(dir)
        local cf = Flash.spot(tRoot.Position, d, dist)
        if openSpot(tChar, cf, rp, op) then
            local pts = route(me.Position, cf.Position, rp)
            if pts then return d, pts end
            tries = tries + 1
            if tries >= 3 then break end -- shortcut: 3 pathfinds max per flash, raise if it keeps refusing reachable spots
        end
    end
    return nil
end

-- Travel the waypoints in `dur` seconds; the LAST point is dest() re-read every frame so it follows a
-- moving target. Then, while keep() holds, stay pinned on dest() (the tracking hold through the hit frame).
local function glide(pts, dest, keep)
    local r = rootOf(LP.Character); if not r then moving = false; return end
    local gen, trav = generation, 0
    local rp = excl(faceChar)
    local nodes = { r.Position }
    for i = 1, #pts - 1 do nodes[#nodes + 1] = pts[i] end
    moving = true
    local c; c = RunService.Heartbeat:Connect(function()
        local r2, cf = rootOf(LP.Character), dest()
        if not (r2 and cf) or gen ~= generation then c:Disconnect(); moving = false; return end
        nodes[#pts + 1] = cf.Position -- live final point
        local total, segs = 0, {}
        for i = 1, #nodes - 1 do local l = (nodes[i + 1] - nodes[i]).Magnitude; segs[i] = l; total = total + l end
        trav = trav + math.min(STEP, total / 3) -- Blink pace: STEP studs per physics frame, never fewer than 3 frames
        local a = math.min(trav / math.max(total, 0.001), 1)
        local p
        if a < 1 then
            local sdist = a * total
            p = nodes[#nodes]
            for i = 1, #segs do
                if sdist <= segs[i] then p = nodes[i]:Lerp(nodes[i + 1], segs[i] > 0 and sdist / segs[i] or 1); break end
                sdist = sdist - segs[i]
            end
        else
            if not (keep and keep()) then c:Disconnect(); moving = false; return end
            if Workspace:Raycast(r2.Position, cf.Position - r2.Position, rp) then c:Disconnect(); moving = false; return end -- a wall moved between us
            p = cf.Position
        end
        r2.CFrame = CFrame.new(p) * cf.Rotation
        r2.AssemblyLinearVelocity = Vector3.zero
    end)
end

local function disengage()
    if hpConn then pcall(hpConn.Disconnect, hpConn) end
    hpConn, engaged = nil, nil
end

-- Face lock: while engaged, pin the body yaw at the target every frame, AFTER the game shiftlock
-- (RenderStepped at Camera+150) and before physics (Stepped), plus an AlignOrientation so physics
-- agrees. Same method as Pantheon Rotation Lock; shiftlock on or off makes no difference.
local faceUntil, align, attach, wasFacing = 0, nil, nil, false
local BIND = "PantheonFlashStrikeFace"
local function faceStep()
    local char = LP.Character
    local root, hum = rootOf(char), char and char:FindFirstChildOfClass("Humanoid")
    local tRoot = faceChar and os.clock() < faceUntil and alive(faceChar) and rootOf(faceChar)
    if not (root and hum and tRoot) then
        if align then align.Enabled = false end
        if wasFacing and hum then hum.AutoRotate = true; wasFacing = false end
        return
    end
    local f = flat(tRoot.Position - root.Position)
    if f.Magnitude < 0.001 then return end
    if not (attach and attach.Parent == root) then
        attach = Instance.new("Attachment"); attach.Name = "PantheonFlashStrikeAttach"; attach.Parent = root
        align = Instance.new("AlignOrientation"); align.Name = "PantheonFlashStrikeAlign"
        align.Mode = Enum.OrientationAlignmentMode.OneAttachment; align.Attachment0 = attach
        align.RigidityEnabled = true; align.Responsiveness = 200; align.MaxTorque = math.huge; align.Parent = root
    end
    hum.AutoRotate = false; wasFacing = true
    align.Enabled = true; align.CFrame = CFrame.lookAt(Vector3.zero, f)
    local _, yaw = CFrame.lookAt(root.Position, root.Position + f):ToEulerAnglesYXZ()
    root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, yaw, 0)
end
local function faceFor(tChar) faceChar = tChar; faceUntil = os.clock() + HIT_WINDOW end

local function travel(tChar, dir, dist, keep)
    local d, pts = plan(tChar, dir, dist)
    if not d then moving = false; return false end
    glide(pts, function() local tr = rootOf(tChar); return tr and Flash.spot(tr.Position, d, dist) end, keep)
    return true
end

local function onHit(tChar)
    recent[tChar] = os.clock()
    faceFor(tChar)
    disengage()
    if not CFG.through then return end
    generation = generation + 1 -- cut the tracking hold
    local me, tRoot = rootOf(LP.Character), rootOf(tChar)
    if not (me and tRoot) then return end
    travel(tChar, tRoot.Position - me.Position, CFG.exit) -- far side, CFG.exit studs out
end

local function onAttack()
    if moving then return end
    local me, cam = rootOf(LP.Character), Workspace.CurrentCamera
    if not (me and cam and alive(LP.Character)) then return end
    local now = os.clock()
    local tChar = pick(me.Position, cam.CFrame.LookVector, now)
    if not tChar then return end
    local tRoot = rootOf(tChar)
    moving = true -- claimed now: plan() may yield on pathfinding
    faceFor(tChar)
    disengage()
    local hum = tChar:FindFirstChildOfClass("Humanoid")
    local last = hum.Health
    engaged = tChar
    hpConn = hum.HealthChanged:Connect(function(h)
        local dropped = h < last
        last = h
        if dropped and engaged == tChar and os.clock() - now < HIT_WINDOW then task.spawn(onHit, tChar) end
    end)
    task.delay(HIT_WINDOW, function() if engaged == tChar then disengage() end end)
    local holdEnd = now + HOLD
    task.spawn(travel, tChar, me.Position - tRoot.Position, CFG.reach, function() return engaged == tChar and os.clock() < holdEnd end)
end

-- Whoever hurts me becomes "recent": blame the nearest enemy.
local function watchMyHealth(char)
    local hum = char and char:FindFirstChildOfClass("Humanoid"); if not hum then return end
    local last = hum.Health
    conns[#conns + 1] = hum.HealthChanged:Connect(function(h)
        if h < last then
            local me = rootOf(char)
            local nearest, nd = nil, 15
            for _, c in ipairs(candidates()) do
                if me and c and c ~= char and alive(c) then
                    local d = (rootOf(c).Position - me.Position).Magnitude
                    if d < nd then nearest, nd = c, d end
                end
            end
            if nearest then recent[nearest] = os.clock() end
        end
        last = h
    end)
end

function Flash.start()
    Flash.stop()
    conns[#conns + 1] = UIS.InputBegan:Connect(function(input, gp)
        if gp or not CFG.enabled then return end
        if input.UserInputType == Enum.UserInputType.MouseButton1 or ATTACK_KEYS[input.KeyCode] then onAttack() end
    end)
    watchMyHealth(LP.Character)
    conns[#conns + 1] = LP.CharacterAdded:Connect(watchMyHealth)
    RunService:BindToRenderStep(BIND, Enum.RenderPriority.Camera.Value + 150, faceStep)
    conns[#conns + 1] = RunService.Stepped:Connect(faceStep)
end

function Flash.stop()
    generation = generation + 1
    moving = false
    disengage()
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)
    pcall(function() RunService:UnbindFromRenderStep(BIND) end)
    faceChar = nil; pcall(faceStep) -- hands AutoRotate back, disables the align
    if align then pcall(function() align:Destroy() end) end
    if attach then pcall(function() attach:Destroy() end) end
end

function Flash.feature()
    return {
        id          = "jjs.flash_strike",
        name        = "Flash Strike",
        description = "Every attack (M1, 1-4, R) flashes you (Blink pace, pathfinding around walls) to just in front of whoever you're looking at, facing them (face-locked on them for the follow-ups, shiftlock or not); when the hit lands you flash through to their far side, landing the exit distance away. Targets whoever is nearest your crosshair, preferring people you've recently traded damage with. Won't flash into walls.",
        default     = false,
        onToggle    = function(v)
            CFG.enabled = v and true or false
            if CFG.enabled then Flash.start() else Flash.stop() end
        end,
        settings = {
            { type = "slider", name = "Stand-off distance (studs)", key = "reach",
              min = 2, max = 8, step = 0.5, default = 4.5, onChange = function(v) CFG.reach = v end },
            { type = "slider", name = "Target range (studs)", key = "range",
              min = 10, max = 500, step = 10, default = 250, onChange = function(v) CFG.range = v end },
            { type = "slider", name = "Exit distance after the hit (studs)", key = "exit",
              min = 5, max = 40, step = 1, default = 17, onChange = function(v) CFG.exit = v end },
            { type = "toggle", name = "Flash through on hit", key = "through", default = true,
              onChange = function(v) CFG.through = v and true or false end },
        },
    }
end

return Flash
