-- Friendlies: a per-session list of players to NEVER target. Each row shows the
-- player's avatar headshot (rbxthumb), their name, and a FRIENDLY / neutral
-- toggle. Marking someone writes state.friendlies[UserId], which
-- targeting.getBestTarget() already skips -- so a friendly is excluded from
-- Target Select, Lock-On, Swap, Highlight, and Bot Mode all at once.
--
-- The "All" button flips EVERY player in the server friendly (or back to
-- neutral) in one click -- the usual "friendly all" for ceasefires / teammates.
--
-- Session-only on purpose: UserId entries are dropped on re-execute, so a fresh
-- server starts with a clean slate rather than silently carrying a whitelist.

local window     = require("ui.window")
local container  = require("ui.container")
local components = require("ui.components")
local theme      = require("ui.theme")
local state      = require("modules.aim.state")
local log        = require("core.log")

local Players = game:GetService("Players")

local Friendlies = {}

local conns = {}            -- PlayerAdded/Removing + the scroll fit-height signal
local listFrame             -- ScrollingFrame the player rows live in
local repaintAll            -- repaints the "All" button (set in register)
local rebuildPending = false

local function isFriendly(plr) return state.friendlies[plr.UserId] == true end
local function setFriendly(plr, v)
    state.friendlies[plr.UserId] = v and true or nil
end

-- True only when there's at least one other player AND every one is friendly.
local function allFriendly()
    local me, any = Players.LocalPlayer, false
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= me then
            any = true
            if not isFriendly(plr) then return false end
        end
    end
    return any
end

local function setAll(v)
    local me = Players.LocalPlayer
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= me then setFriendly(plr, v) end
    end
end

local function avatarImage(userId)
    return ("rbxthumb://type=AvatarHeadShot&id=%d&w=60&h=60"):format(userId)
end

local function buildRow(plr)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 34)
    row.BackgroundColor3 = theme.bgAlt
    row.BorderSizePixel = 0

    local avatar = Instance.new("ImageLabel")
    avatar.Size = UDim2.fromOffset(26, 26)
    avatar.Position = UDim2.fromOffset(4, 4)
    avatar.BackgroundColor3 = theme.bgDark
    avatar.BorderSizePixel = 0
    avatar.Image = avatarImage(plr.UserId)
    avatar.Parent = row

    local name = Instance.new("TextLabel")
    name.Position = UDim2.fromOffset(36, 0)
    name.Size = UDim2.new(1, -98, 1, 0)
    name.BackgroundTransparency = 1
    name.Text = (plr.DisplayName and plr.DisplayName ~= plr.Name)
        and (plr.DisplayName .. "  @" .. plr.Name) or plr.Name
    name.TextColor3 = theme.fg
    name.Font = theme.font
    name.TextSize = 12
    name.TextXAlignment = Enum.TextXAlignment.Left
    name.TextTruncate = Enum.TextTruncate.AtEnd
    name.Parent = row

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.fromOffset(54, 20)
    btn.Position = UDim2.new(1, -58, 0.5, -10)
    btn.AutoButtonColor = false
    btn.Font = theme.fontBold
    btn.TextSize = 10
    btn.BorderSizePixel = 0
    btn.Parent = row

    local function paint()
        local f = isFriendly(plr)
        btn.BackgroundColor3 = f and theme.on or theme.bgDark
        btn.TextColor3 = f and theme.bgDark or theme.fgDim
        btn.Text = f and "FRIENDLY" or "neutral"
    end
    paint()
    btn.MouseButton1Click:Connect(function()
        setFriendly(plr, not isFriendly(plr))
        paint()
        if repaintAll then repaintAll() end
    end)

    return row
end

local function rebuild()
    rebuildPending = false
    if not listFrame then return end
    for _, c in ipairs(listFrame:GetChildren()) do
        if not c:IsA("UIListLayout") then c:Destroy() end
    end

    local me = Players.LocalPlayer
    local players = Players:GetPlayers()
    table.sort(players, function(a, b)
        return (a.DisplayName or a.Name):lower() < (b.DisplayName or b.Name):lower()
    end)

    local n = 0
    for _, plr in ipairs(players) do
        if plr ~= me then
            n = n + 1
            local row = buildRow(plr)
            row.LayoutOrder = n
            row.Parent = listFrame
        end
    end
    if n == 0 then
        local empty = components.Label(listFrame, "No other players in server.")
        empty.LayoutOrder = 1
    end
    if repaintAll then repaintAll() end
end

local function scheduleRebuild()
    if rebuildPending then return end
    rebuildPending = true
    task.delay(0.3, rebuild)   -- debounce so a mass join/leave rebuilds once
end

function Friendlies.register()
    local box = container.new(window.parent(), "Friendlies")

    local holder = Instance.new("Frame")
    holder.Size = UDim2.new(1, 0, 0, 0)
    holder.AutomaticSize = Enum.AutomaticSize.Y
    holder.BackgroundTransparency = 1
    local hl = Instance.new("UIListLayout", holder)
    hl.SortOrder = Enum.SortOrder.LayoutOrder
    hl.Padding = UDim.new(0, 3)

    -- Header: hint on the left, the "All" toggle on the right.
    local header = Instance.new("Frame")
    header.Size = UDim2.new(1, 0, 0, 22)
    header.BackgroundTransparency = 1
    header.LayoutOrder = 1
    header.Parent = holder

    local hint = Instance.new("TextLabel")
    hint.Size = UDim2.new(1, -60, 1, 0)
    hint.BackgroundTransparency = 1
    hint.Text = "Marked = never targeted"
    hint.TextColor3 = theme.fgDim
    hint.Font = theme.font
    hint.TextSize = 11
    hint.TextXAlignment = Enum.TextXAlignment.Left
    hint.Parent = header

    local allBtn = Instance.new("TextButton")
    allBtn.Size = UDim2.fromOffset(54, 18)
    allBtn.Position = UDim2.new(1, -56, 0.5, -9)
    allBtn.AutoButtonColor = false
    allBtn.Font = theme.fontBold
    allBtn.TextSize = 10
    allBtn.BorderSizePixel = 0
    allBtn.Parent = header

    local function paintAll()
        local on = allFriendly()
        allBtn.BackgroundColor3 = on and theme.on or theme.bgDark
        allBtn.TextColor3 = on and theme.bgDark or theme.fgDim
        allBtn.Text = on and "ALL ✓" or "All"
    end
    repaintAll = paintAll
    allBtn.MouseButton1Click:Connect(function()
        setAll(not allFriendly())
        rebuild()
    end)

    -- Player list: grows with the roster up to a cap, then scrolls (so a 40-player
    -- server doesn't make the window taller than the screen).
    local scroll = Instance.new("ScrollingFrame")
    scroll.Size = UDim2.new(1, 0, 0, 0)
    scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    scroll.ScrollBarThickness = 4
    scroll.ScrollBarImageColor3 = theme.fgDim
    scroll.BackgroundTransparency = 1
    scroll.BorderSizePixel = 0
    scroll.LayoutOrder = 2
    scroll.Parent = holder

    local sl = Instance.new("UIListLayout", scroll)
    sl.SortOrder = Enum.SortOrder.LayoutOrder
    sl.Padding = UDim.new(0, 2)

    local MAX_H = 220
    local function fitHeight()
        scroll.Size = UDim2.new(1, 0, 0, math.min(sl.AbsoluteContentSize.Y, MAX_H))
    end
    conns[#conns + 1] = sl:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(fitHeight)
    fitHeight()

    listFrame = scroll
    box:add(holder)

    conns[#conns + 1] = Players.PlayerAdded:Connect(scheduleRebuild)
    conns[#conns + 1] = Players.PlayerRemoving:Connect(scheduleRebuild)
    rebuild()

    log.info("Friendlies module registered")
end

function Friendlies.destroy()
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    conns = {}
    listFrame, repaintAll = nil, nil
end

return Friendlies
