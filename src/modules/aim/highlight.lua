-- Target visuals: outline highlight (red active / yellow swap target) + a fixed
-- top-center on-screen HUD showing the current target's name and health bar,
-- matching the original lock-on script's indicator. Plus optional self-fade.

local state = require("modules.aim.state")
local env   = require("core.env")

local Players = game:GetService("Players")

local Highlight = {}

local RED    = Color3.fromRGB(255, 60, 60)
local YELLOW = Color3.fromRGB(255, 215, 40)

local highlights = {} -- [target] = Highlight instance  (target = Player OR NPC model)

-- Resolve the character to outline: a Player target outlines its .Character; an
-- NPC target IS its own character model. Works for both the primary (red) target
-- and the next-best (yellow) one, whose type isn't tracked in state.
local function charOf(target)
    if not target then return nil end
    if target:IsA("Player") then return target.Character end
    return target
end

-- outline ---------------------------------------------------------------------
local function setHighlight(plr, color, on)
    local h = highlights[plr]
    if on then
        local char = charOf(plr)
        if not char then
            if h then h:Destroy() end; highlights[plr] = nil; return
        end
        if not h or not h.Parent then
            h = Instance.new("Highlight")
            h.Name = "_" .. math.random(100000, 999999)
            h.FillTransparency = 0.5
            h.OutlineTransparency = 0
            h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
            highlights[plr] = h
        end
        h.Adornee = char
        h.FillColor = color
        h.OutlineColor = color
        h.Parent = char
    else
        if h then h:Destroy() end; highlights[plr] = nil
    end
end

-- top-center target info HUD (name + health bar) -- on-screen, NOT over the head,
-- mirroring the original lock-on script's indicator. Current target only.
local info  -- { gui, indicator, container, bar, text }
local function ensureInfo()
    if info and info.gui.Parent then return info end
    local gui = Instance.new("ScreenGui")
    gui.Name = "_" .. math.random(100000, 999999)
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    env.protectGui(gui)
    gui.Parent = env.guiParent()

    local indicator = Instance.new("TextLabel")
    indicator.Size = UDim2.new(0, 160, 0, 28)
    indicator.Position = UDim2.new(0.5, -80, 0, 10)
    indicator.BackgroundColor3 = Color3.fromRGB(16, 16, 20)
    indicator.BackgroundTransparency = 0.1
    indicator.TextColor3 = Color3.new(1, 1, 1)
    indicator.Font = Enum.Font.GothamBold
    indicator.TextSize = 13
    indicator.Visible = false
    indicator.Parent = gui
    Instance.new("UICorner", indicator).CornerRadius = UDim.new(0, 10)
    local iStroke = Instance.new("UIStroke", indicator); iStroke.Thickness = 2; iStroke.Color = RED

    local container = Instance.new("Frame")
    container.Size = UDim2.new(0, 160, 0, 20)
    container.Position = UDim2.new(0.5, -80, 0, 42)
    container.BackgroundColor3 = Color3.fromRGB(16, 16, 20)
    container.BackgroundTransparency = 0.1
    container.Visible = false
    container.Parent = gui
    Instance.new("UICorner", container).CornerRadius = UDim.new(0, 10)
    local cStroke = Instance.new("UIStroke", container); cStroke.Thickness = 2; cStroke.Color = RED

    local bar = Instance.new("Frame")
    bar.Size = UDim2.new(1, -8, 1, -8)
    bar.Position = UDim2.new(0, 4, 0, 4)
    bar.BackgroundColor3 = Color3.fromRGB(0, 255, 100)
    bar.BorderSizePixel = 0
    bar.Parent = container
    Instance.new("UICorner", bar).CornerRadius = UDim.new(0, 6)

    local text = Instance.new("TextLabel")
    text.Size = UDim2.fromScale(1, 1)
    text.BackgroundTransparency = 1
    text.TextColor3 = Color3.new(1, 1, 1)
    text.Font = Enum.Font.GothamBold
    text.TextSize = 11
    text.Text = ""
    text.Parent = container

    info = { gui = gui, indicator = indicator, container = container, bar = bar, text = text }
    return info
end

local function hideInfo()
    if info then info.indicator.Visible = false; info.container.Visible = false end
end

local function updateInfo(currentTarget)
    if not state.targetInfoEnabled or not currentTarget then hideInfo(); return end
    local isNpc = not currentTarget:IsA("Player")
    local char  = charOf(currentTarget)
    local hum   = char and char:FindFirstChildOfClass("Humanoid")
    if not hum then hideInfo(); return end

    local i = ensureInfo()
    i.indicator.Visible = true
    i.container.Visible = true

    local nm = currentTarget.Name
    if not isNpc then
        local dn = currentTarget.DisplayName
        nm = (dn and dn ~= "" and dn) or currentTarget.Name
    end
    i.indicator.Text = (isNpc and "👾 " or "🎯 ") .. tostring(nm)

    local maxHp = math.max(hum.MaxHealth, 1)
    local ratio = math.clamp(hum.Health / maxHp, 0, 1)
    i.bar.Size = UDim2.new(ratio * (1 - 8 / 160), 0, 1, -8)
    if ratio > 0.5 then
        i.bar.BackgroundColor3 = Color3.fromRGB(0, 255, 100)
    elseif ratio > 0.25 then
        i.bar.BackgroundColor3 = Color3.fromRGB(255, 200, 0)
    else
        i.bar.BackgroundColor3 = Color3.fromRGB(255, 50, 50)
    end
    i.text.Text = math.floor(hum.Health) .. "/" .. math.floor(hum.MaxHealth)
end

function Highlight.clearAll()
    for plr in pairs(highlights) do setHighlight(plr, nil, false) end
    hideInfo()
end

-- Diff-based outline update (reuse instances) + the top-center info HUD.
function Highlight.update(currentTarget, getSecondFn)
    if not state.highlightEnabled or not currentTarget then
        Highlight.clearAll()
        return
    end

    local desired = {}
    if not state.isFriendly(currentTarget) then desired[currentTarget] = RED end
    if state.highlightSecondEnabled and getSecondFn then
        local second = getSecondFn(currentTarget)
        if second and second ~= currentTarget and not state.isFriendly(second) then
            desired[second] = YELLOW
        end
    end

    for plr in pairs(highlights) do if not desired[plr] then setHighlight(plr, nil, false) end end
    for plr, color in pairs(desired) do setHighlight(plr, color, true) end

    updateInfo(currentTarget)
end

-- self-fade -------------------------------------------------------------------
local function applySelfFade(char)
    if not char then return end
    for _, d in ipairs(char:GetDescendants()) do
        if d:IsA("BasePart") then
            d.LocalTransparencyModifier = state.selfFadeEnabled and 0.6 or 0
        elseif d:IsA("Decal") then
            d.Transparency = state.selfFadeEnabled and 0.6 or 0
        end
    end
end

function Highlight.setSelfFade(v)
    state.selfFadeEnabled = v and true or false
    applySelfFade(Players.LocalPlayer.Character)
end

function Highlight.setEnabled(v)
    state.highlightEnabled = v and true or false
    if not v then Highlight.clearAll() end
end

function Highlight.setSecondEnabled(v)
    state.highlightSecondEnabled = v and true or false
end

function Highlight.setTargetInfo(v)
    state.targetInfoEnabled = v and true or false
    if not v then hideInfo() end
end

local charConn

function Highlight.init()
    charConn = Players.LocalPlayer.CharacterAdded:Connect(function(char)
        if state.selfFadeEnabled then
            char:WaitForChild("HumanoidRootPart", 5)
            applySelfFade(char)
        end
    end)
end

function Highlight.destroy()
    if charConn then charConn:Disconnect(); charConn = nil end
    Highlight.clearAll()
    if info and info.gui then pcall(function() info.gui:Destroy() end); info = nil end
end

return Highlight
