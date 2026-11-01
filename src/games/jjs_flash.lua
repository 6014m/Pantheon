-- JJS: Flash Strike. On any attack input (M1 / 1-4) glide to just in front of whoever
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
local CAS        = game:GetService("ContextActionService")
local VIM        = game:GetService("VirtualInputManager")

local LP = Players.LocalPlayer

local Flash = {}
local CFG = { enabled = false, reach = 4.5, range = 250, through = true, exit = 22, lockTimeout = 8, flurry = true }

local HIT_WINDOW, RECENT = 1.5, 6
local PAUSE, BURST_MIN, BURST_MAX = 0.5, 4, 5 -- flurry rhythm: pause after a flash, then a burst of N flashes
local INTERRUPT_RANGE = 12 -- someone this close who damages me steals the lock

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
-- Sticky lock: the last target we damaged stays the target regardless of look angle until it dies,
-- the feature key clears it, or lockTimeout passes since our last landed hit on it.
local lock, lockHitAt = nil, 0
local function setLock(c, now) lock, lockHitAt = c, now or 0 end
function Flash.clearLock() setLock(nil) end
function Flash.pick(myPos, look, now)
    if lock then
        if alive(lock) and now - lockHitAt < CFG.lockTimeout and (rootOf(lock).Position - myPos).Magnitude <= CFG.range then return lock end
        lock = nil
    end
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

-- spot `dist` studs from the target along dir (flat), facing them, at their height (+lift: above/below, tilted at them)
function Flash.spot(tPos, dir, dist, lift)
    local f = flat(dir)
    f = f.Magnitude > 0.01 and f.Unit or Vector3.new(0, 0, 1)
    local pos = tPos + f * dist + Vector3.new(0, lift or 0, 0)
    if lift and lift ~= 0 then return CFrame.lookAt(pos, tPos) end
    return CFrame.lookAt(pos, Vector3.new(tPos.X, pos.Y, tPos.Z))
end
local function airborne(c)
    local h, r = c:FindFirstChildOfClass("Humanoid"), rootOf(c)
    if not (h and r) then return false end
    local st = h:GetState()
    if st == Enum.HumanoidStateType.Freefall or st == Enum.HumanoidStateType.Jumping then return true end
    local rp = RaycastParams.new(); rp.FilterType = Enum.RaycastFilterType.Exclude; rp.FilterDescendantsInstances = { c }
    return Workspace:Raycast(r.Position, Vector3.new(0, -7, 0), rp) == nil
end

local STEP = 2    -- studs per physics frame along the route (same pace as Blink Push mode)
local CREEP = 8   -- studs/s drifting through the hit zone while the attack is active
local LEAD, TAIL = 0.10, 0.25 -- reach the stand-off spot LEAD s before the hit; keep creeping TAIL s past it if no hit yet
local DEFAULT_H = 0.35 -- hit delay (s after input) for moves not learned yet

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
    for _, part in ipairs(Workspace:GetPartBoundsInBox(cf, Vector3.new(2, 2, 2), op)) do
        if part.CanCollide then return false end
    end
    return true
end
local function route(from, pos, rp)
    if not Workspace:Raycast(from, pos - from, rp) then return { pos } end
    local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true, WaypointSpacing = 4 })
    local ok = pcall(path.ComputeAsync, path, from, pos)
    if ok and path.Status == Enum.PathStatus.Success then
        local pts = {}
        for _, wp in ipairs(path:GetWaypoints()) do pts[#pts + 1] = wp.Position + Vector3.new(0, 2.5, 0) end -- waypoints sit on the floor
        pts[#pts + 1] = pos
        return pts
    end
    -- no walkable route (rooftops, gaps): arc over the top at the lowest height whose three legs are clear
    for _, h in ipairs({ 6, 12, 24, 48, 90 }) do
        local up = Vector3.new(0, h, 0)
        local a, b = from + up, pos + up
        if not Workspace:Raycast(from, up, rp) and not Workspace:Raycast(a, b - a, rp) and not Workspace:Raycast(b, pos - b, rp) then
            return { a, b, pos }
        end
    end
    return nil
end
-- returns dir, waypoint list (last point = the spot) or nil when nothing around the target is reachable
local function plan(tChar, dir, dist, lift)
    local me, tRoot = rootOf(LP.Character), rootOf(tChar)
    if not (me and tRoot) then return nil end
    local rp, op = excl(tChar)
    local tries = 0
    -- pass 1 wants an open spot; pass 2 takes any reachable one (slopes / crowds fail the box test but are fine to land on)
    for pass = 1, 2 do
        for _, deg in ipairs(ANGLES) do
            local d = CFrame.Angles(0, math.rad(deg), 0) * flat(dir)
            local cf = Flash.spot(tRoot.Position, d, dist, lift)
            if pass == 2 or openSpot(tChar, cf, rp, op) then
                local pts = route(me.Position, cf.Position, rp)
                if pts then return d, pts end
                tries = tries + 1
                if tries >= 4 then return nil end -- shortcut: 4 route attempts max per flash, raise if it keeps refusing reachable spots
            end
        end
    end
    return nil
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
    local f = tRoot.Position - root.Position
    if not (CFG.flurry and math.abs(f.Y) > 3) then f = flat(f) end -- tilt the body at them only when they are clearly above/below
    if f.Magnitude < 0.001 then return end
    if not (attach and attach.Parent == root) then
        attach = Instance.new("Attachment"); attach.Name = "PantheonFlashStrikeAttach"; attach.Parent = root
        align = Instance.new("AlignOrientation"); align.Name = "PantheonFlashStrikeAlign"
        align.Mode = Enum.OrientationAlignmentMode.OneAttachment; align.Attachment0 = attach
        align.RigidityEnabled = true; align.Responsiveness = 200; align.MaxTorque = math.huge; align.Parent = root
    end
    hum.AutoRotate = false; wasFacing = true
    align.Enabled = true; align.CFrame = CFrame.lookAt(Vector3.zero, f)
    root.CFrame = CFrame.lookAt(root.Position, root.Position + f)
end
local function faceFor(tChar) faceChar = tChar; faceUntil = os.clock() + HIT_WINDOW end

-- Hit timing, learned from our own hits: input time -> first HP drop on the target, per animation id
-- (M1 combo steps and skills each play their own animation). Persisted in the executor workspace.
local HttpService = game:GetService("HttpService")
local timings, keyAnim = {}, {} -- animId -> { d = delay, n = samples } ; input name -> last animId it produced
pcall(function() if isfile and isfile("Pantheon/flash_timings.json") then timings = HttpService:JSONDecode(readfile("Pantheon/flash_timings.json")) end end)
local function saveTimings() pcall(function() if writefile then writefile("Pantheon/flash_timings.json", HttpService:JSONEncode(timings)) end end) end
local function hitDelayFor(animId) local t = animId and timings[animId]; return t and t.d or DEFAULT_H end
local function learn(animId, delay)
    if not animId or delay <= 0 or delay > 1.5 then return end
    local t = timings[animId] or { d = delay, n = 0 }
    t.d = (t.n == 0) and delay or (t.d * 0.6 + delay * 0.4); t.n = t.n + 1
    timings[animId] = t; saveTimings()
end
Flash.timings = timings

-- Motion: one Heartbeat loop per attack running phases in order. A phase returns the position for this
-- frame, or nil when it is finished. Facing is always at the target (tilted when they are above/below).
local function run(tChar, phases)
    local gen, i = generation, 1
    moving = true
    local c; c = RunService.Heartbeat:Connect(function(dt)
        local r2, tr = rootOf(LP.Character), rootOf(tChar)
        if not (r2 and tr) or gen ~= generation then c:Disconnect(); moving = false; return end
        local pos
        while i <= #phases do
            pos = phases[i](dt, r2, tr)
            if pos then break end
            i = i + 1
        end
        if not pos then c:Disconnect(); moving = false; return end
        local f = tr.Position - pos
        if not (CFG.flurry and math.abs(f.Y) > 3) then f = flat(f) end
        if f.Magnitude > 0.01 then r2.CFrame = CFrame.lookAt(pos, pos + f) else r2.CFrame = CFrame.new(pos) * r2.CFrame.Rotation end
        r2.AssemblyLinearVelocity = Vector3.zero
    end)
end

-- Phase: travel the waypoints to the live spot. dueAt() = arrive exactly then (slides in slowly when close);
-- nil = Blink pace. The last point is re-read every frame so it follows a moving target.
local function approach(pts, dest, dueAt)
    local nodes, trav, done = nil, 0, false
    return function(dt, r2, tr)
        if done then return nil end
        local cf = dest(tr); if not cf then return nil end
        if not nodes then nodes = { r2.Position }; for i = 1, #pts - 1 do nodes[#nodes + 1] = pts[i] end end
        nodes[#pts + 1] = cf.Position
        local total, segs = 0, {}
        for i = 1, #nodes - 1 do local l = (nodes[i + 1] - nodes[i]).Magnitude; segs[i] = l; total = total + l end
        local step = math.min(STEP, total / 3)
        local due = dueAt and dueAt()
        if due then
            local left = due - os.clock()
            if left > dt then step = math.min(step, (total - trav) * dt / left) end -- pace it to land on time
        end
        trav = trav + step
        if trav >= total then done = true; return cf.Position end
        local sdist, p = trav, nodes[#nodes]
        for i = 1, #segs do
            if sdist <= segs[i] then p = nodes[i]:Lerp(nodes[i + 1], segs[i] > 0 and sdist / segs[i] or 1); break end
            sdist = sdist - segs[i]
        end
        return p
    end
end

-- Phase: drift toward the target through the hit zone until stop() says so, never closer than 1.5 studs.
local function creep(stop)
    return function(dt, r2, tr)
        if stop() then return nil end
        local to = flat(tr.Position - r2.Position)
        local d = to.Magnitude
        local move = math.min(CREEP * dt, math.max(d - 1.5, 0))
        return r2.Position + (d > 0.01 and to.Unit * move or Vector3.zero)
    end
end

-- Exit spot without pathfinding (we are next to them): first angle whose straight line from here is clear.
local function exitSpot(tChar, dir, dist)
    local me, tRoot = rootOf(LP.Character), rootOf(tChar)
    if not (me and tRoot) then return nil end
    local rp, op = excl(tChar)
    for _, deg in ipairs(ANGLES) do
        local d = CFrame.Angles(0, math.rad(deg), 0) * flat(dir)
        local cf = Flash.spot(tRoot.Position, d, dist)
        if openSpot(tChar, cf, rp, op) and not Workspace:Raycast(me.Position, cf.Position - me.Position, rp) then return d end
    end
    return nil
end

local burstLeft, lastExit = 0, -1e9
local function onHit(tChar)
    recent[tChar] = os.clock()
    setLock(tChar, recent[tChar])
    faceFor(tChar)
end

-- Click gate: when you are too far to slide in before the hit frame, the input is swallowed, you travel,
-- and the SAME input is re-sent the frame you arrive. Inputs we re-send pass straight through.
local replayUntil = 0
local function replay(input)
    replayUntil = os.clock() + 0.15
    if not input then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        local m = UIS:GetMouseLocation()
        VIM:SendMouseButtonEvent(m.X, m.Y, 0, true, game, 0); VIM:SendMouseButtonEvent(m.X, m.Y, 0, false, game, 0)
    else
        VIM:SendKeyEvent(true, input.KeyCode, false, game); VIM:SendKeyEvent(false, input.KeyCode, false, game)
    end
end

-- returns true when the input was swallowed (gate mode)
local function onAttack(input)
    if moving then return false end
    local me, cam = rootOf(LP.Character), Workspace.CurrentCamera
    if not (me and cam and alive(LP.Character)) then return false end
    local now = os.clock()
    local tChar = pick(me.Position, cam.CFrame.LookVector, now)
    if not tChar then return false end
    local tRoot = rootOf(tChar)
    moving = true -- claimed now: plan() may yield on pathfinding
    faceFor(tChar)
    disengage()

    local keyName = (input and input.UserInputType ~= Enum.UserInputType.MouseButton1) and input.KeyCode.Name or "M1"
    local animId = keyAnim[keyName]
    local H = hitDelayFor(animId)
    local t0, hitAt = nil, nil

    -- entry side + lift (flurry: their back when they face me; above/below when airborne)
    local dir, lift = me.Position - tRoot.Position, 0
    if CFG.flurry then
        if tRoot.CFrame.LookVector:Dot(flat(me.Position - tRoot.Position).Unit) > 0.5 then dir = -tRoot.CFrame.LookVector end
        if airborne(tChar) then lift = ({ -4, 0, 4 })[math.random(3)] end
    end

    -- gate decision has to be synchronous: too far to reach the spot before the hit frame -> swallow the click
    local dist0 = math.max((tRoot.Position - me.Position).Magnitude - CFG.reach, 0)
    local rp = excl(tChar)
    if Workspace:Raycast(me.Position, tRoot.Position - me.Position, rp) then dist0 = dist0 * 1.6 end -- blocked: a route is longer
    local gated = dist0 / (STEP * math.max(Workspace:GetRealPhysicsFPS(), 30)) > math.max(H - LEAD, 0.05)
    if not gated then t0 = now end

    -- hit watch: first HP drop after t0 = the hit; learn the delay for this animation
    local hum = tChar:FindFirstChildOfClass("Humanoid")
    local last = hum.Health
    engaged = tChar
    hpConn = hum.HealthChanged:Connect(function(h)
        local dropped = h < last
        last = h
        if dropped and engaged == tChar and t0 and not hitAt then
            hitAt = os.clock()
            learn(animId, hitAt - t0)
            task.spawn(onHit, tChar)
        end
    end)
    -- animation watch: the first non-looped track our humanoid starts after t0 names the move
    local myHum = LP.Character:FindFirstChildOfClass("Humanoid")
    local animConn
    local function watchAnim()
        if not myHum or animConn then return end
        animConn = myHum.AnimationPlayed:Connect(function(track)
            if track.Looped or not t0 or os.clock() - t0 > 0.4 then return end
            animId = track.Animation and track.Animation.AnimationId or animId
            keyAnim[keyName] = animId
            H = hitDelayFor(animId)
            animConn:Disconnect(); animConn = nil
        end)
        task.delay(0.5, function() if animConn then animConn:Disconnect(); animConn = nil end end)
    end
    if t0 then watchAnim() end

    task.spawn(function()
        local d, pts = plan(tChar, dir, CFG.reach, lift)
        if not d then
            moving = false
            if gated then replay(input) end -- never eat the click
            return
        end
        local dest = function(tr) return Flash.spot(tr.Position, d, CFG.reach, lift) end
        local phases = {
            approach(pts, dest, (not gated) and function() return t0 + H - LEAD end or nil),
            function() if gated and not t0 then t0 = os.clock(); replay(input); watchAnim() end return nil end,
            creep(function() return hitAt ~= nil or (t0 and os.clock() > t0 + H + TAIL) end),
            function(dt, r2, tr) -- exit: full distance in a burst, a short pass-through during the pause
                local nowc = os.clock()
                local far = true
                if CFG.flurry then
                    if burstLeft > 0 then burstLeft = burstLeft - 1
                    elseif nowc - lastExit > PAUSE then burstLeft = math.random(BURST_MIN, BURST_MAX) - 1
                    else far = false end
                end
                if not CFG.through then return nil end
                lastExit = nowc
                local deg = CFG.flurry and ({ 0, 30, -30, 60, -60 })[math.random(5)] or 0
                local ed = exitSpot(tChar, CFrame.Angles(0, math.rad(deg), 0) * flat(tr.Position - r2.Position), far and CFG.exit or CFG.reach + 2)
                if not ed then return nil end
                local edist = far and CFG.exit or CFG.reach + 2
                phases[#phases + 1] = approach({ Vector3.zero }, function(t) return Flash.spot(t.Position, ed, edist) end, nil)
                return nil
            end,
        }
        run(tChar, phases)
    end)
    task.delay(HIT_WINDOW + 1, function() if engaged == tChar then disengage() end end)
    return gated
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
            if nearest then
                recent[nearest] = os.clock()
                if nearest ~= lock and nd <= INTERRUPT_RANGE then setLock(nearest, recent[nearest]) end -- an interrupter eats the attacks too
            end
        end
        last = h
    end)
end

function Flash.start()
    Flash.stop()
    CAS:BindActionAtPriority("PantheonFlashStrikeGate", function(_, st, input)
        if st ~= Enum.UserInputState.Begin or not CFG.enabled or os.clock() < replayUntil or UIS:GetFocusedTextBox() then
            return Enum.ContextActionResult.Pass
        end
        return onAttack(input) and Enum.ContextActionResult.Sink or Enum.ContextActionResult.Pass
    end, false, Enum.ContextActionPriority.High.Value + 500, Enum.UserInputType.MouseButton1, Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four)
    watchMyHealth(LP.Character)
    conns[#conns + 1] = LP.CharacterAdded:Connect(function(c)
        generation = generation + 1; moving = false; disengage(); setLock(nil); burstLeft = 0
        watchMyHealth(c)
    end)
    RunService:BindToRenderStep(BIND, Enum.RenderPriority.Camera.Value + 150, faceStep)
    conns[#conns + 1] = RunService.Stepped:Connect(faceStep)
end

function Flash.stop()
    generation = generation + 1
    moving = false
    disengage()
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)
    pcall(function() CAS:UnbindAction("PantheonFlashStrikeGate") end)
    pcall(function() RunService:UnbindFromRenderStep(BIND) end)
    faceChar = nil; pcall(faceStep) -- hands AutoRotate back, disables the align
    if align then pcall(function() align:Destroy() end) end
    if attach then pcall(function() attach:Destroy() end) end
end

function Flash.feature()
    return {
        id          = "jjs.flash_strike",
        name        = "Flash Strike",
        description = "Every attack (M1, 1-4) flashes you (Blink pace, pathfinding around walls) to just in front of whoever you're looking at, facing them (face-locked on them for the follow-ups, shiftlock or not); when the hit lands you flash through to their far side, landing the exit distance away. Flurry adds the anime read: one flash, a second of hits in place, then 4-5 flashes back to back at varied angles on curved paths; enters from their BACK when they face you (guards only cover the front); comes in from above/below on airborne targets with the body tilted at them. Whoever damages you up close steals the lock. Targets whoever is nearest your crosshair; once you land a hit that target is LOCKED regardless of where you look, until they die, the feature key (cog) clears it, or the lock timeout passes without another landed hit. Won't flash into walls.",
        default     = false,
        onKey       = function() Flash.clearLock() end,
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
              min = 5, max = 40, step = 1, default = 22, onChange = function(v) CFG.exit = v end },
            { type = "slider", name = "Drop the locked target after (s without landing a hit)", key = "lock_timeout",
              min = 2, max = 30, step = 1, default = 8, onChange = function(v) CFG.lockTimeout = v end },
            { type = "toggle", name = "Flurry (burst rhythm, varied angles, back entries, aerial)", key = "flurry", default = true,
              onChange = function(v) CFG.flurry = v and true or false end },
            { type = "toggle", name = "Flash through on hit", key = "through", default = true,
              onChange = function(v) CFG.through = v and true or false end },
        },
    }
end

return Flash
