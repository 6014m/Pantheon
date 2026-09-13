-- System / "Pantheon" container: global utilities.
--
-- Auto Re-Execute (teleport persistence): a Roblox teleport (e.g. JJS lobby ->
-- a match) drops every executor script. queue_on_teleport asks the executor to
-- run a payload after the next teleport; our payload waits for the new place to
-- load, then re-loadstrings the Pantheon bundle so the hub follows you across
-- teleports. Ported from the legacy lock-on script:
--   METHOD 1 -- queue once at startup (covers executors that need the queue set
--               before the teleport).
--   METHOD 2 -- re-queue when Player.OnTeleport fires Started, and flush settings
--               first so the new place loads your latest toggles.
--
-- Re-Execute Now: reload the latest bundle on demand (cog button).

local feature    = require("ui.feature")
local window     = require("ui.window")
local container  = require("ui.container")
local persist    = require("core.persist")
local notify     = require("ui.notify")
local log        = require("core.log")

local Players = game:GetService("Players")

local System = {}

-- The released bundle. ?v=tick() busts Wave's aggressive HttpGet cache -- but
-- NOT GitHub's raw CDN, which ignores the query string and serves the branch
-- path stale for up to 5 minutes after a push. So the bundle is fetched by
-- COMMIT SHA (a path the CDN has never seen = always the real latest): ask the
-- GitHub API for main's head, then load raw/<sha>/dist/main.lua. Falls back to
-- the branch path if the API is unreachable / rate-limited (60/hr unauth).
local REPO_API = "https://api.github.com/repos/6014m/Pantheon/commits/main"
local RAW_BASE = "https://raw.githubusercontent.com/6014m/Pantheon/"
local DIST_URL = RAW_BASE .. "main/dist/main.lua"
local function resolveDistUrl()
    local ok, r = pcall(function() return game:HttpGet(REPO_API) end)
    local sha = ok and type(r) == "string" and r:match('"sha"%s*:%s*"(%x+)"') or nil
    return RAW_BASE .. (sha or "main") .. "/dist/main.lua?v=" .. tostring(tick())
end

-- queue_on_teleport varies by executor. Undefined names resolve to nil safely,
-- so this just picks the first one that exists.
local queueteleport = queue_on_teleport
    or (syn and syn.queue_on_teleport)
    or (fluxus and fluxus.queue_on_teleport)
    or (getgenv and getgenv().queue_on_teleport)

-- Payload run in the NEW place after a teleport. Same SHA-pinned resolve as
-- resolveDistUrl(), written out as source text so it evaluates at re-exec
-- time in the destination place (long string: no escaping to get wrong).
local PAYLOAD = [[
repeat task.wait() until game:IsLoaded()
task.wait(2)
pcall(function()
    local ok, r = pcall(function() return game:HttpGet("]] .. REPO_API .. [[") end)
    local sha = ok and type(r) == "string" and r:match('"sha"%s*:%s*"(%x+)"') or "main"
    loadstring(game:HttpGet("]] .. RAW_BASE .. [[" .. sha .. "/dist/main.lua?v=" .. tostring(tick())))()
end)
]]

local s = { auto = false, tpConn = nil }

-- Manual reload (cog button): re-run the latest bundle right now. The bundle's
-- own teardown (getgenv().Pantheon.shutdown) replaces the current instance.
local function reexecNow()
    task.spawn(function()
        local ok, src = pcall(function()
            return game:HttpGet(resolveDistUrl())
        end)
        if not ok or type(src) ~= "string" or #src == 0 then
            notify.warn("Re-execute: download failed"); return
        end
        local fn, err = loadstring(src)
        if not fn then
            notify.warn("Re-execute: compile failed"); log.warn("reexec compile: " .. tostring(err)); return
        end
        local rok, rerr = pcall(fn)
        if not rok then log.warn("reexec run: " .. tostring(rerr)) end
    end)
end
System.reexec = reexecNow

-- "Unload Pantheon": the user-facing unexecute. Two-click confirm because the
-- button sits right next to "Re-Execute Now" -- a misclick here would otherwise
-- nuke the whole hub. Delegates to the bundle's full teardown + global-erase
-- (genv.Pantheon.unload), with a hand-rolled fallback for older bundles.
local unloadArmed = false
local function unloadPantheon()
    if not unloadArmed then
        unloadArmed = true
        notify.warn("Click 'Unload Pantheon' again to fully remove the hub.")
        task.delay(4, function() unloadArmed = false end)
        return
    end
    unloadArmed = false
    local genv = (getgenv and getgenv()) or _G
    if genv.Pantheon and type(genv.Pantheon.unload) == "function" then
        genv.Pantheon.unload()
    elseif genv.Pantheon and type(genv.Pantheon.shutdown) == "function" then
        pcall(genv.Pantheon.shutdown)
        genv.Pantheon          = nil
        genv.PANTHEON_TP_QUEUED = nil
    end
end

local function queuePayload()
    if not queueteleport then return false end
    return (pcall(queueteleport, PAYLOAD))
end

local function setAuto(v)
    s.auto = v and true or false
    local genv = (getgenv and getgenv()) or _G

    if s.auto then
        if not queueteleport then
            notify.warn("Teleport persistence: your executor has no queue_on_teleport")
            return
        end
        -- METHOD 1: queue once per executor session. Re-exec'd instances (after a
        -- teleport) see the persisted getgenv flag and skip; METHOD 2 carries the
        -- chain forward on each subsequent teleport.
        if not genv.PANTHEON_TP_QUEUED then
            if queuePayload() then genv.PANTHEON_TP_QUEUED = true end
        end
        -- METHOD 2: re-queue + flush settings the moment a teleport starts.
        if not s.tpConn then
            s.tpConn = Players.LocalPlayer.OnTeleport:Connect(function(st)
                if st == Enum.TeleportState.Started and s.auto then
                    pcall(function() persist.flush() end)
                    queuePayload()
                end
            end)
        end
    else
        if s.tpConn then s.tpConn:Disconnect(); s.tpConn = nil end
        -- An already-registered payload can't be un-queued on most executors, but
        -- METHOD 2 won't re-queue and the next teleport's instance will boot with
        -- the toggle persisted off, so the chain stops there.
    end
end

function System.register()
    local box = container.new(window.parent(), "Pantheon")
    box:add(feature.declare({
        id          = "system.auto_reexec",
        name        = "Auto Re-Execute (teleport)",
        description = "Re-runs Pantheon automatically after a Roblox teleport (e.g. JJS lobby to a match) so the hub follows you. Uses your executor's queue_on_teleport. Use 'Re-Execute Now' to reload the latest build on demand, or 'Unload Pantheon' to fully remove the hub (un-execute) -- it tears everything down and clears its globals so the game is left clean.",
        default     = true,
        onToggle    = setAuto,
        settings    = {
            { type = "button", name = "Re-Execute Now", onClick = function() reexecNow() end },
            { type = "button", name = "Unload Pantheon", onClick = function() unloadPantheon() end },
        },
    }).root)
    log.info("System module registered")
end

function System.destroy()
    if s.tpConn then s.tpConn:Disconnect(); s.tpConn = nil end
end

return System
