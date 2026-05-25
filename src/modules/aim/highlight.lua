-- Target visuals: outline highlight + a healthbar/username billboard, plus
-- optional self-fade. Red on the active target, yellow on the next-best (the
-- target Swap Target would cycle to). Ports LockOnVisualModule.

local state = require("modules.aim.state")
local env   = require("core.env")

local Players = game:GetService("Players")

local Highlight = {}

local RED    = Color3.fromRGB(255, 60, 60)
local YELLOW = Color3.fromRGB(255, 215, 40)

local highlights = {} -- [Player] = Highlight instance
local billboards = {} -- [Player] = { gui, accent, name, fill, hptext }

-- outline ---------------------------------------------------------------------
local function setHighlight(plr, color, on)
    local h = highlights[plr]
    if on then
        local char = plr.Character
        if not char then
            if h then h:Destroy() end; highlights[plr] = nil; return
        end
        if not h or not h.Parent then
            h = Instance.new("Highlight")
            h.Name = "_" .. math.random(100000, 999999)   -- unnamed: don't fingerprint as Pantheon
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

-- healthbar + username billboard ---------------------------------------------
local function buildBillboard()
    local gui = Instance.new("BillboardGui")
    gui.Name = "_" .. math.random(100000, 999999)
    gui.Size = UDim2.fromOffset(154, 38)
    gui.StudsOffsetWorldSpace = Vector3.new(0, 3.2, 0)   -- float above the head
    gui.AlwaysOnTop = true
    gui.MaxDistance = 1000
    gui.LightInfluence = 0

    local frame = Instance.new("Frame")
    frame.Size = UDim2.fromScale(1, 1)
    frame.BackgroundColor3 = Color3.fromRGB(16, 16, 20)
    frame.BackgroundTransparency = 0.2
    frame.BorderSizePixel = 0
    frame.Parent = gui
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 6)
    local accent = Instance.new("UIStroke", frame)
    accent.Thickness = 1.5

    local nameLabel = Instance.new("TextLabel")
    nameLabel.BackgroundTransparency = 1
    nameLabel.Position = UDim2.fromOffset(6, 2)
    nameLabel.Size = UDim2.new(1, -12, 0, 18)
    nameLabel.Font = Enum.Font.GothamBold
    nameLabel.TextSize = 13
    nameLabel.TextXAlignment = Enum.TextXAlignment.Left
    nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
    nameLabel.Text = ""
    nameLabel.Parent = frame

    local hpbg = Instance.new("Frame")
    hpbg.Position = UDim2.new(0, 6, 1, -13)
    hpbg.Size = UDim2.new(1, -12, 0, 9)
    hpbg.BackgroundColor3 = Color3.fromRGB(38, 38, 44)
    hpbg.BorderSizePixel = 0
    hpbg.Parent = frame
    Instance.new("UICorner", hpbg).CornerRadius = UDim.new(1, 0)

    local fill = Instance.new("Frame")
    fill.Size = UDim2.fromScale(1, 1)
    fill.BackgroundColor3 = Color3.fromRGB(40, 220, 60)
    fill.BorderSizePixel = 0
    fill.Parent = hpbg
    Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)

    local hptext = Instance.new("TextLabel")
    hptext.BackgroundTransparency = 1
    hptext.Size = UDim2.fromScale(1, 1)
    hptext.Font = Enum.Font.GothamBold
    hptext.TextSize = 9
    hptext.TextColor3 = Color3.fromRGB(255, 255, 255)
    hptext.Text = ""
    hptext.Parent = hpbg

    return { gui = gui, accent = accent, name = nameLabel, fill = fill, hptext = hptext }
end

local function setBillboard(plr, color, on)
    local b = billboards[plr]
    if on and state.targetInfoEnabled then
        local char = plr.Character
        local head = char and (char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart"))
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        if not (head and hum) then
            if b then b.gui:Destroy() end; billboards[plr] = nil; return
        end
        if not b or not b.gui.Parent then
            b = buildBillboard()
            env.protectGui(b.gui)
            b.gui.Parent = env.guiParent()             -- gethui sandbox, never PlayerGui
            billboards[plr] = b
        end
        b.gui.Adornee = head
        b.accent.Color = color
        b.name.TextColor3 = color
        local nm = plr.DisplayName
        b.name.Text = (nm and nm ~= "" and nm) or plr.Name
        local maxh = math.max(hum.MaxHealth, 1)
        local pct  = math.clamp(hum.Health / maxh, 0, 1)
        b.fill.Size = UDim2.fromScale(pct, 1)
        b.fill.BackgroundColor3 = Color3.fromRGB(            -- green (full) -> red (empty)
            math.floor((1 - pct) * 225) + 25,
            math.floor(pct * 200) + 35,
            45)
        b.hptext.Text = string.format("%d / %d", math.floor(hum.Health + 0.5), math.floor(hum.MaxHealth + 0.5))
    else
        if b then b.gui:Destroy(); billboards[plr] = nil end
    end
end

-- combined per-player visual --------------------------------------------------
local function setOne(plr, color, on)
    setHighlight(plr, color, on)
    setBillboard(plr, color, on)
end

function Highlight.clearAll()
    for plr in pairs(highlights) do setHighlight(plr, nil, false) end
    for plr in pairs(billboards) do setBillboard(plr, nil, false) end
end

-- Diff-based: reuse instances across frames. The old clear-then-rebuild ran
-- every frame and would destroy + recreate the billboard ~60x/sec; instead we
-- compute the desired set, drop the stale ones, then create/update the rest.
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
    for plr in pairs(billboards) do if not desired[plr] then setBillboard(plr, nil, false) end end
    for plr, color in pairs(desired) do setOne(plr, color, true) end
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
    if not v then for plr in pairs(billboards) do setBillboard(plr, nil, false) end end
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
end

return Highlight
