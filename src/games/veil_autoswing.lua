-- The Veil: Auto Swing. Holds M1 for you whenever a living enemy is inside your weapon's
-- reach, and lets go the moment nothing is in range -- you just steer. The game combos a
-- HELD left button by itself (that's what M1 Continuation leans on), so one virtual hold
-- is both the most natural-looking and the least input spam.
--
-- What counts as an enemy (user 2026-10-04: Ancient Bones was missed -- not every mob
-- lives in workspace.Monsters, so the scan covers the whole Workspace like Bot Mode's):
--   * any model with a Humanoid + HumanoidRootPart that isn't a player, your character,
--     "Runner", the "Explorer" escort, or a summon (digits-named model / container,
--     PlayerID value, SummonNameGui);
--   * inside workspace.Monsters it counts straight away; anywhere else it must have been
--     seen MOVING first (velocity or a 1.5-stud drift from where Pantheon first saw it),
--     which keeps shopkeepers, trainers and quest NPCs off the swing list -- the same
--     rule Bot Mode's Veil filter uses. The list is rebuilt once a second.
--   * with "Also swing at players" on, players outside your party too (different Team
--     value, not a Pantheon friend) -- for PvP.
--
-- Keeps swinging while you're tabbed out (user 2026-10-04): the hold is ours, not your
-- finger's, so alt-tab only resets the real-finger tracker and farming continues.
--
-- Plays nice with the rest of the kit:
--   * every injected press/release is announced to M1 Continuation (noteFake), so it
--     never mistakes our hold for your finger;
--   * while Auto Weave's jump M1 guard is up (it sinks clicks so a held swing can't eat
--     the double jump) we stop pressing and quietly resync -- the guard already released
--     the button for the game;
--   * your real hold always wins: if your finger is on the button we inject nothing, and
--     we never send a release for a press that was yours;
--   * ragdoll / stun / death / typing in a textbox all drop the hold.

local Players    = game:GetService("Players")
local UIS        = game:GetService("UserInputService")
local VIM        = game:GetService("VirtualInputManager")
local RunService = game:GetService("RunService")
local Workspace  = game:GetService("Workspace")

local log   = require("core.log")
local m1    = require("games.veil_m1")
local weave = require("games.veil_weave")
local state = require("modules.aim.state")

local LP  = Players.LocalPlayer
local MB1 = Enum.UserInputType.MouseButton1

local AS = {}
local CFG = { enabled = false, range = 10, frontOnly = true, players = false }
local conns = {}
local running  = false
local ourHold  = false     -- the button is down because WE put it down
local userHeld = false     -- your real finger (our own injected events are filtered out)
local lastEval = 0

-- our injected events come back through InputBegan/InputEnded like real ones; count them
-- so the userHeld tracker skips them (same trick as veil_m1, with the same staleness rule)
local fakeDowns, fakeUps, fakeAt = 0, 0, 0
local function noteOwnFake(isDown)
    fakeAt = os.clock()
    if isDown then fakeDowns = fakeDowns + 1 else fakeUps = fakeUps + 1 end
end
local function ownFakeEvent(isDown)
    if os.clock() - fakeAt > 0.3 then fakeDowns, fakeUps = 0, 0 end
    if isDown and fakeDowns > 0 then fakeDowns = fakeDowns - 1; return true end
    if not isDown and fakeUps > 0 then fakeUps = fakeUps - 1; return true end
    return false
end

local function send(down)
    noteOwnFake(down)
    pcall(function() m1.noteFake(down) end)          -- M1 Continuation: not the user's event
    local p = UIS:GetMouseLocation()
    pcall(function() VIM:SendMouseButtonEvent(p.X, p.Y, 0, down, game, 0) end)
    ourHold = down
end

local function stringChild(model, name)
    local v = model:FindFirstChild(name)
    return (v and v:IsA("ValueBase")) and tostring(v.Value) or nil
end

-- summons: a digits-named model or ancestor container (Workspace.Monsters.<UserId>[.pet]),
-- the PlayerID value from the 09-19 dump, or the SummonNameGui nameplate. Cached per model.
local summonCache = setmetatable({}, { __mode = "k" })
local function isSummonish(model)
    local c = summonCache[model]
    if c and os.clock() - c.t < 5 then return c.v end
    local v = stringChild(model, "PlayerID") ~= nil
              or model:FindFirstChild("SummonNameGui") ~= nil
    if not v then
        local p = model
        while p and p ~= Workspace do
            if string.match(p.Name, "^%d+$") then v = true; break end
            p = p.Parent
        end
    end
    summonCache[model] = { v = v, t = os.clock() }
    return v
end

-- outside workspace.Monsters a model must move before it counts (idle townsfolk never do)
local seenAt = setmetatable({}, { __mode = "k" })
local function hasMoved(model, root)
    local rec = seenAt[model]
    if not rec then
        seenAt[model] = { pos = root.Position, moved = false }
        return false
    end
    if rec.moved then return true end
    local vel = root.AssemblyLinearVelocity
    if (vel and vel.Magnitude > 2) or (root.Position - rec.pos).Magnitude > 1.5 then
        rec.moved = true
        return true
    end
    return false
end

-- living-mob cache, rebuilt once a second (a full GetDescendants walk each tick would be
-- brutal; Bot Mode's own NPC scan runs at 0.5 s with the same shape)
local mobList, mobStamp = {}, 0
local function getMobs()
    if mobStamp ~= 0 and os.clock() - mobStamp < 1 then return mobList end
    mobStamp = os.clock()
    local out, seen = {}, {}
    local myChar = LP.Character
    local monsters = Workspace:FindFirstChild("Monsters")
    for _, d in ipairs(Workspace:GetDescendants()) do
        if d:IsA("Humanoid") then
            local model = d.Parent
            if model and not seen[model] and model ~= myChar
               and not Players:GetPlayerFromCharacter(model)
               and model.Name ~= "Runner" and model.Name ~= "Explorer" then
                seen[model] = true
                local root = model:FindFirstChild("HumanoidRootPart")
                if root and not isSummonish(model) then
                    local inMonsters = monsters ~= nil and model:IsDescendantOf(monsters)
                    if inMonsters or hasMoved(model, root) then
                        out[#out + 1] = { hum = d, root = root }
                    end
                end
            end
        end
    end
    mobList = out
    return mobList
end

local function myTeam()
    local char = LP.Character
    return char and stringChild(char, "Team") or nil
end

local function inReach(mypos, look, root)
    local off = root.Position - mypos
    local d = off.Magnitude
    if d > CFG.range then return false end
    if not CFG.frontOnly or d < 1 then return true end
    -- in front = anywhere in the forward half-space (M1 arcs are wide)
    return (look.X * off.X + look.Y * off.Y + look.Z * off.Z) > 0
end

local function enemyInRange(myRoot)
    local mypos = myRoot.Position
    local look  = myRoot.CFrame.LookVector
    for _, rec in ipairs(getMobs()) do
        if rec.root.Parent and rec.hum.Health > 0 and inReach(mypos, look, rec.root) then
            return true
        end
    end
    if CFG.players then
        local mine = myTeam()
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LP and not state.isFriendly(plr) then
                local char = plr.Character
                local root = char and char:FindFirstChild("HumanoidRootPart")
                local hum  = char and char:FindFirstChildOfClass("Humanoid")
                if root and hum and hum.Health > 0
                   and not (mine ~= nil and stringChild(char, "Team") == mine)
                   and inReach(mypos, look, root) then
                    return true
                end
            end
        end
    end
    return false
end

local function step()
    local t = os.clock()
    if t - lastEval < 0.1 then return end
    lastEval = t

    local actual = UIS:IsMouseButtonPressed(MB1)
    if ourHold and not actual then ourHold = false end   -- jump guard let it go: resync

    local desired = false
    if running and CFG.enabled and not UIS:GetFocusedTextBox() then
        local guarded = false
        pcall(function() guarded = weave.m1Guarded() end)
        local blockedNow = false
        pcall(function() blockedNow = m1.isBlocked() end)
        if not guarded and not blockedNow then
            local char = LP.Character
            local myRoot = char and char:FindFirstChild("HumanoidRootPart")
            if myRoot then desired = enemyInRange(myRoot) end
        end
    end

    if desired and not actual and not userHeld then
        send(true)
    elseif not desired and actual and ourHold and not userHeld then
        send(false)
    end
end

function AS.start()
    AS.stop()
    running = true
    userHeld = UIS:IsMouseButtonPressed(MB1)
    fakeDowns, fakeUps = 0, 0
    mobStamp = 0
    conns[#conns + 1] = UIS.InputBegan:Connect(function(input)
        if input.UserInputType ~= MB1 or ownFakeEvent(true) then return end
        userHeld = true
    end)
    conns[#conns + 1] = UIS.InputEnded:Connect(function(input)
        if input.UserInputType ~= MB1 or ownFakeEvent(false) then return end
        userHeld = false
    end)
    -- alt-tab eats real releases: forget the finger, but KEEP swinging (tabbed-out farming)
    conns[#conns + 1] = UIS.WindowFocusReleased:Connect(function() userHeld = false end)
    conns[#conns + 1] = RunService.Heartbeat:Connect(step)
    log.info("[Auto Swing] on")
end

function AS.stop()
    running = false
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)
    if ourHold then send(false) end
end

function AS.feature()
    return {
        id          = "veil.auto_swing",
        name        = "Auto Swing",
        description = "Swings your weapon for you: whenever a living enemy is within reach, your left click is held down (the game combos a held M1 by itself) and released the moment nothing is in range. You just move. Enemies are found everywhere, not just the Monsters folder -- anything outside it counts once it's been seen moving, which keeps shopkeepers and quest NPCs safe. Skips Runners, the Explorer and summons; keeps swinging while you're tabbed out; your own real clicks always take priority, and it backs off while Auto Weave blocks clicks for a jump. Swing range = how far an enemy can be (studs) -- match it to your weapon's reach. Only in front = ignore enemies behind you.",
        default     = false,
        onToggle    = function(v)
            CFG.enabled = v and true or false
            if CFG.enabled then AS.start() else AS.stop() end
        end,
        settings = {
            { type = "slider", name = "Swing range (studs)", key = "range", min = 4, max = 30, step = 0.5,
              default = 10, onChange = function(v) CFG.range = v end },
            { type = "toggle", name = "Only enemies in front", key = "frontOnly", default = true,
              onChange = function(v) CFG.frontOnly = v and true or false end },
            { type = "toggle", name = "Also swing at players (PvP)", key = "players", default = false,
              onChange = function(v) CFG.players = v and true or false end },
        },
    }
end

return AS
