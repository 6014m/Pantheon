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
local CFG = { enabled = false, reach = 4.5, dashTime = 0.08, range = 45, through = true }

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

local function blocked(tChar, cf)
    local tRoot = rootOf(tChar)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { tChar, LP.Character }
    return Workspace:Raycast(tRoot.Position, cf.Position - tRoot.Position, params) ~= nil
end

local function glide(cf)
    local r = rootOf(LP.Character); if not r then return end
    local from, t0, gen = r.CFrame, os.clock(), generation
    moving = true
    local c; c = RunService.Heartbeat:Connect(function()
        local r2 = rootOf(LP.Character)
        if not r2 or gen ~= generation then c:Disconnect(); moving = false; return end
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

local function onHit(tChar)
    recent[tChar] = os.clock()
    disengage()
    if not CFG.through then return end
    local me, tRoot = rootOf(LP.Character), rootOf(tChar)
    if not (me and tRoot) then return end
    -- far side = mirror of where I am across them
    local cf = Flash.spot(tRoot.Position, tRoot.Position - me.Position, CFG.reach)
    if blocked(tChar, cf) then
        local side = flat(me.Position - tRoot.Position):Cross(Vector3.yAxis)
        cf = Flash.spot(tRoot.Position, side, CFG.reach)
        if blocked(tChar, cf) then return end
    end
    glide(cf)
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
    glide(Flash.spot(tRoot.Position, me.Position - tRoot.Position, CFG.reach))

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
end

function Flash.stop()
    generation = generation + 1
    moving = false
    disengage()
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)
end

function Flash.feature()
    return {
        id          = "jjs.flash_strike",
        name        = "Flash Strike",
        description = "Every attack (M1, 1-4, R) flashes you to just in front of whoever you're looking at, facing them; when the hit lands you flash through to their far side. Targets whoever is nearest your crosshair, preferring people you've recently traded damage with. Won't flash into walls.",
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
              min = 10, max = 100, step = 5, default = 45, onChange = function(v) CFG.range = v end },
            { type = "toggle", name = "Flash through on hit", key = "through", default = true,
              onChange = function(v) CFG.through = v and true or false end },
        },
    }
end

return Flash
