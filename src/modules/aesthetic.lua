-- Aesthetic: client-side "how the game looks" tweaks (Lighting + camera).
-- Each feature persists via [[ui.feature]]; a single RenderStepped pass
-- re-applies the active ones so games that overwrite Lighting don't win.
-- Everything is reverted on disable and on module teardown (re-execute safe).

local feature   = require("ui.feature")
local window    = require("ui.window")
local container = require("ui.container")
local log       = require("core.log")

local Lighting   = game:GetService("Lighting")
local RunService = game:GetService("RunService")

local Aesthetic = {}

-- Snapshot the game's original look once so toggles can revert cleanly.
local orig = {
    Ambient        = Lighting.Ambient,
    OutdoorAmbient = Lighting.OutdoorAmbient,
    Brightness     = Lighting.Brightness,
    GlobalShadows  = Lighting.GlobalShadows,
    FogEnd         = Lighting.FogEnd,
    ClockTime      = Lighting.ClockTime,
    FieldOfView    = (workspace.CurrentCamera and workspace.CurrentCamera.FieldOfView) or 70,
}

local st = {
    fullbright = false,
    nofog      = false,
    fovOn      = false, fov   = 90,
    timeOn     = false, clock = 12,
}

local enforceConn

-- Re-assert whatever is currently enabled. Run once on change and every frame
-- (while anything is on) so games that rewrite Lighting/FOV don't override us.
local function apply()
    if st.fullbright then
        Lighting.Brightness     = 2
        Lighting.Ambient        = Color3.fromRGB(178, 178, 178)
        Lighting.OutdoorAmbient = Color3.fromRGB(178, 178, 178)
        Lighting.GlobalShadows  = false
    end
    if st.nofog then
        Lighting.FogEnd = 1e9
    end
    if st.timeOn then
        Lighting.ClockTime = st.clock
    end
    if st.fovOn then
        local cam = workspace.CurrentCamera
        if cam then cam.FieldOfView = st.fov end
    end
end

local function ensureLoop()
    local need = st.fullbright or st.nofog or st.timeOn or st.fovOn
    if need and not enforceConn then
        enforceConn = RunService.RenderStepped:Connect(apply)
    elseif not need and enforceConn then
        enforceConn:Disconnect(); enforceConn = nil
    end
end

local function revertFullbright()
    Lighting.Brightness     = orig.Brightness
    Lighting.Ambient        = orig.Ambient
    Lighting.OutdoorAmbient = orig.OutdoorAmbient
    Lighting.GlobalShadows  = orig.GlobalShadows
end
local function revertFog()  Lighting.FogEnd   = orig.FogEnd   end
local function revertTime() Lighting.ClockTime = orig.ClockTime end
local function revertFov()
    local cam = workspace.CurrentCamera
    if cam then cam.FieldOfView = orig.FieldOfView end
end

function Aesthetic.register()
    local box = container.new(window.parent(), "Aesthetic")

    box:add(feature.declare({
        id          = "aesthetic.fullbright",
        name        = "Fullbright",
        description = "Max ambient light and no shadows so dark areas are fully lit. Restores the game's lighting when turned off.",
        default     = false,
        onToggle    = function(v) st.fullbright = v; if not v then revertFullbright() end; apply(); ensureLoop() end,
    }).root)

    box:add(feature.declare({
        id          = "aesthetic.nofog",
        name        = "No Fog",
        description = "Pushes fog out to the horizon so distant geometry is visible.",
        default     = false,
        onToggle    = function(v) st.nofog = v; if not v then revertFog() end; apply(); ensureLoop() end,
    }).root)

    box:add(feature.declare({
        id          = "aesthetic.fov",
        name        = "Custom FOV",
        description = "Forces the camera field of view. Set the value with the cog slider.",
        default     = false,
        onToggle    = function(v) st.fovOn = v; if not v then revertFov() end; apply(); ensureLoop() end,
        settings    = {
            { type = "slider", name = "FOV", key = "value", min = 40, max = 120, step = 1, default = 90,
              onChange = function(x) st.fov = x; if st.fovOn then apply() end end },
        },
    }).root)

    box:add(feature.declare({
        id          = "aesthetic.time",
        name        = "Custom Time",
        description = "Locks the time of day (0-24). Set it with the cog slider -- handy for forcing daytime.",
        default     = false,
        onToggle    = function(v) st.timeOn = v; if not v then revertTime() end; apply(); ensureLoop() end,
        settings    = {
            { type = "slider", name = "Time of day", key = "value", min = 0, max = 24, step = 1, default = 12,
              onChange = function(x) st.clock = x; if st.timeOn then apply() end end },
        },
    }).root)

    log.info("Aesthetic module registered")
end

-- Re-execute / teardown: drop the enforcement loop and put the game's look
-- back exactly as we found it, so a reload doesn't compound or leave changes.
function Aesthetic.destroy()
    if enforceConn then enforceConn:Disconnect(); enforceConn = nil end
    revertFullbright(); revertFog(); revertTime(); revertFov()
end

return Aesthetic
