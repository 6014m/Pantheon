-- Example universal module: walk speed / jump power / notify demo.
-- Acts as a template for new modules and a smoke test for the UI primitives.

local components = require("ui.components")
local notify     = require("ui.notify")

local Players = game:GetService("Players")

local function setHumanoid(prop, value)
    local char = Players.LocalPlayer.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    if prop == "JumpPower" then hum.UseJumpPower = true end
    hum[prop] = value
end

local module = {}

function module.register(window)
    local tab = window:AddTab("Movement")

    components.Section(tab, "Locomotion")
    components.Slider(tab, {
        text    = "WalkSpeed",
        min     = 16,
        max     = 200,
        default = 16,
        step    = 1,
        onChange = function(v) setHumanoid("WalkSpeed", v) end,
    })
    components.Slider(tab, {
        text    = "JumpPower",
        min     = 50,
        max     = 500,
        default = 50,
        step    = 1,
        onChange = function(v) setHumanoid("JumpPower", v) end,
    })

    components.Section(tab, "Demo")
    components.Button(tab, {
        text    = "Test notification",
        onClick = function() notify.success("Hello from Pantheon.") end,
    })
end

return module
