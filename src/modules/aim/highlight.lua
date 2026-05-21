-- Target highlights + optional self-fade. Ports LockOnVisualModule.

local state = require("modules.aim.state")

local Players = game:GetService("Players")

local Highlight = {}

local highlights = {} -- [Player] = Highlight instance

local function setOne(plr, color, on)
    local h = highlights[plr]
    if on then
        local char = plr.Character
        if not char then
            if h then h:Destroy() end
            highlights[plr] = nil
            return
        end
        if not h or not h.Parent then
            h = Instance.new("Highlight")
            h.Name = "PantheonLockOnHighlight"
            highlights[plr] = h
        end
        h.Adornee = char
        h.FillColor = color
        h.FillTransparency = 0.5
        h.OutlineColor = color
        h.OutlineTransparency = 0
        h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        h.Parent = char
    else
        if h then h:Destroy() end
        highlights[plr] = nil
    end
end

function Highlight.clearAll()
    for plr in pairs(highlights) do
        setOne(plr, Color3.new(1, 0, 0), false)
    end
end

function Highlight.update(currentTarget, getSecondFn)
    Highlight.clearAll()
    if not state.highlightEnabled or not currentTarget then return end

    if not state.isFriendly(currentTarget) then
        setOne(currentTarget, Color3.new(1, 0, 0), true)
    end

    if state.highlightSecondEnabled and getSecondFn then
        local second = getSecondFn(currentTarget)
        if second and not state.isFriendly(second) then
            setOne(second, Color3.new(1, 1, 0), true)
        end
    end
end

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
