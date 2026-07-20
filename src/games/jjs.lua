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

local registry   = require("games.registry")
local window     = require("ui.window")
local container  = require("ui.container")
local feature    = require("ui.feature")
local components = require("ui.components")
local keybinds   = require("core.keybinds")
local persist    = require("core.persist")
local state      = require("modules.aim.state")
local targeting  = require("modules.aim.targeting")
local shiftlock  = require("modules.aim.shiftlock")
local log        = require("core.log")
local notify     = require("ui.notify")

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local RunService          = game:GetService("RunService")
local VirtualInputManager = game:GetService("VirtualInputManager")

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
local emoteList            -- the ScrollingFrame the emote keybind rows live in
local emoteKeyIds = {}     -- bound keybind ids for the emotes (cleared on rescan / destroy)
local emoteConns = {}      -- watchers that auto-rescan when the emote GUI loads/changes

local function rootOf(c) return c and c:FindFirstChild("HumanoidRootPart") end

-- Prefer the Target Select / Lock-On target; fall back to the nearest valid
-- target so it still works if you haven't engaged Target Select first.
local function targetChar()
    local t = state.target
    if t then
        return (state.target_type == "npc") and t or t.Character
    end
    -- Fallback: nearest valid target when Target Select hasn't engaged. Mirror the
    -- (target, type) handling above -- with Bot Mode on, best may be an NPC Model,
    -- and reading `.Character` off a Model throws ("not a valid member").
    local best, ty = targeting.getBestTarget()
    if not best then return nil end
    return (ty == "npc") and best or best.Character
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

    -- Engine's Use Move path = fireButton (firesignal MouseButton1Down) on the
    -- ItemName TextButton. Confirmed live by a throwaway tester: PB casts when
    -- MB1Down is fired on PlayerGui.Main.Controls.Moveset["Projection Breaker"]
    -- .ItemName -- the earlier "ItemName is visual-only" guess was wrong, the
    -- button's MB1Down handler IS the move's fire-on-press. We still record
    -- `key` so JJS.useMove (RE-direct path) can use it if needed; useKey is
    -- omitted so engine takes the button-fire path by default.
    local out, names = {}, {}
    for i, s in ipairs(slots) do
        out[#out + 1] = {
            button = s.button, name = s.name, text = s.name,
            key = s.key or tostring(i),
        }
        names[#names + 1] = s.name
    end
    scanReport("ok", #out, table.concat(names, ", "))
    return out
end

-- Per-game useMove hook. We're now relying on the engine's button-fire path
-- (firesignal MouseButton1Down on the slot's ItemName button -- confirmed
-- working live for Projection Breaker), so this hook only fires when a move
-- is EXPLICITLY pinned to a Knit RE remote below. No substring/auto guesses
-- -- those risked firing the wrong move on a coincidental name match.
-- Add an entry here when (a) the button-fire path doesn't work for a move,
-- AND (b) we've verified the exact service + remote + arg shape.
local MOVE_REMOTE = {
    -- ["Move Name"] = { service = "FooService", remote = "Activated" },
}

local function findKnitRE(svcName, remoteName)
    local knit = ReplicatedStorage:FindFirstChild("Knit")
    if not knit then return nil end
    local inner = knit:FindFirstChild("Knit") or knit
    local svcs = inner:FindFirstChild("Services")
    local svc = svcs and svcs:FindFirstChild(svcName)
    local re = svc and svc:FindFirstChild("RE")
    return re and re:FindFirstChild(remoteName) or nil
end

-- Detect which JJS character we're playing as, for char-locked techs. The
-- HUD's Ultimate.Title text is the awakening name and is character-unique
-- (verified via reference_jjs_autoblock: "HUD swap signal = ultimate Title;
-- stable thru variant switches"). Returns the name or nil if not yet built.
function JJS.detectCharacter()
    local pg = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not pg then return nil end
    local main = pg:FindFirstChild("Main")
    local controls = main and main:FindFirstChild("Controls")
    local ult = controls and controls:FindFirstChild("Ultimate")
    local title = ult and ult:FindFirstChild("Title")
    if title and title:IsA("TextLabel") then
        local t = title.Text
        if t and t ~= "" then return t end
    end
    return nil
end

function JJS.useMove(name)
    local pin = MOVE_REMOTE[name]
    if not pin then return false end
    local re = findKnitRE(pin.service, pin.remote)
    if not re then
        log.warn(("[jjs] useMove: %s.RE.%s not found, falling through"):format(pin.service, pin.remote))
        return false
    end
    local ok, err = pcall(function() re:FireServer() end)
    if not ok then
        log.warn(("[jjs] useMove fire %s: %s"):format(pin.service, tostring(err)))
        return false
    end
    return true
end

-- ===== Emote Keybinds =====
-- JJS emote menu: PlayerGui.Emotes.Emote.Page<N>.<slot>.Clickable (the button) +
-- .EmoteName.Txt (the emote's name). Bind a key to fire an emote's Clickable
-- without opening the menu.

-- fire a GUI button by the signal it actually has handlers on (firesignal), with a
-- real VIM click as a last resort.
local function fireGui(btn)
    if not btn then return end
    local function conns(sig)
        if typeof(getconnections) ~= "function" then return nil end
        local ok, c = pcall(getconnections, sig); return ok and c or nil
    end
    if typeof(firesignal) == "function" then
        local cx = btn.AbsolutePosition.X + btn.AbsoluteSize.X / 2
        local cy = btn.AbsolutePosition.Y + btn.AbsoluteSize.Y / 2
        local d = conns(btn.MouseButton1Down)
        if d and #d > 0 then
            pcall(firesignal, btn.MouseButton1Down, cx, cy)
            local u = conns(btn.MouseButton1Up); if u and #u > 0 then pcall(firesignal, btn.MouseButton1Up, cx, cy) end
            return
        end
        local c = conns(btn.MouseButton1Click); if c and #c > 0 then pcall(firesignal, btn.MouseButton1Click); return end
        local a = conns(btn.Activated);          if a and #a > 0 then pcall(firesignal, btn.Activated); return end
    end
    local VIM = game:GetService("VirtualInputManager")
    local p, s = btn.AbsolutePosition, btn.AbsoluteSize
    local x, y = p.X + s.X / 2, p.Y + s.Y / 2 + 36
    pcall(function() VIM:SendMouseButtonEvent(x, y, 0, true, game, 0); task.wait(); VIM:SendMouseButtonEvent(x, y, 0, false, game, 0) end)
end

-- Buy Cola: the Soda purchase button in the shop. Resolved fresh each click so it
-- survives the shop UI rebuilding. Path: PlayerGui.Menus.Group.Shop.Items.Shop.Shop.Soda.Purchase.Cash
local COLA_PATH = { "Menus", "Group", "Shop", "Items", "Shop", "Shop", "Soda", "Purchase", "Cash" }
local function findCola()
    local node = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    for _, n in ipairs(COLA_PATH) do
        if not node then return nil end
        node = node:FindFirstChild(n)
    end
    return node
end
local function buyCola()
    local b = findCola()
    if b then fireGui(b); pcall(notify.info, "Bought cola", 2)
    else pcall(notify.warn, "Soda purchase button not found -- open the shop once?") end
end

-- re-resolve a slot's Clickable at fire time (survives the menu rebuilding)
local function findClickable(page, slot)
    local pg = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local emote = pg and pg:FindFirstChild("Emotes")
    emote = emote and emote:FindFirstChild("Emote")
    local p = emote and emote:FindFirstChild(page)
    if not p then return nil end
    local s = p:FindFirstChild(slot)
    if s then local c = s:FindFirstChild("Clickable"); if c then return c end end
    -- fallback: any Clickable under the page whose parent matches the slot name
    for _, d in ipairs(p:GetDescendants()) do
        if d.Name == "Clickable" and d.Parent and d.Parent.Name == slot then return d end
    end
    return nil
end

-- list { name, page, slot } for every emote slot that has a Clickable. Lenient:
-- any descendant named "Clickable" counts as a slot; the name is read from a
-- sibling EmoteName.Txt if present, else falls back to page+slot. Returns a diag
-- table too so we can surface WHERE detection fails.
local function scanEmotes()
    local pg = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local emotes = pg and pg:FindFirstChild("Emotes")
    local emote = emotes and emotes:FindFirstChild("Emote")
    local out, diag = {}, { emotes = emotes ~= nil, emote = emote ~= nil, pages = 0, slots = 0 }
    if not emote then return out, diag end
    -- find every "Clickable" under a Page* and treat its parent as the slot
    for _, page in ipairs(emote:GetChildren()) do
        if page.Name:sub(1, 4) == "Page" then
            diag.pages = diag.pages + 1
            for _, desc in ipairs(page:GetDescendants()) do
                if desc.Name == "Clickable" then
                    local slot = desc.Parent
                    diag.slots = diag.slots + 1
                    local nm
                    local en  = slot and slot:FindFirstChild("EmoteName")
                    local txt = en and (en:FindFirstChild("Txt") or en)
                    if txt then local ok, t = pcall(function() return txt.Text end); if ok and type(t) == "string" and t ~= "" then nm = t end end
                    out[#out + 1] = {
                        name = nm or (page.Name .. " " .. (slot and slot.Name or "?")),
                        page = page.Name, slot = slot and slot.Name or "?",
                    }
                end
            end
        end
    end
    return out, diag
end

local function rebuildEmotes()
    if not emoteList then return end
    for _, id in ipairs(emoteKeyIds) do pcall(function() keybinds.clear(id) end) end
    emoteKeyIds = {}
    for _, c in ipairs(emoteList:GetChildren()) do if not c:IsA("UIListLayout") then c:Destroy() end end

    local emotes, diag = scanEmotes()
    if #emotes == 0 then
        local msg
        if not diag.emotes then msg = "PlayerGui.Emotes missing"
        elseif not diag.emote then msg = "Emotes.Emote missing"
        elseif diag.pages == 0 then msg = "no Page* (open the emote menu?)"
        elseif diag.slots == 0 then msg = "pages found, 0 Clickables"
        else msg = "none" end
        local empty = components.Label(emoteList, "Emotes: " .. msg .. "  -> Rescan")
        empty.LayoutOrder = 1
        return
    end
    for i, e in ipairs(emotes) do
        local id = "jjs.emote." .. persist.slug(e.name)
        local function onPress() local btn = findClickable(e.page, e.slot); if btn then fireGui(btn) end end
        local saved = persist.stringToKey(persist.get(id .. ".bind"))
        if saved and saved ~= Enum.KeyCode.Unknown then keybinds.set(id, saved, onPress); emoteKeyIds[#emoteKeyIds + 1] = id end
        local ks = components.KeybindSetter(emoteList, {
            label   = e.name,
            default = saved,
            onChange = function(k)
                if k and k ~= Enum.KeyCode.Unknown then
                    keybinds.set(id, k, onPress)
                    if not table.find(emoteKeyIds, id) then emoteKeyIds[#emoteKeyIds + 1] = id end
                else
                    keybinds.clear(id)
                end
                persist.set(id .. ".bind", persist.keyToString(k))
            end,
        })
        ks.frame.LayoutOrder = i
    end
end

-- ===== Auto QTE (Higuruma "Deadly Sentencing" struggle, and any JJS QTE) =====
-- No-misfire: reads the game's own prompt label PlayerGui.QTE (ScreenGui) ->
-- QTE_PC (TextLabel) and presses EXACTLY the W/A/S/D shown, ONLY while that QTE
-- GUI is active (Enabled + visible up its ancestry + single-letter text). QTE_PC
-- is used for nothing else, so it can't fire off the hotbar or other UI.
-- (GUI path confirmed by the [Dev] JJS QTE Dump inspector; Higuruma = HiromiService.)
--
-- Humanize (default on): instead of frame-perfect taps, wait a human reaction
-- time per new letter, sometimes "whiff" (a late press), and rarely hesitate for
-- ~1s once per QTE -- so it reads as a person barely scraping the win, not a bot.
local QTE_KEYS = { W = Enum.KeyCode.W, A = Enum.KeyCode.A, S = Enum.KeyCode.S, D = Enum.KeyCode.D }
local qte = {
    enabled  = false,
    humanize = true,
    reactMs  = 200,   -- base reaction delay per new letter (ms)
    jitterMs = 120,   -- random extra on top (ms)
    whiffPct = 12,    -- % chance a step gets an extra "whiff" delay
    pausePct = 10,    -- % chance of ONE longer hesitation per QTE
    conn = nil,
    -- runtime
    lastLetter = nil, lastPress = 0, reactReady = nil, pauseUntil = 0, pauseUsed = false,
}

local function qteReset()
    qte.lastLetter = nil; qte.reactReady = nil; qte.pauseUntil = 0; qte.pauseUsed = false
end

-- Current required key for an ACTIVE QTE, or nil. Layered guards = misfire-proof.
local function qteCurrentKey()
    local pgui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not pgui then return nil end
    local scr = pgui:FindFirstChild("QTE")
    if not scr then return nil end
    if scr:IsA("ScreenGui") and not scr.Enabled then return nil end
    local lbl = scr:FindFirstChild("QTE_PC")
    if not lbl or not (lbl:IsA("TextLabel") or lbl:IsA("TextButton")) then return nil end
    if not lbl.Visible then return nil end
    local n = lbl.Parent
    while n and n:IsA("GuiObject") do if not n.Visible then return nil end; n = n.Parent end
    local t = (tostring(lbl.Text):gsub("%s", "")):upper()
    if #t ~= 1 then return nil end
    return QTE_KEYS[t], t
end

local function qteTap(kc)
    VirtualInputManager:SendKeyEvent(true, kc, false, game)
    task.spawn(function() task.wait(0.012); VirtualInputManager:SendKeyEvent(false, kc, false, game) end)
end

local function qteReactionDelay()
    return (qte.reactMs + math.random() * qte.jitterMs) / 1000
end

local function qteStep()
    if not qte.enabled then return end
    local kc, letter = qteCurrentKey()
    if not kc then qteReset(); return end
    local now = os.clock()

    -- Base (fast) behaviour when Humanize is off: instant, mash-cadence re-press.
    if not qte.humanize then
        if letter ~= qte.lastLetter or (now - qte.lastPress) >= 0.08 then
            qteTap(kc); qte.lastLetter = letter; qte.lastPress = now
        end
        return
    end

    -- Humanized: sit out an active hesitation window first.
    if now < qte.pauseUntil then return end

    if letter ~= qte.lastLetter then
        qte.lastLetter = letter
        -- one longer hesitation per QTE (the "not press for a bit" pass)
        if (not qte.pauseUsed) and math.random(100) <= qte.pausePct then
            qte.pauseUsed = true
            qte.pauseUntil = now + 0.7 + math.random() * 0.9   -- ~0.7-1.6s
            qte.reactReady = qte.pauseUntil + qteReactionDelay()
            return
        end
        -- normal human reaction to a new letter; occasionally a late "whiff"
        local delay = qteReactionDelay()
        if math.random(100) <= qte.whiffPct then delay = delay + 0.15 + math.random() * 0.25 end
        qte.reactReady = now + delay
        return
    end

    -- Same letter still up: press once the reaction window elapses, then re-press
    -- at a human mash cadence for consecutive-identical steps.
    if qte.reactReady and now >= qte.reactReady then
        qteTap(kc)
        qte.lastPress = now
        qte.reactReady = now + 0.12 + math.random() * 0.10   -- ~120-220ms
    end
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

    -- Auto QTE: auto-clears the struggle QTE (Higuruma's Deadly Sentencing etc).
    box:add(feature.declare({
        id          = "jjs.auto_qte",
        name        = "Auto QTE",
        description = "Auto-completes the on-screen struggle QTE (e.g. Higuruma's Deadly Sentencing). Reads the game's own prompt (PlayerGui.QTE.QTE_PC) and presses exactly the shown W/A/S/D key, only while that QTE is active -- it can't misfire onto the hotbar or anything else. Humanize (on by default) adds human reaction time, the odd whiff, and a rare ~1s hesitation so it looks like a person barely scraping the win instead of a frame-perfect bot. Turn Humanize off for instant frame-perfect clears.",
        default     = false,
        onToggle    = function(v) qte.enabled = v and true or false; if not v then qteReset() end end,
        settings = {
            { type = "toggle", name = "Humanize (look human)", key = "humanize", default = true,
              onChange = function(v) qte.humanize = v and true or false end },
            { type = "slider", name = "Reaction time (ms)", key = "react_ms",
              min = 60, max = 500, step = 10, default = 200,
              onChange = function(v) qte.reactMs = v end },
            { type = "slider", name = "Reaction jitter (ms)", key = "jitter_ms",
              min = 0, max = 300, step = 10, default = 120,
              onChange = function(v) qte.jitterMs = v end },
            { type = "slider", name = "Whiff chance (%)", key = "whiff_pct",
              min = 0, max = 50, step = 1, default = 12,
              onChange = function(v) qte.whiffPct = v end },
            { type = "slider", name = "Hesitation chance (%)", key = "pause_pct",
              min = 0, max = 40, step = 1, default = 10,
              onChange = function(v) qte.pausePct = v end },
        },
    }).root)

    -- One Heartbeat drives the QTE reader; qteStep no-ops unless the feature's on.
    if qte.conn then pcall(function() qte.conn:Disconnect() end) end
    qte.conn = RunService.Heartbeat:Connect(qteStep)

    -- Buy Cola: feature row so it gets the cog (set a keybind there). The bound key
    -- buys; clicking the toggle also buys once then flips itself back off (momentary).
    local colaFeat
    colaFeat = feature.declare({
        id          = "jjs.buy_cola",
        name        = "Buy Cola",
        description = "Buys a soda from the shop (fires its Cash purchase button). Set a key in the cog to buy on press, or click the toggle to buy once.",
        default     = false,
        onKey       = function() buyCola() end,
        onToggle    = function(v) if v then buyCola(); task.defer(function() if colaFeat then colaFeat.setEnabled(false) end end) end end,
    })
    box:add(colaFeat.root)

    -- Emote Keybinds: bind a key to each emote (fires its Clickable without opening the menu)
    do
        local holder = Instance.new("Frame")
        holder.Size = UDim2.new(1, 0, 0, 0); holder.AutomaticSize = Enum.AutomaticSize.Y; holder.BackgroundTransparency = 1
        local hl = Instance.new("UIListLayout", holder); hl.SortOrder = Enum.SortOrder.LayoutOrder; hl.Padding = UDim.new(0, 2)
        local sec = components.Section(holder, "Emote Keybinds"); sec.LayoutOrder = 1
        local rescan = components.Button(holder, { text = "Rescan emotes", onClick = function() rebuildEmotes() end }); rescan.LayoutOrder = 2
        emoteList = Instance.new("ScrollingFrame")
        emoteList.Size = UDim2.new(1, 0, 0, 0); emoteList.AutomaticCanvasSize = Enum.AutomaticSize.Y
        emoteList.CanvasSize = UDim2.new(0, 0, 0, 0); emoteList.ScrollBarThickness = 4
        emoteList.BackgroundTransparency = 1; emoteList.BorderSizePixel = 0; emoteList.LayoutOrder = 3; emoteList.Parent = holder
        local el = Instance.new("UIListLayout", emoteList); el.SortOrder = Enum.SortOrder.LayoutOrder; el.Padding = UDim.new(0, 1)
        local MAXH = 200
        el:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
            emoteList.Size = UDim2.new(1, 0, 0, math.min(el.AbsoluteContentSize.Y, MAXH))
        end)
        box:add(holder)
        rebuildEmotes()
        -- auto-rescan when the emote GUI loads/changes (it may not exist until the
        -- emote menu is opened the first time), debounced.
        local pg = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
        if pg then
            local pending = false
            emoteConns[#emoteConns + 1] = pg.DescendantAdded:Connect(function(d)
                local n = d.Name
                if n == "Clickable" or n == "Emote" or n == "Emotes" then
                    if not pending then pending = true; task.delay(0.4, function() pending = false; rebuildEmotes() end) end
                end
            end)
        end
        -- a couple of deferred passes too, for emotes that populate shortly after join
        task.delay(2, function() pcall(rebuildEmotes) end)
        task.delay(5, function() pcall(rebuildEmotes) end)
    end

    log.info("JJS module registered -- Nanami Perfect Special + Buy Cola + Emote Keybinds")
end

-- Called by init.lua's shutdown (Auto Re-Execute / re-execute). register() runs
-- again on every boot, so anything it changed on shared modules must be undone
-- here or it compounds across teleports. The "Jujutsu Shenanigans" container,
-- the Nanami feature row, and its keybind are torn down by window.destroy /
-- keybinds.destroy; what's left is the module-level state below.
function JJS.destroy()
    enabled = false
    lastScanReport = -1
    -- stop the Auto QTE reader and clear its per-QTE state
    qte.enabled = false
    if qte.conn then pcall(function() qte.conn:Disconnect() end); qte.conn = nil end
    qteReset()
    -- clear emote keybinds (their ids are ours; the rows/keybind UI die with the window)
    for _, id in ipairs(emoteKeyIds) do pcall(function() keybinds.clear(id) end) end
    emoteKeyIds = {}
    for _, c in ipairs(emoteConns) do pcall(function() c:Disconnect() end) end
    emoteConns = {}
    emoteList = nil
    -- register() force-enabled shiftlock PAIR (mirror) mode for JJS; undo it so a
    -- re-execute or a hop to a non-JJS place doesn't leave Pantheon mirroring a
    -- game shiftlock that isn't there.
    pcall(function() shiftlock.setShiftlockMirror(false) end)
end

registry.register(JJS_IDS, JJS)

return JJS
