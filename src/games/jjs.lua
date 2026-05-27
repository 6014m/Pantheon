-- Jujutsu Shenanigans (PlaceId 17016840407) integration.
--
-- Registered into the game registry; its container only appears when you're
-- actually in JJS -- init.lua calls registry.current().register() gated on
-- game.PlaceId, so this never shows in other games.
--
-- Feature: Nanami "Perfect Special" -- auto-times Salaryman's R special, Ratio
-- Point (NanamiService.RE.RightActivated). Per the JJS wiki, Ratio Point marks a
-- target within 70 STUDS and runs a quick-time event whose timing speeds up as
-- the target's HP drops; this fires the confirm after an HP-scaled delay so it
-- lands on the ratio. Ported from the old lock-on script, which used a wrong
-- 27-stud range -- corrected to the wiki's 70.

local registry  = require("games.registry")
local window    = require("ui.window")
local container = require("ui.container")
local feature   = require("ui.feature")
local state     = require("modules.aim.state")
local targeting = require("modules.aim.targeting")
local shiftlock = require("modules.aim.shiftlock")
local log       = require("core.log")
local notify    = require("ui.notify")

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- JJS spans multiple places (17016840407 = "Lobby", 9391468976 = experience root)
-- under ONE GameId 3508322461 (grabbed in-game; matches the legacy script's id).
-- registry.current() checks game.GameId, so the GameId entry covers EVERY place /
-- VIP server in one go; the place ids are just extra redundancy.
local JJS_IDS = { 3508322461, 17016840407, 9391468976 }   -- GameId first, then known places

local JJS = {}

local CFG = {
    range    = 70,     -- studs -- wiki: Ratio Point marks a target within 70 studs
    delayHi  = 0.63,   -- s, target >= 80% HP (QTE slower early-fight)
    delayLo  = 0.55,   -- s, target <  80% HP (QTE faster as HP drops)
    hpThresh = 80,     -- % HP threshold between the two timings
}
local enabled = false

local function rootOf(c) return c and c:FindFirstChild("HumanoidRootPart") end

-- Prefer the Target Select / Lock-On target; fall back to the nearest valid
-- target so it still works if you haven't engaged Target Select first.
local function targetChar()
    local t = state.target
    if t then
        return (state.target_type == "npc") and t or t.Character
    end
    local best = targeting.getBestTarget()
    return best and best.Character or nil
end

local function ratioPointPerfect()
    if not enabled then return end
    local tChar = targetChar()
    if not tChar then return end
    local myRoot, tRoot = rootOf(Players.LocalPlayer.Character), rootOf(tChar)
    if not (myRoot and tRoot) then return end
    if (myRoot.Position - tRoot.Position).Magnitude > CFG.range then return end
    local hum = tChar:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    local hpPct = (hum.Health / math.max(hum.MaxHealth, 1)) * 100
    local delay = (hpPct < CFG.hpThresh) and CFG.delayLo or CFG.delayHi
    task.delay(delay, function()
        pcall(function()
            ReplicatedStorage.Knit.Knit.Services.NanamiService.RE.RightActivated:FireServer(tChar)
        end)
    end)
end

-- Per-game move scanner hook (called by modules.tech.scanner first; generic scan is
-- the fallback). JJS's hotbar: PlayerGui.Controls (SG) > Controls > Moveset > <MoveName>
-- > ItemName -- the inner "Controls" Frame matters (the SG and its Frame child share a
-- name). Each ItemName TextButton has the real MouseButton1Down handler on it directly
-- (no inner Base button like TSB). Slot frame's Name is the move name (e.g. "Projection
-- Breaker"); keys 1..N map to the slots LEFT-TO-RIGHT by AbsolutePosition.X. The scanner
-- annotates `move` (Knit service name) from these entries via the shared stem matcher.
local lastScanReport = -1
local function scanReport(stage, n, names)
    if n == lastScanReport then return end
    lastScanReport = n
    local msg = ("JJS scanMoves [%s]: %d move(s) %s"):format(stage, n, names and ("[" .. names .. "]") or "")
    log.info(msg)
    pcall(function() notify.info(msg, 6) end)
end

-- JJS hotbar lives at PlayerGui.Main.Controls.Moveset.<MoveName>.ItemName. There's
-- a SEPARATE ScreenGui named "Controls" in PlayerGui that's the Mobile UI (no
-- Moveset descendant) -- earlier versions of this hook targeted the wrong SG.
function JJS.scanMoves(pg)
    local main = pg:FindFirstChild("Main")
    if not main then scanReport("no Main SG", 0); return nil end
    local controls = main:FindFirstChild("Controls")
    local moveset  = controls and controls:FindFirstChild("Moveset")
    if not moveset then scanReport("no Main.Controls.Moveset", 0); return nil end

    local slots = {}
    for _, child in ipairs(moveset:GetChildren()) do
        local btn = child:FindFirstChild("ItemName")
        if btn and (btn:IsA("TextButton") or btn:IsA("ImageButton")) then
            -- Read the slot's actual keybind from the Key.Key TextLabel (per
            -- reference_jjs_autoblock: JJS stores "1".."4" there). Position-
            -- index fallback if the label is missing; the previous assume-
            -- positional-order code would send the wrong slot key whenever
            -- slots weren't packed left-to-right starting at "1".
            local keyFrame = child:FindFirstChild("Key")
            local keyTxt = keyFrame and keyFrame:FindFirstChild("Key")
            local label = keyTxt and keyTxt:IsA("TextLabel") and keyTxt.Text
            slots[#slots + 1] = {
                name = child.Name, button = btn,
                x = btn.AbsolutePosition.X,
                key = (label and label ~= "" and label) or nil,
            }
        end
    end
    if #slots == 0 then scanReport("Moveset empty", 0); return nil end
    table.sort(slots, function(a, b) return a.x < b.x end)

    -- useKey=true tells the engine's Use Move action to VIM-send the slot key
    -- instead of clicking the button. JJS's ItemName button MB1Down handler is
    -- visual-only; the actual move fires from the keypress (or, even better,
    -- from JJS.useMove firing the move's RE directly -- see below).
    local out, names = {}, {}
    for i, s in ipairs(slots) do
        out[#out + 1] = {
            button = s.button, name = s.name, text = s.name,
            key = s.key or tostring(i),
            useKey = true,
        }
        names[#names + 1] = s.name
    end
    scanReport("ok", #out, table.concat(names, ", "))
    return out
end

-- Map JJS hotbar move name -> Knit Service name. Per reference_jjs_autoblock
-- the Knit pattern is `ReplicatedStorage.Knit.Knit.Services.<Service>.RE.
-- Activated:FireServer()` and "most services are named after the move"; the
-- BlockService remote is verified by the public autoblock. Add entries as we
-- confirm them. JJS.useMove looks them up and fires the RE directly, which is
-- more reliable than VIM-sending the slot key (PB wasn't firing on VIM).
local MOVE_SERVICE = {
    ["Projection Breaker"] = "ProjectionBreakerService",
}

local function findKnitService(svcName)
    local knit = ReplicatedStorage:FindFirstChild("Knit")
    if not knit then return nil end
    local inner = knit:FindFirstChild("Knit") or knit
    local svcs = inner:FindFirstChild("Services")
    return svcs and svcs:FindFirstChild(svcName) or nil
end

-- Per-game useMove hook called by engine.ACTIONS.usebtn BEFORE the generic VIM
-- key path. Return true if we handled the move (engine stops); false/nil to
-- let the engine fall through to the VIM/click path.
function JJS.useMove(name)
    local svcName = MOVE_SERVICE[name]
    if not svcName then return false end
    local svc = findKnitService(svcName)
    local re  = svc and svc:FindFirstChild("RE")
    local act = re and re:FindFirstChild("Activated")
    if not act then
        log.warn("[jjs] useMove: " .. svcName .. ".RE.Activated not found, falling through to VIM")
        return false
    end
    local ok, err = pcall(function() act:FireServer() end)
    if not ok then
        log.warn("[jjs] useMove fire " .. svcName .. ": " .. tostring(err))
        return false
    end
    return true
end

function JJS.register()
    -- LOUD load-time toast so we can SEE whether this code path actually ran in
    -- the executor. If you see "Pantheon loaded" but NOT "JJS registered" then
    -- registry.current() didn't find us for this PlaceId/GameId.
    local buildTag = tostring(rawget(_G, "PANTHEON_BUILD") or "?")
    pcall(function() notify.success("JJS registered (build " .. buildTag .. ")", 8) end)
    log.info("JJS module REGISTER on PlaceId=" .. tostring(game.PlaceId) .. " GameId=" .. tostring(game.GameId))

    -- Eagerly run scanMoves once now so the diagnostic toast fires at load
    -- (instead of waiting for the user to open the picker).
    pcall(function()
        local Players = game:GetService("Players")
        local pg = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
        if pg then JJS.scanMoves(pg) end
    end)

    -- JJS ships its own shiftlock, which overlapped Pantheon's. Auto-engage PAIR mode
    -- so Pantheon syncs its shiftlock to the game's and keeps rotating in lockstep
    -- (instead of running a second competing one or fighting it). Per-game patch:
    -- runs at load, BEFORE any shiftlock-enable, so the foreign sweep never kills
    -- the game's shiftlock we want to pair with.
    shiftlock.setShiftlockMirror(true)

    local box = container.new(window.parent(), "Jujutsu Shenanigans")
    box:add(feature.declare({
        id          = "jjs.nanami_special",
        name        = "Nanami Perfect Special",
        description = "Auto-times Salaryman's R special, Ratio Point, onto your target. With a target within 70 studs (wiki range), pressing the key fires Ratio Point after an HP-timed delay so the confirm lands on the ratio QTE (the QTE speeds up at lower HP). Uses your Target Select / Lock-On target, else the nearest player.",
        default     = false,
        defaultKey  = Enum.KeyCode.R,
        onToggle    = function(v) enabled = v and true or false end,
        onKey       = function() ratioPointPerfect() end,
    }).root)

    log.info("JJS module registered -- Nanami Perfect Special (Ratio Point, 70-stud range)")
end

registry.register(JJS_IDS, JJS)

return JJS
