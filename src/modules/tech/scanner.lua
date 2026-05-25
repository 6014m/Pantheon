-- Move-button scanner: detect the game's on-screen MOVE buttons so you can see
-- which moves you can build techs around (and, later, trigger off a button press).
--
-- Heuristic -- Roblox has no "this is a move button" flag -- but the strong signal
-- is cross-referencing on-screen buttons against the REAL move list
-- (ReplicatedStorage.Knit.Knit.Services that own an RE). Plus skill-bar / cooldown
-- / keybind cues. You confirm the matches.

local Players = game:GetService("Players")
local RS      = game:GetService("ReplicatedStorage")

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

-- Detect MOVE-BAR slots from the GUI itself (not service names, which over-match
-- emotes/animations like "conga"): the button is on screen and carries a single
-- capital-letter KEYBIND label (Z / X / C / R / ...), plus a cooldown child or a
-- skill-bar ancestor. Service names are used ONLY to label a match, never to flag.
-- Returns { services = {...}, buttons = { {button, name, text, move, key}, ... } }
function Scanner.scan()
    local LP = Players.LocalPlayer
    local pg = LP:FindFirstChildOfClass("PlayerGui")
    local services = Scanner.moveServices()
    local stems = {}
    for _, svc in ipairs(services) do
        local stem = clean((svc:gsub("Service$", "")))
        if #stem >= 3 then stems[stem] = svc end
    end

    local buttons = {}
    if pg then
        for _, d in ipairs(pg:GetDescendants()) do
            if (d:IsA("TextButton") or d:IsA("ImageButton")) and onScreen(d) then
                local keyHint, hasCD = nil, false
                for _, c in ipairs(d:GetDescendants()) do
                    if not keyHint and c:IsA("TextLabel") then
                        local t = c.Text
                        if t and t:match("^%u$") then keyHint = t end   -- single capital = keybind letter
                    end
                    if not hasCD then
                        local cn = clean(c.Name)
                        if cn:find("cooldown") or cn == "cd" then hasCD = true end
                    end
                end
                if keyHint and (hasCD or ancestorSkill(d)) then
                    local nm  = clean(d.Name)
                    local txt = clean((d:IsA("TextButton") and d.Text) or "")
                    local move
                    for stem, svc in pairs(stems) do
                        if nm:find(stem, 1, true) or (txt ~= "" and txt:find(stem, 1, true)) then move = svc; break end
                    end
                    buttons[#buttons + 1] = {
                        button = d, name = d.Name,
                        text = (d:IsA("TextButton") and d.Text) or "",
                        move = move, key = keyHint,
                    }
                end
            end
        end
    end
    cached = { services = services, buttons = buttons }
    return cached
end

function Scanner.cached() return cached end

return Scanner
