-- Free Cam: detaches the camera from your character and flies it around freely
-- while the body stays put.
--
-- Technique borrowed from the OpenGui freecam, because driving a Scriptable camera
-- (the previous approach) didn't hold up in-game -- BindToRenderStep/Scriptable can
-- get fought or fail in some executor/game contexts and the camera just froze.
--
-- This one never takes the camera off the default controller at all. It spawns an
-- invisible ANCHORED part, points the camera's CameraSubject at THAT part, and flies
-- the part. The game's normal camera keeps running and simply follows the part, so:
--   * mouse-look is the game's own camera (rotate / zoom exactly as usual) -- no
--     cursor capture, no fighting, the Pantheon menu stays clickable, and
--   * WASD / Q-E (or Space / Ctrl) move the part, smoothed, relative to where you
--     look (the part is re-aimed down the camera's look each frame).
-- Your character's root is anchored so the body stays where you left it; it's
-- un-anchored again on exit. Anchored=true replicates -- this makes no anti-cheat-
-- safety claims ([[feedback_adonis_detection]]).

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
local anchored = nil       -- the BasePart we anchored, so we restore exactly it
local dir      = { w = false, a = false, s = false, d = false, up = false, down = false }

local renderConn, beganConn, endedConn

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
        or char:FindFirstChild("Torso")
        or char:FindFirstChild("UpperTorso")
        or char:FindFirstChildWhichIsA("BasePart")
end

-- Anchor the current character's root so it stays put (re-targets the new root
-- after a respawn so it keeps working without a yielding respawn handler).
local function anchorBody()
    local part = rootOf(LP.Character)
    if not part then return end
    if anchored and anchored ~= part then pcall(function() anchored.Anchored = false end) end
    anchored = part
    if not part.Anchored then pcall(function() part.Anchored = true end) end
end

local function unanchorBody()
    if anchored then pcall(function() anchored.Anchored = false end); anchored = nil end
end

local function step()
    if not enabled then return end
    local camera = Workspace.CurrentCamera
    if not camera or not camPart then return end

    anchorBody()                          -- keep the body parked (respawn-proof)
    camera.CameraSubject = camPart        -- re-assert: the camera follows our part

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

        anchorBody()
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

        notify.success("Free Cam ON -- WASD + Space/Ctrl to fly, mouse to look")
    else
        enabled = false
        if renderConn then pcall(function() renderConn:Disconnect() end); renderConn = nil end
        if beganConn  then pcall(function() beganConn:Disconnect()  end); beganConn  = nil end
        if endedConn  then pcall(function() endedConn:Disconnect()  end); endedConn  = nil end

        unanchorBody()
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
        description = "Detaches the camera from your character and lets you fly it around freely while your body stays put where you left it. Look around with your mouse exactly like normal (it rides the game's own camera -- no cursor lock, this menu stays clickable), and fly with WASD relative to where you're looking, Space / Q to rise and Left-Ctrl / E to drop. \"Speed\" sets how fast it flies, \"Smoothness\" how floaty (lower = driftier, higher = snappier). Your root is anchored while flying so the body stays put, and released when you exit. Survives respawns while it's on.",
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
