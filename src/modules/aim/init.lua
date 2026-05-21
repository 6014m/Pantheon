-- Aim Assist: declarative feature definitions across three categories.
-- Target Select picks the target, Lock-On applies aim assist (camera + rotation
-- sub-toggles), Highlight reflects the selected target.

local window       = require("ui.window")
local container    = require("ui.container")
local feature      = require("ui.feature")
local state        = require("modules.aim.state")
local highlight    = require("modules.aim.highlight")
local shiftlock    = require("modules.aim.shiftlock")
local rotationLock = require("modules.aim.rotation_lock")
local lockon       = require("modules.aim.lockon")
local targetSelect = require("modules.aim.target_select")
local log          = require("core.log")

local module = {}

function module.register()
    -- Boot the implementations
    highlight.init()
    shiftlock.init()
    rotationLock.init()
    lockon.init()
    targetSelect.init()
    shiftlock.setExternalSkipRotation(rotationLock.isActive)

    local parent = window.parent()

    -- 1. Movement -------------------------------------------------------------
    local move = container.new(parent, "Movement")
    move:add(feature.declare({
        id          = "aim.shiftlock",
        name        = "Custom Shiftlock",
        description = "Locks your mouse to the center of the screen and rotates your character to face the camera. Replaces Roblox's built-in shift-lock and disconnects competing shift-lock loops from other scripts on enable, disable, and boot.",
        default     = false,
        defaultKey  = Enum.KeyCode.LeftShift,
        onToggle    = function(v) shiftlock.setEnabled(v) end,
        -- Key only toggles the lock when the feature master toggle is on.
        -- shiftlock.toggle() returns early otherwise, matching target_select
        -- and rotation_lock's pattern. Previously this auto-enabled the
        -- feature on Shift press, which made walking silently turn shiftlock
        -- on while the UI button still showed OFF.
        onKey       = function() shiftlock.toggle() end,
        settings = {
            { type = "toggle", name = "Kill foreign shiftlock GUIs / loops", default = true,
              onChange = function(v) state.killForeign = v end },
            -- Off => rotation still fires through grab welds. Lets you keep
            -- aiming during nerf-style moves that lock your camera by
            -- welding your HRP to the victim (JJS, etc). On (default) =>
            -- keep the safety so grab moves don't drag the welded player.
            { type = "toggle", name = "Skip rotation while welded to enemy",
              key = "weld_safety", default = true,
              onChange = function(v) state.weldSafetyEnabled = v end },
        },
    }).root)

    -- 2. Combat ---------------------------------------------------------------
    local combat = container.new(parent, "Combat")

    -- Target Select: owns the X hotkey, picks targets, triggers Highlight.
    combat:add(feature.declare({
        id           = "aim.target_select",
        name         = "Target Select",
        description  = "Picks the nearest valid target (with optional FOV / health / visibility / range filters) and triggers the Highlight. Lock-On and Rotation Lock read the chosen target. Hold-mode releases when you release the key; toggle-mode latches.",
        default      = false,
        defaultKey   = Enum.KeyCode.X,
        onToggle     = function(v) targetSelect.setEnabled(v) end,
        onKey        = function() targetSelect.hotkeyPress()   end,
        onKeyRelease = function() targetSelect.hotkeyRelease() end,
        settings = {
            { type = "toggle", name = "Hold mode (vs toggle)", default = false,
              onChange = function(v) targetSelect.setHoldMode(v) end },
            { type = "toggle", name = "Skip dead / shielded", default = true,
              onChange = function(v) state.checkHealthEnabled = v end },
            { type = "slider", name = "Range (0 = inf)",
              min = 0, max = 500, step = 5, default = 0,
              onChange = function(v) state.rangeLimit = v end },
        },
    }).root)

    -- Lock-On: aim-assist applicator. Master toggle plus sub-toggles for
    -- Camera Lock and Rotation Lock so the user can mix-and-match.
    -- Depends on Target Select (needs a target to lock onto).
    combat:add(feature.declare({
        id           = "aim.lockon",
        name         = "Lock-On",
        description  = "Applies aim assist to the target picked by Target Select. Sub-toggles let you mix the type: Camera Lock forces the camera to look at the target, Rotation Lock (its own keybind) spins your body to face them. Resistance gives you a free-aim deadzone before the camera pull kicks in.",
        default      = false,
        dependencies = { "aim.target_select" },
        onToggle     = function(v) lockon.setEnabled(v) end,
        settings = {
            { type = "section", name = "Types" },
            { type = "toggle", name = "Camera Lock", default = true,
              onChange = function(v) state.cameraLockEnabled = v end },
            { type = "toggle", name = "Rotation Lock", default = false,
              onChange = function(v) rotationLock.setEnabled(v) end },
            { type = "keybind", name = "Rotation Lock key",
              id       = "aim.rotation_lock",
              default  = Enum.KeyCode.Q,
              onPress  = function() rotationLock.hotkeyPress()   end,
              onRelease= function() rotationLock.hotkeyRelease() end },
            { type = "toggle", name = "Rotation Lock hold mode", default = true,
              onChange = function(v) rotationLock.setHoldMode(v) end },
            { type = "toggle", name = "Battlegrounds-safe", default = true,
              onChange = function(v) state.bgSafeEnabled = v end },

            { type = "section", name = "Resistance" },
            { type = "toggle", name = "Enable Resistance", default = false,
              onChange = function(v) state.resistance_enabled = v end },
            { type = "slider", name = "Threshold (deg)",
              min = 0, max = 30, step = 1, default = 5,
              onChange = function(v) state.resistance_threshold = v end },
            { type = "slider", name = "Strength",
              min = 0.05, max = 1, step = 0.05, default = 0.5,
              onChange = function(v) state.resistance_strength = v end },
        },
    }).root)

    -- Swap Target: cycles to the next-best target while Target Select is engaged.
    -- Depends on Target Select (nothing to swap from without a current target).
    combat:add(feature.declare({
        id           = "aim.swap_target",
        name         = "Swap Target",
        description  = "While Target Select has a target, press this key to cycle to the next-best target.",
        default      = true,
        defaultKey   = Enum.KeyCode.C,
        dependencies = { "aim.target_select" },
        onToggle     = function(v) state.swap_enabled = v end,
        onKey        = function() targetSelect.swapTarget() end,
    }).root)

    -- 3. Visuals --------------------------------------------------------------
    -- Highlight depends on Target Select (renders nothing without a target).
    local vis = container.new(parent, "Visuals")
    vis:add(feature.declare({
        id           = "aim.highlight",
        name         = "Highlight",
        description  = "Outlines whichever target Target Select picks: red on the active target, optional yellow on the next-best. Self-fade drops your own character's opacity so you don't get blocked by your own back.",
        default      = true,
        dependencies = { "aim.target_select" },
        onToggle     = function(v) highlight.setEnabled(v) end,
        settings = {
            { type = "toggle", name = "Highlight next-best (yellow)", default = false,
              onChange = function(v) highlight.setSecondEnabled(v) end },
            { type = "toggle", name = "Self-fade", default = false,
              onChange = function(v) highlight.setSelfFade(v) end },
        },
    }).root)

    log.info("Aim Assist registered (Movement / Combat / Visuals)")
end

function module.destroy()
    pcall(function() if targetSelect.destroy then targetSelect.destroy() end end)
    pcall(function() if rotationLock.destroy then rotationLock.destroy() end end)
    pcall(function() if lockon.destroy       then lockon.destroy()       end end)
    pcall(function() if shiftlock.destroy    then shiftlock.destroy()    end end)
    pcall(function() if highlight.destroy    then highlight.destroy()    end end)
end

return module
