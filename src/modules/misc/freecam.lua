-- Free Cam: detaches the camera from your character and flies it around freely
-- while the body stays put.
--
-- Camera technique borrowed from the OpenGui freecam: never touch CameraType. Spawn
-- an invisible part, point camera.CameraSubject at it, and fly the part. The game's
-- own camera keeps running and just follows the part, so mouse-look is the native
-- camera (no cursor lock, this menu stays clickable) and nothing fights us.
--
-- Keeping the body still: we DISABLE THE PLAYER'S CONTROL MODULE
-- (PlayerModule:GetControls():Disable()) -- so WASD/jump simply stop driving the
-- character. No anchoring, no WalkSpeed/JumpPower changes; the body just stands there
-- intact and the controls are re-enabled on exit. Pantheon's global `require` is the
-- bundler shim ([[feedback_pantheon_require_shim]]), so we reach Roblox's real
-- `require` via getrenv() to load the PlayerModule. If that isn't available we fall
-- back to cancelling the body's velocity each frame (still no anchor / no speed edit).

local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players          = game:GetService("Players")
local Workspace        = game:GetService("Workspace")
local LP               = Players.LocalPlayer

local feature = require("ui.feature")
local log     = require("core.log")
local notify  = require("ui.notify")

local FreeCam = {}

local enabled    = false
local speed      = 5       -- per-frame move magnitude (pre-smoothing)
local smoothness = 0.2     -- 0..1 lerp factor; lower = floatier, higher = snappier

local camPart  = nil       -- the invisible part the camera follows
local moveCF   = nil       -- smoothed local-space move offset (a CFrame, lerped)
local dir      = { w = false, a = false, s = false, d = false, up = false, down = false }

local controls       = nil    -- PlayerModule Controls, while we hold it disabled
local controlsFailed = false  -- couldn't get controls -> use the per-frame fallback

local renderConn, beganConn, endedConn, charConn

-- which fly flag each key drives (Space/Q rise, Ctrl/E drop)
local KEY = {
    [Enum.KeyCode.W] = "w", [Enum.KeyCode.A] = "a",
    [Enum.KeyCode.S] = "s", [Enum.KeyCode.D] = "d",
    [Enum.KeyCode.Space] = "up",   [Enum.KeyCode.Q] = "up",
    [Enum.KeyCode.LeftControl] = "down", [Enum.KeyCode.E] = "down",
}

local function rootOf(char)
    if not char then return nil end
    return char.PrimaryPart
        or char:FindFirstChild("HumanoidRootPart")
        or char:FindFirstChildWhichIsA("BasePart")
end

-- Roblox's REAL require (our global `require` is the bundler shim, which can't load a
-- ModuleScript). getrenv() exposes the real global env on Wave/most executors.
local function getControls()
    local ps = LP:FindFirstChild("PlayerScripts")
    local pm = ps and ps:FindFirstChild("PlayerModule")
    if not pm then return nil end
    local rr
    pcall(function() if getrenv then rr = getrenv().require end end)
    if type(rr) ~= "function" then return nil end
    local ok, mod = pcall(rr, pm)
    if not ok or type(mod) ~= "table" then return nil end
    local ok2, c = pcall(function() return mod:GetControls() end)
    if ok2 and c then return c end
    return nil
end

-- Stop the body walking by disabling the control module (NOT anchor / NOT speed).
local function freezeControls()
    if not controls then controls = getControls() end
    if controls then
        pcall(function() controls:Disable() end)
        controlsFailed = false
    else
        controlsFailed = true   -- step() will damp velocity instead
    end
end

local function thawControls()
    if controls then pcall(function() controls:Enable() end); controls = nil end
    controlsFailed = false
end

-- Fallback ONLY when the controls module is unreachable: cancel the body's own motion
-- each frame -- still no anchoring and no WalkSpeed/JumpPower edits.
local function dampBody()
    local char = LP.Character
    local hrp  = char and rootOf(char)
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    if hrp then pcall(function() hrp.AssemblyLinearVelocity = Vector3.zero end) end
    if hum then pcall(function() hum:Move(Vector3.zero, false) end) end
end

local function step()
    if not enabled then return end
    local camera = Workspace.CurrentCamera
    if not camera or not camPart then return end

    camera.CameraSubject = camPart        -- re-assert: the camera follows our part
    if controlsFailed then dampBody() end

    -- aim the part down the camera's look so WASD is view-relative
    camPart.CFrame = CFrame.new(camPart.CFrame.Position, (camera.CFrame * CFrame.new(0, 0, -100)).Position)

    -- assemble the local-space move from held keys (-Z is forward)
    local x, y, z = 0, 0, 0
    if dir.w    then z = z - speed end
    if dir.s    then z = z + speed end
    if dir.a    then x = x - speed end
    if dir.d    then x = x + speed end
    if dir.up   then y = y + speed end
    if dir.down then y = y - speed end

    -- smooth the input, then ease the part toward part * move (OpenGui's feel)
    moveCF = moveCF:Lerp(CFrame.new(x, y, z), smoothness)
    camPart.CFrame = camPart.CFrame:Lerp(camPart.CFrame * moveCF, smoothness)
end

local function setActive(v)
    v = v and true or false
    if enabled == v then return end

    if v then
        local camera = Workspace.CurrentCamera
        if not camera then
            notify.warn("Free Cam: no camera available")
            return
        end

        enabled = true
        moveCF  = CFrame.new()
        dir     = { w = false, a = false, s = false, d = false, up = false, down = false }

        camPart = Instance.new("Part")
        camPart.Name         = "Camera"
        camPart.Transparency = 1
        camPart.Anchored     = true
        camPart.CanCollide   = false
        camPart.CanTouch     = false
        camPart.CanQuery     = false
        camPart.CFrame       = camera.CFrame
        camPart.Parent       = Workspace

        freezeControls()
        -- kill any residual walk momentum once so the body doesn't drift on start
        pcall(function() local r = rootOf(LP.Character); if r then r.AssemblyLinearVelocity = Vector3.zero end end)
        camera.CameraSubject = camPart

        renderConn = RunService.RenderStepped:Connect(step)
        beganConn  = UserInputService.InputBegan:Connect(function(input, gameProcessed)
            if gameProcessed then return end          -- ignore typing / UI input
            local k = KEY[input.KeyCode]
            if k then dir[k] = true end
        end)
        endedConn  = UserInputService.InputEnded:Connect(function(input)
            local k = KEY[input.KeyCode]               -- never gate release (no stuck keys)
            if k then dir[k] = false end
        end)
        -- re-disable the controls after a respawn (no yield -> dodges the Wave
        -- respawn/taskwait quirk [[feedback_executor_signal_taskwait]])
        charConn = LP.CharacterAdded:Connect(function()
            if enabled then freezeControls() end
        end)

        notify.success("Free Cam ON -- WASD + Space/Ctrl to fly, mouse to look")
    else
        enabled = false
        if renderConn then pcall(function() renderConn:Disconnect() end); renderConn = nil end
        if beganConn  then pcall(function() beganConn:Disconnect()  end); beganConn  = nil end
        if endedConn  then pcall(function() endedConn:Disconnect()  end); endedConn  = nil end
        if charConn   then pcall(function() charConn:Disconnect()   end); charConn   = nil end

        thawControls()
        local camera = Workspace.CurrentCamera
        if camera then
            local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
            pcall(function() camera.CameraSubject = hum end)   -- hand the camera back
        end
        if camPart then pcall(function() camPart:Destroy() end); camPart = nil end

        notify.info("Free Cam OFF -- camera returned")
    end
end

function FreeCam.register(box)
    box:add(feature.declare({
        id          = "misc.freecam",
        name        = "Free Cam",
        description = "Detaches the camera from your character and lets you fly it around freely while your body stays put where you left it. Look around with your mouse exactly like normal (it rides the game's own camera -- no cursor lock, this menu stays clickable), and fly with WASD relative to where you're looking, Space / Q to rise and Left-Ctrl / E to drop. \"Speed\" sets how fast it flies, \"Smoothness\" how floaty (lower = driftier, higher = snappier). While flying, your character's movement controls are simply switched off so the body stands still -- no anchoring, no walkspeed changes -- and switched back on when you exit. Survives respawns while it's on.",
        default     = false,
        onToggle    = setActive,
        settings    = {
            { type = "slider", name = "Speed", key = "speed",
              min = 1, max = 50, step = 1, default = 5,
              onChange = function(v) speed = v end },
            { type = "slider", name = "Smoothness", key = "smoothness",
              min = 0.05, max = 1, step = 0.05, default = 0.2,
              onChange = function(v) smoothness = v end },
        },
    }).root)

    log.info("Free Cam feature registered")
end

function FreeCam.destroy()
    setActive(false)
end

return FreeCam
