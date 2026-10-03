-- Huss Valley: Anti AFK. The game puts you in "AFK" (sitting matches out) when you tab out
-- (user, 2026-10-03). What its scripts show:
--   * AFK is the Player attribute `AFK` (true = "Sitting this match out").
--   * You toggle it yourself with K or the lobby's AFK button -- the client then asks the server
--     (PlayerPreferences "SetAFK"). So pressing K while AFK is on turns it back off.
--   * WHAT flips it when you tab out was not in the scripts that decompiled. The only
--     focus-loss handler found (LobbyControlsClient) just releases the cursor.
-- So this works from three sides, none of which needs to know the exact trigger:
--   1. UNDO: when AFK turns on while the Roblox window is NOT focused (or within 2 s of coming
--      back) it presses K for you until the game says AFK is off. An AFK you switch on yourself
--      with the window focused is left alone.
--   2. HIDE (optional, needs the executor's getconnections): the game's own scripts stop being
--      told that the window lost focus. Roblox's core scripts are not touched.
--   3. The usual 20-minute idle kick is answered the standard way (VirtualUser).

local Players     = game:GetService("Players")
local UIS         = game:GetService("UserInputService")
local VIM         = game:GetService("VirtualInputManager")

local log    = require("core.log")
local notify = require("ui.notify")

local LP = Players.LocalPlayer

local AntiAfk = {}
local CFG = { enabled = false, hide = true }

local conns = {}
local hidden = {}                 -- game connections we switched off (to switch back on)
local focused, focusAt = true, -math.huge
local busy, running = false, false
local undone = 0

local function onReleased() focused = false end
local function onFocused() focused, focusAt = true, os.clock() end

-- is the Roblox window the active one right now?
local function windowActive()
    local probe = isrbxactive or iswindowactive      -- executor functions, when it has them
    if type(probe) == "function" then
        local ok, v = pcall(probe)
        if ok then return v and true or false end
    end
    return focused
end

local function pressK()
    pcall(function() VIM:SendKeyEvent(true, Enum.KeyCode.K, false, game) end)
    task.wait(0.05)
    pcall(function() VIM:SendKeyEvent(false, Enum.KeyCode.K, false, game) end)
end

local function onAfk()
    if not CFG.enabled or busy or LP:GetAttribute("AFK") ~= true then return end
    -- your own choice: window focused and not just regained
    if windowActive() and os.clock() - focusAt > 2 then
        log.info("[AntiAFK] AFK switched on with the window focused -- left alone (your choice)")
        return
    end
    busy = true
    task.spawn(function()
        for _ = 1, 6 do
            if not CFG.enabled or LP:GetAttribute("AFK") ~= true then break end
            if not UIS:GetFocusedTextBox() then pressK() end
            task.wait(0.7)        -- the game ignores a second toggle within 0.5 s
        end
        busy = false
        if LP:GetAttribute("AFK") ~= true then
            undone += 1
            log.info("[AntiAFK] the game set AFK while you were tabbed out -- switched back off (" .. undone .. ")")
            pcall(notify.info, "Anti AFK: switched AFK back off", 4)
        else
            log.info("[AntiAFK] could not switch AFK off (the game only allows it in the lobby)")
        end
    end)
end

-- Stop the GAME's scripts hearing "window lost focus". Only connections made by game scripts are
-- switched off; anything from Roblox's own core scripts (or another Lua state) is left alone.
local function hideFocusLoss()
    local get = getconnections
    if not CFG.hide or type(get) ~= "function" then return end
    local ok, list = pcall(get, UIS.WindowFocusReleased)
    if not ok or type(list) ~= "table" then return end
    for _, c in ipairs(list) do
        pcall(function()
            local fn = c.Function
            if fn and fn ~= onReleased and not c.ForeignState and c.Enabled ~= false then
                local src = debug.info(fn, "s")
                if type(src) == "string" and not string.find(src, "^Core") and not string.find(src, "Pantheon", 1, true) then
                    c:Disable()
                    hidden[#hidden + 1] = c
                end
            end
        end)
    end
end

local function unhide()
    for _, c in ipairs(hidden) do pcall(function() c:Enable() end) end
    table.clear(hidden)
end

function AntiAfk.start()
    AntiAfk.stop()
    running = true
    focused, focusAt = true, -math.huge
    conns[#conns + 1] = UIS.WindowFocusReleased:Connect(onReleased)
    conns[#conns + 1] = UIS.WindowFocused:Connect(onFocused)
    conns[#conns + 1] = LP:GetAttributeChangedSignal("AFK"):Connect(onAfk)
    conns[#conns + 1] = LP.Idled:Connect(function()
        pcall(function()
            local vu = game:GetService("VirtualUser")
            vu:CaptureController()
            vu:ClickButton2(Vector2.new())
        end)
    end)
    hideFocusLoss()
    task.spawn(function()
        while running do
            task.wait(5)
            if running then
                pcall(hideFocusLoss)      -- the game's GUI scripts are recreated between matches
                pcall(onAfk)              -- and catch an AFK that slipped past while a press was refused
            end
        end
    end)
    onAfk()
    log.info("[AntiAFK] on (" .. #hidden .. " game focus handler(s) hidden)")
end

function AntiAfk.stop()
    running, busy = false, false
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)
    unhide()
end

function AntiAfk.feature()
    return {
        id          = "huss.anti_afk",
        name        = "Anti AFK",
        description = "Stops the game parking you in AFK when you tab out. If AFK gets switched on while the Roblox window isn't focused, it presses K (the game's own AFK key) to switch it straight back off, and it keeps Roblox's 20-minute idle kick away. An AFK you turn on yourself while you're in the window is left alone.",
        default     = false,
        onToggle    = function(v)
            CFG.enabled = v and true or false
            if CFG.enabled then AntiAfk.start() else AntiAfk.stop() end
        end,
        settings = {
            { type = "toggle", name = "Also hide tab-outs from the game's scripts", key = "hide", default = true,
              onChange = function(v)
                  CFG.hide = v and true or false
                  if not running then return end
                  if CFG.hide then hideFocusLoss() else unhide() end
              end },
        },
    }
end

return AntiAfk
