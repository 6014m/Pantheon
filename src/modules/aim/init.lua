-- Aim Assist: declarative feature definitions. Implementations live in their
-- own files; this file wires them into the Wurst-style UI via feature.declare.

local window      = require("ui.window")
local container   = require("ui.container")
local feature     = require("ui.feature")
local state       = require("modules.aim.state")
local highlight   = require("modules.aim.highlight")
local shiftlock   = require("modules.aim.shiftlock")
local lockon_plus = require("modules.aim.lockon_plus")
local lockon      = require("modules.aim.lockon")
local log         = require("core.log")

local module = {}

function module.register()
    -- Boot the implementations
    highlight.init()
    shiftlock.init()
    lockon_plus.init()
    lockon.init()
    shiftlock.setExternalSkipRotation(lockon_plus.isActive)

    -- Build the Aim Assist container
    local cat = container.new(window.parent(), "Aim Assist")

    -- Custom Shiftlock --------------------------------------------------------
    cat:add(feature.declare({
        id         = "aim.shiftlock",
        name       = "Custom Shiftlock",
        default    = false,
        defaultKey = Enum.KeyCode.LeftShift,
        onToggle   = function(v) shiftlock.setEnabled(v) end,
        onKey      = function()
            if not state.shiftlock_enabled then
                shiftlock.setEnabled(true)
            end
            shiftlock.toggle()
        end,
        settings = {
            { type = "toggle", name = "Kill foreign shiftlock GUIs", default = true,
              onChange = function(v) state.killForeign = v end },
        },
    }).root)

    -- Lock-On -----------------------------------------------------------------
    cat:add(feature.declare({
        id           = "aim.lockon",
        name         = "Lock-On",
        default      = false,
        defaultKey   = Enum.KeyCode.E,
        onToggle     = function(v) lockon.setEnabled(v) end,
        onKey        = function() lockon.hotkeyPress()   end,
        onKeyRelease = function() lockon.hotkeyRelease() end,
        settings = {
            { type = "toggle", name = "Hold mode (vs toggle)", default = false,
              onChange = function(v) lockon.setHoldMode(v) end },
            { type = "toggle", name = "Realistic FOV (60 deg)", default = false,
              onChange = function(v) state.realisticEnabled = v end },
            { type = "toggle", name = "Skip dead / shielded", default = true,
              onChange = function(v) state.checkHealthEnabled = v end },
            { type = "toggle", name = "Require visibility (raycast)", default = false,
              onChange = function(v) state.visibilityCheckEnabled = v end },
            { type = "slider", name = "Range (0 = inf)",
              min = 0, max = 500, step = 5, default = 0,
              onChange = function(v) state.rangeLimit = v end },
        },
    }).root)

    -- Highlight ---------------------------------------------------------------
    cat:add(feature.declare({
        id       = "aim.highlight",
        name     = "Highlight",
        default  = true,
        onToggle = function(v) highlight.setEnabled(v) end,
        settings = {
            { type = "toggle", name = "Highlight next-best (yellow)", default = false,
              onChange = function(v) highlight.setSecondEnabled(v) end },
            { type = "toggle", name = "Self-fade", default = false,
              onChange = function(v) highlight.setSelfFade(v) end },
        },
    }).root)

    -- Lock-On+ ----------------------------------------------------------------
    cat:add(feature.declare({
        id       = "aim.lockon_plus",
        name     = "Lock-On+",
        default  = false,
        onToggle = function(v) state.lockonPlusEnabled = v end,
        settings = {
            { type = "toggle", name = "Battlegrounds-safe", default = true,
              onChange = function(v) state.bgSafeEnabled = v end },
        },
    }).root)

    log.info("Aim Assist registered")
end

return module
