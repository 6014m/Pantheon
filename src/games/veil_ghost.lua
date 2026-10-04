-- The Veil: Ghost ESP. "A Ghost" is the Pale NPC that starts The Masquerade. He spawns at
-- random, and the game only puts its own quest marker on him while the quest points there, so
-- finding him again (to retry the fight) means wandering the Pale.
--
-- What he is in the world (ghost watch dump, 2026-10-03):
--     Workspace.NPCs["A Ghost"]   Model, R6, body parts at Transparency 0.8
--       HumanoidRootPart / Torso / Head ...   Humanoid "NPC"   NPCDialogueConfig
-- The Veil streams the map in, so he only exists on your client once you are close enough for
-- his part of the Pale to load (first seen from ~190 studs) -- this marks him the moment he
-- does, it cannot see him from across the map.
--
-- Nothing is added to the game's own objects: the outline and the label live in the executor's
-- GUI container and only point at him (Adornee).

local Players   = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local env    = require("core.env")
local log    = require("core.log")
local notify = require("ui.notify")

local LP = Players.LocalPlayer

local Ghost = {}
local CFG = { enabled = false, notify = true }
local NAME  = "A Ghost"
local COLOR = Color3.fromRGB(190, 225, 255)

local running = false
local gui, hl, bb, label
local current        -- the model being marked
local announced = setmetatable({}, { __mode = "k" })   -- model -> true (one note per spawn)

local function find()
    local folder = Workspace:FindFirstChild("NPCs")
    if not folder then return nil end
    local m = folder:FindFirstChild(NAME)
    if m then return m end
    for _, c in ipairs(folder:GetChildren()) do      -- in case the name ever changes a little
        if string.find(string.lower(c.Name), "ghost", 1, true) then return c end
    end
    return nil
end

local function anchorPart(model)
    return model:FindFirstChild("Head") or model:FindFirstChild("HumanoidRootPart")
        or model:FindFirstChildWhichIsA("BasePart", true)
end

local function clear()
    if gui then pcall(function() gui:Destroy() end) end
    gui, hl, bb, label, current = nil, nil, nil, nil, nil
end

local function mark(model)
    clear()
    local part = anchorPart(model)
    if not part then return false end

    -- Camera children render but never replicate (the game parks its own client effects there
    -- too). The executor's hidden GUI container did NOT render 3D adornments like Highlights --
    -- found when the Loot ESP addon's marks never appeared (2026-10-03).
    gui = Instance.new("Folder")
    gui.Name = "PantheonGhostESP"
    gui.Parent = Workspace.CurrentCamera or env.guiParent()

    hl = Instance.new("Highlight")
    hl.Adornee = model
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.FillColor = COLOR
    hl.FillTransparency = 0.55
    hl.OutlineColor = COLOR
    hl.OutlineTransparency = 0
    hl.Parent = gui

    bb = Instance.new("BillboardGui")
    bb.Adornee = part
    bb.AlwaysOnTop = true
    bb.Size = UDim2.fromOffset(220, 34)
    bb.StudsOffset = Vector3.new(0, 3.2, 0)
    bb.MaxDistance = math.huge
    bb.Parent = gui

    label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamBold
    label.TextSize = 15
    label.TextColor3 = COLOR
    label.TextStrokeTransparency = 0.25
    label.Text = NAME
    label.Parent = bb

    current = model
    return true
end

local function distanceTo(model)
    local char = LP.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local part = anchorPart(model)
    if not (root and part) then return nil end
    return (part.Position - root.Position).Magnitude
end

local function step()
    local model = find()
    if not model then
        if current then clear() end
        return
    end
    if model ~= current or not (gui and gui.Parent) then
        if not mark(model) then return end
        if not announced[model] then
            announced[model] = true
            local d = distanceTo(model)
            log.info("[GhostESP] found " .. model:GetFullName() .. (d and string.format(" at %.0f studs", d) or ""))
            if CFG.notify then
                notify.success(d and string.format("The Ghost is here -- %.0f studs away", d) or "The Ghost is here", 8)
            end
        end
    end
    local d = distanceTo(model)
    if label then label.Text = d and string.format("%s  [%.0f studs]", NAME, d) or NAME end
end

function Ghost.start()
    Ghost.stop()
    running = true
    task.spawn(function()
        while running do
            pcall(step)
            task.wait(0.5)
        end
    end)
    log.info("[GhostESP] on")
end

function Ghost.stop()
    running = false
    clear()
end

function Ghost.feature()
    return {
        id          = "veil.ghost_esp",
        name        = "Ghost ESP",
        description = "Marks \"A Ghost\" -- the NPC that spawns at random in the Pale and starts The Masquerade -- with an outline you can see through walls and a label showing how far away he is. He only shows up once you're close enough for his part of the Pale to load (roughly 190 studs), so you still have to roam the Pale; this just makes him impossible to walk past.",
        default     = false,
        onToggle    = function(v)
            CFG.enabled = v and true or false
            if CFG.enabled then Ghost.start() else Ghost.stop() end
        end,
        settings = {
            { type = "toggle", name = "Notify when he appears", key = "notify", default = true,
              onChange = function(v) CFG.notify = v and true or false end },
        },
    }
end

return Ghost
