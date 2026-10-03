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

local log = require("core.log")

local LP = Players.LocalPlayer

local Lunge = {}
local CFG = { enabled = false, range = 25, lead = true, camera = true, skipSafe = true }

local ACTION     = "PantheonHussLungeAim"
local DIVE_SPEED = 38      -- studs/s: 15 studs over 0.4 s
local MAX_LEAD   = 0.35    -- seconds of runner movement to aim ahead by, at most
local REACH      = 4       -- the catch reaches this far in front of the dive

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

local function onKey(_, inputState)
    if inputState ~= Enum.UserInputState.Begin then return Enum.ContextActionResult.Pass end
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
    dlog("LUNGE at %s  %.1f studs  lead %.2f s  turned %.0f deg", target.Name, dist, lead, turned)

    -- afterwards: did the dive actually go where we aimed, and did it land?
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
    return Enum.ContextActionResult.Pass      -- the game's own lunge handler runs next, on the same press
end

function Lunge.start()
    Lunge.stop()
    if type(writefile) == "function" then
        if makefolder and isfolder and not isfolder("Huss_Recon") then pcall(makefolder, "Huss_Recon") end
        logPath = "Huss_Recon/lunge_" .. os.date("%m%d_%H%M%S") .. ".log"
        pcall(writefile, logPath, "")
    end
    -- above the game's own bind (2000) so this sees the key first; it never sinks the key
    CAS:BindActionAtPriority(ACTION, function(...)
        local ok, res = pcall(onKey, ...)
        return ok and res or Enum.ContextActionResult.Pass
    end, false, 3000, Enum.KeyCode.Space, Enum.KeyCode.E, Enum.KeyCode.ButtonR2)
    bound = true
    local acc = 0
    flushConn = game:GetService("RunService").Heartbeat:Connect(function(dt)
        acc += dt
        if acc >= 2 then acc = 0; dlogFlush() end
    end)
    dlog("START range=%s lead=%s camera=%s", tostring(CFG.range), tostring(CFG.lead), tostring(CFG.camera))
    log.info("[LungeAim] on")
end

function Lunge.stop()
    if bound then pcall(function() CAS:UnbindAction(ACTION) end); bound = false end
    if flushConn then flushConn:Disconnect(); flushConn = nil end
    dlogFlush()
end

function Lunge.feature()
    return {
        id          = "huss.lunge_aim",
        name        = "Lunge Aim",
        description = "As a Catcher, turns you to face the nearest runner the instant you lunge (Space / E), so the dive goes at them. The game fixes a dive's direction at the press, so the turn happens just before your key reaches the game. It aims ahead of a moving runner, only picks runners who can still be caught, and does nothing if none is in range. Each lunge is logged to workspace/Huss_Recon.",
        default     = false,
        onToggle    = function(v)
            CFG.enabled = v and true or false
            if CFG.enabled then Lunge.start() else Lunge.stop() end
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
