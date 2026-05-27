-- Move-button scanner: detect the game's on-screen MOVE buttons so you can see
-- which moves you can build techs around (and, later, trigger off a button press).
--
-- Heuristic -- Roblox has no "this is a move button" flag -- but the strong signal
-- is cross-referencing on-screen buttons against the REAL move list
-- (ReplicatedStorage.Knit.Knit.Services that own an RE). Plus skill-bar / cooldown
-- / keybind cues. You confirm the matches.

local Players  = game:GetService("Players")
local RS       = game:GetService("ReplicatedStorage")
local log      = require("core.log")
local registry = require("games.registry")

local Scanner = {}
local cached = nil

local function clean(s) return (s and (s:lower():gsub("%s", ""))) or "" end

-- Knit services that look like moves (own an RE) = the things "move used" can fire on.
function Scanner.moveServices()
    local out = {}
    local knit     = RS:FindFirstChild("Knit")
    local inner    = knit and knit:FindFirstChild("Knit")
    local services = inner and inner:FindFirstChild("Services")
    if services then
        for _, s in ipairs(services:GetChildren()) do
            if s:FindFirstChild("RE") then out[#out + 1] = s.Name end
        end
        table.sort(out)
    end
    return out
end

local SKILL_KW = { "move", "skill", "abilit", "hotbar", "combat", "slot", "action", "spell", "ult" }
local function ancestorSkill(inst)
    local cur, depth = inst.Parent, 0
    while cur and depth < 7 do
        local n = clean(cur.Name)
        for _, kw in ipairs(SKILL_KW) do if n:find(kw, 1, true) then return true end end
        cur, depth = cur.Parent, depth + 1
    end
    return false
end

-- on screen = the button AND every GuiObject ancestor is Visible -- so we skip
-- buttons sitting in a CLOSED menu (e.g. the emote list with "conga").
local function onScreen(d)
    local cur = d
    while cur and cur:IsA("GuiObject") do
        if not cur.Visible then return false end
        cur = cur.Parent
    end
    return true
end

-- a button's keybind letter (single capital) + whether it has a cooldown child
local function indicators(b)
    local keyHint, hasCD = nil, false
    for _, c in ipairs(b:GetDescendants()) do
        if not keyHint and c:IsA("TextLabel") and c.Text and c.Text:match("^%u$") then keyHint = c.Text end
        if not hasCD then
            local cn = clean(c.Name)
            if cn:find("cooldown") or cn == "cd" then hasCD = true end
        end
    end
    return keyHint, hasCD
end

-- A NAMED move slot: a button carrying a label like ToolName / MoveName with a
-- real move name (not "N/A"/empty), plus optionally a Number/keybind label.
-- Strongest, cleanest signal -- e.g. TSB hotbar slots have ToolName + Number.
-- Keywords are SPECIFIC compounds on purpose: a bare "name"/"displayname" matched
-- player-list / leaderboard labels, so whole players showed up as "moves".
local NAME_KW = { "toolname", "movename", "abilityname", "skillname", "moveslot", "skillslot" }
local KEY_KW  = { "number", "keybind", "bind", "input", "key", "slot" }
local function slotLabels(b)
    local moveName, keyHint
    for _, c in ipairs(b:GetDescendants()) do
        if c:IsA("TextLabel") then
            local nm, t = clean(c.Name), c.Text
            if not moveName and t and t ~= "" and string.upper(t) ~= "N/A" then
                for _, kw in ipairs(NAME_KW) do if string.find(nm, kw, 1, true) then moveName = t; break end end
            end
            if not keyHint and t and #t >= 1 and #t <= 3 then
                for _, kw in ipairs(KEY_KW) do if string.find(nm, kw, 1, true) then keyHint = t; break end end
            end
        end
    end
    return moveName, keyHint
end

-- Move-bar detection.
--   PRIMARY: named slots (a button with a ToolName/MoveName/... label = a hotbar
--     slot; gives the real move name + keybind -- equipped moves only, works for
--     TSB). Deduped by move name.
--   FALLBACK (games without named slots): a CLUSTER of 3+ similar on-screen
--     buttons in the lower screen, or a solo button with a keybind letter +
--     cooldown. Service names only label a match. Closed menus skipped (onScreen).
-- Returns { services, buttons = {{button,name,text,move,key},...}, diag = {...} }
-- Annotate a button entry's `move` (Knit service name) by matching its name/text
-- against service stems (e.g. "Projection Breaker" -> "ProjectionBreakerService"),
-- so per-game scans don't have to duplicate this logic.
local function annotateMove(b, stems)
    if b.move then return end
    local nm  = clean(b.name or "")
    local txt = clean(b.text or "")
    for stem, svc in pairs(stems) do
        if (nm ~= "" and nm:find(stem, 1, true)) or (txt ~= "" and txt:find(stem, 1, true)) then
            b.move = svc; return
        end
    end
end

function Scanner.scan()
    local LP = Players.LocalPlayer
    local pg = LP:FindFirstChildOfClass("PlayerGui")
    local services = Scanner.moveServices()
    local stems = {}
    for _, svc in ipairs(services) do
        local stem = clean((svc:gsub("Service$", "")))
        if #stem >= 3 then stems[stem] = svc end
    end

    -- PER-GAME HOOK: a game module (e.g. games/jjs.lua) may expose scanMoves(pg)
    -- that knows the game's exact moveset layout. Runs FIRST and is AUTHORITATIVE
    -- for that game: if registered, we never fall through to the generic
    -- heuristics (which would otherwise pick up unrelated clusters like the emote
    -- wheel when the game's UI isn't ready). Empty result -> return empty WITHOUT
    -- caching, so the next call re-scans (by which time the UI may be ready).
    if pg then
        local mod = registry.current()
        if mod and type(mod.scanMoves) == "function" then
            local ok, gameButtons = pcall(mod.scanMoves, pg)
            if ok and type(gameButtons) == "table" then
                if #gameButtons > 0 then
                    for _, b in ipairs(gameButtons) do annotateMove(b, stems) end
                    cached = { services = services, buttons = gameButtons, diag = { "per-game scan (" .. tostring(#gameButtons) .. ")" } }
                    return cached
                end
                -- hook ran, found nothing yet -- DON'T fall through to generic and
                -- DON'T cache the empty so next open retries
                return { services = services, buttons = {}, diag = { "per-game scan: empty (UI not ready)" } }
            end
        end
    end

    local buttons, diag, cand = {}, {}, {}
    if pg then
        for _, d in ipairs(pg:GetDescendants()) do
            if (d:IsA("ImageButton") or d:IsA("TextButton")) and onScreen(d) then cand[#cand + 1] = d end
        end
        -- PRIMARY: named slots (dedup by move name)
        local seenName = {}
        for _, b in ipairs(cand) do
            local moveName, keyHint = slotLabels(b)
            if moveName and not seenName[string.lower(moveName)] then
                seenName[string.lower(moveName)] = true
                buttons[#buttons + 1] = { button = b, name = b.Name, text = moveName, move = nil, key = keyHint }
            end
        end
    end

    -- FALLBACK: cluster / keybind+cooldown (only if no named slots were found)
    if #buttons == 0 and pg then
        local cam = workspace.CurrentCamera
        local vh = (cam and cam.ViewportSize.Y) or 1080
        local sized = {}
        for _, b in ipairs(cand) do
            local sz = b.AbsoluteSize
            if sz.X >= 22 and sz.X <= 180 and sz.Y >= 22 and sz.Y <= 180 then sized[#sized + 1] = b end
        end
        local picked, byParent = {}, {}
        for _, b in ipairs(sized) do byParent[b.Parent] = byParent[b.Parent] or {}; table.insert(byParent[b.Parent], b) end
        for p, list in pairs(byParent) do
            if #list >= 3 then
                local sumY = 0
                for _, b in ipairs(list) do sumY = sumY + (b.AbsolutePosition.Y + b.AbsoluteSize.Y / 2) end
                diag[#diag + 1] = (p and p.Name or "?") .. " x" .. #list
                if (sumY / #list) > vh * 0.30 then for _, b in ipairs(list) do picked[b] = true end end
            end
        end
        for _, b in ipairs(sized) do
            if not picked[b] then local k, cd = indicators(b); if k and cd then picked[b] = true end end
        end
        for b in pairs(picked) do
            local k = indicators(b)
            local nm = clean(b.Name); local txt = clean((b:IsA("TextButton") and b.Text) or "")
            local move
            for stem, svc in pairs(stems) do
                if nm:find(stem, 1, true) or (txt ~= "" and txt:find(stem, 1, true)) then move = svc; break end
            end
            buttons[#buttons + 1] = { button = b, name = b.Name, text = (b:IsA("TextButton") and b.Text) or "", move = move, key = k }
        end
    end

    if #buttons == 0 and #diag > 0 then
        log.info("scan: no move bar; clusters seen -> " .. table.concat(diag, ", "))
    end
    -- Only cache a non-empty result. Caching {buttons={}} traps the picker on a
    -- stale empty (or worse, on a one-time pick-up of unrelated clusters that
    -- happened to match the lower-half heuristic at scan time) for the rest of
    -- the session.
    local res = { services = services, buttons = buttons, diag = diag }
    if #buttons > 0 then cached = res end
    return res
end

-- Only hand back a cache that actually has moves -- callers fall back to scan().
function Scanner.cached()
    if cached and #(cached.buttons or {}) > 0 then return cached end
    return nil
end

-- Clear the cached scan so the next .scan() rebuilds from the LIVE PlayerGui.
-- Called from Builder.open(): without it, the first scan (often taken before
-- the game's hotbar UI is rebuilt for the current character / server) became
-- sticky for the rest of the session and the Use Move picker showed stale
-- (or empty) move names.
function Scanner.clearCache() cached = nil end

return Scanner
