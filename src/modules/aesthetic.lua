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

-- ===== Preset Shaders (RTX-style lighting + post-processing) ================
-- Ported from the user's RTX paste. Presets differ only by the primary color-
-- grade tint (Summer vs Autumn); every numeric value is exposed as a slider.
-- NOTE: this CREATES post-processing instances on Lighting + a BlurEffect on the
-- camera (client-side). A strict client anti-cheat can scan Lighting for these,
-- so it's surfaced in the feature description as "avoid on strict-AC games".
local PRESETS = {}
PRESETS.Summer = {
    ambient = Color3.fromRGB(33, 33, 33), brightness = 6.67,
    csBottom = Color3.fromRGB(0, 0, 0), csTop = Color3.fromRGB(255, 247, 237),
    envDiffuse = 0.105, envSpecular = 0.522, outdoor = Color3.fromRGB(51, 54, 67),
    shadowSoftness = 0.04, geoLat = -15.525, exposure = 0.75,
    bloomIntensity = 0.04, bloomSize = 1900, bloomThreshold = 0.915,
    cc1B = 0.176, cc1C = 0.39, cc1S = 0.2, cc1Tint = Color3.fromRGB(255, 220, 148),
    dofFar = 0.077, dofFocus = 21.54, dofRadius = 20.77, dofNear = 0.277,
    cc2B = 0, cc2C = -0.07, cc2S = 0, cc2Tint = Color3.fromRGB(255, 247, 239),
    cc3B = 0.2, cc3C = 0.45, cc3S = -0.1, cc3Tint = Color3.fromRGB(255, 255, 255),
    sunIntensity = 0.01, sunSpread = 0.146, blurAmount = 10,
}
PRESETS.Autumn = {}
for k, v in pairs(PRESETS.Summer) do PRESETS.Autumn[k] = v end
PRESETS.Autumn.cc1Tint = Color3.fromRGB(217, 145, 57)

-- live values (start from Summer); sliders mutate these
local sv = {}
for k, v in pairs(PRESETS.Summer) do sv[k] = v end

local sh = { enabled = false, preset = "Summer", fx = {}, orig = nil, blur = nil, conns = {} }

local function shClearFx()
    for _, e in pairs(sh.fx) do pcall(function() e:Destroy() end) end
    sh.fx = {}
    if sh.blur then pcall(function() sh.blur:Destroy() end); sh.blur = nil end
    for _, c in ipairs(sh.conns) do pcall(function() c:Disconnect() end) end
    sh.conns = {}
end

local function shSnapshot()
    sh.orig = {
        Ambient = Lighting.Ambient, Brightness = Lighting.Brightness,
        ColorShift_Bottom = Lighting.ColorShift_Bottom, ColorShift_Top = Lighting.ColorShift_Top,
        EnvironmentDiffuseScale = Lighting.EnvironmentDiffuseScale,
        EnvironmentSpecularScale = Lighting.EnvironmentSpecularScale,
        GlobalShadows = Lighting.GlobalShadows, OutdoorAmbient = Lighting.OutdoorAmbient,
        ShadowSoftness = Lighting.ShadowSoftness, GeographicLatitude = Lighting.GeographicLatitude,
        ExposureCompensation = Lighting.ExposureCompensation,
    }
end

local function shRevert()
    if not sh.orig then return end
    for k, v in pairs(sh.orig) do pcall(function() Lighting[k] = v end) end
end

-- Push current sv (+ preset tint) onto the live Lighting + effects. No-op until
-- the effects exist (built on enable), so boot-time setting onChanges just stage
-- values into sv and the master toggle applies them.
local function shApply()
    if not sh.enabled then return end
    pcall(function()
        Lighting.Ambient = sv.ambient
        Lighting.Brightness = sv.brightness
        Lighting.ColorShift_Bottom = sv.csBottom
        Lighting.ColorShift_Top = sv.csTop
        Lighting.EnvironmentDiffuseScale = sv.envDiffuse
        Lighting.EnvironmentSpecularScale = sv.envSpecular
        Lighting.GlobalShadows = true
        Lighting.OutdoorAmbient = sv.outdoor
        Lighting.ShadowSoftness = sv.shadowSoftness
        Lighting.GeographicLatitude = sv.geoLat
        Lighting.ExposureCompensation = sv.exposure
    end)
    local f, tint = sh.fx, (PRESETS[sh.preset] or PRESETS.Summer).cc1Tint
    if f.bloom then f.bloom.Intensity = sv.bloomIntensity; f.bloom.Size = sv.bloomSize; f.bloom.Threshold = sv.bloomThreshold end
    if f.cc1   then f.cc1.Brightness = sv.cc1B; f.cc1.Contrast = sv.cc1C; f.cc1.Saturation = sv.cc1S; f.cc1.TintColor = tint end
    if f.dof   then f.dof.FarIntensity = sv.dofFar; f.dof.FocusDistance = sv.dofFocus; f.dof.InFocusRadius = sv.dofRadius; f.dof.NearIntensity = sv.dofNear end
    if f.cc2   then f.cc2.Brightness = sv.cc2B; f.cc2.Contrast = sv.cc2C; f.cc2.Saturation = sv.cc2S; f.cc2.TintColor = sv.cc2Tint end
    if f.cc3   then f.cc3.Brightness = sv.cc3B; f.cc3.Contrast = sv.cc3C; f.cc3.Saturation = sv.cc3S; f.cc3.TintColor = sv.cc3Tint end
    if f.sun   then f.sun.Intensity = sv.sunIntensity; f.sun.Spread = sv.sunSpread end
end

local function shEnable(on)
    sh.enabled = on and true or false
    if not sh.enabled then shClearFx(); shRevert(); return end
    shClearFx()
    shSnapshot()
    local L = Lighting
    local function mk(class) local e = Instance.new(class); e.Enabled = true; e.Parent = L; return e end
    sh.fx.bloom = mk("BloomEffect")
    sh.fx.cc1   = mk("ColorCorrectionEffect")
    sh.fx.dof   = mk("DepthOfFieldEffect")
    sh.fx.cc2   = mk("ColorCorrectionEffect")
    sh.fx.cc3   = mk("ColorCorrectionEffect")
    sh.fx.sun   = mk("SunRaysEffect")
    local cam = workspace.CurrentCamera
    if cam then
        sh.blur = Instance.new("BlurEffect"); sh.blur.Parent = cam
        local last = cam.CFrame.LookVector
        sh.conns[#sh.conns + 1] = RunService.Heartbeat:Connect(function()
            local c = workspace.CurrentCamera
            if not c then return end
            if not sh.blur or sh.blur.Parent == nil then sh.blur = Instance.new("BlurEffect"); sh.blur.Parent = c end
            local mag = (c.CFrame.LookVector - last).Magnitude
            sh.blur.Size = math.abs(mag) * (sv.blurAmount or 10) * 5 / 2
            last = c.CFrame.LookVector
        end)
    end
    shApply()
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

    box:add(feature.declare({
        id          = "aesthetic.shader",
        name        = "Preset Shaders",
        description = "RTX-style lighting: bloom, color grading, depth of field, sun rays, ambient/exposure tuning + camera motion blur. Pick a preset to auto-apply a full look, then fine-tune any value. NOTE: creates post-processing effects on Lighting/Camera (client-side) -- avoid on games with strict anti-cheat.",
        default     = false,
        onToggle    = function(v) shEnable(v) end,
        settings    = {
            { type = "dropdown", name = "Preset", key = "preset", options = { "Summer", "Autumn" }, default = "Summer",
              onChange = function(v) sh.preset = v; shApply() end },

            { type = "section", name = "Lighting" },
            { type = "slider", name = "Brightness", key = "brightness", min = 0, max = 10, step = 0.01, default = PRESETS.Summer.brightness,
              onChange = function(v) sv.brightness = v; shApply() end },
            { type = "slider", name = "Exposure", key = "exposure", min = -3, max = 3, step = 0.01, default = PRESETS.Summer.exposure,
              onChange = function(v) sv.exposure = v; shApply() end },
            { type = "slider", name = "Shadow Softness", key = "shadowsoftness", min = 0, max = 1, step = 0.01, default = PRESETS.Summer.shadowSoftness,
              onChange = function(v) sv.shadowSoftness = v; shApply() end },
            { type = "slider", name = "Env Diffuse", key = "envdiffuse", min = 0, max = 1, step = 0.001, default = PRESETS.Summer.envDiffuse,
              onChange = function(v) sv.envDiffuse = v; shApply() end },
            { type = "slider", name = "Env Specular", key = "envspecular", min = 0, max = 1, step = 0.001, default = PRESETS.Summer.envSpecular,
              onChange = function(v) sv.envSpecular = v; shApply() end },
            { type = "slider", name = "Geo Latitude", key = "geolat", min = -90, max = 90, step = 0.025, default = PRESETS.Summer.geoLat,
              onChange = function(v) sv.geoLat = v; shApply() end },

            { type = "section", name = "Bloom" },
            { type = "slider", name = "Bloom Intensity", key = "bloomi", min = 0, max = 4, step = 0.01, default = PRESETS.Summer.bloomIntensity,
              onChange = function(v) sv.bloomIntensity = v; shApply() end },
            { type = "slider", name = "Bloom Size", key = "blooms", min = 0, max = 2000, step = 10, default = PRESETS.Summer.bloomSize,
              onChange = function(v) sv.bloomSize = v; shApply() end },
            { type = "slider", name = "Bloom Threshold", key = "bloomt", min = 0, max = 5, step = 0.005, default = PRESETS.Summer.bloomThreshold,
              onChange = function(v) sv.bloomThreshold = v; shApply() end },

            { type = "section", name = "Depth of Field" },
            { type = "slider", name = "Focus Distance", key = "doffocus", min = 0, max = 200, step = 0.01, default = PRESETS.Summer.dofFocus,
              onChange = function(v) sv.dofFocus = v; shApply() end },
            { type = "slider", name = "In-Focus Radius", key = "dofradius", min = 0, max = 200, step = 0.01, default = PRESETS.Summer.dofRadius,
              onChange = function(v) sv.dofRadius = v; shApply() end },
            { type = "slider", name = "Near Intensity", key = "dofnear", min = 0, max = 1, step = 0.001, default = PRESETS.Summer.dofNear,
              onChange = function(v) sv.dofNear = v; shApply() end },
            { type = "slider", name = "Far Intensity", key = "doffar", min = 0, max = 1, step = 0.001, default = PRESETS.Summer.dofFar,
              onChange = function(v) sv.dofFar = v; shApply() end },

            { type = "section", name = "Sun Rays" },
            { type = "slider", name = "Sun Intensity", key = "suni", min = 0, max = 1, step = 0.001, default = PRESETS.Summer.sunIntensity,
              onChange = function(v) sv.sunIntensity = v; shApply() end },
            { type = "slider", name = "Sun Spread", key = "suns", min = 0, max = 1, step = 0.001, default = PRESETS.Summer.sunSpread,
              onChange = function(v) sv.sunSpread = v; shApply() end },

            { type = "section", name = "Color Grade" },
            { type = "slider", name = "Contrast", key = "cc1c", min = -1, max = 1, step = 0.01, default = PRESETS.Summer.cc1C,
              onChange = function(v) sv.cc1C = v; shApply() end },
            { type = "slider", name = "Saturation", key = "cc1s", min = -1, max = 1, step = 0.01, default = PRESETS.Summer.cc1S,
              onChange = function(v) sv.cc1S = v; shApply() end },
            { type = "slider", name = "Grade Brightness", key = "cc1b", min = -1, max = 1, step = 0.001, default = PRESETS.Summer.cc1B,
              onChange = function(v) sv.cc1B = v; shApply() end },

            { type = "section", name = "Motion Blur" },
            { type = "slider", name = "Blur Amount", key = "blur", min = 0, max = 30, step = 1, default = PRESETS.Summer.blurAmount,
              onChange = function(v) sv.blurAmount = v end },
        },
    }).root)

    log.info("Aesthetic module registered")
end

-- Re-execute / teardown: drop the enforcement loop and put the game's look
-- back exactly as we found it, so a reload doesn't compound or leave changes.
function Aesthetic.destroy()
    if enforceConn then enforceConn:Disconnect(); enforceConn = nil end
    revertFullbright(); revertFog(); revertTime(); revertFov()
    shClearFx(); shRevert()   -- tear down post-processing effects + restore Lighting
end

return Aesthetic
