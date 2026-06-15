-- Free Cam: detaches the camera from your character and flies it around freely
-- while the body stays put. A classic spectate / scout tool.
--
-- Mechanism: take the camera off the player by switching it to a Scriptable
-- CameraType, then drive its CFrame ourselves every render frame from a little
-- fly-state (position + yaw/pitch). WASD moves relative to where we're looking,
-- Space / Left-Ctrl go straight up / down (world axis, independent of pitch),
-- Left-Shift sprints. We re-assert Scriptable every frame so a game that grabs
-- the camera back (e.g. on respawn) loses the tug-of-war.
--
-- Look is bound to the RIGHT MOUSE BUTTON on purpose. While RMB is held we lock
-- the cursor to centre and steer from UserInputService:GetMouseDelta(); the
-- moment it's released the cursor comes back, so the Pantheon menu (and the
-- feature's own OFF / keybind) stay clickable. A full-time cursor lock would
-- trap a user who never set a toggle key -- this can't.
--
-- The body would otherwise march off, because the default control scripts read
-- WASD straight from UserInputService regardless of what we do with the camera.
-- So we park the Humanoid (WalkSpeed / Jump / AutoRotate -> 0/false) for as long
-- as we fly and restore the originals on exit. The park is re-applied from the
-- render loop, re-snapshotting whenever a respawn hands us a fresh Humanoid, so
-- it survives death without a yielding respawn handler (sidesteps the Wave
-- "task.wait in a respawn signal may not resume" quirk
-- [[feedback_executor_signal_taskwait]]). WalkSpeed=0 is a property tell -- this
-- makes no anti-cheat-safety claims ([[feedback_adonis_detection]]).

local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players          = game:GetService("Players")
local Workspace        = game:GetService("Workspace")
local LP               = Players.LocalPlayer

local feature = require("ui.feature")
local log     = require("core.log")
local notify  = require("ui.notify")

local FreeCam = {}

local RENDER_NAME = "PantheonFreeCam"
local SENS_BASE   = 0.0006              -- radians per mouse pixel at sensitivity 1
local PITCH_LIMIT = math.rad(89)        -- stop the view flipping over the poles
local MAX_DT      = 0.1                 -- clamp lag spikes so a hitch can't teleport us

local enabled = false

-- fly state (seeded from the live camera on enable so the view never snaps)
local pos   = nil   -- Vector3 we fly around
local yaw   = 0
local pitch = 0

-- tunables, driven by the settings sliders (seeded at declare time)
local speed  = 60
local sens   = 6
local sprint = 3

-- host state saved on enable, restored on disable
local savedCamType   = nil
local savedSubject   = nil
local savedMouseIcon = nil

-- humanoid park: zero movement so the default WASD controller can't walk the
-- body while we fly. Re-snapshots on a fresh humanoid so restore is exact.
local speedSaved = nil   -- { hum, walk, jumpP, jumpH, autoRot }

-- mouse look (only while right mouse button held)
local mouseLocked = false
local justLocked  = false

local renderBound = false
local charConn    = nil

local function currentHumanoid()
    local char = LP.Character
    return char and char:FindFirstChildOfClass("Humanoid")
end

local function park(hum)
    if not hum then return end
    if not speedSaved or speedSaved.hum ~= hum then   -- first time, or a respawn
        speedSaved = {
            hum     = hum,
            walk    = hum.WalkSpeed,
            jumpP   = hum.JumpPower,
            jumpH   = hum.JumpHeight,
            autoRot = hum.AutoRotate,
        }
    end
    if hum.WalkSpeed  ~= 0     then pcall(function() hum.WalkSpeed  = 0 end) end
    if hum.JumpPower  ~= 0     then pcall(function() hum.JumpPower  = 0 end) end
    if hum.JumpHeight ~= 0     then pcall(function() hum.JumpHeight = 0 end) end
    if hum.AutoRotate ~= false then pcall(function() hum.AutoRotate = false end) end
end

local function unpark()
    if speedSaved and speedSaved.hum then
        local hum = speedSaved.hum
        pcall(function() hum.WalkSpeed  = speedSaved.walk end)
        pcall(function() hum.JumpPower  = speedSaved.jumpP end)
        pcall(function() hum.JumpHeight = speedSaved.jumpH end)
        pcall(function() hum.AutoRotate = speedSaved.autoRot end)
    end
    speedSaved = nil
end

-- Lock/unlock the cursor to follow the right mouse button. Re-asserts the lock
-- each frame while looking in case the game flips MouseBehavior back.
local function setMouseLook(looking)
    if looking == mouseLocked then
        if looking and UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
            pcall(function() UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter end)
        end
        return
    end
    mouseLocked = looking
    if looking then
        pcall(function() UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter end)
        pcall(function() UserInputService.MouseIconEnabled = false end)
        justLocked = true   -- swallow the first delta so the view doesn't jump
    else
        pcall(function() UserInputService.MouseBehavior = Enum.MouseBehavior.Default end)
        pcall(function() UserInputService.MouseIconEnabled = (savedMouseIcon ~= false) end)
    end
end

local function step(dt)
    if not enabled then return end
    local cam = Workspace.CurrentCamera
    if not cam then return end
    if not pos then pos = cam.CFrame.Position end
    dt = math.clamp(dt or 0, 0, MAX_DT)

    -- keep ownership of the camera even if the game flips it back
    if cam.CameraType ~= Enum.CameraType.Scriptable then
        pcall(function() cam.CameraType = Enum.CameraType.Scriptable end)
    end

    -- park the body every frame (respawn-proof; no-ops once it's zeroed)
    park(currentHumanoid())

    -- LOOK: only while the right mouse button is held
    local looking = UserInputService:IsMouseButtonDown(Enum.UserInputType.MouseButton2)
    setMouseLook(looking)
    if looking then
        if justLocked then
            justLocked = false
        else
            local d = UserInputService:GetMouseDelta()
            yaw   = yaw - d.X * SENS_BASE * sens
            pitch = math.clamp(pitch - d.Y * SENS_BASE * sens, -PITCH_LIMIT, PITCH_LIMIT)
        end
    end

    -- MOVE: WASD relative to look, Space/Ctrl world up/down, Shift sprint.
    -- Suppressed while a text box is focused so typing a keybind or chatting
    -- doesn't fly the camera out from under you.
    local move = Vector3.zero
    if not UserInputService:GetFocusedTextBox() then
        local cf    = cam.CFrame
        local look  = cf.LookVector
        local right = cf.RightVector
        if UserInputService:IsKeyDown(Enum.KeyCode.W) then move = move + look end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then move = move - look end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) then move = move + right end
        if UserInputService:IsKeyDown(Enum.KeyCode.A) then move = move - right end
        if UserInputService:IsKeyDown(Enum.KeyCode.Space)       then move = move + Vector3.new(0, 1, 0) end
        if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then move = move - Vector3.new(0, 1, 0) end
    end
    if move.Magnitude > 0 then
        local sp = speed * (UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) and sprint or 1)
        pos = pos + move.Unit * (sp * dt)
    end

    -- stop the in-place walk animation while the body is parked
    local hum = currentHumanoid()
    if hum then pcall(function() hum:Move(Vector3.zero, false) end) end

    cam.CFrame = CFrame.new(pos) * CFrame.fromEulerAnglesYXZ(pitch, yaw, 0)
end

local function setActive(v)
    v = v and true or false
    if enabled == v then return end

    if v then
        local cam = Workspace.CurrentCamera
        if not cam then
            notify.warn("Free Cam: no camera available")
            return   -- leave disabled; toggling again once a camera exists works
        end

        -- seed fly state from where the camera is right now (no snap)
        local cf = cam.CFrame
        pos = cf.Position
        local rx, ry = cf:ToEulerAnglesYXZ()
        pitch = math.clamp(rx, -PITCH_LIMIT, PITCH_LIMIT)
        yaw   = ry

        savedCamType   = cam.CameraType
        savedSubject   = cam.CameraSubject
        savedMouseIcon = UserInputService.MouseIconEnabled

        enabled = true
        pcall(function() cam.CameraType = Enum.CameraType.Scriptable end)
        park(currentHumanoid())

        -- re-park after a respawn (no yield -> dodges the Wave respawn/taskwait quirk)
        if not charConn then
            charConn = LP.CharacterAdded:Connect(function()
                if enabled then park(currentHumanoid()) end
            end)
        end

        if not renderBound then
            RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Camera.Value + 1, step)
            renderBound = true
        end
        notify.success("Free Cam ON -- WASD to fly, hold RMB to look, Shift to sprint")
    else
        enabled = false
        if renderBound then
            pcall(function() RunService:UnbindFromRenderStep(RENDER_NAME) end)
            renderBound = false
        end
        if charConn then pcall(function() charConn:Disconnect() end); charConn = nil end

        -- hand the camera back to the player
        local cam = Workspace.CurrentCamera
        if cam then
            pcall(function()
                cam.CameraType = (savedCamType and savedCamType ~= Enum.CameraType.Scriptable)
                    and savedCamType or Enum.CameraType.Custom
            end)
            local hum = currentHumanoid()
            pcall(function() cam.CameraSubject = hum or savedSubject end)
        end

        -- release the cursor + restore the body
        mouseLocked = false
        pcall(function() UserInputService.MouseBehavior = Enum.MouseBehavior.Default end)
        pcall(function() UserInputService.MouseIconEnabled = (savedMouseIcon ~= false) end)
        unpark()

        notify.info("Free Cam OFF -- camera returned")
    end
end

function FreeCam.register(box)
    box:add(feature.declare({
        id          = "misc.freecam",
        name        = "Free Cam",
        description = "Detaches the camera from your character and lets you fly it around freely while your body stays put where you left it. WASD flies relative to where you're looking, Space / Left-Ctrl rise and drop straight up and down, and hold Left-Shift to sprint. Hold the RIGHT MOUSE BUTTON to look around -- the cursor returns the instant you let go, so you can still click this menu (or your bound key, or the OFF button here) to come back to your character. Your walk speed is parked to zero while flying so WASD doesn't also march your avatar off; it's restored when you exit. Survives respawns while it's on.",
        default     = false,
        onToggle    = setActive,
        settings    = {
            { type = "slider", name = "Fly speed", key = "speed",
              min = 5, max = 300, step = 5, default = 60,
              onChange = function(v) speed = v end },
            { type = "slider", name = "Look sensitivity", key = "sens",
              min = 1, max = 20, step = 1, default = 6,
              onChange = function(v) sens = v end },
            { type = "slider", name = "Sprint multiplier", key = "sprint",
              min = 1, max = 8, step = 1, default = 3,
              onChange = function(v) sprint = v end },
        },
    }).root)

    log.info("Free Cam feature registered")
end

function FreeCam.destroy()
    setActive(false)
end

return FreeCam
