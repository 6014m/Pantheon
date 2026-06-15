-- Miscellaneous: catch-all menu for standalone utility scripts that don't fit
-- the aim / aesthetic / tech buckets. Each script self-contains its own feature
-- declaration and lifecycle; this just owns the shared container and fans
-- register()/destroy() out to them. Add a new script: require it here, call its
-- .register(box) in Misc.register, and its .destroy() in Misc.destroy.

local container = require("ui.container")
local window    = require("ui.window")
local log       = require("core.log")

local faketab   = require("modules.misc.faketab")
local freecam   = require("modules.misc.freecam")

local Misc = {}

local scripts = { faketab, freecam }

function Misc.register()
    local box = container.new(window.parent(), "Miscellaneous")
    for _, m in ipairs(scripts) do
        local ok, err = pcall(function() m.register(box) end)
        if not ok then log.warn("misc script register failed: " .. tostring(err)) end
    end
    log.info("Miscellaneous module registered")
end

function Misc.destroy()
    for _, m in ipairs(scripts) do
        pcall(function() if m.destroy then m.destroy() end end)
    end
end

return Misc
