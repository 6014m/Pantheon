-- Aesthetic: client-side "how the game looks" tweaks (Lighting + camera).
-- Each feature persists via [[ui.feature]] (per-game); SAVED shader presets are
-- stored GLOBALLY (persist.getGlobal/setGlobal) so they follow you to any game.
-- Everything is reverted on disable and on module teardown (re-execute safe).

local feature   = require("ui.feature")
local window    = require("ui.window")
local container = require("ui.container")
local persist   = require("core.persist")
local log       = require("core.log")

local Lighting   = game:GetService("Lighting")
local RunService = game:GetService("RunService")

local Aesthetic = {}

local orig = {
    Ambient        = Lighting.Ambient,
    OutdoorAmbient = Lighting.OutdoorAmbient,
    Brightness     = Lighting.Brightness,
    GlobalShadows  = Lighting.GlobalShadows,
    FogEnd         = Lighting.FogEnd,
    ClockTime      = Lighting.ClockTime,
    FieldOfView    = (workspace.CurrentCamera and workspace.CurrentCamera.FieldOfView) or 70,
}

local st = { fullbright = false, nofog = false, fovOn = false, fov = 90, timeOn = false, clock = 12 }
local enforceConn

local function apply()
    if st.fullbright then
        Lighting.Brightness = 2; Lighting.Ambient = Color3.fromRGB(178, 178, 178)
        Lighting.OutdoorAmbient = Color3.fromRGB(178, 178, 178); Lighting.GlobalShadows = false
    end
    if st.nofog then Lighting.FogEnd = 1e9 end
    if st.timeOn then Lighting.ClockTime = st.clock end
    if st.fovOn then local cam = workspace.CurrentCamera; if cam then cam.FieldOfView = st.fov end end
end
local function ensureLoop()
    local need = st.fullbright or st.nofog or st.timeOn or st.fovOn
    if need and not enforceConn then enforceConn = RunService.RenderStepped:Connect(apply)
    elseif not need and enforceConn then enforceConn:Disconnect(); enforceConn = nil end
end

local function revertFullbright()
    Lighting.Brightness = orig.Brightness; Lighting.Ambient = orig.Ambient
    Lighting.OutdoorAmbient = orig.OutdoorAmbient; Lighting.GlobalShadows = orig.GlobalShadows
end
local function revertFog()  Lighting.FogEnd   = orig.FogEnd   end
local function revertTime() Lighting.ClockTime = orig.ClockTime end
local function revertFov() local cam = workspace.CurrentCamera; if cam then cam.FieldOfView = orig.FieldOfView end end

-- ===== RTX-style lighting + post-processing + presets =======================
-- Each effect is its own toggle (like Fullbright). "Preset Shaders" is the master
-- + the holder of saved presets: enabling it applies the lighting AND turns every
-- effect on; disabling it turns them all off AND resets every value to default.
-- A RenderStepped pass re-asserts all values each frame so the GAME can't override
-- the shader. Presets (and the "Default") live in the GLOBAL store, so a shader
-- you save in one game shows up in every game. NOTE: real client-side post-process
-- instances on Lighting/Camera -- a strict client AC can scan them; avoid there.
local GRADE_TINT = Color3.fromRGB(255, 220, 148)   -- baked warm RTX grade tint
local FIXED = {
    ambient = Color3.fromRGB(33, 33, 33), outdoor = Color3.fromRGB(51, 54, 67),
    csTop = Color3.fromRGB(255, 247, 237), csBottom = Color3.fromRGB(0, 0, 0),
}
local DEFAULTS = {
    brightness = 6.67, exposure = 0.75, shadowSoftness = 0.04, envDiffuse = 0.105,
    envSpecular = 0.522, geoLat = -15.525,
    bloomIntensity = 0.04, bloomSize = 1900, bloomThreshold = 0.915,
    dofFocus = 21.54, dofRadius = 20.77, dofNear = 0.277, dofFar = 0.077,
    sunIntensity = 0.01, sunSpread = 0.146,
    cc1B = 0.176, cc1C = 0.39, cc1S = 0.2, blurAmount = 10,
}
local NUM_KEYS = {
    "brightness", "exposure", "shadowSoftness", "envDiffuse", "envSpecular", "geoLat",
    "bloomIntensity", "bloomSize", "bloomThreshold",
    "dofFocus", "dofRadius", "dofNear", "dofFar", "sunIntensity", "sunSpread",
    "cc1B", "cc1C", "cc1S", "blurAmount",
}

local sv = {}
for k, v in pairs(DEFAULTS) do sv[k] = v end

local function builtin() local p = {}; for _, k in ipairs(NUM_KEYS) do p[k] = DEFAULTS[k] end; return p end
local PRESETS = { Default = builtin() }   -- Summer/Autumn removed; just a reset baseline

local customPresets = {}   -- name -> { numeric values } (GLOBAL: persist.getGlobal)
local customCount   = 0
local handles       = {}   -- sv-field -> component api; + .preset, .name

local fx = {}
local fxBlurConn = nil
local lightOrig  = nil
local shaderEnsureEnforce   -- forward decl (assigned after the apply* fns)
local shaderEnforceConn
-- effect keys the user enabled -> kept alive (recreated) even if the GAME deletes
-- the instance from Lighting; their class so the enforcer can rebuild them.
local FX_CLASS = { bloom = "BloomEffect", dof = "DepthOfFieldEffect", sun = "SunRaysEffect",
                   cc1 = "ColorCorrectionEffect", cc2 = "ColorCorrectionEffect", cc3 = "ColorCorrectionEffect" }
local want = {}

local SHADER_CHILDREN = { "aesthetic.bloom", "aesthetic.dof", "aesthetic.sunrays", "aesthetic.grade", "aesthetic.motionblur" }
local shaderBooting = true

local function newFx(key, class)
    want[key] = true
    if not fx[key] or fx[key].Parent == nil then
        local e = Instance.new(class); e.Enabled = true; e.Parent = Lighting; fx[key] = e
    end
    if shaderEnsureEnforce then shaderEnsureEnforce() end
    return fx[key]
end
local function killFx(key)
    want[key] = nil
    if fx[key] then pcall(function() fx[key]:Destroy() end); fx[key] = nil end
    if shaderEnsureEnforce then shaderEnsureEnforce() end
end

local function applyLighting()
    if not lightOrig then return end
    pcall(function()
        Lighting.Ambient = FIXED.ambient;                 Lighting.Brightness = sv.brightness
        Lighting.ColorShift_Top = FIXED.csTop;            Lighting.ColorShift_Bottom = FIXED.csBottom
        Lighting.EnvironmentDiffuseScale = sv.envDiffuse; Lighting.EnvironmentSpecularScale = sv.envSpecular
        Lighting.GlobalShadows = true;                    Lighting.OutdoorAmbient = FIXED.outdoor
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
    if shaderEnsureEnforce then shaderEnsureEnforce() end
end

local function applyBloom() local e = fx.bloom; if e then e.Intensity = sv.bloomIntensity; e.Size = sv.bloomSize; e.Threshold = sv.bloomThreshold end end
local function applyDof()   local e = fx.dof;   if e then e.FocusDistance = sv.dofFocus; e.InFocusRadius = sv.dofRadius; e.NearIntensity = sv.dofNear; e.FarIntensity = sv.dofFar end end
local function applySun()   local e = fx.sun;   if e then e.Intensity = sv.sunIntensity; e.Spread = sv.sunSpread end end
local function applyGrade()
    if fx.cc1 then fx.cc1.Brightness = sv.cc1B; fx.cc1.Contrast = sv.cc1C; fx.cc1.Saturation = sv.cc1S; fx.cc1.TintColor = GRADE_TINT end
    if fx.cc2 then fx.cc2.Brightness = 0;   fx.cc2.Contrast = -0.07; fx.cc2.Saturation = 0;    fx.cc2.TintColor = Color3.fromRGB(255, 247, 239) end
    if fx.cc3 then fx.cc3.Brightness = 0.2; fx.cc3.Contrast = 0.45;  fx.cc3.Saturation = -0.1; fx.cc3.TintColor = Color3.fromRGB(255, 255, 255) end
end

local function enableBlur(on)
    if on then
        local cam = workspace.CurrentCamera
        if cam then
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
        end
    else
        if fxBlurConn then pcall(function() fxBlurConn:Disconnect() end); fxBlurConn = nil end
        killFx("blur")
    end
    if shaderEnsureEnforce then shaderEnsureEnforce() end
end

-- Re-assert all active shader values every frame so the game can't override them.
-- Each apply* self-gates (no-op unless its part is enabled), so this only does
-- real work for what's on. Runs only while something is active.
shaderEnsureEnforce = function()
    local need = lightOrig ~= nil or next(want) ~= nil
    if need and not shaderEnforceConn then
        shaderEnforceConn = RunService.RenderStepped:Connect(function()
            applyLighting()
            -- rebuild any wanted effect the game may have deleted, then re-assert values
            for key in pairs(want) do
                if not fx[key] or fx[key].Parent == nil then
                    local e = Instance.new(FX_CLASS[key]); e.Enabled = true; e.Parent = Lighting; fx[key] = e
                end
            end
            applyBloom(); applyDof(); applySun(); applyGrade()
        end)
    elseif not need and shaderEnforceConn then
        shaderEnforceConn:Disconnect(); shaderEnforceConn = nil
    end
end

local function shaderTeardown()
    if shaderEnforceConn then shaderEnforceConn:Disconnect(); shaderEnforceConn = nil end
    enableLighting(false); enableBlur(false)
    for _, k in ipairs({ "bloom", "dof", "sun", "cc1", "cc2", "cc3" }) do killFx(k) end
end

-- Apply a preset's numeric values. `full` pushes them onto the sliders (which
-- re-apply the live effects); on boot `full` is false so each slider restores its
-- own saved value instead of the preset clobbering it.
local function applyPreset(name, full)
    local p = PRESETS[name] or customPresets[name]
    if not (p and full) then return end
    for _, k in ipairs(NUM_KEYS) do
        if p[k] ~= nil then sv[k] = p[k]; if handles[k] then handles[k]:Set(p[k]) end end
    end
end

local function saveCurrentPreset()
    local name = (handles.name and handles.name:Get()) or ""
    name = tostring(name):gsub("^%s*(.-)%s*$", "%1")
    if name == "" then customCount = customCount + 1; name = "Custom " .. customCount end
    local isNew = customPresets[name] == nil
    local p = {}
    for _, k in ipairs(NUM_KEYS) do p[k] = sv[k] end
    customPresets[name] = p
    persist.setGlobal("aesthetic.shaderPresets", customPresets)
    persist.setGlobal("aesthetic.shaderPresetCount", customCount)
    if handles.preset then
        if isNew and handles.preset.AddOption then handles.preset:AddOption(name) end
        handles.preset:Set(name)
    end
    if handles.name then handles.name:Set("") end
end

local function resetAll()
    if handles.preset then handles.preset:Set("Default") else applyPreset("Default", true) end
end

function Aesthetic.register()
    local box = container.new(window.parent(), "Aesthetic")

    box:add(feature.declare({
        id = "aesthetic.fullbright", name = "Fullbright",
        description = "Max ambient light and no shadows so dark areas are fully lit. Restores the game's lighting when off.",
        default = false, onToggle = function(v) st.fullbright = v; if not v then revertFullbright() end; apply(); ensureLoop() end,
    }).root)

    box:add(feature.declare({
        id = "aesthetic.nofog", name = "No Fog",
        description = "Pushes fog out to the horizon so distant geometry is visible.",
        default = false, onToggle = function(v) st.nofog = v; if not v then revertFog() end; apply(); ensureLoop() end,
    }).root)

    box:add(feature.declare({
        id = "aesthetic.fov", name = "Custom FOV",
        description = "Forces the camera field of view. Set the value with the cog slider.",
        default = false, onToggle = function(v) st.fovOn = v; if not v then revertFov() end; apply(); ensureLoop() end,
        settings = { { type = "slider", name = "FOV", key = "value", min = 40, max = 120, step = 1, default = 90,
            onChange = function(x) st.fov = x; if st.fovOn then apply() end end } },
    }).root)

    box:add(feature.declare({
        id = "aesthetic.time", name = "Custom Time",
        description = "Locks the time of day (0-24). Set it with the cog slider -- handy for forcing daytime.",
        default = false, onToggle = function(v) st.timeOn = v; if not v then revertTime() end; apply(); ensureLoop() end,
        settings = { { type = "slider", name = "Time of day", key = "value", min = 0, max = 24, step = 1, default = 12,
            onChange = function(x) st.clock = x; if st.timeOn then apply() end end } },
    }).root)

    -- Saved shaders are GLOBAL so they follow the user across games.
    customPresets = persist.getGlobal("aesthetic.shaderPresets", {}) or {}
    customCount   = persist.getGlobal("aesthetic.shaderPresetCount", 0) or 0
    -- One-time migration: shaders used to be saved per-game. If the global store
    -- is empty but THIS game has old per-game saves, lift them into global so a
    -- shader made before this update isn't lost.
    if next(customPresets) == nil then
        local old = persist.get("aesthetic.shaderPresets", nil)
        if type(old) == "table" and next(old) ~= nil then
            customPresets = old
            customCount = persist.get("aesthetic.shaderPresetCount", 0) or 0
            persist.setGlobal("aesthetic.shaderPresets", customPresets)
            persist.setGlobal("aesthetic.shaderPresetCount", customCount)
        end
    end
    local presetOptions = { "Default" }
    for name in pairs(customPresets) do presetOptions[#presetOptions + 1] = name end

    box:add(feature.declare({
        id          = "aesthetic.preset",
        name        = "Preset Shaders",
        description = "Master RTX look + your saved shaders. Enabling applies the cinematic Lighting AND turns on Bloom, Depth of Field, Sun Rays, Color Grade and Motion Blur, and re-asserts every value each frame so the GAME can't override it. Pick a saved shader to load it; type a Name + 'Save' to store the current look (saved shaders are GLOBAL -- they show up in every game). Turn any effect off on its own; disabling Preset Shaders turns them all off AND resets to defaults. NOTE: client-side post-processing -- avoid on strict-AC games.",
        default     = false,
        onToggle    = function(v)
            enableLighting(v)
            if shaderBooting then return end
            if v then
                for _, id in ipairs(SHADER_CHILDREN) do feature.setEnabled(id, true) end
            else
                for _, id in ipairs(SHADER_CHILDREN) do feature.setEnabled(id, false) end
                resetAll()
            end
        end,
        settings = {
            { type = "dropdown", name = "Shader", key = "preset", options = presetOptions, default = "Default",
              onChange = function(v) applyPreset(v, not shaderBooting) end,
              onCreate = function(h) handles.preset = h end },
            { type = "textbox", name = "Name", key = "savename", placeholder = "name your shader",
              onCreate = function(h) handles.name = h end },
            { type = "button", name = "Save current as new preset", onClick = function() saveCurrentPreset() end },
            { type = "section", name = "Lighting" },
            { type = "slider", name = "Brightness",      key = "b",  min = 0,   max = 10, step = 0.01,  default = DEFAULTS.brightness,     onChange = function(v) sv.brightness = v;     applyLighting() end, onCreate = function(h) handles.brightness = h end },
            { type = "slider", name = "Exposure",        key = "e",  min = -3,  max = 3,  step = 0.01,  default = DEFAULTS.exposure,       onChange = function(v) sv.exposure = v;       applyLighting() end, onCreate = function(h) handles.exposure = h end },
            { type = "slider", name = "Shadow Softness", key = "ss", min = 0,   max = 1,  step = 0.01,  default = DEFAULTS.shadowSoftness, onChange = function(v) sv.shadowSoftness = v; applyLighting() end, onCreate = function(h) handles.shadowSoftness = h end },
            { type = "slider", name = "Env Diffuse",     key = "ed", min = 0,   max = 1,  step = 0.001, default = DEFAULTS.envDiffuse,     onChange = function(v) sv.envDiffuse = v;     applyLighting() end, onCreate = function(h) handles.envDiffuse = h end },
            { type = "slider", name = "Env Specular",    key = "es", min = 0,   max = 1,  step = 0.001, default = DEFAULTS.envSpecular,    onChange = function(v) sv.envSpecular = v;    applyLighting() end, onCreate = function(h) handles.envSpecular = h end },
            { type = "slider", name = "Geo Latitude",    key = "gl", min = -90, max = 90, step = 0.025, default = DEFAULTS.geoLat,         onChange = function(v) sv.geoLat = v;         applyLighting() end, onCreate = function(h) handles.geoLat = h end },
        },
    }).root)

    box:add(feature.declare({
        id = "aesthetic.bloom", name = "Bloom",
        description = "Soft glow on bright pixels. Client-side BloomEffect -- avoid on strict-AC games.",
        default = false, onToggle = function(v) if v then newFx("bloom", "BloomEffect"); applyBloom() else killFx("bloom") end end,
        settings = {
            { type = "slider", name = "Intensity", key = "i", min = 0, max = 4,    step = 0.01,  default = DEFAULTS.bloomIntensity, onChange = function(v) sv.bloomIntensity = v; applyBloom() end, onCreate = function(h) handles.bloomIntensity = h end },
            { type = "slider", name = "Size",      key = "s", min = 0, max = 2000, step = 10,    default = DEFAULTS.bloomSize,      onChange = function(v) sv.bloomSize = v;      applyBloom() end, onCreate = function(h) handles.bloomSize = h end },
            { type = "slider", name = "Threshold", key = "t", min = 0, max = 5,    step = 0.005, default = DEFAULTS.bloomThreshold, onChange = function(v) sv.bloomThreshold = v; applyBloom() end, onCreate = function(h) handles.bloomThreshold = h end },
        },
    }).root)

    box:add(feature.declare({
        id = "aesthetic.dof", name = "Depth of Field",
        description = "Blurs near/far, keeps a focus band sharp. Client-side DepthOfFieldEffect -- avoid on strict-AC games.",
        default = false, onToggle = function(v) if v then newFx("dof", "DepthOfFieldEffect"); applyDof() else killFx("dof") end end,
        settings = {
            { type = "slider", name = "Focus Distance",  key = "fd", min = 0, max = 200, step = 0.01,  default = DEFAULTS.dofFocus,  onChange = function(v) sv.dofFocus = v;  applyDof() end, onCreate = function(h) handles.dofFocus = h end },
            { type = "slider", name = "In-Focus Radius", key = "fr", min = 0, max = 200, step = 0.01,  default = DEFAULTS.dofRadius, onChange = function(v) sv.dofRadius = v; applyDof() end, onCreate = function(h) handles.dofRadius = h end },
            { type = "slider", name = "Near Intensity",  key = "ni", min = 0, max = 1,   step = 0.001, default = DEFAULTS.dofNear,   onChange = function(v) sv.dofNear = v;   applyDof() end, onCreate = function(h) handles.dofNear = h end },
            { type = "slider", name = "Far Intensity",   key = "fi", min = 0, max = 1,   step = 0.001, default = DEFAULTS.dofFar,    onChange = function(v) sv.dofFar = v;    applyDof() end, onCreate = function(h) handles.dofFar = h end },
        },
    }).root)

    box:add(feature.declare({
        id = "aesthetic.sunrays", name = "Sun Rays",
        description = "Volumetric light shafts from the sun. Client-side SunRaysEffect -- avoid on strict-AC games.",
        default = false, onToggle = function(v) if v then newFx("sun", "SunRaysEffect"); applySun() else killFx("sun") end end,
        settings = {
            { type = "slider", name = "Intensity", key = "i", min = 0, max = 1, step = 0.001, default = DEFAULTS.sunIntensity, onChange = function(v) sv.sunIntensity = v; applySun() end, onCreate = function(h) handles.sunIntensity = h end },
            { type = "slider", name = "Spread",    key = "s", min = 0, max = 1, step = 0.001, default = DEFAULTS.sunSpread,    onChange = function(v) sv.sunSpread = v;    applySun() end, onCreate = function(h) handles.sunSpread = h end },
        },
    }).root)

    box:add(feature.declare({
        id = "aesthetic.grade", name = "Color Grade",
        description = "Cinematic color grade (3 stacked passes). Client-side ColorCorrectionEffects -- avoid on strict-AC games.",
        default = false, onToggle = function(v)
            if v then newFx("cc1", "ColorCorrectionEffect"); newFx("cc2", "ColorCorrectionEffect"); newFx("cc3", "ColorCorrectionEffect"); applyGrade()
            else killFx("cc1"); killFx("cc2"); killFx("cc3") end
        end,
        settings = {
            { type = "slider", name = "Contrast",   key = "c", min = -1, max = 1, step = 0.01,  default = DEFAULTS.cc1C, onChange = function(v) sv.cc1C = v; applyGrade() end, onCreate = function(h) handles.cc1C = h end },
            { type = "slider", name = "Saturation", key = "s", min = -1, max = 1, step = 0.01,  default = DEFAULTS.cc1S, onChange = function(v) sv.cc1S = v; applyGrade() end, onCreate = function(h) handles.cc1S = h end },
            { type = "slider", name = "Brightness", key = "b", min = -1, max = 1, step = 0.001, default = DEFAULTS.cc1B, onChange = function(v) sv.cc1B = v; applyGrade() end, onCreate = function(h) handles.cc1B = h end },
        },
    }).root)

    box:add(feature.declare({
        id = "aesthetic.motionblur", name = "Motion Blur",
        description = "Camera blur scaled by how fast you turn. Client-side BlurEffect on the camera -- avoid on strict-AC games.",
        default = false, onToggle = function(v) enableBlur(v) end,
        settings = {
            { type = "slider", name = "Amount", key = "a", min = 0, max = 30, step = 1, default = DEFAULTS.blurAmount, onChange = function(v) sv.blurAmount = v end, onCreate = function(h) handles.blurAmount = h end },
        },
    }).root)

    shaderBooting = false
    log.info("Aesthetic module registered")
end

function Aesthetic.destroy()
    if enforceConn then enforceConn:Disconnect(); enforceConn = nil end
    revertFullbright(); revertFog(); revertTime(); revertFov()
    shaderTeardown()
end

return Aesthetic
