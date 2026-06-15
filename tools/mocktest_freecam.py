import os, lupa

SRC = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "src"))
def read_file(rel):
    path = os.path.join(SRC, *rel.split(".")) + ".lua"
    with open(path, "r", encoding="utf-8") as f:
        return f.read()

rt = lupa.LuaRuntime(unpack_returned_tuples=True)
G = rt.globals()
G.python_read_file = read_file
print("Lua:", rt.eval("_VERSION"))

LUA = r'''
local real = { math=math, string=string, table=table, pcall=pcall, error=error,
  assert=assert, ipairs=ipairs, pairs=pairs, tostring=tostring, tonumber=tonumber,
  type=type, select=select, next=next, setmetatable=setmetatable, print=print, load=load }
local sqrt, sin, cos = real.math.sqrt, real.math.sin, real.math.cos
local ERRORS, NOTIFY = {}, {}

-- math + math.clamp (lupa's 5.1 math has no clamp; Roblox does)
local mathx = real.setmetatable({
  clamp = function(x, lo, hi) if x < lo then return lo elseif x > hi then return hi else return x end end,
}, { __index = real.math })

------------------------------------------------------------------- Vector3
local V3MT = {}
local function v3(x, y, z) return real.setmetatable({ _isV3=true, _x=x, _y=y, _z=z }, V3MT) end
V3MT.__index = function(self, k)
  if k == "X" then return self._x elseif k == "Y" then return self._y elseif k == "Z" then return self._z
  elseif k == "Magnitude" then return sqrt(self._x*self._x + self._y*self._y + self._z*self._z)
  elseif k == "Unit" then local m = sqrt(self._x*self._x + self._y*self._y + self._z*self._z)
    if m == 0 then return v3(0,0,0) end return v3(self._x/m, self._y/m, self._z/m) end
  return nil
end
V3MT.__add = function(a, b) return v3(a._x+b._x, a._y+b._y, a._z+b._z) end
V3MT.__sub = function(a, b) return v3(a._x-b._x, a._y-b._y, a._z-b._z) end
V3MT.__mul = function(a, b)
  if real.type(a) == "number" then return v3(b._x*a, b._y*a, b._z*a) end
  if real.type(b) == "number" then return v3(a._x*b, a._y*b, a._z*b) end
  return v3(a._x*b._x, a._y*b._y, a._z*b._z)
end
local Vector3 = { new = v3, zero = v3(0,0,0) }

------------------------------------------------------------------- CFrame
-- Stored as position + (pitch, yaw). Roblox conventions: yaw=pitch=0 looks down -Z.
local CFMT = {}
local function cf(pos, pitch, yaw) return real.setmetatable({ _isCF=true, _pos=pos, _pitch=pitch, _yaw=yaw }, CFMT) end
CFMT.__index = function(self, k)
  if k == "Position" then return self._pos
  elseif k == "LookVector" then
    return v3(-sin(self._yaw)*cos(self._pitch), sin(self._pitch), -cos(self._yaw)*cos(self._pitch))
  elseif k == "RightVector" then
    return v3(cos(self._yaw), 0, -sin(self._yaw))
  elseif k == "ToEulerAnglesYXZ" then
    return function(s) return s._pitch, s._yaw, 0 end
  end
  return nil
end
-- translation(pos) * rotation(pitch,yaw): pos from the left, angles from the right
CFMT.__mul = function(a, b) return cf(a._pos, a._pitch + b._pitch, a._yaw + b._yaw) end
local CFrame = {
  new = function(a, b, c)
    if real.type(a) == "table" and a._isV3 then return cf(a, 0, 0) end
    return cf(v3(a or 0, b or 0, c or 0), 0, 0)
  end,
  fromEulerAnglesYXZ = function(px, py, pz) return cf(v3(0,0,0), px, py) end,
}

------------------------------------------------------------------- Enum
local function sentinel(n) return real.setmetatable({ _enum = n }, { __tostring = function() return n end }) end
local Enum = {
  KeyCode = { W=sentinel("W"), A=sentinel("A"), S=sentinel("S"), D=sentinel("D"),
              Space=sentinel("Space"), LeftControl=sentinel("LeftControl"), LeftShift=sentinel("LeftShift") },
  UserInputType = { MouseButton2 = sentinel("MouseButton2") },
  MouseBehavior = { LockCenter = sentinel("LockCenter"), Default = sentinel("Default") },
  CameraType    = { Scriptable = sentinel("Scriptable"), Custom = sentinel("Custom") },
  RenderPriority = { Camera = { Value = 200 } },
}

------------------------------------------------------------------- Instances (chars/humanoids)
local InstanceMT
local function newInstance(cls) return real.setmetatable({ _isInstance=true, ClassName=cls, Name=cls, _children={}, _props={}, _events={} }, InstanceMT) end
local function setParent(self, parent)
  local old = self._props.Parent
  if old then for i,c in real.ipairs(old._children) do if c==self then real.table.remove(old._children,i) break end end end
  self._props.Parent = parent
  if parent then parent._children[#parent._children+1] = self end
end
local METHODS = {}
function METHODS:FindFirstChildOfClass(cl) for _,c in real.ipairs(self._children) do if c.ClassName==cl then return c end end return nil end
function METHODS:FindFirstChild(n) for _,c in real.ipairs(self._children) do if c.Name==n then return c end end return nil end
function METHODS:Move(_, _) self._moved = true end
InstanceMT = {
  __index = function(self, k)
    if k == "Parent" then return self._props.Parent end
    if METHODS[k] then return METHODS[k] end
    if self._props[k] ~= nil then return self._props[k] end
    return nil
  end,
  __newindex = function(self, k, v) if k == "Parent" then setParent(self, v) else self._props[k] = v end end,
}
local function mkChar(name)
  local m = newInstance("Model"); m.Name = name
  local hum = newInstance("Humanoid")
  hum.WalkSpeed = 16; hum.JumpPower = 50; hum.JumpHeight = 7.2; hum.AutoRotate = true
  setParent(hum, m)
  return m, hum
end

------------------------------------------------------------------- CharacterAdded event
local function newEvent()
  local h = {}
  local ev = {}
  function ev:Connect(fn) h[#h+1] = fn; return { Disconnect = function() for i,x in real.ipairs(h) do if x==fn then real.table.remove(h,i) break end end end } end
  function ev:Fire(...) for _,fn in real.ipairs(h) do local ok,e = real.pcall(fn, ...); if not ok then ERRORS[#ERRORS+1] = "CharacterAdded: "..real.tostring(e) end end end
  return ev
end

local char0, hum0 = mkChar("Char0")
local charAdded = newEvent()
local LocalPlayer = real.setmetatable({ _isInstance=true, ClassName="Player", Name="Tester",
  _props = { Character = char0 }, CharacterAdded = charAdded }, {
  __index = function(self, k) if k == "Character" then return self._props.Character end return real.rawget(self, k) end,
  __newindex = function(self, k, v) if k == "Character" then self._props.Character = v else real.rawset(self, k, v) end end,
})

------------------------------------------------------------------- Services
local camera = newInstance("Camera")
camera.CFrame = CFrame.new(v3(0,0,0))           -- yaw=pitch=0, looking down -Z
camera.CameraType = Enum.CameraType.Custom
camera.CameraSubject = hum0
camera.FieldOfView = 70
local Workspace = { CurrentCamera = camera }

local RunService = {}
local renderFn, renderConnected = nil, false
RunService.RenderStepped = {
  Connect = function(_, fn) renderFn = fn; renderConnected = true
    return { Disconnect = function() renderConnected = false end } end,
}

local UIS = {
  MouseBehavior = Enum.MouseBehavior.Default, MouseIconEnabled = true,
  _keys = {}, _mb2 = false, _delta = { X=0, Y=0 }, _focused = nil,
}
function UIS:IsKeyDown(kc) return self._keys[kc] == true end
function UIS:IsMouseButtonDown(it) return it == Enum.UserInputType.MouseButton2 and self._mb2 == true end
function UIS:GetMouseDelta() return self._delta end
function UIS:GetFocusedTextBox() return self._focused end

local Players = { LocalPlayer = LocalPlayer }
local SERVICES = { RunService=RunService, UserInputService=UIS, Players=Players, Workspace=Workspace }
local game = { PlaceId = 1 }
function game:GetService(n) return SERVICES[n] end

------------------------------------------------------------------- module stubs (feature/log/notify)
local capturedDef = nil
local function stub(name)
  if name == "ui.feature" then return { declare = function(def) capturedDef = def; return { root = newInstance("Frame") } end } end
  if name == "core.log" then return { info=function() end, warn=function() end, error=function() end } end
  if name == "ui.notify" then return {
    info    = function(m) NOTIFY[#NOTIFY+1] = "info:"..real.tostring(m) end,
    success = function(m) NOTIFY[#NOTIFY+1] = "success:"..real.tostring(m) end,
    warn    = function(m) NOTIFY[#NOTIFY+1] = "warn:"..real.tostring(m) end } end
  return real.setmetatable({}, { __index = function() return function() end end })
end
local cache = {}
local function myrequire(name) if cache[name] ~= nil then return cache[name] end local s = stub(name); cache[name] = s; return s end

local ENV = real.setmetatable({
  game = game, Vector3 = Vector3, CFrame = CFrame, Enum = Enum,
  require = myrequire, math = mathx, print = real.print, warn = function() end,
  string = real.string, table = real.table, pcall = real.pcall, ipairs = real.ipairs,
  pairs = real.pairs, tostring = real.tostring, tonumber = real.tonumber, type = real.type,
  select = real.select, next = real.next, setmetatable = real.setmetatable, error = real.error, assert = real.assert,
}, { __index = _G })

local src   = python_read_file("modules.misc.freecam")
local chunk = real.assert(real.load(src, "@freecam", "t", ENV))
local mod   = chunk()

local out = {}
local function approx(a, b) return real.math.abs(a - b) < 1e-3 end
out.loaded = (mod ~= nil) and (mod.register ~= nil) and (mod.destroy ~= nil)

-- register
local box = { added = 0 }
function box:add(_) self.added = self.added + 1 end
local okR, errR = real.pcall(function() mod.register(box) end)
out.register_ok = okR; if not okR then out.register_err = real.tostring(errR) end
out.box_added   = box.added
out.feature_id  = capturedDef and capturedDef.id or "nil"
out.has_3_sliders = capturedDef and capturedDef.settings and (#capturedDef.settings == 3)

local function frame(dt) if renderConnected and renderFn then renderFn(dt) end end

-- ---- enable ----
real.pcall(function() capturedDef.onToggle(true) end)
out.enable_scriptable = (camera.CameraType == Enum.CameraType.Scriptable)
out.enable_bound      = (renderConnected == true)
out.enable_parked     = (hum0.WalkSpeed == 0) and (hum0.JumpPower == 0) and (hum0.AutoRotate == false)

-- ---- fly forward: hold W one frame at speed 60, dt 0.1 (yaw 0 -> -Z) = 6 studs ----
local z0 = camera.CFrame._pos._z
UIS._keys[Enum.KeyCode.W] = true; frame(0.1); UIS._keys[Enum.KeyCode.W] = nil
out.fly_forward = approx(camera.CFrame._pos._z - z0, -6)

-- ---- speed slider drives distance: set 120, dt 0.1 -> 12 studs this frame ----
local speedOpt
for _,o in real.ipairs(capturedDef.settings) do if o.key == "speed" then speedOpt = o end end
out.speed_opt_found = speedOpt ~= nil
if speedOpt then speedOpt.onChange(120) end
local z1 = camera.CFrame._pos._z
UIS._keys[Enum.KeyCode.W] = true; frame(0.1); UIS._keys[Enum.KeyCode.W] = nil
out.fly_speed_slider = approx(camera.CFrame._pos._z - z1, -12)
if speedOpt then speedOpt.onChange(60) end

-- ---- dt clamp: a 5s hitch is capped at MAX_DT (0.1) -> 6 studs, not 300 ----
local z2 = camera.CFrame._pos._z
UIS._keys[Enum.KeyCode.W] = true; frame(5); UIS._keys[Enum.KeyCode.W] = nil
out.dt_clamped = approx(camera.CFrame._pos._z - z2, -6)   -- 60 * 0.1, NOT 60 * 5

-- ---- look: hold RMB. First frame swallows delta; second applies it (turn right) ----
UIS._mb2 = true; UIS._delta = { X = 100, Y = 0 }
local yawA = camera.CFrame._yaw
frame(1)                                   -- swallow (justLocked)
out.look_swallow_first = approx(camera.CFrame._yaw, yawA)
out.mouse_locked = (UIS.MouseBehavior == Enum.MouseBehavior.LockCenter)
frame(1)                                   -- apply: yaw -= 100*0.0006*6 = 0.36
out.look_right = (camera.CFrame._yaw < -0.30) and (camera.CFrame._yaw > -0.40)
-- pitch via mouse Y
UIS._delta = { X = 0, Y = 100 }
frame(1)                                   -- pitch -= 0.36 -> look down
out.look_down = (camera.CFrame._pitch < -0.30) and (camera.CFrame._pitch > -0.40)
UIS._mb2 = false; UIS._delta = { X=0, Y=0 }

-- ---- typing suppression: focused text box -> WASD must not move the camera ----
frame(1)   -- releases mouse lock now that mb2 is false
local z3 = camera.CFrame._pos._z
UIS._focused = newInstance("TextBox")
UIS._keys[Enum.KeyCode.W] = true; frame(1); UIS._keys[Enum.KeyCode.W] = nil
UIS._focused = nil
out.typing_suppressed = approx(camera.CFrame._pos._z, z3)
out.mouse_released_on_rmb_up = (UIS.MouseBehavior == Enum.MouseBehavior.Default)

-- ---- respawn while active: new humanoid gets parked, old snapshot replaced ----
local char1, hum1 = mkChar("Char1")
LocalPlayer.Character = char1
charAdded:Fire(char1)
frame(1)
out.respawn_parked = (hum1.WalkSpeed == 0) and (hum1.AutoRotate == false)

-- ---- disable: camera handed back, render unbound, body restored, mouse default ----
real.pcall(function() capturedDef.onToggle(false) end)
out.disable_cam_restored = (camera.CameraType == Enum.CameraType.Custom)
out.disable_unbound      = (renderConnected == false)
out.disable_body_restored = (hum1.WalkSpeed == 16) and (hum1.JumpPower == 50) and (hum1.AutoRotate == true)
out.disable_subject       = (camera.CameraSubject == hum1)
out.disable_mouse_default  = (UIS.MouseBehavior == Enum.MouseBehavior.Default)
out.disable_mouse_icon     = (UIS.MouseIconEnabled == true)

-- ---- disabled tick is inert (manually invoking step would do nothing) ----
out.no_render_after_disable = (renderConnected == false)

-- ---- destroy clean ----
local okD, errD = real.pcall(function() mod.destroy() end)
out.destroy_ok = okD; if not okD then out.destroy_err = real.tostring(errD) end

out.notifies = real.table.concat(NOTIFY, " | ")
out.errors   = (#ERRORS > 0) and real.table.concat(ERRORS, " ;; ") or "none"

local function ser(v) if real.type(v)=="table" then local s="{" for k,val in real.pairs(v) do s=s.."\n  "..real.tostring(k).." = "..ser(val) end return s.."\n}" else return real.tostring(v) end end
return ser(out)
'''
print(rt.execute(LUA))
