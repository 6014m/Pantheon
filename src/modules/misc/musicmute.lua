-- Mute Music: silences background music in any game, on your client only, and keeps it silent.
--
-- "Music" = a Sound that is long (a track, not an effect) or is named like music. Sound effects,
-- footsteps and short warning loops (a heartbeat when you're being chased) are left alone -- they
-- are short. A game's own "mute music" setting often doesn't stick between sessions or misses
-- some tracks; this doesn't depend on it.
--
-- How: the Sound's Volume is set to 0 and held there (games fade their music in with tweens, so
-- every change is put back to 0). The original volume is remembered and restored when the
-- feature is turned off. Nothing is created, destroyed, stopped or re-parented.

local feature = require("ui.feature")
local log     = require("core.log")

local MusicMute = {}

local CFG = { enabled = false, minLength = 20 }
local NAME_HINTS = { "music", "soundtrack", "theme", "bgm", "ost", "song", "radio", "jukebox" }

local tracked = setmetatable({}, { __mode = "k" })   -- Sound -> { volume, conns, muted }
local conns = {}
local muting = false     -- true while WE are writing Volume (so our own write isn't "the game changed it")

local function nameHint(snd)
    local n = string.lower(snd.Name)
    local p = snd.Parent and string.lower(snd.Parent.Name) or ""
    for _, w in ipairs(NAME_HINTS) do
        if string.find(n, w, 1, true) or string.find(p, w, 1, true) then return true end
    end
    return false
end

local function isMusic(snd)
    if nameHint(snd) then return true end
    return snd.TimeLength >= CFG.minLength
end

local function hold(snd, rec)
    if not CFG.enabled or not isMusic(snd) then return end
    if snd.Volume ~= 0 then
        if not rec.muted then rec.volume = snd.Volume end   -- what the game wants it at
        muting = true
        pcall(function() snd.Volume = 0 end)
        muting = false
    end
    if not rec.muted then
        rec.muted = true
        log.info("[MuteMusic] muted " .. snd:GetFullName() .. string.format(" (%.0f s)", snd.TimeLength))
    end
end

local function track(snd)
    if tracked[snd] then return end
    local rec = { volume = snd.Volume, conns = {}, muted = false }
    tracked[snd] = rec
    -- the length isn't known until the audio has loaded
    rec.conns[#rec.conns + 1] = snd:GetPropertyChangedSignal("TimeLength"):Connect(function() hold(snd, rec) end)
    rec.conns[#rec.conns + 1] = snd:GetPropertyChangedSignal("SoundId"):Connect(function()
        rec.muted = false                      -- a different track now: judge it again
        hold(snd, rec)
    end)
    rec.conns[#rec.conns + 1] = snd:GetPropertyChangedSignal("Volume"):Connect(function()
        if muting then return end
        if rec.muted and snd.Volume ~= 0 then rec.volume = snd.Volume end   -- the game's new target volume
        hold(snd, rec)
    end)
    hold(snd, rec)
end

local function release(snd, rec)
    for _, c in ipairs(rec.conns) do pcall(function() c:Disconnect() end) end
    if rec.muted and snd.Parent then
        muting = true
        pcall(function() snd.Volume = rec.volume end)
        muting = false
    end
end

local function start()
    local ok, all = pcall(game.GetDescendants, game)
    if not ok then      -- some executors refuse a whole-game walk: go service by service
        all = {}
        for _, name in ipairs({ "Workspace", "SoundService", "ReplicatedFirst", "ReplicatedStorage", "Lighting", "Players" }) do
            local got, list = pcall(function() return game:GetService(name):GetDescendants() end)
            if got then for _, d in ipairs(list) do all[#all + 1] = d end end
        end
    end
    for _, d in ipairs(all) do
        if d:IsA("Sound") then pcall(track, d) end
    end
    conns[#conns + 1] = game.DescendantAdded:Connect(function(d)
        if d:IsA("Sound") then pcall(track, d) end
    end)
end

local function stop()
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)
    for snd, rec in pairs(tracked) do release(snd, rec) end
    table.clear(tracked)
end

local function setEnabled(v)
    v = v and true or false
    if CFG.enabled == v then return end
    CFG.enabled = v
    if v then start() else stop() end
end

function MusicMute.register(box)
    box:add(feature.declare({
        id          = "misc.mute_music",
        name        = "Mute Music",
        description = "Silences background music in whatever game you're in, automatically and only for you: any sound that is a long track (or is named like music) is held at zero volume, including tracks that start later. Sound effects and short loops are left alone. Turning it off puts every volume back.",
        default     = false,
        onToggle    = setEnabled,
        settings = {
            { type = "slider", name = "Counts as music if longer than (seconds)", key = "min_length",
              min = 5, max = 120, step = 5, default = 20,
              onChange = function(v)
                  CFG.minLength = v
                  if not CFG.enabled then return end
                  for snd, rec in pairs(tracked) do      -- re-judge everything against the new length
                      if rec.muted and not isMusic(snd) then
                          rec.muted = false
                          muting = true
                          pcall(function() snd.Volume = rec.volume end)
                          muting = false
                      else
                          hold(snd, rec)
                      end
                  end
              end },
        },
    }).root)
    log.info("Mute Music feature registered")
end

function MusicMute.destroy()
    CFG.enabled = false
    stop()
end

return MusicMute
