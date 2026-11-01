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

local LP = Players.LocalPlayer

local Flash = {}
local CFG = { enabled = false, reach = 4.5, dashTime = 0.08, range = 250, through = true, exit = 17 }

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

-- Terrain: first free angle around the target (preferred first, then widening). A spot is free when
-- the ray target->spot is clear (not inside a wall), the ray me->spot is clear (no warping through
-- geometry) and no solid part overlaps the landing box.
local ANGLES = { 0, 45, -45, 90, -90, 135, -135, 180 }
local function clearDir(tChar, dir, dist)
    local me, tRoot = rootOf(LP.Character), rootOf(tChar)
    if not (me and tRoot) then return nil end
    local rp = RaycastParams.new(); rp.FilterType = Enum.RaycastFilterType.Exclude; rp.FilterDescendantsInstances = { tChar, LP.Character }
    local op = OverlapParams.new(); op.FilterType = Enum.RaycastFilterType.Exclude; op.FilterDescendantsInstances = { tChar, LP.Character }
    for _, deg in ipairs(ANGLES) do
        local d = CFrame.Angles(0, math.rad(deg), 0) * flat(dir)
        local cf = Flash.spot(tRoot.Position, d, dist)
        local free = not Workspace:Raycast(tRoot.Position, cf.Position - tRoot.Position, rp)
            and not Workspace:Raycast(me.Position, cf.Position - me.Position, rp)
        if free then
            for _, part in ipairs(Workspace:GetPartBoundsInBox(cf, Vector3.new(2, 4, 2), op)) do
                if part.CanCollide then free = false; break end
            end
        end
        if free then return d end
    end
    return nil
end

-- dest() is re-evaluated every frame so the landing spot follows a moving target
local faceChar -- the current target (assigned by faceFor below)
local function glide(dest)
    local r = rootOf(LP.Character); if not r then return end
    local from, t0, gen = r.CFrame, os.clock(), generation
    local pathParams = RaycastParams.new(); pathParams.FilterType = Enum.RaycastFilterType.Exclude
    pathParams.FilterDescendantsInstances = { LP.Character, faceChar }
    moving = true
    local c; c = RunService.Heartbeat:Connect(function()
        local r2, cf = rootOf(LP.Character), dest()
        if not (r2 and cf) or gen ~= generation or Workspace:Raycast(r2.Position, cf.Position - r2.Position, pathParams) then
            c:Disconnect(); moving = false; return -- done, stopped, or a wall moved into the path: stop here
        end
        local a = math.min((os.clock() - t0) / CFG.dashTime, 1)
        r2.CFrame = from:Lerp(cf, a)
        r2.AssemblyLinearVelocity = Vector3.zero
        if a >= 1 then c:Disconnect(); moving = false end
    end)
end

local function disengage()
    if hpConn then pcall(function() hpConn:Disconnect() end) end
    hpConn, engaged = nil, nil
end

-- Face lock: while engaged, pin the body's yaw at the target every frame AFTER the game's
-- shiftlock (RenderStepped at Camera+150) and before physics (Stepped), plus an
-- AlignOrientation so physics agrees. Same method as modules.aim.rotation_lock; shiftlock
-- on or off makes no difference.
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

local function onHit(tChar)
    recent[tChar] = os.clock()
    faceFor(tChar)
    disengage()
    if not CFG.through then return end
    local me, tRoot = rootOf(LP.Character), rootOf(tChar)
    if not (me and tRoot) then return end
    -- far side = mirror of where I am across them
    local dir = clearDir(tChar, tRoot.Position - me.Position, CFG.exit)
    if not dir then return end
    glide(function() local tr = rootOf(tChar); return tr and Flash.spot(tr.Position, dir, CFG.exit) end)
end

local function onAttack()
    if moving then return end
    local me = rootOf(LP.Character)
    local cam = Workspace.CurrentCamera
    if not (me and cam and alive(LP.Character)) then return end
    local now = os.clock()
    local tChar = Flash.pick(me.Position, cam.CFrame.LookVector, now)
    if not tChar then return end
    local tRoot = rootOf(tChar)
    faceFor(tChar)
    local dir = clearDir(tChar, me.Position - tRoot.Position, CFG.reach)
    if not dir then return end
    glide(function() local tr = rootOf(tChar); return tr and Flash.spot(tr.Position, dir, CFG.reach) end)

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
        description = "Every attack (M1, 1-4, R) flashes you to just in front of whoever you're looking at, facing them (face-locked on them for the follow-ups, shiftlock or not); when the hit lands you flash through to their far side, landing the exit distance away. Targets whoever is nearest your crosshair, preferring people you've recently traded damage with. Won't flash into walls.",
        default     = false,
        onToggle    = function(v)
            CFG.enabled = v and true or false
            if CFG.enabled then Flash.start() else Flash.stop() end
        end,
        settings = {
            { type = "slider", name = "Stand-off distance (studs)", key = "reach",
              min = 2, max = 8, step = 0.5, default = 4.5, onChange = function(v) CFG.reach = v end },
            { type = "slider", name = "Flash duration (seconds)", key = "dash_time",
              min = 0.02, max = 0.25, step = 0.01, default = 0.08, onChange = function(v) CFG.dashTime = v end },
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
