-- Huss Valley: Lunge Aim (catcher side). The instant you lunge, turn to face the nearest runner
-- so the dive goes at them.
--
-- What the recordings + the game's own scripts show (2026-10-03):
--   * The lunge is Space / E (ContextActionService "CoHTackle", priority 2000) ->
--     Game.TacklePrediction.request(). The dive's direction is FIXED when it starts: a world-space
--     LinearVelocity plus an AlignOrientation holding that direction (so nothing can steer it
--     mid-dive -- it has to be right at the press).
--   * In 21 recorded lunges that direction was the way the body faced at the press (0-8 degrees
--     off), NOT the way the user was moving (30-52 degrees off). The body normally faces where
--     the camera looks, so whether the game reads the body or the camera can't be told apart
--     from the recordings (request() didn't decompile) -> BOTH are turned.
--   * Dive: up to 15 studs in <= 0.4 s (Long Dive needs 80% of top speed), catch reach 4-5.5
--     studs, 1.1 s cooldown. Runners run ~36 stud/s, about as fast as the dive, so the aim is led.
--     12 of 14 lunges in the second recording missed while aimed within 2-27 degrees.
--
-- How: a second action is bound to the same keys at a HIGHER priority. It runs first, snaps your
-- body (and, for that one instant, the camera -- the camera script rewrites it on the next frame,
-- so the view doesn't move) to face the lead point on the nearest catchable runner, then passes
-- the key on untouched so the game's own lunge fires as normal.
--
-- Every lunge is logged to workspace/Huss_Recon/lunge_<time>.log with how far the dive actually
-- went from the aim -- if that is consistently large the game isn't reading what we turn.

local Players   = game:GetService("Players")
local CAS       = game:GetService("ContextActionService")
local UIS       = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local VIM       = game:GetService("VirtualInputManager")
local RunService = game:GetService("RunService")

local log = require("core.log")

local LP = Players.LocalPlayer

local Lunge = {}
local CFG = { enabled = false, range = 25, lead = true, camera = true, skipSafe = true }

-- AUTO LUNGE (user 2026-10-03: "we need an auto lunge for when I'm on red team"): presses the
-- lunge for you the moment a dive started now would land. From the game's own numbers
-- (GameConfig.Tackle + TackleProfile): a dive travels max(variant distance x 1.15, your speed x
-- 0.4 x 1.45) studs, capped at 15, in 0.4 s (shorter when capped); variant by your speed --
-- under 40% of top speed Short (2.4 studs, reach 4), under 80% Medium (4.8, reach 4.75), else
-- Long (8.4, reach 5.5). A miss costs ~1.1 s (0.6 s recovery + cooldown), so it only fires when
-- the runner's led position is inside dive distance + reach with `margin` studs to spare.
local AUTO = { on = false, margin = 1.5, cone = 120, conn = nil, last = -math.huge, aimedAt = -math.huge }

local ACTION     = "PantheonHussLungeAim"
local DIVE_SPEED = 38      -- studs/s: 15 studs over 0.4 s
local MAX_LEAD   = 0.35    -- seconds of runner movement to aim ahead by, at most
local REACH      = 4       -- the catch reaches this far in front of the dive
local TOP_SPEED  = 37      -- catcher top speed (33.6 x 1.1)
local SEEN_LATE  = 0.2     -- other players reach your client about this late

local bound = false
local logPath, logBuf, flushConn = nil, {}, nil

local function dlog(fmt, ...)
    logBuf[#logBuf + 1] = string.format("%.3f ", os.clock()) .. string.format(fmt, ...)
end

local function dlogFlush()
    if #logBuf == 0 or not logPath or type(appendfile) ~= "function" then return end
    if pcall(appendfile, logPath, table.concat(logBuf, "\n") .. "\n") then table.clear(logBuf) end
    if #logBuf > 2000 then table.clear(logBuf) end
end

local function flat(v) return Vector3.new(v.X, 0, v.Z) end

-- can a lunge go out right now? (mirrors the game's own check, so we never turn you for nothing)
local function canLunge()
    if LP:GetAttribute("GameRole") ~= "Catcher" or LP:GetAttribute("RunState") ~= "Active" then return false end
    local c = LP.Character
    local hum = c and c:FindFirstChildOfClass("Humanoid")
    if not (hum and hum.Health > 0) or hum.Sit or hum.PlatformStand then return false end
    if c:GetAttribute("MovementLocked") or c:GetAttribute("TackleActive") then return false end
    local ready = LP:GetAttribute("TackleReadyAt")
    if type(ready) == "number" and ready - Workspace:GetServerTimeNow() > 0.02 then return false end
    return true
end

local function isGreen(char)
    local h = char:FindFirstChild("RoleOutline")
    if not (h and h:IsA("Highlight")) then return false end
    local hue, s, v = h.OutlineColor:ToHSV()
    return s >= 0.2 and v >= 0.15 and hue >= 0.2 and hue <= 0.5
end

-- nearest runner that can still be caught
local function nearestRunner(me)
    local best, bestDist
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP and plr:GetAttribute("GameRole") == "Runner" and plr:GetAttribute("RunState") == "Active" then
            local char = plr.Character
            local root = char and char:FindFirstChild("HumanoidRootPart")
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if root and hum and hum.Health > 0 and not (CFG.skipSafe and isGreen(char)) then
                local d = flat(root.Position - me).Magnitude
                if d <= CFG.range and (not bestDist or d < bestDist) then best, bestDist = plr, d end
            end
        end
    end
    return best, bestDist
end

local function aimPoint(root, dist)
    if not CFG.lead then return root.Position, 0 end
    local t = math.clamp((dist - REACH) / DIVE_SPEED, 0, MAX_LEAD)
    return root.Position + flat(root.AssemblyLinearVelocity) * t, t
end

-- Turn the body (and for this one instant the camera heading) to `dir`. Returns degrees turned.
local function face(myRoot, dir)
    local was = flat(myRoot.CFrame.LookVector)
    local turned = was.Magnitude > 1e-3 and math.deg(math.acos(math.clamp(was.Unit:Dot(dir), -1, 1))) or 0
    myRoot.CFrame = CFrame.lookAt(myRoot.Position, myRoot.Position + dir)
    if CFG.camera then
        local cam = Workspace.CurrentCamera
        if cam then
            -- same spot, same pitch, new heading; the camera script overwrites this next frame
            local look = cam.CFrame.LookVector
            local horiz = math.sqrt(math.max(0, 1 - look.Y * look.Y))
            local pos = cam.CFrame.Position
            cam.CFrame = CFrame.lookAt(pos, pos + Vector3.new(dir.X * horiz, look.Y, dir.Z * horiz))
        end
    end
    return turned
end

local report      -- (dir) logs afterwards where the dive went and whether it caught; defined below

local function onKey(_, inputState)
    if inputState ~= Enum.UserInputState.Begin then return Enum.ContextActionResult.Pass end
    if os.clock() - AUTO.aimedAt < 0.15 then return Enum.ContextActionResult.Pass end   -- Auto Lunge just aimed this press
    if not CFG.enabled or UIS:GetFocusedTextBox() or not canLunge() then return Enum.ContextActionResult.Pass end
    local char = LP.Character
    local myRoot = char and char:FindFirstChild("HumanoidRootPart")
    if not myRoot or myRoot.Anchored then return Enum.ContextActionResult.Pass end

    local target, dist = nearestRunner(myRoot.Position)
    if not target then
        dlog("LUNGE no runner within %d studs -- left alone", CFG.range)
        return Enum.ContextActionResult.Pass
    end
    local troot = target.Character.HumanoidRootPart
    local point, lead = aimPoint(troot, dist)
    local dir = flat(point - myRoot.Position)
    if dir.Magnitude < 0.05 then return Enum.ContextActionResult.Pass end
    dir = dir.Unit

    local turned = face(myRoot, dir)
    dlog("LUNGE at %s  %.1f studs  lead %.2f s  turned %.0f deg", target.Name, dist, lead, turned)
    report(dir)
    return Enum.ContextActionResult.Pass      -- the game's own lunge handler runs next, on the same press
end

-- afterwards: did the dive actually go where we aimed, and did it land?
report = function(dir)
    local stats = LP:FindFirstChild("leaderstats")
    local catches = stats and stats:FindFirstChild("Catches")
    local before = catches and catches.Value
    task.delay(0.15, function()
        local c = LP.Character
        local went = c and c:GetAttribute("TackleDirection")
        if c and c:GetAttribute("TackleActive") and typeof(went) == "Vector3" and flat(went).Magnitude > 1e-3 then
            dlog("  -> dive went %.0f deg off the aim (%s)", math.deg(math.acos(math.clamp(flat(went).Unit:Dot(dir), -1, 1))),
                tostring(c:GetAttribute("TackleVariant")))
        else
            dlog("  -> no dive started")
        end
    end)
    task.delay(1.2, function()
        if catches and before then dlog("  -> %s", catches.Value > before and "CAUGHT" or "missed") end
    end)
end

--------------------------------------------------------------------- auto lunge

-- how far, how long and how far ahead a dive started at this speed reaches (the game's formula)
local function diveProfile(speed)
    local ratio = math.clamp(speed / TOP_SPEED, 0, 1)
    local dist, reach = 2.4, 4
    if ratio >= 0.8 then dist, reach = 8.4, 5.5 elseif ratio >= 0.4 then dist, reach = 4.8, 4.75 end
    local raw = math.max(dist * 1.15, speed * 0.4 * 1.45)
    local capped = math.min(raw, 15)
    return capped, 0.4 * (raw > 0 and capped / raw or 1), reach
end

-- Would a dive started right now reach this runner? Returns the point to aim at and the time
-- into the dive it connects, or nil.
local function solve(me, speed, troot)
    local dist, dur, reach = diveProfile(speed)
    local v = flat(troot.AssemblyLinearVelocity)
    local p = troot.Position + v * SEEN_LATE
    local t = 0.06
    while t <= dur + 0.001 do
        local at = p + v * t
        local need = flat(at - me).Magnitude - reach
        if need <= dist * math.min(1, t / dur) - AUTO.margin then return at, t end
        t += 0.04
    end
    return nil
end

local function autoStep()
    if not AUTO.on or os.clock() - AUTO.last < 0.5 then return end
    if UIS:GetFocusedTextBox() or not canLunge() then return end
    local char = LP.Character
    local myRoot = char and char:FindFirstChild("HumanoidRootPart")
    if not myRoot or myRoot.Anchored then return end
    local me = myRoot.Position
    local speed = flat(myRoot.AssemblyLinearVelocity).Magnitude
    local look = flat(myRoot.CFrame.LookVector)
    local limit = math.cos(math.rad(AUTO.cone / 2))
    local best, bestT, bestPoint
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP and plr:GetAttribute("GameRole") == "Runner" and plr:GetAttribute("RunState") == "Active" then
            local c = plr.Character
            local troot = c and c:FindFirstChild("HumanoidRootPart")
            local hum = c and c:FindFirstChildOfClass("Humanoid")
            if troot and hum and hum.Health > 0 and not (CFG.skipSafe and isGreen(c))
               and flat(troot.Position - me).Magnitude <= 32 then
                local point, t = solve(me, speed, troot)
                if point then
                    local dir = flat(point - me)
                    local inCone = dir.Magnitude < 0.05 or look.Magnitude < 1e-3 or look.Unit:Dot(dir.Unit) >= limit
                    if inCone and (not bestT or t < bestT) then best, bestT, bestPoint = plr, t, point end
                end
            end
        end
    end
    if not best then return end
    local dir = flat(bestPoint - me)
    if dir.Magnitude < 0.05 then dir = look end
    if dir.Magnitude < 1e-3 then return end
    dir = dir.Unit
    AUTO.last, AUTO.aimedAt = os.clock(), os.clock()
    local turned = face(myRoot, dir)
    dlog("AUTO lunge at %s  %.1f studs  connects in %.2f s  speed %.0f  turned %.0f deg", best.Name,
        flat(best.Character.HumanoidRootPart.Position - me).Magnitude, bestT, speed, turned)
    report(dir)
    -- E is the lunge and nothing else (Space is also the runner's dash)
    pcall(function() VIM:SendKeyEvent(true, Enum.KeyCode.E, false, game) end)
    task.delay(0.04, function() pcall(function() VIM:SendKeyEvent(false, Enum.KeyCode.E, false, game) end) end)
end

--------------------------------------------------------------------- lifecycle

-- log + flush run while either feature is on; the key bind only for Lunge Aim, the loop only for Auto Lunge
local function refresh()
    local any = CFG.enabled or AUTO.on
    if any and not flushConn then
        if type(writefile) == "function" then
            if makefolder and isfolder and not isfolder("Huss_Recon") then pcall(makefolder, "Huss_Recon") end
            logPath = "Huss_Recon/lunge_" .. os.date("%m%d_%H%M%S") .. ".log"
            pcall(writefile, logPath, "")
        end
        local acc = 0
        flushConn = RunService.Heartbeat:Connect(function(dt)
            acc += dt
            if acc >= 2 then acc = 0; dlogFlush() end
        end)
    elseif not any and flushConn then
        flushConn:Disconnect(); flushConn = nil
        dlogFlush()
    end
    if CFG.enabled and not bound then
        -- above the game's own bind (2000) so this sees the key first; it never sinks the key
        CAS:BindActionAtPriority(ACTION, function(...)
            local ok, res = pcall(onKey, ...)
            return ok and res or Enum.ContextActionResult.Pass
        end, false, 3000, Enum.KeyCode.Space, Enum.KeyCode.E, Enum.KeyCode.ButtonR2)
        bound = true
        dlog("AIM on  range=%s lead=%s camera=%s", tostring(CFG.range), tostring(CFG.lead), tostring(CFG.camera))
    elseif not CFG.enabled and bound then
        pcall(function() CAS:UnbindAction(ACTION) end); bound = false
    end
    if AUTO.on and not AUTO.conn then
        local acc = 0
        AUTO.conn = RunService.Heartbeat:Connect(function(dt)
            acc += dt
            if acc >= 0.03 then acc = 0; pcall(autoStep) end
        end)
        dlog("AUTO on  margin=%s cone=%s", tostring(AUTO.margin), tostring(AUTO.cone))
    elseif not AUTO.on and AUTO.conn then
        AUTO.conn:Disconnect(); AUTO.conn = nil
    end
end

function Lunge.start() CFG.enabled = true; refresh(); log.info("[LungeAim] on") end

function Lunge.stop()
    CFG.enabled, AUTO.on = false, false
    refresh()
end

function Lunge.autoFeature()
    return {
        id          = "huss.auto_lunge",
        name        = "Auto Lunge",
        description = "As a Catcher, lunges for you the instant a dive would land: it works out how far your dive goes at your current speed (the faster you're running, the further and longer it reaches), aims ahead of the runner, and presses the lunge only when they're inside that reach with room to spare -- a miss costs over a second, so it doesn't guess. It turns you to the runner the same way Lunge Aim does. Picks runners who can still be caught. Each lunge is logged to workspace/Huss_Recon.",
        default     = false,
        onToggle    = function(v) AUTO.on = v and true or false; refresh() end,
        settings = {
            { type = "slider", name = "Spare room before lunging (studs; higher = fewer, surer lunges)", key = "margin",
              min = 0, max = 5, step = 0.5, default = 1.5,
              onChange = function(v) AUTO.margin = v end },
            { type = "slider", name = "Only runners within this arc in front of you (degrees)", key = "cone",
              min = 30, max = 360, step = 10, default = 120,
              onChange = function(v) AUTO.cone = v end },
        },
    }
end

function Lunge.feature()
    return {
        id          = "huss.lunge_aim",
        name        = "Lunge Aim",
        description = "As a Catcher, turns you to face the nearest runner the instant you lunge (Space / E), so the dive goes at them. The game fixes a dive's direction at the press, so the turn happens just before your key reaches the game. It aims ahead of a moving runner, only picks runners who can still be caught, and does nothing if none is in range. Each lunge is logged to workspace/Huss_Recon.",
        default     = false,
        onToggle    = function(v)
            CFG.enabled = v and true or false
            refresh()
        end,
        settings = {
            { type = "slider", name = "Only aim at runners within (studs)", key = "range", min = 8, max = 60, step = 1, default = 25,
              onChange = function(v) CFG.range = v end },
            { type = "toggle", name = "Aim ahead of a moving runner", key = "lead", default = true,
              onChange = function(v) CFG.lead = v and true or false end },
            { type = "toggle", name = "Turn the camera heading too (for that instant)", key = "camera", default = true,
              onChange = function(v) CFG.camera = v and true or false end },
            { type = "toggle", name = "Skip green-outlined runners", key = "skip_safe", default = true,
              onChange = function(v) CFG.skipSafe = v and true or false end },
        },
    }
end

return Lunge
