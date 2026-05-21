-- Central keybind dispatcher. Features register (id, key, onPress, onRelease).
-- One pair of UserInputService listeners routes events to the right callback(s).
-- Multiple features can share a key — all callbacks fire.

local UserInputService = game:GetService("UserInputService")

local Keybinds = {}

local bindings = {} -- [id] = { key = KeyCode, onPress = fn, onRelease = fn }
local keyToIds = {} -- [KeyCode] = { id, ... }
local hooked   = false
local inputBeganConn, inputEndedConn

local function removeFromKeyTable(id)
    local b = bindings[id]
    if not b or not b.key then return end
    local arr = keyToIds[b.key]
    if not arr then return end
    for i, fid in ipairs(arr) do
        if fid == id then
            table.remove(arr, i)
            break
        end
    end
end

function Keybinds.set(id, key, onPress, onRelease)
    if not id then return end
    removeFromKeyTable(id)
    bindings[id] = { key = key, onPress = onPress, onRelease = onRelease }
    if key and key ~= Enum.KeyCode.Unknown then
        keyToIds[key] = keyToIds[key] or {}
        table.insert(keyToIds[key], id)
    end
end

function Keybinds.get(id)
    local b = bindings[id]
    return b and b.key
end

function Keybinds.clear(id)
    removeFromKeyTable(id)
    bindings[id] = nil
end

function Keybinds.all()
    return bindings
end

function Keybinds.init()
    if hooked then return end
    hooked = true

    inputBeganConn = UserInputService.InputBegan:Connect(function(input, gpe)
        if gpe then return end
        if input.KeyCode == Enum.KeyCode.Unknown then return end
        local ids = keyToIds[input.KeyCode]
        if not ids then return end
        for _, id in ipairs(ids) do
            local b = bindings[id]
            if b and b.onPress then
                task.spawn(b.onPress)
            end
        end
    end)

    inputEndedConn = UserInputService.InputEnded:Connect(function(input)
        if input.KeyCode == Enum.KeyCode.Unknown then return end
        local ids = keyToIds[input.KeyCode]
        if not ids then return end
        for _, id in ipairs(ids) do
            local b = bindings[id]
            if b and b.onRelease then
                task.spawn(b.onRelease)
            end
        end
    end)
end

function Keybinds.destroy()
    if inputBeganConn then inputBeganConn:Disconnect(); inputBeganConn = nil end
    if inputEndedConn then inputEndedConn:Disconnect(); inputEndedConn = nil end
    bindings = {}
    keyToIds = {}
    hooked = false
end

return Keybinds
