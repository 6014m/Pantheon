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

-- Returns { services = {serviceName,...}, buttons = { {button, name, text, move, key, score}, ... } }
function Scanner.scan()
    local LP = Players.LocalPlayer
    local pg = LP:FindFirstChildOfClass("PlayerGui")
    local services = Scanner.moveServices()

    -- stems for matching button names/text to a service (strip trailing "Service")
    local stems = {}
    for _, svc in ipairs(services) do
        local stem = clean((svc:gsub("Service$", "")))
        if #stem >= 3 then stems[stem] = svc end
    end

    local buttons = {}
    if pg then
        for _, d in ipairs(pg:GetDescendants()) do
            if d:IsA("TextButton") or d:IsA("ImageButton") then
                local nm  = clean(d.Name)
                local txt = clean((d:IsA("TextButton") and d.Text) or "")
                local score, matched = 0, nil
                for stem, svc in pairs(stems) do
                    if nm:find(stem, 1, true) or (txt ~= "" and txt:find(stem, 1, true)) then
                        score, matched = score + 5, svc; break
                    end
                end
                if ancestorSkill(d) then score = score + 2 end
                -- a keybind letter / cooldown label hints at a move button
                local keyHint
                for _, c in ipairs(d:GetDescendants()) do
                    local cn = clean(c.Name)
                    if cn:find("cooldown") or cn:find("keybind") or cn == "cd" or cn == "key" then
                        score = score + 1
                        if c:IsA("TextLabel") and #c.Text > 0 and #c.Text <= 3 then keyHint = c.Text end
                    end
                end
                if score >= 3 then
                    buttons[#buttons + 1] = {
                        button = d, name = d.Name,
                        text = (d:IsA("TextButton") and d.Text) or "",
                        move = matched, key = keyHint, score = score,
                    }
                end
            end
        end
        table.sort(buttons, function(a, b) return a.score > b.score end)
    end

    cached = { services = services, buttons = buttons }
    return cached
end

function Scanner.cached() return cached end

return Scanner
