-- Aim Assist wiring: brings up targeting / lockon / lockon+ / highlight / shiftlock
-- and registers the UI tab.

local state       = require("modules.aim.state")
local components  = require("ui.components")
local highlight   = require("modules.aim.highlight")
local shiftlock   = require("modules.aim.shiftlock")
local lockon_plus = require("modules.aim.lockon_plus")
local lockon      = require("modules.aim.lockon")
local log         = require("core.log")

local module = {}

function module.register(window)
    -- Boot sub-systems
    highlight.init()
    shiftlock.init()
    lockon_plus.init()
    lockon.init()

    -- Shiftlock yields rotation to LockOn+ while LockOn+ is driving
    shiftlock.setExternalSkipRotation(lockon_plus.isActive)

    local tab = window:AddTab("Aim Assist")

    -- Shiftlock ------------------------------------------------------------
    components.Section(tab, "Shiftlock")
    components.Toggle(tab, {
        text     = "Custom Shiftlock",
        default  = false,
        onChange = function(v) shiftlock.setEnabled(v) end,
    })
    components.Toggle(tab, {
        text     = "Kill foreign shiftlock GUIs on enable",
        default  = true,
        onChange = function(v) state.killForeign = v end,
    })
    components.Button(tab, {
        text    = "Toggle Shiftlock Now",
        onClick = function() shiftlock.toggle() end,
    })

    -- Lock-on --------------------------------------------------------------
    components.Section(tab, "Lock-On")
    components.Toggle(tab, {
        text     = "Enable Lock-On (hotkey E)",
        default  = false,
        onChange = function(v) lockon.setEnabled(v) end,
    })
    components.Toggle(tab, {
        text     = "Hold mode (vs toggle)",
        default  = false,
        onChange = function(v) lockon.setHoldMode(v) end,
    })
    components.Toggle(tab, {
        text     = "Realistic FOV (60 deg)",
        default  = false,
        onChange = function(v) state.realisticEnabled = v end,
    })
    components.Toggle(tab, {
        text     = "Skip dead / shielded",
        default  = true,
        onChange = function(v) state.checkHealthEnabled = v end,
    })
    components.Toggle(tab, {
        text     = "Require visibility (raycast)",
        default  = false,
        onChange = function(v) state.visibilityCheckEnabled = v end,
    })
    components.Slider(tab, {
        text     = "Range limit (0 = infinite)",
        min      = 0,
        max      = 500,
        default  = 0,
        step     = 5,
        onChange = function(v) state.rangeLimit = v end,
    })

    -- Highlight ------------------------------------------------------------
    components.Section(tab, "Highlight")
    components.Toggle(tab, {
        text     = "Highlight target (red)",
        default  = true,
        onChange = function(v) highlight.setEnabled(v) end,
    })
    components.Toggle(tab, {
        text     = "Highlight next-best (yellow)",
        default  = false,
        onChange = function(v) highlight.setSecondEnabled(v) end,
    })
    components.Toggle(tab, {
        text     = "Self-fade",
        default  = false,
        onChange = function(v) highlight.setSelfFade(v) end,
    })

    -- Lock-on+ -------------------------------------------------------------
    components.Section(tab, "Lock-On+")
    components.Toggle(tab, {
        text     = "Enable Lock-On+ (rotate body to target)",
        default  = false,
        onChange = function(v) state.lockonPlusEnabled = v end,
    })
    components.Toggle(tab, {
        text     = "Battlegrounds-safe (suppress on ragdoll)",
        default  = true,
        onChange = function(v) state.bgSafeEnabled = v end,
    })

    log.info("Aim Assist registered")
end

return module
