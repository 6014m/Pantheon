-- The Veil: Auto Potions. Two watchers, each its own toggle:
--
--   * Low sanity: when your Sanity drops under the slider and you carry a Sanity Potion,
--     one is drunk for you -- the panic button you don't have to press. The Sanity value is
--     looked up on your character (ValueBase or attribute named "Sanity"); if the game hides
--     it somewhere else, the log prints every value name on your character once so the
--     lookup can be adapted -- read the log if the toggle complains.
--
--   * Keep Nightcall running: drinks a Nightcall Potion again when the 150 s double-spawn
--     effect runs out (a couple of seconds early, so the uptime is seamless). The buff has
--     no visible marker we know of, so the clock starts at OUR drink; a potion you drink by
--     hand is noticed too (the Backpack count drops) and restarts the clock. Turning the
--     toggle on drinks one right away -- it can't see a buff that was already running.
--
-- Drinking looks like a player doing it: equip the potion Tool (Humanoid:EquipTool), one
-- real click (VirtualInputManager, announced to M1 Continuation / Auto Swing's trackers via
-- noteFake), then your previous weapon comes back out. No remotes are fired. Won't drink
-- while ragdolled / stunned / dead (veil_m1.isBlocked) -- it retries right after.

local Players    = game:GetService("Players")
local UIS        = game:GetService("UserInputService")
local VIM        = game:GetService("VirtualInputManager")
local RunService = game:GetService("RunService")

local log    = require("core.log")
local notify = require("ui.notify")
local m1     = require("games.veil_m1")

local LP = Players.LocalPlayer

local NIGHTCALL_SECS = 150      -- effect length (inventory panel, 2026-09-09)
local REDRINK_EARLY  = 2        -- drink the next one this many seconds before it ends
local SIP_GAP        = 4        -- min seconds between two sanity potions (no panic chugging)

local AP = {}
local CFG = { enabled = false, sanity = true, sanThreshold = 30, nightcall = false }
local conns = {}
local running = false
local drinking = false
local lastEval = 0
local lastSanityDrink = 0
local sanityValue = nil         -- cached Instance (ValueBase) once found
local sanityMissingAt = nil     -- when we started looking and found nothing
local complained = {}           -- one-shot warnings, keyed by reason
local night = { expiry = 0, lastCount = nil, ourDrinkAt = 0 }

local function complainOnce(key, text)
    if complained[key] then return end
    complained[key] = true
    notify.warn("Auto Potions: " .. text, 6)
    log.info("[Auto Potions] " .. text)
end

-- potion Tools in the Backpack: name carries the word(s), and it's potion-shaped
-- (the game marks them with an IsPotion child; the name usually says Potion too)
local function eachPotion(word, fn)
    local bag = LP:FindFirstChild("Backpack")
    if not bag then return end
    for _, tool in ipairs(bag:GetChildren()) do
        if tool:IsA("Tool") then
            local lname = string.lower(tool.Name)
            if string.find(lname, word, 1, true)
               and (tool:FindFirstChild("IsPotion") or string.find(lname, "potion", 1, true)) then
                if fn(tool) then return end
            end
        end
    end
end

local function findPotion(word)
    local found = nil
    eachPotion(word, function(t) found = t; return true end)
    return found
end

local function countPotions(word)
    local n = 0
    eachPotion(word, function() n = n + 1 end)
    return n
end

-- your Sanity: a ValueBase named "Sanity" anywhere on the character, or a character /
-- player attribute. Cached; re-found when the character respawns.
local function readSanity()
    local char = LP.Character
    if not char then return nil end
    if sanityValue and sanityValue.Parent and sanityValue:IsDescendantOf(char) then
        return tonumber(sanityValue.Value)
    end
    sanityValue = nil
    for _, d in ipairs(char:GetDescendants()) do
        if d:IsA("ValueBase") and string.lower(d.Name) == "sanity" then
            sanityValue = d
            log.info("[Auto Potions] Sanity value found: " .. d:GetFullName())
            return tonumber(d.Value)
        end
    end
    local attr = char:GetAttribute("Sanity")
    if attr == nil then attr = LP:GetAttribute("Sanity") end
    if type(attr) == "number" then return attr end
    -- nothing yet: after 10 s of looking, dump the value names once so it can be adapted
    if not sanityMissingAt then sanityMissingAt = os.clock() end
    if os.clock() - sanityMissingAt > 10 and not complained.nosanity then
        local names = {}
        for _, d in ipairs(char:GetDescendants()) do
            if d:IsA("ValueBase") then names[#names + 1] = d.Name end
        end
        log.info("[Auto Potions] no Sanity value on the character; ValueBases seen: "
            .. table.concat(names, ", "))
        complainOnce("nosanity", "can't find your Sanity value yet (names dumped to the log)")
    end
    return nil
end

local function click()
    local p = UIS:GetMouseLocation()
    if UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
        pcall(function() m1.noteFake(false) end)
        pcall(function() VIM:SendMouseButtonEvent(p.X, p.Y, 0, false, game, 0) end)
    end
    pcall(function() m1.noteFake(true) end)
    pcall(function() VIM:SendMouseButtonEvent(p.X, p.Y, 0, true, game, 0) end)
    pcall(function() m1.noteFake(false) end)
    pcall(function() VIM:SendMouseButtonEvent(p.X, p.Y, 0, false, game, 0) end)
end

-- equip -> click -> old weapon back. Runs detached (never task.wait inside Heartbeat).
local function drink(tool, why)
    if drinking then return false end
    local char = LP.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not (char and hum) then return false end
    local blockedNow = false
    pcall(function() blockedNow = m1.isBlocked() end)
    if blockedNow then return false end
    drinking = true
    log.info("[Auto Potions] drinking " .. tool.Name .. " (" .. why .. ")")
    notify.info("Auto Potions: " .. tool.Name .. " (" .. why .. ")", 3)
    task.spawn(function()
        local prev = char:FindFirstChildOfClass("Tool")
        pcall(function() hum:EquipTool(tool) end)
        task.wait(0.25)
        if tool.Parent == char then
            click()
            task.wait(0.6)
        end
        if prev and prev ~= tool and prev.Parent then
            pcall(function() hum:EquipTool(prev) end)
        elseif tool.Parent == char then
            pcall(function() hum:UnequipTools() end)
        end
        drinking = false
    end)
    return true
end

local function stepSanity(t)
    if not CFG.sanity then return end
    local s = readSanity()
    if s == nil or s > CFG.sanThreshold then return end
    if t - lastSanityDrink < SIP_GAP then return end
    local tool = findPotion("sanity")
    if not tool then
        complainOnce("nosanitypot", "sanity is low but you have no Sanity Potions")
        return
    end
    complained.nosanitypot = nil
    if drink(tool, "sanity " .. tostring(math.floor(s))) then lastSanityDrink = t end
end

local function stepNightcall(t)
    if not CFG.nightcall then return end
    local cnt = countPotions("nightcall")
    -- a drink we didn't do (count fell outside our own drink window) restarts the clock
    if night.lastCount ~= nil and cnt < night.lastCount and t - night.ourDrinkAt > 3 then
        night.expiry = t + NIGHTCALL_SECS
        log.info("[Auto Potions] Nightcall drunk by hand, clock restarted")
    end
    night.lastCount = cnt
    if t < night.expiry - REDRINK_EARLY then return end
    if cnt == 0 then
        complainOnce("nonight", "no Nightcall Potions left")
        return
    end
    complained.nonight = nil
    local tool = findPotion("nightcall")
    if tool and drink(tool, "Nightcall refresh") then
        night.ourDrinkAt = t
        night.expiry = t + NIGHTCALL_SECS
        night.lastCount = nil        -- our own count drop isn't a manual drink
    end
end

local function step()
    local t = os.clock()
    if t - lastEval < 0.25 then return end
    lastEval = t
    if not (running and CFG.enabled) or drinking then return end
    stepSanity(t)
    stepNightcall(t)
end

function AP.start()
    AP.stop()
    running = true
    night.expiry, night.lastCount, night.ourDrinkAt = 0, nil, 0
    sanityValue, sanityMissingAt = nil, nil
    table.clear(complained)
    conns[#conns + 1] = RunService.Heartbeat:Connect(step)
    log.info("[Auto Potions] on")
end

function AP.stop()
    running = false
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)
end

function AP.feature()
    return {
        id          = "veil.auto_potions",
        name        = "Auto Potions",
        description = "Drinks potions for you. Low sanity = when your Sanity drops under the slider, a Sanity Potion from your Backpack is drunk (equips it, one click, your weapon comes back out) -- at most one every few seconds. Keep Nightcall running = drinks a Nightcall Potion again a moment before the 150 s double-spawn effect ends; turning it on drinks one right away, since an already-running buff can't be seen, and a potion you drink by hand restarts the clock too. Warns once when you run out of either potion. Won't drink while ragdolled, stunned or dead -- it retries straight after.",
        default     = false,
        onToggle    = function(v)
            CFG.enabled = v and true or false
            if CFG.enabled then AP.start() else AP.stop() end
        end,
        settings = {
            { type = "toggle", name = "Low sanity: drink a Sanity Potion", key = "sanity", default = true,
              onChange = function(v) CFG.sanity = v and true or false end },
            { type = "slider", name = "At sanity below", key = "sanThreshold", min = 5, max = 95, step = 5,
              default = 30, onChange = function(v) CFG.sanThreshold = v end },
            { type = "toggle", name = "Keep Nightcall running", key = "nightcall", default = false,
              onChange = function(v)
                  CFG.nightcall = v and true or false
                  if not v then night.expiry = 0; night.lastCount = nil end
              end },
        },
    }
end

return AP
