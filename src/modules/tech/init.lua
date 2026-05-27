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
local builder    = require("modules.tech.builder_ui")
local scanner    = require("modules.tech.scanner")
local dumper     = require("modules.tech.dumper")
local log        = require("core.log")

local module = {}

-- Bucketize a scope for the list. Returns "here" (this game / this character),
-- "uni" (universal), or "other" (different game / different char -> hidden).
-- char-scoped techs go into "here" while you're playing as that character so
-- they appear in the same This Game section; out-of-game / out-of-character
-- techs are hidden so the list stays tight.
local registry = require("games.registry")
local function classifyScope(scope)
    if scope == "universal" then return "uni" end
    if scope == game.PlaceId or scope == game.GameId then return "here" end
    if type(scope) == "string" then
        local want = scope:match("^char:(.+)$")
        if want then
            local mod = registry.current()
            local fn = mod and mod.detectCharacter
            if type(fn) == "function" then
                local ok, name = pcall(fn)
                if ok and name == want then return "here" end
            end
            return "other"
        end
    end
    return "other"
end

-- A single tech row: name on the left, an ON/OFF button on the right.
local function buildRow(parent, tech)
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, 0, 0, 26)
    f.BackgroundColor3 = theme.bgAlt
    f.BorderSizePixel = 0
    f.Parent = parent

    -- name (custom techs leave room for a delete button on top of the edit one)
    local name = Instance.new("TextLabel")
    name.Size = UDim2.new(1, tech.custom and -106 or -82, 1, 0)
    name.Position = UDim2.fromOffset(8, 0)
    name.BackgroundTransparency = 1
    name.Text = tech.name or tech.id
    name.TextColor3 = tech.enabled and theme.fg or theme.fgDim
    name.Font = theme.font
    name.TextSize = 12
    name.TextXAlignment = Enum.TextXAlignment.Left
    name.TextTruncate = Enum.TextTruncate.AtEnd
    name.Parent = f

    -- ON/OFF toggle. Lets engine.changed rebuild the list to repaint (no per-row state).
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
    btn.MouseButton1Click:Connect(function() engine.setEnabled(tech.id, not tech.enabled) end)

    -- Edit (every tech). Editing a built-in saves a persistent custom override.
    local edit = Instance.new("TextButton")
    edit.Size = UDim2.fromOffset(30, 18)
    edit.Position = UDim2.new(1, -78, 0.5, -9)
    edit.AutoButtonColor = false
    edit.BackgroundColor3 = theme.bgDark
    edit.TextColor3 = theme.fg
    edit.Font = theme.font
    edit.TextSize = 10
    edit.Text = "Edit"
    edit.Parent = f
    edit.MouseButton1Click:Connect(function() builder.open(tech) end)

    -- Delete (custom techs only; deleting a custom override of a built-in reverts
    -- to the built-in on next load).
    if tech.custom then
        local del = Instance.new("TextButton")
        del.Size = UDim2.fromOffset(20, 18)
        del.Position = UDim2.new(1, -102, 0.5, -9)
        del.BackgroundColor3 = theme.danger
        del.AutoButtonColor = false
        del.TextColor3 = theme.fg
        del.Font = theme.fontBold
        del.TextSize = 10
        del.Text = "X"
        del.Parent = f
        del.MouseButton1Click:Connect(function() engine.remove(tech.id) end)
    end

    return f
end

local function refreshList(listFrame)
    for _, c in ipairs(listFrame:GetChildren()) do
        if not c:IsA("UIListLayout") then c:Destroy() end
    end

    local here, uni = {}, {}
    for _, t in pairs(engine.all()) do
        local cls = classifyScope(t.scope)
        if cls == "here" then here[#here + 1] = t
        elseif cls == "uni" then uni[#uni + 1] = t end
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
        onClick = function() builder.open() end,
    })
    openBtn.LayoutOrder = 1

    -- Dev dumps: write raw GUI + animation data to files so move-bar detection and
    -- move->animation mapping can be set up correctly per game (vs heuristics).
    local status = components.Label(holder, "")
    status.LayoutOrder = 4
    status.Visible = false

    local dumpGuiBtn = components.Button(holder, { text = "Dump GUI (for setup)", onClick = function()
        local n = dumper.dumpGui()
        status.Visible = true
        status.Text = "GUI dumped (" .. n .. " buttons) -> pantheon_gui_dump.txt"
        pcall(function() notify.info("GUI dumped: " .. n .. " buttons", 4) end)
    end })
    dumpGuiBtn.LayoutOrder = 2

    -- Static anim dumper removed -- the editor's active anim logging (animLog +
    -- Capture) covers what the dump file was for, and friendly names now fall
    -- back to Animation:GetFullName() live in recordAnim. The Dump GUI button
    -- stays since per-game hotbar setup still needs the GUI tree dump.

    local listFrame = Instance.new("Frame")
    listFrame.Size = UDim2.new(1, 0, 0, 0)
    listFrame.AutomaticSize = Enum.AutomaticSize.Y
    listFrame.BackgroundTransparency = 1
    listFrame.LayoutOrder = 5
    listFrame.Parent = holder
    local ll = Instance.new("UIListLayout", listFrame)
    ll.SortOrder = Enum.SortOrder.LayoutOrder
    ll.Padding = UDim.new(0, 1)

    box:add(holder)

    -- Rebuild the list whenever the tech set changes (toggles, or per-game
    -- modules adding their techs after this point).
    engine.changed:Connect(function() refreshList(listFrame) end)

    engine.loadCustom()   -- rehydrate persisted user-built techs
    refreshList(listFrame)

    log.info("Tech Builder registered")
end

function module.destroy()
    pcall(function() builder.destroy() end)
    pcall(function() engine.destroy() end)
end

return module
