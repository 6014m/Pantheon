-- System / "Pantheon" container: global utilities.
--
-- Auto Re-Execute: when on, re-runs the Pantheon bundle on respawn. Pantheon's
-- render binds + hooks already survive respawn (they re-resolve LocalPlayer.
-- Character each frame), but some games reset state on death in ways that leave
-- a feature half-broken; re-executing gives a clean reboot. Re-exec tears down
-- the previous instance first (init.lua's getgenv().Pantheon.shutdown), so there
-- are never stacked GUIs / listeners. Persisted, so it survives the reload it
-- triggers and keeps going every subsequent respawn.
--
-- Re-Execute Now: the same reload on demand (cog button).

local feature    = require("ui.feature")
local window     = require("ui.window")
local container  = require("ui.container")
local components = require("ui.components")
local notify     = require("ui.notify")
local log        = require("core.log")

local Players = game:GetService("Players")

local System = {}

-- The released bundle. ?v=tick() busts Wave's aggressive HttpGet cache so a
-- re-exec actually pulls the latest push, not a stale copy.
local DIST_URL = "https://raw.githubusercontent.com/6014m/Pantheon/main/dist/main.lua"

local s = { auto = false, conn = nil }

local function reexec()
    task.spawn(function()
        local ok, src = pcall(function()
            return game:HttpGet(DIST_URL .. "?v=" .. tostring(tick()))
        end)
        if not ok or type(src) ~= "string" or #src == 0 then
            notify.warn("Re-execute: download failed")
            return
        end
        local fn, err = loadstring(src)
        if not fn then
            notify.warn("Re-execute: compile failed")
            log.warn("reexec compile: " .. tostring(err))
            return
        end
        local rok, rerr = pcall(fn)
        if not rok then log.warn("reexec run: " .. tostring(rerr)) end
    end)
end
System.reexec = reexec

local function setAuto(v)
    s.auto = v and true or false
    if s.conn then s.conn:Disconnect(); s.conn = nil end
    if s.auto then
        s.conn = Players.LocalPlayer.CharacterAdded:Connect(function()
            -- let the new character settle before reloading; re-check the flag
            -- after the wait in case the user toggled it off in between.
            task.wait(1.5)
            if s.auto then reexec() end
        end)
    end
end

function System.register()
    local box = container.new(window.parent(), "Pantheon")
    box:add(feature.declare({
        id          = "system.auto_reexec",
        name        = "Auto Re-Execute",
        description = "Re-runs Pantheon automatically after you respawn (clean reboot; re-fetches the latest build). Off by default. Use 'Re-Execute Now' in this panel to reload on demand.",
        default     = false,
        onToggle    = setAuto,
        settings    = {
            { type = "button", name = "Re-Execute Now", onClick = function() reexec() end },
        },
    }).root)
    log.info("System module registered")
end

function System.destroy()
    if s.conn then s.conn:Disconnect(); s.conn = nil end
end

return System
