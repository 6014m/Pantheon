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
local bot          = require("modules.aim.bot")
local log          = require("core.log")

local module = {}

function module.register()
    -- Boot the implementations
    highlight.init()
    shiftlock.init()
    rotationLock.init()
    lockon.init()
    targetSelect.init()
    bot.init()
    -- Shiftlock's rotation pin yields while Rotation Lock drives the body so
    -- the two don't fight over the character's facing.
    shiftlock.setExternalSkipRotation(function()
        return rotationLock.isActive()
    end)

    -- Expose Lock-On's sub-toggles to the Tech Builder's "Use" step (they aren't
    -- standalone feature rows, so feature.all() wouldn't list them otherwise).
    feature.addInvokable({
        id   = "aim.rotationlock",
        name = "Rotation Lock (Lock-On+)",
        get  = function() return state.rotationLockEnabled and rotationLock.isActive() end,
        set  = function(v)
            rotationLock.setEnabled(v)
            if v then rotationLock.hotkeyPress() else rotationLock.hotkeyRelease() end
        end,
    })
    feature.addInvokable({
        id   = "aim.cameralock",
        name = "Camera Lock",
        get  = function() return state.cameraLockEnabled end,
        set  = function(v) state.cameraLockEnabled = v and true or false end,
    })

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
            -- Pair WITH the game's own shiftlock instead of running a competing one:
            -- Pantheon syncs its on/off to the game's and keeps rotating, but lets
            -- the game own the cursor (no fight). Turn on in games with their own
            -- shiftlock, e.g. JJS (the JJS module auto-enables it). Off => Pantheon
            -- runs its own standalone shiftlock.
            { type = "toggle", name = "Pair with game's shiftlock",
              key = "mirror", default = false,
              onChange = function(v) shiftlock.setShiftlockMirror(v) end },
            { type = "toggle", name = "Kill foreign shiftlock GUIs / loops", default = true,
              onChange = function(v) shiftlock.setKillForeign(v) end },
            -- Off (default) => rotation fires through grab welds, matching
            -- the normal-player behavior in games like JJS where Decisive
            -- Strikes welds the victim but the game doesn't lock rotation.
            -- Game-imposed lock states (bleedout / PlatformStand / Ragdoll
            -- / Physics / Dead) are already caught further up the rotation
            -- pass. On => Battlegrounds-style safety: skip rotation while
            -- welded so the victim isn't dragged around with you.
            { type = "toggle", name = "Skip rotation while welded to enemy",
              key = "weld_safety", default = false,
              onChange = function(v) state.weldSafetyEnabled = v end },
            -- On => when Pantheon shiftlock is off, yield the pin pass +
            -- hook so the game's own shiftlock (custom in-game script or
            -- Roblox's vanilla MouseLockController) can drive the cursor.
            -- Pantheon still fully owns cursor state while its own
            -- shiftlock is on. Off (default) => Pantheon enforces free
            -- movement when its shiftlock is off; no game shiftlock.
            { type = "toggle", name = "Allow game shiftlock when Pantheon off",
              key = "allow_game", default = false,
              onChange = function(v) shiftlock.setAllowGameShiftlock(v) end },
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

            -- Aim lead: lockon's camera + rotation_lock's body both shift
            -- their aim by (target.AssemblyLinearVelocity * lead). With
            -- Auto on, the lead self-tunes from the TARGET'S TANGENTIAL
            -- VELOCITY RELATIVE TO YOU (the orbit/strafe part the camera
            -- must rotate to chase) -- pumps up for fast players + skilled
            -- close orbits (high angular rate), drops to zero for stationary
            -- or charging-at-you targets. The slider below is the manual
            -- fallback used only when Auto is off.
            { type = "toggle", name = "Auto prediction (velocity-based)", default = true,
              onChange = function(v) state.predictionAuto = v end },
            -- Below this tangential speed (stud/s, orbit/strafe component
            -- relative to you), auto prediction returns 0 lead -- so casual
            -- walking targets don't get pre-judged. Persists via feature.lua
            -- like every other slider in this panel.
            { type = "slider", name = "Auto prediction threshold (stud/s)",
              key = "prediction_threshold", min = 0, max = 50, step = 1, default = 20,
              onChange = function(v) state.predictionThreshold = v end },
            { type = "slider", name = "Aim prediction (s, manual)",
              key = "prediction", min = 0, max = 0.3, step = 0.01, default = 0.1,
              onChange = function(v) state.predictionTime = v end },

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

    -- Bot Mode: hands-free auto-combat. Auto-acquires the nearest enemy and keeps
    -- it locked so the aim stack (camera / rotation) tracks it without holding the
    -- Target Select key. Depends on Lock-On (which depends on Target Select), so
    -- one toggle turns the whole aim stack on. Friendlies are skipped automatically.
    combat:add(feature.declare({
        id           = "aim.bot",
        name         = "Bot Mode",
        description  = "Hands-free auto-combat. Continuously locks onto the nearest valid (non-friendly) enemy and keeps it engaged so Lock-On tracks it without holding the Target Select key. Turn on Rotation Lock (in Lock-On) too if you want your body to face them for melee. Optional Auto-attack fires left-clicks on an interval. Mark teammates in the Friendlies panel so the bot ignores them.",
        default      = false,
        defaultKey   = Enum.KeyCode.B,
        dependencies = { "aim.lockon" },
        onToggle     = function(v) bot.setEnabled(v) end,
        settings = {
            { type = "toggle", name = "Auto-attack (left click)", key = "auto_attack", default = false,
              onChange = function(v) bot.setAutoAttack(v) end },
            { type = "slider", name = "Attack interval (s)", key = "attack_interval",
              min = 0.1, max = 1, step = 0.05, default = 0.4,
              onChange = function(v) bot.setAttackInterval(v) end },
            { type = "toggle", name = "Re-acquire on target death", key = "reacquire", default = true,
              onChange = function(v) bot.setReacquire(v) end },
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
        description  = "Target visuals: red outline on the active target, yellow on the swap target (the next-best one Swap Target would cycle to), and a top-center HUD showing the current target's name + a live health bar. Self-fade drops your own character's opacity so you don't get blocked by your own back.",
        default      = true,
        dependencies = { "aim.target_select" },
        onToggle     = function(v) highlight.setEnabled(v) end,
        settings = {
            { type = "toggle", name = "Highlight swap target (yellow)", key = "swap_highlight", default = true,
              onChange = function(v) highlight.setSecondEnabled(v) end },
            { type = "toggle", name = "Target info (health bar + name)", key = "target_info", default = true,
              onChange = function(v) highlight.setTargetInfo(v) end },
            { type = "toggle", name = "Self-fade", default = false,
              onChange = function(v) highlight.setSelfFade(v) end },
        },
    }).root)

    log.info("Aim Assist registered (Movement / Combat / Visuals)")
end

function module.destroy()
    pcall(function() if bot.destroy          then bot.destroy()          end end)
    pcall(function() if targetSelect.destroy then targetSelect.destroy() end end)
    pcall(function() if rotationLock.destroy then rotationLock.destroy() end end)
    pcall(function() if lockon.destroy       then lockon.destroy()       end end)
    pcall(function() if shiftlock.destroy    then shiftlock.destroy()    end end)
    pcall(function() if highlight.destroy    then highlight.destroy()    end end)
end

return module
