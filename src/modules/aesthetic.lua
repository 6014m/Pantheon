-- Aesthetic: client-side "how the game looks" tweaks (Lighting + camera).
-- Each feature persists via [[ui.feature]]; a single RenderStepped pass
-- re-applies the active basic ones so games that overwrite Lighting don't win.
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

-- ===== RTX-style lighting + post-processing =================================
-- Modular: each effect is its OWN toggle (like Fullbright / No Fog) so they can
-- be mixed freely and flipped without opening settings. Values are from the
-- user's RTX paste; Color Grade's Tint picks the Summer / Autumn look.
-- NOTE: the post-process effects are real instances created on Lighting / the
-- Camera (client-side). A strict client anti-cheat can scan for them, so each
-- effect's "i" description flags "avoid on strict-AC games".
local TINTS = { Summer = Color3.fromRGB(255, 220, 148), Autumn = Color3.fromRGB(217, 145, 57) }

-- live values (from the RTX paste); sliders mutate these
local sv = {
    brightness = 6.67, exposure = 0.75, shadowSoftness = 0.04, envDiffuse = 0.105,
    envSpecular = 0.522, geoLat = -15.525,
    ambient = Color3.fromRGB(33, 33, 33), outdoor = Color3.fromRGB(51, 54, 67),
    csTop = Color3.fromRGB(255, 247, 237), csBottom = Color3.fromRGB(0, 0, 0),
    bloomIntensity = 0.04, bloomSize = 1900, bloomThreshold = 0.915,
    dofFocus = 21.54, dofRadius = 20.77, dofNear = 0.277, dofFar = 0.077,
    sunIntensity = 0.01, sunSpread = 0.146,
    tint = "Summer", cc1B = 0.176, cc1C = 0.39, cc1S = 0.2,
    blurAmount = 10,
}

local fx = {}              -- live effect instances by key
local fxBlurConn = nil     -- motion-blur Heartbeat connection
local lightOrig  = nil     -- RTX Lighting revert snapshot

-- Preset Shaders is the master: enabling it applies the cinematic Lighting AND
-- turns on every effect below; disabling it turns them all off. The effects stay
-- independently toggleable while it's on (turning one off does NOT disable the
-- master -- that's why this is a manual cascade, not feature.lua `dependencies`,
-- which kills the parent when a child goes off). The cascade is suppressed during
-- boot so each effect restores its own saved on/off instead of the master forcing
-- them all on.
local SHADER_CHILDREN = { "aesthetic.bloom", "aesthetic.dof", "aesthetic.sunrays", "aesthetic.grade", "aesthetic.motionblur" }
local shaderBooting = true

local function newFx(key, class)
    if not fx[key] then
        local e = Instance.new(class); e.Enabled = true; e.Parent = Lighting; fx[key] = e
    end
    return fx[key]
end
local function killFx(key)
    if fx[key] then pcall(function() fx[key]:Destroy() end); fx[key] = nil end
end

-- RTX Lighting (the Lighting-property tune; reverts to the captured original)
local function applyLighting()
    if not lightOrig then return end
    pcall(function()
        Lighting.Ambient = sv.ambient;                    Lighting.Brightness = sv.brightness
        Lighting.ColorShift_Top = sv.csTop;               Lighting.ColorShift_Bottom = sv.csBottom
        Lighting.EnvironmentDiffuseScale = sv.envDiffuse; Lighting.EnvironmentSpecularScale = sv.envSpecular
        Lighting.GlobalShadows = true;                    Lighting.OutdoorAmbient = sv.outdoor
        Lighting.ShadowSoftness = sv.shadowSoftness;      Lighting.GeographicLatitude = sv.geoLat
        Lighting.ExposureCompensation = sv.exposure
    end)
end
local function enableLighting(on)
    if on then
        lightOrig = lightOrig or {
            Ambient = Lighting.Ambient, Brightness = Lighting.Brightness,
            ColorShift_Top = Lighting.ColorShift_Top, ColorShift_Bottom = Lighting.ColorShift_Bottom,
            EnvironmentDiffuseScale = Lighting.EnvironmentDiffuseScale,
            EnvironmentSpecularScale = Lighting.EnvironmentSpecularScale,
            GlobalShadows = Lighting.GlobalShadows, OutdoorAmbient = Lighting.OutdoorAmbient,
            ShadowSoftness = Lighting.ShadowSoftness, GeographicLatitude = Lighting.GeographicLatitude,
            ExposureCompensation = Lighting.ExposureCompensation,
        }
        applyLighting()
    elseif lightOrig then
        for k, v in pairs(lightOrig) do pcall(function() Lighting[k] = v end) end
        lightOrig = nil
    end
end

local function applyBloom() local e = fx.bloom; if e then e.Intensity = sv.bloomIntensity; e.Size = sv.bloomSize; e.Threshold = sv.bloomThreshold end end
local function applyDof()   local e = fx.dof;   if e then e.FocusDistance = sv.dofFocus; e.InFocusRadius = sv.dofRadius; e.NearIntensity = sv.dofNear; e.FarIntensity = sv.dofFar end end
local function applySun()   local e = fx.sun;   if e then e.Intensity = sv.sunIntensity; e.Spread = sv.sunSpread end end
local function applyGrade()
    if fx.cc1 then fx.cc1.Brightness = sv.cc1B; fx.cc1.Contrast = sv.cc1C; fx.cc1.Saturation = sv.cc1S; fx.cc1.TintColor = TINTS[sv.tint] or TINTS.Summer end
    if fx.cc2 then fx.cc2.Brightness = 0;   fx.cc2.Contrast = -0.07; fx.cc2.Saturation = 0;    fx.cc2.TintColor = Color3.fromRGB(255, 247, 239) end
    if fx.cc3 then fx.cc3.Brightness = 0.2; fx.cc3.Contrast = 0.45;  fx.cc3.Saturation = -0.1; fx.cc3.TintColor = Color3.fromRGB(255, 255, 255) end
end

local function enableBlur(on)
    if on then
        local cam = workspace.CurrentCamera
        if not cam then return end
        fx.blur = Instance.new("BlurEffect"); fx.blur.Parent = cam
        local last = cam.CFrame.LookVector
        fxBlurConn = RunService.Heartbeat:Connect(function()
            local c = workspace.CurrentCamera
            if not c then return end
            if not fx.blur or fx.blur.Parent == nil then fx.blur = Instance.new("BlurEffect"); fx.blur.Parent = c end
            local mag = (c.CFrame.LookVector - last).Magnitude
            fx.blur.Size = math.abs(mag) * (sv.blurAmount or 10) * 5 / 2
            last = c.CFrame.LookVector
        end)
    else
        if fxBlurConn then pcall(function() fxBlurConn:Disconnect() end); fxBlurConn = nil end
        killFx("blur")
    end
end

local function shaderTeardown()
    enableLighting(false)
    enableBlur(false)
    for _, k in ipairs({ "bloom", "dof", "sun", "cc1", "cc2", "cc3" }) do killFx(k) end
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

    -- ----- RTX shader effects: each its own toggle ---------------------------
    box:add(feature.declare({
        id          = "aesthetic.preset",
        name        = "Preset Shaders",
        description = "Master RTX look. Enabling applies the cinematic Lighting AND turns on Bloom, Depth of Field, Sun Rays, Color Grade and Motion Blur. Turn any of those off on their own to drop just that effect; disabling Preset Shaders turns them all off. The Lighting tune (below) reverts when off. NOTE: creates client-side post-processing -- avoid on strict-AC games.",
        default     = false,
        onToggle    = function(v)
            enableLighting(v)
            if shaderBooting then return end   -- on boot each effect restores its own saved state
            for _, id in ipairs(SHADER_CHILDREN) do feature.setEnabled(id, v) end
        end,
        settings    = {
            { type = "slider", name = "Brightness",      key = "b",  min = 0,   max = 10, step = 0.01,  default = sv.brightness,     onChange = function(v) sv.brightness = v;     applyLighting() end },
            { type = "slider", name = "Exposure",        key = "e",  min = -3,  max = 3,  step = 0.01,  default = sv.exposure,       onChange = function(v) sv.exposure = v;       applyLighting() end },
            { type = "slider", name = "Shadow Softness", key = "ss", min = 0,   max = 1,  step = 0.01,  default = sv.shadowSoftness, onChange = function(v) sv.shadowSoftness = v; applyLighting() end },
            { type = "slider", name = "Env Diffuse",     key = "ed", min = 0,   max = 1,  step = 0.001, default = sv.envDiffuse,     onChange = function(v) sv.envDiffuse = v;     applyLighting() end },
            { type = "slider", name = "Env Specular",    key = "es", min = 0,   max = 1,  step = 0.001, default = sv.envSpecular,    onChange = function(v) sv.envSpecular = v;    applyLighting() end },
            { type = "slider", name = "Geo Latitude",    key = "gl", min = -90, max = 90, step = 0.025, default = sv.geoLat,         onChange = function(v) sv.geoLat = v;         applyLighting() end },
        },
    }).root)

    box:add(feature.declare({
        id          = "aesthetic.bloom",
        name        = "Bloom",
        description = "Soft glow on bright pixels. Creates a BloomEffect on Lighting (client-side) -- avoid on strict-AC games.",
        default     = false,
        onToggle    = function(v) if v then newFx("bloom", "BloomEffect"); applyBloom() else killFx("bloom") end end,
        settings    = {
            { type = "slider", name = "Intensity", key = "i", min = 0, max = 4,    step = 0.01,  default = sv.bloomIntensity, onChange = function(v) sv.bloomIntensity = v; applyBloom() end },
            { type = "slider", name = "Size",      key = "s", min = 0, max = 2000, step = 10,    default = sv.bloomSize,      onChange = function(v) sv.bloomSize = v;      applyBloom() end },
            { type = "slider", name = "Threshold", key = "t", min = 0, max = 5,    step = 0.005, default = sv.bloomThreshold, onChange = function(v) sv.bloomThreshold = v; applyBloom() end },
        },
    }).root)

    box:add(feature.declare({
        id          = "aesthetic.dof",
        name        = "Depth of Field",
        description = "Blurs near/far and keeps a focus band sharp. Creates a DepthOfFieldEffect (client-side) -- avoid on strict-AC games.",
        default     = false,
        onToggle    = function(v) if v then newFx("dof", "DepthOfFieldEffect"); applyDof() else killFx("dof") end end,
        settings    = {
            { type = "slider", name = "Focus Distance",  key = "fd", min = 0, max = 200, step = 0.01,  default = sv.dofFocus,  onChange = function(v) sv.dofFocus = v;  applyDof() end },
            { type = "slider", name = "In-Focus Radius", key = "fr", min = 0, max = 200, step = 0.01,  default = sv.dofRadius, onChange = function(v) sv.dofRadius = v; applyDof() end },
            { type = "slider", name = "Near Intensity",  key = "ni", min = 0, max = 1,   step = 0.001, default = sv.dofNear,   onChange = function(v) sv.dofNear = v;   applyDof() end },
            { type = "slider", name = "Far Intensity",   key = "fi", min = 0, max = 1,   step = 0.001, default = sv.dofFar,    onChange = function(v) sv.dofFar = v;    applyDof() end },
        },
    }).root)

    box:add(feature.declare({
        id          = "aesthetic.sunrays",
        name        = "Sun Rays",
        description = "Volumetric light shafts from the sun. Creates a SunRaysEffect (client-side) -- avoid on strict-AC games.",
        default     = false,
        onToggle    = function(v) if v then newFx("sun", "SunRaysEffect"); applySun() else killFx("sun") end end,
        settings    = {
            { type = "slider", name = "Intensity", key = "i", min = 0, max = 1, step = 0.001, default = sv.sunIntensity, onChange = function(v) sv.sunIntensity = v; applySun() end },
            { type = "slider", name = "Spread",    key = "s", min = 0, max = 1, step = 0.001, default = sv.sunSpread,    onChange = function(v) sv.sunSpread = v;    applySun() end },
        },
    }).root)

    box:add(feature.declare({
        id          = "aesthetic.grade",
        name        = "Color Grade",
        description = "Cinematic color grade (3 stacked passes). Tint picks the Summer / Autumn season look. Creates ColorCorrectionEffects (client-side) -- avoid on strict-AC games.",
        default     = false,
        onToggle    = function(v)
            if v then newFx("cc1", "ColorCorrectionEffect"); newFx("cc2", "ColorCorrectionEffect"); newFx("cc3", "ColorCorrectionEffect"); applyGrade()
            else killFx("cc1"); killFx("cc2"); killFx("cc3") end
        end,
        settings    = {
            { type = "dropdown", name = "Tint", key = "tint", options = { "Summer", "Autumn" }, default = "Summer", onChange = function(v) sv.tint = v; applyGrade() end },
            { type = "slider", name = "Contrast",   key = "c", min = -1, max = 1, step = 0.01,  default = sv.cc1C, onChange = function(v) sv.cc1C = v; applyGrade() end },
            { type = "slider", name = "Saturation", key = "s", min = -1, max = 1, step = 0.01,  default = sv.cc1S, onChange = function(v) sv.cc1S = v; applyGrade() end },
            { type = "slider", name = "Brightness", key = "b", min = -1, max = 1, step = 0.001, default = sv.cc1B, onChange = function(v) sv.cc1B = v; applyGrade() end },
        },
    }).root)

    box:add(feature.declare({
        id          = "aesthetic.motionblur",
        name        = "Motion Blur",
        description = "Camera blur scaled by how fast you turn. Creates a BlurEffect on the camera (client-side) -- avoid on strict-AC games.",
        default     = false,
        onToggle    = function(v) enableBlur(v) end,
        settings    = {
            { type = "slider", name = "Amount", key = "a", min = 0, max = 30, step = 1, default = sv.blurAmount, onChange = function(v) sv.blurAmount = v end },
        },
    }).root)

    shaderBooting = false   -- boot done; Preset Shaders now cascades to the effects
    log.info("Aesthetic module registered")
end

-- Re-execute / teardown: drop the enforcement loop and put the game's look
-- back exactly as we found it, so a reload doesn't compound or leave changes.
function Aesthetic.destroy()
    if enforceConn then enforceConn:Disconnect(); enforceConn = nil end
    revertFullbright(); revertFog(); revertTime(); revertFov()
    shaderTeardown()   -- destroy post-processing effects + restore RTX Lighting
end

return Aesthetic
