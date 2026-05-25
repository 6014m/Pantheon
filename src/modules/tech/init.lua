-- Tech Builder UI: the "Tech Builder" container.
--
-- Top row  : "Open Tech Builder" -> the avatar+dummy viewport with the timeline
--            reenactment (stage 2; for now it announces it's coming).
-- Below    : the saved techs, split into "This Game" (scope matches the current
--            PlaceId/GameId) and "Universal" (scope == "universal"). Techs built
--            for OTHER games are hidden. Each row toggles the tech on/off.
--
-- The list re-reads [[modules.tech.engine]] on engine.changed, so techs added by
-- per-game modules (which register AFTER this section is built) appear live.

local window     = require("ui.window")
local container  = require("ui.container")
local components = require("ui.components")
local theme      = require("ui.theme")
local notify     = require("ui.notify")
local engine     = require("modules.tech.engine")
local log        = require("core.log")

local module = {}

local function inThisGame(scope)
    if scope == "universal" then return true end
    return scope == game.PlaceId or scope == game.GameId
end

-- A single tech row: name on the left, an ON/OFF button on the right.
local function buildRow(parent, tech)
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, 0, 0, 26)
    f.BackgroundColor3 = theme.bgAlt
    f.BorderSizePixel = 0
    f.Parent = parent

    local name = Instance.new("TextLabel")
    name.Size = UDim2.new(1, -52, 1, 0)
    name.Position = UDim2.fromOffset(8, 0)
    name.BackgroundTransparency = 1
    name.Text = tech.name or tech.id
    name.TextColor3 = tech.enabled and theme.fg or theme.fgDim
    name.Font = theme.font
    name.TextSize = 12
    name.TextXAlignment = Enum.TextXAlignment.Left
    name.TextTruncate = Enum.TextTruncate.AtEnd
    name.Parent = f

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.fromOffset(38, 18)
    btn.Position = UDim2.new(1, -44, 0.5, -9)
    btn.AutoButtonColor = false
    btn.BackgroundColor3 = tech.enabled and theme.on or theme.off
    btn.TextColor3 = theme.fg
    btn.Font = theme.fontBold
    btn.TextSize = 10
    btn.Text = tech.enabled and "ON" or "OFF"
    btn.Parent = f

    -- Toggle, then let engine.changed rebuild the whole list (keeps this row in
    -- sync without per-row state). No paint() here -- the rebuild repaints.
    btn.MouseButton1Click:Connect(function()
        engine.setEnabled(tech.id, not tech.enabled)
    end)

    return f
end

local function refreshList(listFrame)
    for _, c in ipairs(listFrame:GetChildren()) do
        if not c:IsA("UIListLayout") then c:Destroy() end
    end

    local here, uni = {}, {}
    for _, t in pairs(engine.all()) do
        if t.scope == "universal" then
            uni[#uni + 1] = t
        elseif inThisGame(t.scope) then
            here[#here + 1] = t
        end
    end
    local byName = function(a, b) return (a.name or a.id) < (b.name or b.id) end
    table.sort(here, byName)
    table.sort(uni, byName)

    local ord = 0
    local function place(inst) ord = ord + 1; inst.LayoutOrder = ord; return inst end

    if #here > 0 then
        place(components.Section(listFrame, "This Game"))
        for _, t in ipairs(here) do place(buildRow(listFrame, t)) end
    end
    if #uni > 0 then
        place(components.Section(listFrame, "Universal"))
        for _, t in ipairs(uni) do place(buildRow(listFrame, t)) end
    end
    if #here == 0 and #uni == 0 then
        place(components.Label(listFrame, "No techs yet."))
    end
end

-- Built-in universal example: hold a key to snap-look 180 off the lock target
-- and auto-return on release. Demonstrates the look/hold/condition path. Off by
-- default so it doesn't claim a key until you turn it on.
local function registerExamples()
    engine.add({
        id      = "reverse_look",
        name    = "Reverse Look (hold)",
        scope   = "universal",
        enabled = false,
        trigger = { event = "keyhold", key = Enum.KeyCode.V, conditions = { "locked_on" } },
        actions = { { type = "look", x = 180, y = 0 } },
    })
end

function module.register()
    engine.init()

    local box = container.new(window.parent(), "Tech Builder")

    local holder = Instance.new("Frame")
    holder.Size = UDim2.new(1, 0, 0, 0)
    holder.AutomaticSize = Enum.AutomaticSize.Y
    holder.BackgroundTransparency = 1
    local hl = Instance.new("UIListLayout", holder)
    hl.SortOrder = Enum.SortOrder.LayoutOrder
    hl.Padding = UDim.new(0, 2)

    local openBtn = components.Button(holder, {
        text    = "Open Tech Builder",
        onClick = function()
            notify.info("Tech Builder editor + avatar/dummy viewport are coming in the next update. Built-in techs are usable now below.", 5)
        end,
    })
    openBtn.LayoutOrder = 1

    local listFrame = Instance.new("Frame")
    listFrame.Size = UDim2.new(1, 0, 0, 0)
    listFrame.AutomaticSize = Enum.AutomaticSize.Y
    listFrame.BackgroundTransparency = 1
    listFrame.LayoutOrder = 2
    listFrame.Parent = holder
    local ll = Instance.new("UIListLayout", listFrame)
    ll.SortOrder = Enum.SortOrder.LayoutOrder
    ll.Padding = UDim.new(0, 1)

    box:add(holder)

    -- Rebuild the list whenever the tech set changes (toggles, or per-game
    -- modules adding their techs after this point).
    engine.changed:Connect(function() refreshList(listFrame) end)

    registerExamples()
    refreshList(listFrame)

    log.info("Tech Builder registered")
end

function module.destroy()
    pcall(function() engine.destroy() end)
end

return module
