-- Huss Valley: Auto Dash (runner side). Dashes out of the way the moment a catcher commits.
--
-- What the first recording showed (2026-10-03, Huss_Recon/rec_1003_160229):
--   * A catcher's DIVE is announced on their character the instant it starts: attribute
--     TackleDirection, then TackleActive = true. The dive covers ~14 studs in ~0.33 s and
--     catches within TackleReach (4.5 / 5.5 / 6.5 studs). The user was caught 0.25 s after one
--     started 23 studs out, 27 degrees off them, with their dash ready.
--   * A catcher's close-range GRAB names its target: ReachTargetUserId = your UserId, with
--     ReachPhase Tracking -> Windup -> Active.
--   * Your DASH is Space (ContextActionService "CoHBoost"), 8-9 studs, 1.1 s cooldown
--     (character attributes DashReady / DashCooldown / DashCount).
--   * User: "the dash is directional but if you're running straight you can't really dash
--     straight, it has to be another direction" -- it goes where your movement keys point, and
--     that must differ from where you're already heading.
--
-- So: when a dive is aimed at you (or a grab targets you), work out the sideways direction that
-- takes you off the catcher's line, ADD the movement keys that lean your input that way
-- (relative to the camera; on top of whatever you're holding), tap Space, and let the added
-- keys go. Everything is done with key presses, the same inputs a player makes.
--
-- NOT yet proven live: that the dash clears a dive in time, and the danger-zone sizes below.
-- Every trigger is logged to workspace/Huss_Recon/autodash_<time>.log with whether the dash
-- went out and whether you were caught anyway -- tune from that.

local Players    = game:GetService("Players")
local UIS        = game:GetService("UserInputService")
local VIM        = game:GetService("VirtualInputManager")
local RunService = game:GetService("RunService")
local Workspace  = game:GetService("Workspace")

local log = require("core.log")

local LP = Players.LocalPlayer

local Dash = {}
local CFG = { enabled = false, dives = true, grabs = true, near = 0 }

local DIVE_AHEAD = 28     -- studs along the dive line that count as "aimed at you" (dive ~14 + run-in)
local DIVE_WIDTH = 12     -- studs either side of that line (reach 6.5 + how far you both move)
local GRAB_RANGE = 16     -- a grab only matters this close
local STRAIGHT   = 0.8    -- a key direction this aligned with your travel counts as "straight" (~37 deg)
local RETRIGGER  = 0.3    -- seconds between two of our own dash attempts

local KEYS  = { W = Enum.KeyCode.W, A = Enum.KeyCode.A, S = Enum.KeyCode.S, D = Enum.KeyCode.D }
local ORDER = { "W", "A", "S", "D" }

local running = false
local conns, charConns = {}, {}
local realHeld = { W = false, A = false, S = false, D = false }   -- YOUR fingers, not our presses
local fakeDown, fakeUp = { W = 0, A = 0, S = 0, D = 0 }, { W = 0, A = 0, S = 0, D = 0 }
local fakeAt = 0
local busy, lastTry = false, -math.huge
local logPath, logBuf = nil, {}

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

local OPPOSITE = { W = "S", S = "W", A = "D", D = "A" }

-- Which movement keys to ADD to the ones you're holding so your input leans towards `desired`.
-- Keys are only ever added, never taken away: a key you are physically holding can't be
-- "released" for you and handed back safely (if you let go meanwhile the game never hears it
-- and the re-press would stick). The recorded dashes were all a 90-degree sidestep to one side
-- or the other, so leaning the input to the right side is what picks the dash direction.
-- If the result would still be straight along your travel (the game won't dash straight), the
-- sideways key that takes you away from the catcher is added too.
local function pickKeys(desired, away, travel)
    local cam = Workspace.CurrentCamera
    if not cam then return nil end
    local f = flat(cam.CFrame.LookVector)
    if f.Magnitude < 1e-3 then return nil end
    f = f.Unit
    local r = Vector3.new(-f.Z, 0, f.X)
    local dirs = { W = f, S = -f, D = r, A = -r }
    local adds = {}
    local function free(k) return not realHeld[k] and not adds[k] and not realHeld[OPPOSITE[k]] and not adds[OPPOSITE[k]] end
    local function input()
        local v = Vector3.new(0, 0, 0)
        for _, k in ipairs(ORDER) do if realHeld[k] or adds[k] then v = v + dirs[k] end end
        return v
    end
    for _, k in ipairs(ORDER) do
        if free(k) and dirs[k]:Dot(desired) > 0.35 then adds[k] = true end
    end
    local v = input()
    if v.Magnitude < 0.1 or (travel and v.Unit:Dot(travel) > STRAIGHT) then
        local best, bestScore
        for _, k in ipairs(ORDER) do
            if free(k) and (not travel or math.abs(dirs[k]:Dot(travel)) < 0.5) then
                local score = dirs[k]:Dot(desired) + 0.5 * dirs[k]:Dot(away)
                if not bestScore or score > bestScore then best, bestScore = k, score end
            end
        end
        if best then adds[best] = true end
        v = input()
    end
    local list = {}
    for _, k in ipairs(ORDER) do if adds[k] then list[#list + 1] = k end end
    return list, (v.Magnitude > 0.1) and v.Unit:Dot(desired) or 0
end

-- Sideways off the threat's line, on the side you're already on (or already moving towards).
local function escapeDir(threatPos, threatDir, me, myVel)
    local T = flat(threatDir)
    if T.Magnitude < 1e-3 then return nil end
    T = T.Unit
    local P = Vector3.new(-T.Z, 0, T.X)
    local rel = flat(me - threatPos)
    local side = P:Dot(rel)
    if math.abs(side) < 1.5 then side = P:Dot(flat(myVel)) end   -- dead on its line: keep your sideways momentum
    if side < 0 then P = -P end
    return P
end

local function tryDash(reason, catcher, threatPos, threatDir)
    if busy or os.clock() - lastTry < RETRIGGER then return end
    local ok, why = canDash()
    local root = myRoot()
    if not ok or not root then
        if why ~= "not an active runner" then dlog("SKIP %s from %s (%s)", reason, catcher, tostring(why)) end
        return
    end
    local vel = flat(root.AssemblyLinearVelocity)
    local travel = vel.Magnitude > 5 and vel.Unit or nil
    local desired = escapeDir(threatPos, threatDir, root.Position, vel)
    local awayVec = flat(root.Position - threatPos)
    local away = awayVec.Magnitude > 1e-3 and awayVec.Unit or (desired or Vector3.new(0, 0, 0))
    local combo, score
    if desired then combo, score = pickKeys(desired, away, travel) end
    if not combo then dlog("SKIP %s from %s (no direction)", reason, catcher); return end

    busy, lastTry = true, os.clock()
    local char = LP.Character
    local before = char and char:GetAttribute("DashCount")
    dlog("DASH %s from %s  dist %.1f  adding %s (fit %.2f)  held %s%s%s%s", reason, catcher,
        awayVec.Magnitude, #combo > 0 and table.concat(combo, "+") or "nothing", score,
        realHeld.W and "W" or "", realHeld.A and "A" or "", realHeld.S and "S" or "", realHeld.D and "D" or "")

    task.spawn(function()
        for _, k in ipairs(combo) do send(k, true) end
        RunService.Heartbeat:Wait()          -- let the game read the new direction
        RunService.Heartbeat:Wait()
        pcall(function() VIM:SendKeyEvent(true, Enum.KeyCode.Space, false, game) end)
        task.wait(0.03)
        pcall(function() VIM:SendKeyEvent(false, Enum.KeyCode.Space, false, game) end)
        task.wait(0.2)
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

local function isCatcher(plr) return plr:GetAttribute("GameRole") == "Catcher" end

-- a dive just started on this catcher: is its line coming through you?
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
    local along = rel:Dot(T)
    local lateral = (rel - T * along).Magnitude
    if along < -2 or along > DIVE_AHEAD or lateral > DIVE_WIDTH then return end
    tryDash(string.format("dive (%.0f ahead, %.0f off line)", along, lateral), plr.Name, croot.Position, T)
end

local function onGrab(plr, char)
    if not (CFG.enabled and CFG.grabs) or not isCatcher(plr) then return end
    if char:GetAttribute("ReachTargetUserId") ~= LP.UserId then return end
    local phase = char:GetAttribute("ReachPhase")
    if phase ~= "Tracking" and phase ~= "Windup" then return end
    local croot = char:FindFirstChild("HumanoidRootPart")
    local root = myRoot()
    if not (croot and root) then return end
    local rel = flat(root.Position - croot.Position)
    if rel.Magnitude > GRAB_RANGE or rel.Magnitude < 1e-3 then return end
    tryDash("grab (" .. tostring(phase) .. ")", plr.Name, croot.Position, rel)
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

-- optional: don't wait for the dive -- dash when a catcher is this close and closing in
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
                        tryDash(string.format("close (%.0f studs, closing %.0f)", rel.Magnitude, closing), plr.Name, croot.Position, rel)
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
    dlog("START dives=%s grabs=%s near=%s", tostring(CFG.dives), tostring(CFG.grabs), tostring(CFG.near))
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
        description = "As a Runner, dashes sideways out of a catcher's way the instant they commit: when a dive is aimed at you, or their close-range grab picks you as its target. It adds the movement key that leans you off the catcher's line on top of whatever you're holding (and a sideways one if that would still be straight ahead, since the game won't dash straight), taps Space, then lets the added key go. It never releases a key you're holding. Only acts while your dash is ready. Each attempt is logged to workspace/Huss_Recon so it can be tuned.",
        default     = false,
        onToggle    = function(v)
            CFG.enabled = v and true or false
            if CFG.enabled then Dash.start() else Dash.stop() end
        end,
        settings = {
            { type = "toggle", name = "Dash when a dive is aimed at you", key = "dives", default = true,
              onChange = function(v) CFG.dives = v and true or false end },
            { type = "toggle", name = "Dash when a grab targets you", key = "grabs", default = true,
              onChange = function(v) CFG.grabs = v and true or false end },
            { type = "slider", name = "Also dash when a catcher closes within (studs, 0 = off)", key = "near",
              min = 0, max = 25, step = 1, default = 0,
              onChange = function(v) CFG.near = v end },
        },
    }
end

return Dash
