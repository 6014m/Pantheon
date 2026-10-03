-- Huss Valley: Auto Dash (runner side). Dashes the moment a catcher commits, and picks the side
-- that leaves the most catchers flat-footed.
--
-- The game's rules (its own scripts, pulled 2026-10-03: MovementConfig.Dash, MovementModel,
-- DashAnimationPolicy, GameConfig.Tackle, ContactCatchConfig):
--   * DASH = Space ("CoHBoost"): 10.8 studs in 0.28 s, 1.1 s cooldown. It only fires as a
--     REDIRECT: your input must point at least 35 degrees away from where you have been
--     travelling (looked back 0.38 s; Space itself is buffered 0.18 s). The dash then goes
--     along the part of your input that is sideways to your travel -- i.e. a hard cut LEFT or
--     RIGHT (input more than 90 degrees off travel goes where the input points: back cuts).
--     That is the user's "you can't dash straight, it has to be another direction".
--   * A catcher's DIVE is announced on their character the instant it starts (TackleDirection,
--     then TackleActive = true): fixed direction, up to 15 studs in <= 0.4 s, catching 4-5.5
--     studs ahead in a 3.4-wide lane, then ~0.6 s of recovery where they can't do anything.
--   * A catcher's automatic close-range GRAB names its target (ReachTargetUserId) and goes
--     Tracking -> Windup 0.12 s -> Active 0.18 s; it commits from ~10.5 studs.
--   * Catchers run 37 stud/s and turn at 300 degrees/s; runners 35.6.
--
-- WHICH SIDE (user 2026-10-03: "it needs to really focus on breaking people's ankles and
-- disorientating groups because eventually it's me vs like 20 ... if I'm always dashing the same
-- way I'm likely to get caught"). Both sides are scored and the better one is taken:
--   * where EVERY catcher within 45 studs will be over the next 0.6 s (a diving one along its
--     dive line, the rest along their current run) against where the dash would put you --
--     being near any of them costs, being within catching reach costs a lot. This is what
--     steers you out of a pack instead of into the next catcher;
--   * ankle breaker: cutting AGAINST a chasing catcher's sideways motion scores extra -- they
--     have to stop and turn back (300 deg/s), which is the stumble;
--   * a wall or prop in the way within the dash's length costs;
--   * dashing the same side as last time costs more each time in a row, and a little randomness
--     breaks near-ties -- so there is no pattern to read.
--
-- INPUT, two methods (the "How to cut" setting):
--   * "Turn my heading" (default): swings the camera heading about your character so the keys
--     you already hold point along the cut, waits out the swing, taps Space, runs the new way
--     for the hold time, then eases the view back. No key is ever touched (W is pressed only
--     when you hold nothing), and every direction is reachable -- including the back cuts.
--   * "Add movement keys": presses A / D on top of what you hold (left / right only). It never
--     releases a key your finger is on (a fake release can't be handed back safely), which is
--     why holding W+A used to leave no side available -- the reason the turn method exists.
--
-- Every attempt is logged to workspace/Huss_Recon/autodash_<time>.log: every cut's score, the
-- cut taken, whether the dash came out and whether you were caught anyway.

local Players    = game:GetService("Players")
local UIS        = game:GetService("UserInputService")
local VIM        = game:GetService("VirtualInputManager")
local RunService = game:GetService("RunService")
local Workspace  = game:GetService("Workspace")

local log = require("core.log")

local LP = Players.LocalPlayer

local Dash = {}
local METHOD_TURN, METHOD_KEYS = "Turn my heading", "Add movement keys"
local CFG = { enabled = false, dives = true, grabs = true, near = 0, vary = true, method = METHOD_TURN, hold = 0.5 }

local DASH_DIST, DASH_TIME = 10.8, 0.28
local DIVE_DIST, DIVE_SPEED = 15, 37.5
local CATCH_RANGE = 8.5     -- studs: closer than this to a diving catcher's path = caught (reach 5.5 + your body + lag)
local DIVE_AHEAD  = 30      -- a dive further than this along its line can't reach you
local GRAB_RANGE  = 16      -- a grab only matters this close
local AWARE       = 45      -- catchers within this many studs are weighed when picking a side
local MIN_INTENT  = 0.766   -- cos(40 deg): the input must be at least this far off your travel (game needs 35)
local RETRIGGER   = 0.3     -- seconds between two of our own dash attempts
-- Other players reach your client LATE. Recording 1: the user was caught 0.25 s after a dive
-- appeared to start 23 studs away -- a dive covers 15 studs in 0.4 s, so the catcher was really
-- ~10 studs closer than shown and the dive already under way. Every catcher is therefore
-- treated as this far ahead of where it appears, along its own motion.
local LAG         = 0.25

local KEYS  = { W = Enum.KeyCode.W, A = Enum.KeyCode.A, S = Enum.KeyCode.S, D = Enum.KeyCode.D }
local ORDER = { "W", "A", "S", "D" }
local OPPOSITE = { W = "S", S = "W", A = "D", D = "A" }

local running = false
local conns, charConns = {}, {}
local realHeld = { W = false, A = false, S = false, D = false }   -- YOUR fingers, not our presses
local fakeDown, fakeUp = { W = 0, A = 0, S = 0, D = 0 }, { W = 0, A = 0, S = 0, D = 0 }
local fakeAt = 0
local busy, lastTry = false, -math.huge
local generation = 0                 -- bumped by stop(): a dash still in flight then does nothing more
local lastSide, streak = nil, 0      -- "left" / "right" and how many times in a row
local logPath, logBuf = nil, {}
local rayParams = RaycastParams.new()

local function dlog(fmt, ...)
    logBuf[#logBuf + 1] = string.format("%.3f ", os.clock()) .. string.format(fmt, ...)
end

local function dlogFlush()
    if #logBuf == 0 or not logPath or type(appendfile) ~= "function" then return end
    if pcall(appendfile, logPath, table.concat(logBuf, "\n") .. "\n") then table.clear(logBuf) end
    if #logBuf > 2000 then table.clear(logBuf) end
end

local function flat(v) return Vector3.new(v.X, 0, v.Z) end

local function myRoot()
    local c = LP.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

-- Runner, in a live crossing, able to move, dash off cooldown
local function canDash()
    if LP:GetAttribute("GameRole") ~= "Runner" or LP:GetAttribute("RunState") ~= "Active" then return false, "not an active runner" end
    local c = LP.Character
    local hum = c and c:FindFirstChildOfClass("Humanoid")
    if not (hum and hum.Health > 0) then return false, "no character" end
    if c:GetAttribute("MovementLocked") then return false, "movement locked" end
    if c:GetAttribute("DashReady") == false then return false, "dash on cooldown" end
    if UIS:GetFocusedTextBox() then return false, "typing" end
    return true
end

-- Is this key event one of ours? (same bookkeeping as The Veil's Auto Sprint: counts go stale
-- when a key-up is sent for a key that was already up, so they're forgotten after 0.4 s)
local function fakeEvent(name, isDown)
    if os.clock() - fakeAt > 0.4 then
        for _, k in ipairs(ORDER) do fakeDown[k], fakeUp[k] = 0, 0 end
    end
    local t = isDown and fakeDown or fakeUp
    if t[name] > 0 then t[name] -= 1; return true end
    return false
end

local function send(name, down)
    fakeAt = os.clock()
    if down then fakeDown[name] += 1 else fakeUp[name] += 1 end
    pcall(function() VIM:SendKeyEvent(down, KEYS[name], false, game) end)
end

--------------------------------------------------------------------- the catchers around you

local function isCatcher(plr) return plr:GetAttribute("GameRole") == "Catcher" end

-- every catcher within AWARE studs: where it is, how it's moving, and its dive line if diving
local function catchersNear(me)
    local list, chars = {}, {}
    for _, plr in ipairs(Players:GetPlayers()) do
        local char = plr.Character
        if char then chars[#chars + 1] = char end
        if plr ~= LP and char and isCatcher(plr) then
            local root = char:FindFirstChild("HumanoidRootPart")
            if root and flat(root.Position - me).Magnitude <= AWARE then
                local c = { name = plr.Name, pos = root.Position, vel = flat(root.AssemblyLinearVelocity), diving = false }
                if char:GetAttribute("TackleActive") == true then
                    local dir = char:GetAttribute("TackleDirection")
                    if typeof(dir) ~= "Vector3" then dir = root.CFrame.LookVector end
                    dir = flat(dir)
                    if dir.Magnitude > 1e-3 then c.diving, c.dir = true, dir.Unit end
                end
                list[#list + 1] = c
            end
        end
    end
    return list, chars
end

-- where a catcher will be `t` seconds from now
local function catcherAt(c, t)
    if c.diving then return c.pos + c.dir * (DIVE_SPEED * LAG + math.min(DIVE_DIST, DIVE_SPEED * t)) end
    return c.pos + c.vel * (t + LAG)
end

-- where you'd be `t` seconds from now if you cut along `dir` now (dash, then run on)
local function meAt(me, dir, speed, t)
    if t <= DASH_TIME then return me + dir * (DASH_DIST * t / DASH_TIME) end
    return me + dir * (DASH_DIST + speed * 0.85 * (t - DASH_TIME))
end

local SAMPLES = { 0.1, 0.2, 0.3, 0.45, 0.6 }

-- Higher = better. See the header for what goes into it.
local function scoreCut(dir, side, me, speed, list, chars)
    local score, closest = 0, math.huge
    for _, t in ipairs(SAMPLES) do
        local mine = meAt(me, dir, speed, t)
        for _, c in ipairs(list) do
            local d = flat(mine - catcherAt(c, t)).Magnitude
            if d < closest then closest = d end
            if d < 18 then
                local w = ((18 - d) / 18) ^ 2
                if d < CATCH_RANGE then w = w * 4 end      -- inside catching reach
                if c.diving then w = w * 1.5 end           -- a dive can't be out-run, only left
                score -= w
            end
        end
    end
    -- ankle breaker: go against each chaser's sideways motion (relative to the line from it to you)
    for _, c in ipairs(list) do
        if not c.diving then
            local rel = flat(me - c.pos)
            local d = rel.Magnitude
            if d > 1 and d < 30 then
                local toMe = rel.Unit
                local sideways = c.vel - toMe * c.vel:Dot(toMe)
                if sideways.Magnitude > 3 then
                    score += -sideways.Unit:Dot(dir) * math.min(1, sideways.Magnitude / 20) * (1 - d / 30) * 1.5
                end
            end
        end
    end
    -- something solid in the way
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    rayParams.FilterDescendantsInstances = chars
    local hit = Workspace:Raycast(me, dir * (DASH_DIST + 2), rayParams)
    if hit then score -= (1 - (hit.Position - me).Magnitude / (DASH_DIST + 2)) * 5 + 1 end
    -- no pattern
    if CFG.vary then
        if side == lastSide then score -= 0.45 * math.min(streak, 3) end
        score += (math.random() - 0.5) * 0.3
    end
    return score, closest
end

--------------------------------------------------------------------- turning a side into keys

-- The keys to ADD so the game cuts towards `dir`: the input (held + added) must be at least 40
-- degrees off `travel`, and its sideways part must point along `dir`. Returns nil if what you're
-- holding makes that side impossible without releasing a key.
local function keysFor(dir, travel)
    local cam = Workspace.CurrentCamera
    if not cam then return nil end
    local f = flat(cam.CFrame.LookVector)
    if f.Magnitude < 1e-3 then return nil end
    f = f.Unit
    local r = Vector3.new(-f.Z, 0, f.X)
    local dirs = { W = f, S = -f, D = r, A = -r }
    local free = {}
    for _, k in ipairs(ORDER) do
        if not realHeld[k] and not realHeld[OPPOSITE[k]] then free[#free + 1] = k end
    end
    local options = { {} }
    for i, a in ipairs(free) do
        options[#options + 1] = { a }
        for j = i + 1, #free do
            if free[j] ~= OPPOSITE[a] then options[#options + 1] = { a, free[j] } end
        end
    end
    local best, bestFit
    for _, adds in ipairs(options) do
        local v = Vector3.new(0, 0, 0)
        for _, k in ipairs(ORDER) do if realHeld[k] then v = v + dirs[k] end end
        for _, k in ipairs(adds) do v = v + dirs[k] end
        if v.Magnitude > 0.1 then
            local input = v.Unit
            local along = input:Dot(travel)
            if along <= MIN_INTENT then
                local cut = along > 0 and (input - travel * along) or input   -- the game's own rule
                if cut.Magnitude > 0.01 then
                    local fit = cut.Unit:Dot(dir)
                    -- fewest extra keys wins a tie (0.05 per key), so we don't press more than needed
                    local value = fit - 0.05 * #adds
                    if fit > 0.5 and (not bestFit or value > bestFit) then best, bestFit = adds, value end
                end
            end
        end
    end
    return best
end

--------------------------------------------------------------------- turning your heading

-- The other way to give the game a new input direction (user 2026-10-03: "sometimes the best
-- way to break a group's ankles is running in a different direction ... you can rotate my
-- player while I'm holding W"): swing the HEADING. Movement keys are camera-relative, so
-- turning the camera about your character turns where W points -- no key is touched, any
-- direction is reachable (back cuts too), and it works whatever you're holding. The live logs
-- showed why this matters: holding W+A, neither side could be made by adding keys and "NO dash
-- came out" twice.
--
-- Done as an offset on top of the camera script's own result each frame (after it runs), so
-- your mouse still steers underneath; the offset snaps in, is held for the cut, then eases back
-- to zero and hands the camera back untouched.
local STEER = { name = "PantheonHussDashSteer", theta = 0, target = 0, backAt = 0, bound = false }

local function steerStop()
    if STEER.bound then
        pcall(function() RunService:UnbindFromRenderStep(STEER.name) end)
        STEER.bound = false
    end
    STEER.theta, STEER.target = 0, 0
end

local function steerStep(dt)
    local cam = Workspace.CurrentCamera
    local root = myRoot()
    if not (cam and root) then steerStop(); return end
    if os.clock() >= STEER.backAt then STEER.target = 0 end
    -- in fast (a 90 degree swing in ~0.06 s), back out gently
    local rate = math.rad(STEER.target == 0 and 400 or 1500) * dt
    local diff = STEER.target - STEER.theta
    if math.abs(diff) <= rate then STEER.theta = STEER.target
    else STEER.theta += (diff > 0 and rate or -rate) end
    if STEER.theta == 0 and STEER.target == 0 then steerStop(); return end
    local focus = root.Position
    cam.CFrame = CFrame.new(focus) * CFrame.Angles(0, STEER.theta, 0) * CFrame.new(-focus) * cam.CFrame
end

local function steer(theta, hold)
    STEER.target, STEER.backAt = theta, os.clock() + hold
    if not STEER.bound then
        RunService:BindToRenderStep(STEER.name, Enum.RenderPriority.Camera.Value + 2, steerStep)
        STEER.bound = true
    end
end

-- where your held movement keys point right now (world, unit), or nil if you hold none / they cancel
local function heldInput()
    local cam = Workspace.CurrentCamera
    if not cam then return nil end
    local f = flat(cam.CFrame.LookVector)
    if f.Magnitude < 1e-3 then return nil end
    f = f.Unit
    local r = Vector3.new(-f.Z, 0, f.X)
    local dirs = { W = f, S = -f, D = r, A = -r }
    local v = Vector3.new(0, 0, 0)
    for _, k in ipairs(ORDER) do if realHeld[k] then v = v + dirs[k] end end
    if v.Magnitude < 0.1 then return nil, f end
    return v.Unit, f
end

-- turn `v` about the vertical axis by `deg` (positive = to the left, like CFrame.Angles)
local function turned(v, deg)
    local a = math.rad(deg)
    local c, s = math.cos(a), math.sin(a)
    return Vector3.new(v.X * c + v.Z * s, 0, -v.X * s + v.Z * c)
end

--------------------------------------------------------------------- the dash

-- the cuts on offer, as degrees to turn from where you're travelling
local CUTS_TURN = {
    { side = "left", turn = 90, cost = 0 },        { side = "right", turn = -90, cost = 0 },
    { side = "back-left", turn = 135, cost = 0.5 }, { side = "back-right", turn = -135, cost = 0.5 },
    { side = "back", turn = 180, cost = 0.9 },     -- costs: going backwards gives up ground
}
local CUTS_KEYS = { { side = "left", turn = 90, cost = 0 }, { side = "right", turn = -90, cost = 0 } }

local function tryDash(reason, catcherName)
    if busy or os.clock() - lastTry < RETRIGGER then return end
    local ok, why = canDash()
    local root = myRoot()
    if not ok or not root then
        if why ~= "not an active runner" then dlog("SKIP %s from %s (%s)", reason, catcherName, tostring(why)) end
        return
    end
    local me = root.Position
    local vel = flat(root.AssemblyLinearVelocity)
    if vel.Magnitude < 4 then
        dlog("SKIP %s from %s (standing still: the game only dashes as a change of direction)", reason, catcherName)
        return
    end
    local travel, speed = vel.Unit, vel.Magnitude
    local list, chars = catchersNear(me)
    local turning = CFG.method ~= METHOD_KEYS

    local cuts = {}
    for _, def in ipairs(turning and CUTS_TURN or CUTS_KEYS) do
        local c = { side = def.side, turn = def.turn, dir = turned(travel, def.turn) }
        c.score, c.closest = scoreCut(c.dir, c.side, me, speed, list, chars)
        c.score -= def.cost
        if not turning then c.keys = keysFor(c.dir, travel) end
        cuts[#cuts + 1] = c
    end
    table.sort(cuts, function(a, b) return a.score > b.score end)

    local pick, note = cuts[1], ""
    local theta, addW = 0, false
    if turning then
        local input, camLook = heldInput()
        if not input then
            if not camLook then dlog("SKIP %s from %s (no camera)", reason, catcherName); return end
            input, addW = camLook, true          -- holding nothing: W is pressed for the cut
            note = "  (no movement key held: W pressed for the cut)"
        end
        -- the turn that carries your input onto the cut direction
        theta = math.atan2(input.Z * pick.dir.X - input.X * pick.dir.Z, input:Dot(pick.dir))
    else
        pick = nil
        for _, c in ipairs(cuts) do if c.keys then pick = c; break end end
        if pick and pick ~= cuts[1] then note = "  (better side blocked by the keys you're holding)" end
        if not pick then
            -- neither side can be made with added keys: press Space anyway and let your own input decide
            pick = { side = "yours", dir = travel, keys = {}, score = 0, closest = 0 }
            note = "  (no side possible with added keys)"
        end
    end

    busy, lastTry = true, os.clock()
    if pick.side == lastSide then streak += 1 else lastSide, streak = pick.side, 1 end
    local char = LP.Character
    local before = char and char:GetAttribute("DashCount")
    local parts = {}
    for _, c in ipairs(cuts) do parts[#parts + 1] = string.format("%s %.2f (%.0f)", c.side, c.score, c.closest) end
    dlog("DASH %s from %s  catchers %d  [%s]  -> %s x%d  %s  held %s%s%s%s%s",
        reason, catcherName, #list, table.concat(parts, ", "), pick.side, streak,
        turning and string.format("heading %+.0f deg", math.deg(theta))
            or ("adding " .. (#pick.keys > 0 and table.concat(pick.keys, "+") or "nothing")),
        realHeld.W and "W" or "", realHeld.A and "A" or "", realHeld.S and "S" or "", realHeld.D and "D" or "", note)

    local combo = turning and (addW and { "W" } or {}) or pick.keys
    local session = generation
    task.spawn(function()
        for _, k in ipairs(combo) do send(k, true) end
        if turning then
            steer(theta, CFG.hold)
            -- Space BEFORE the swing finishes would dash the wrong way: the game buffers Space
            -- 0.18 s and consumes it the moment the input is 35 deg off travel, so a back cut
            -- pressed mid-swing fires as a side cut. Wait out the swing (90 deg ~ 0.06 s).
            local deadline = os.clock() + 0.25
            repeat RunService.Heartbeat:Wait()
            until math.abs(STEER.theta - STEER.target) < math.rad(8) or os.clock() > deadline
                  or session ~= generation
        else
            RunService.Heartbeat:Wait()          -- let the game read the new direction
            RunService.Heartbeat:Wait()
        end
        if session ~= generation then return end      -- switched off (or restarted) meanwhile
        pcall(function() VIM:SendKeyEvent(true, Enum.KeyCode.Space, false, game) end)
        task.wait(0.03)
        pcall(function() VIM:SendKeyEvent(false, Enum.KeyCode.Space, false, game) end)
        task.wait(0.2)
        if session ~= generation then return end      -- stop() already let every added key go
        -- let go of the keys we added (not one your own finger pressed in the meantime)
        for _, k in ipairs(combo) do
            if not realHeld[k] then send(k, false) end
        end
        busy = false
        local c = LP.Character
        local went = c and c:GetAttribute("DashCount") ~= before
        dlog("  -> %s", went and string.format("dashed (%s, %s studs)", tostring(c:GetAttribute("LastDashAnimation")),
            tostring(c:GetAttribute("LastDashDistance"))) or "NO dash came out")
        task.wait(1.0)
        dlog("  -> %s", LP:GetAttribute("RunState") == "Caught" and "CAUGHT anyway" or "still running")
    end)
end

--------------------------------------------------------------------- triggers

-- a dive just started: will it come within catching range of where you're heading?
local function onDive(plr, char)
    if not (CFG.enabled and CFG.dives) or not isCatcher(plr) then return end
    local croot = char:FindFirstChild("HumanoidRootPart")
    local root = myRoot()
    if not (croot and root) then return end
    local dir = char:GetAttribute("TackleDirection")
    if typeof(dir) ~= "Vector3" then dir = croot.CFrame.LookVector end
    local T = flat(dir)
    if T.Magnitude < 1e-3 then return end
    T = T.Unit
    local rel = flat(root.Position - croot.Position)
    if rel:Dot(T) < -2 or rel:Dot(T) > DIVE_AHEAD + DIVE_SPEED * LAG then return end
    -- closest the dive gets to you if you just keep running (the catcher taken as LAG ahead)
    local vel = flat(root.AssemblyLinearVelocity)
    local c = { pos = croot.Position, dir = T, diving = true }
    local closest = math.huge
    for t = 0, 0.45, 0.05 do
        local d = flat((root.Position + vel * t) - catcherAt(c, t)).Magnitude
        if d < closest then closest = d end
    end
    if closest > CATCH_RANGE then return end
    tryDash(string.format("dive (would pass %.0f studs from you)", closest), plr.Name)
end

local function onGrab(plr, char)
    if not (CFG.enabled and CFG.grabs) or not isCatcher(plr) then return end
    if char:GetAttribute("ReachTargetUserId") ~= LP.UserId then return end
    local phase = char:GetAttribute("ReachPhase")
    if phase ~= "Tracking" and phase ~= "Windup" then return end
    local croot = char:FindFirstChild("HumanoidRootPart")
    local root = myRoot()
    if not (croot and root) then return end
    local d = flat(root.Position - croot.Position).Magnitude
    if d > GRAB_RANGE then return end
    tryDash(string.format("grab (%s, %.0f studs)", tostring(phase), d), plr.Name)
end

local function hookPlayer(plr)
    if plr == LP then return end
    local function hook(char)
        local list = charConns[plr]
        if list then for _, c in ipairs(list) do pcall(function() c:Disconnect() end) end end
        list = {}
        charConns[plr] = list
        list[#list + 1] = char:GetAttributeChangedSignal("TackleActive"):Connect(function()
            if char:GetAttribute("TackleActive") == true then pcall(onDive, plr, char) end
        end)
        list[#list + 1] = char:GetAttributeChangedSignal("ReachTargetUserId"):Connect(function() pcall(onGrab, plr, char) end)
        list[#list + 1] = char:GetAttributeChangedSignal("ReachPhase"):Connect(function() pcall(onGrab, plr, char) end)
    end
    if plr.Character then hook(plr.Character) end
    conns[#conns + 1] = plr.CharacterAdded:Connect(hook)
end

-- optional: don't wait for the dive -- cut when a catcher is this close and closing in
local function proximityStep()
    if not CFG.enabled or CFG.near <= 0 or busy then return end
    local root = myRoot()
    if not root then return end
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP and isCatcher(plr) then
            local croot = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
            if croot then
                local rel = flat(root.Position - croot.Position)
                if rel.Magnitude > 1e-3 and rel.Magnitude <= CFG.near then
                    local closing = flat(croot.AssemblyLinearVelocity - root.AssemblyLinearVelocity):Dot(rel.Unit)
                    if closing > 4 then
                        tryDash(string.format("close (%.0f studs, closing %.0f)", rel.Magnitude, closing), plr.Name)
                        return
                    end
                end
            end
        end
    end
end

function Dash.start()
    Dash.stop()
    running = true
    lastSide, streak = nil, 0
    for _, k in ipairs(ORDER) do realHeld[k] = UIS:IsKeyDown(KEYS[k]); fakeDown[k], fakeUp[k] = 0, 0 end
    if type(writefile) == "function" then
        if makefolder and isfolder and not isfolder("Huss_Recon") then pcall(makefolder, "Huss_Recon") end
        logPath = "Huss_Recon/autodash_" .. os.date("%m%d_%H%M%S") .. ".log"
        pcall(writefile, logPath, "")
    end
    local function keyName(input)
        for _, k in ipairs(ORDER) do if input.KeyCode == KEYS[k] then return k end end
        return nil
    end
    conns[#conns + 1] = UIS.InputBegan:Connect(function(input)
        local k = keyName(input)
        if k and not fakeEvent(k, true) then realHeld[k] = true end
    end)
    conns[#conns + 1] = UIS.InputEnded:Connect(function(input)
        local k = keyName(input)
        if k and not fakeEvent(k, false) then realHeld[k] = false end
    end)
    for _, plr in ipairs(Players:GetPlayers()) do pcall(hookPlayer, plr) end
    conns[#conns + 1] = Players.PlayerAdded:Connect(function(plr) pcall(hookPlayer, plr) end)
    conns[#conns + 1] = Players.PlayerRemoving:Connect(function(plr)
        local list = charConns[plr]
        if list then for _, c in ipairs(list) do pcall(function() c:Disconnect() end) end end
        charConns[plr] = nil
    end)
    local acc, flushAcc = 0, 0
    conns[#conns + 1] = RunService.Heartbeat:Connect(function(dt)
        acc += dt; flushAcc += dt
        if acc >= 0.05 then acc = 0; pcall(proximityStep) end
        if flushAcc >= 2 then flushAcc = 0; dlogFlush() end
    end)
    dlog("START dives=%s grabs=%s near=%s vary=%s", tostring(CFG.dives), tostring(CFG.grabs), tostring(CFG.near), tostring(CFG.vary))
    log.info("[AutoDash] on")
end

function Dash.stop()
    if running then
        -- never leave a movement key held that your finger isn't on
        for _, k in ipairs(ORDER) do
            if UIS:IsKeyDown(KEYS[k]) and not realHeld[k] then
                pcall(function() VIM:SendKeyEvent(false, KEYS[k], false, game) end)
            end
        end
    end
    running, busy = false, false
    generation += 1
    steerStop()
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)
    for _, list in pairs(charConns) do
        for _, c in ipairs(list) do pcall(function() c:Disconnect() end) end
    end
    table.clear(charConns)
    dlogFlush()
end

function Dash.feature()
    return {
        id          = "huss.auto_dash",
        name        = "Auto Dash",
        description = "As a Runner, cuts sideways the instant a catcher commits -- a dive that would reach you, or their close-range grab picking you -- and chooses the side: it works out where every catcher near you will be over the next half second and takes the cut that leaves you furthest from all of them, prefers cutting against a chaser's own sideways momentum (so they have to stop and turn back), avoids walls, and won't keep going the same way. \"Turn my heading\" swings the direction you're facing so the keys you're holding point along the cut (left, right, or back the way you came), dashes, runs that way for a moment, then eases your view back. \"Add movement keys\" presses A / D on top of your keys instead (left / right only). Each attempt is logged to workspace/Huss_Recon.",
        default     = false,
        onToggle    = function(v)
            CFG.enabled = v and true or false
            if CFG.enabled then Dash.start() else Dash.stop() end
        end,
        settings = {
            { type = "dropdown", name = "How to cut", key = "method", default = METHOD_TURN,
              options = { METHOD_TURN, METHOD_KEYS },
              onChange = function(v) CFG.method = v or METHOD_TURN end },
            { type = "slider", name = "Stay on the new heading for (seconds)", key = "hold",
              min = 0.3, max = 3, step = 0.1, default = 0.5,
              onChange = function(v) CFG.hold = v end },
            { type = "toggle", name = "Dash when a dive would reach you", key = "dives", default = true,
              onChange = function(v) CFG.dives = v and true or false end },
            { type = "toggle", name = "Dash when a grab targets you", key = "grabs", default = true,
              onChange = function(v) CFG.grabs = v and true or false end },
            { type = "slider", name = "Also dash when a catcher closes within (studs, 0 = off)", key = "near",
              min = 0, max = 25, step = 1, default = 0,
              onChange = function(v) CFG.near = v end },
            { type = "toggle", name = "Don't repeat the same side (stay unpredictable)", key = "vary", default = true,
              onChange = function(v) CFG.vary = v and true or false end },
        },
    }
end

return Dash
