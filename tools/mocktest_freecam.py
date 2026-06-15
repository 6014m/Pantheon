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

# Verifies the OpenGui-style freecam: enable spawns an invisible anchored follow-
# part, points camera.CameraSubject at it, and anchors the body; held keys fly the
# part (view-relative, smoothed); game-processed input (typing) is ignored; a respawn
# re-anchors the new root; disable restores CameraSubject + un-anchors + destroys the
# part + disconnects. CFrame is mocked functionally enough to prove the part MOVES.
LUA = r'''
local real = { math=math, string=string, table=table, pcall=pcall, error=error,
  assert=assert, ipairs=ipairs, pairs=pairs, tostring=tostring, tonumber=tonumber,
  type=type, select=select, next=next, setmetatable=setmetatable, print=print, load=load }
local ERRORS, NOTIFY = {}, {}

----------------------------------------------------------------- Vector3
local VMT = {}
local function v3(x, y, z) return real.setmetatable({ _v3=true, X=x or 0, Y=y or 0, Z=z or 0 }, VMT) end
VMT.__sub = function(a, b) return v3(a.X-b.X, a.Y-b.Y, a.Z-b.Z) end
VMT.__add = function(a, b) return v3(a.X+b.X, a.Y+b.Y, a.Z+b.Z) end

----------------------------------------------------------------- CFrame
-- Position-only model. Rotation is ignored (the aim line keeps position), which is
-- all we need to prove WASD translates the follow-part.
local CFMT = {}
local function cf(pos) return real.setmetatable({ _cf=true, _pos=pos }, CFMT) end
CFMT.__index = function(self, k)
  if k == "Position" or k == "p" then return self._pos
  elseif k == "Lerp" then
    return function(s, goal, t)
      return cf(v3(s._pos.X + (goal._pos.X - s._pos.X) * t,
                   s._pos.Y + (goal._pos.Y - s._pos.Y) * t,
                   s._pos.Z + (goal._pos.Z - s._pos.Z) * t))
    end
  end
  return nil
end
CFMT.__mul = function(a, b) return cf(v3(a._pos.X+b._pos.X, a._pos.Y+b._pos.Y, a._pos.Z+b._pos.Z)) end
local CFrame = { new = function(a, b, c)
  if real.type(a) == "table" and a._v3 then return cf(a) end          -- new(pos) or new(pos, lookAt)
  return cf(v3(a or 0, b or 0, c or 0))                                -- new(x,y,z) / new()
end }

----------------------------------------------------------------- Enum
local function sent(n) return real.setmetatable({ _e=n }, { __tostring=function() return n end }) end
local Enum = { KeyCode = {
  W=sent("W"), A=sent("A"), S=sent("S"), D=sent("D"),
  Space=sent("Space"), Q=sent("Q"), E=sent("E"), LeftControl=sent("LeftControl") } }

----------------------------------------------------------------- events
local function newEvent()
  local h = {}
  local e = { _h = h }
  function e:Connect(fn) h[#h+1] = fn
    return { Disconnect = function() for i,x in real.ipairs(h) do if x==fn then real.table.remove(h,i); break end end end } end
  function e:Fire(...) local snap = {} for i,fn in real.ipairs(h) do snap[i]=fn end
    for _,fn in real.ipairs(snap) do local ok,err = real.pcall(fn, ...); if not ok then ERRORS[#ERRORS+1]=real.tostring(err) end end end
  return e
end

----------------------------------------------------------------- Instances
local EVENTS = { RenderStepped=true, InputBegan=true, InputEnded=true, CharacterAdded=true }
local InstanceMT
local function newInstance(cls) return real.setmetatable({ _inst=true, ClassName=cls, Name=cls, _ch={}, _props={}, _events={} }, InstanceMT) end
local function setParent(self, parent)
  local old = self._props.Parent
  if old then for i,c in real.ipairs(old._ch) do if c==self then real.table.remove(old._ch,i); break end end end
  self._props.Parent = parent
  if parent then parent._ch[#parent._ch+1] = self end
end
local METHODS = {}
function METHODS:FindFirstChild(n) for _,c in real.ipairs(self._ch) do if c.Name==n then return c end end return nil end
function METHODS:FindFirstChildOfClass(cl) for _,c in real.ipairs(self._ch) do if c.ClassName==cl then return c end end return nil end
function METHODS:FindFirstChildWhichIsA(cl) for _,c in real.ipairs(self._ch) do if c.ClassName==cl then return c end end return nil end
function METHODS:Destroy() self._destroyed = true; setParent(self, nil) end
InstanceMT = {
  __index = function(self, k)
    if k == "Parent" then return self._props.Parent end
    if EVENTS[k] then self._events[k] = self._events[k] or newEvent(); return self._events[k] end
    if METHODS[k] then return METHODS[k] end
    return self._props[k]
  end,
  __newindex = function(self, k, v) if k == "Parent" then setParent(self, v) else self._props[k] = v end end,
}
local Instance = { new = function(cls) return newInstance(cls) end }

local function mkChar(name)
  local m = newInstance("Model"); m.Name = name
  local hrp = newInstance("Part"); hrp.Name = "HumanoidRootPart"; setParent(hrp, m)
  local hum = newInstance("Humanoid"); setParent(hum, m)
  m.PrimaryPart = hrp
  return m, hrp, hum
end

----------------------------------------------------------------- services
local camera = newInstance("Camera"); camera.CFrame = CFrame.new(0, 0, 0)
local Workspace = newInstance("Workspace"); Workspace.CurrentCamera = camera

local char0, hrp0, hum0 = mkChar("Char0")
local LocalPlayer = newInstance("Player"); LocalPlayer.Character = char0
local Players = { LocalPlayer = LocalPlayer }

-- PlayerModule controls: the freecam disables these instead of anchoring
local controlsDisabled = false
local controlsObj = { Disable = function() controlsDisabled = true end, Enable = function() controlsDisabled = false end }
local playerModuleTable = { GetControls = function() return controlsObj end }
local playerScripts = newInstance("PlayerScripts"); setParent(playerScripts, LocalPlayer)
local playerModule  = newInstance("ModuleScript"); playerModule.Name = "PlayerModule"; setParent(playerModule, playerScripts)
local REAL_ENV = { require = function(_) return playerModuleTable end }   -- what getrenv().require returns

local RunService = { RenderStepped = newEvent() }
local UIS = { InputBegan = newEvent(), InputEnded = newEvent() }

local SERVICES = { RunService=RunService, UserInputService=UIS, Players=Players, Workspace=Workspace }
local game = {}
function game:GetService(n) return SERVICES[n] end

----------------------------------------------------------------- module stubs
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
  game=game, CFrame=CFrame, Enum=Enum, Instance=Instance, require=myrequire,
  getrenv=function() return REAL_ENV end,
  Vector3={ zero=v3(0,0,0), new=function(x,y,z) return v3(x,y,z) end },
  pcall=real.pcall, ipairs=real.ipairs, pairs=real.pairs, tostring=real.tostring,
  tonumber=real.tonumber, type=real.type, select=real.select, next=real.next,
  setmetatable=real.setmetatable, error=real.error, assert=real.assert, print=real.print,
  warn=function() end, math=real.math, string=real.string, table=real.table,
}, { __index = _G })

local src   = python_read_file("modules.misc.freecam")
local chunk = real.assert(real.load(src, "@freecam", "t", ENV))
local mod   = chunk()

local out = {}
out.loaded = (mod ~= nil) and (mod.register ~= nil) and (mod.destroy ~= nil)

local box = { added = 0 }
function box:add(_) self.added = self.added + 1 end
local okR, errR = real.pcall(function() mod.register(box) end)
out.register_ok = okR; if not okR then out.register_err = real.tostring(errR) end
out.feature_id  = capturedDef and capturedDef.id or "nil"
out.has_2_sliders = capturedDef and capturedDef.settings and (#capturedDef.settings == 2)

local function tick() RunService.RenderStepped:Fire(0.016) end
local function press(kc)   UIS.InputBegan:Fire({ KeyCode = kc }, false) end
local function typed(kc)   UIS.InputBegan:Fire({ KeyCode = kc }, true)  end   -- game-processed
local function release(kc) UIS.InputEnded:Fire({ KeyCode = kc }) end

-- ---- enable ----
real.pcall(function() capturedDef.onToggle(true) end)
local cp = camera.CameraSubject
out.enable_made_part   = (cp ~= nil) and (cp.ClassName == "Part") and (cp.Anchored == true) and (cp.Transparency == 1)
out.enable_part_parented = (cp ~= nil) and (cp.Parent == Workspace)
out.enable_subject      = (camera.CameraSubject == cp)
out.enable_controls_off = (controlsDisabled == true)
out.enable_not_anchored = (hrp0.Anchored ~= true)               -- body is NOT anchored
out.enable_connected    = (#RunService.RenderStepped._h == 1) and (#UIS.InputBegan._h == 1)
  and (#UIS.InputEnded._h == 1) and (#LocalPlayer.CharacterAdded._h == 1)

-- ---- typing is ignored: a game-processed W must NOT move the part ----
typed(Enum.KeyCode.W)
for _ = 1, 6 do tick() end
out.typing_ignored = (real.math.abs(cp.CFrame.Position.Z) < 0.5)

-- ---- real input flies the part forward (-Z) ----
press(Enum.KeyCode.W)
for _ = 1, 30 do tick() end
out.fly_forward = (cp.CFrame.Position.Z < -1)
release(Enum.KeyCode.W)

-- ---- respawn while active: controls re-disabled on the new character, no anchor ----
local char1, hrp1, hum1 = mkChar("Char1")
LocalPlayer.Character = char1
controlsDisabled = false                       -- simulate the controller re-enabling on spawn
LocalPlayer.CharacterAdded:Fire(char1)          -- module should re-disable the controls
tick()
out.respawn_recontrolled = (controlsDisabled == true)
out.respawn_not_anchored = (hrp1.Anchored ~= true)

-- ---- disable: camera handed back, controls re-enabled, part gone ----
real.pcall(function() capturedDef.onToggle(false) end)
out.disable_subject_hum  = (camera.CameraSubject == hum1)
out.disable_controls_on  = (controlsDisabled == false)
out.disable_part_gone    = (cp._destroyed == true) and (cp.Parent == nil)
out.disable_disconnected = (#RunService.RenderStepped._h == 0) and (#UIS.InputBegan._h == 0)
  and (#UIS.InputEnded._h == 0) and (#LocalPlayer.CharacterAdded._h == 0)

-- ---- a stray RenderStepped after disable is inert (no error) ----
tick()
out.inert_after_disable = true

local okD, errD = real.pcall(function() mod.destroy() end)
out.destroy_ok = okD; if not okD then out.destroy_err = real.tostring(errD) end

out.notifies = real.table.concat(NOTIFY, " | ")
out.errors   = (#ERRORS > 0) and real.table.concat(ERRORS, " ;; ") or "none"

local pass = out.loaded and out.register_ok and out.has_2_sliders and out.enable_made_part
  and out.enable_part_parented and out.enable_subject and out.enable_controls_off and out.enable_not_anchored
  and out.enable_connected and out.typing_ignored and out.fly_forward
  and out.respawn_recontrolled and out.respawn_not_anchored
  and out.disable_subject_hum and out.disable_controls_on and out.disable_part_gone and out.disable_disconnected
  and out.destroy_ok and (out.errors == "none")

local function ser(v) if real.type(v)=="table" then local s="{" for k,val in real.pairs(v) do s=s.."\n  "..real.tostring(k).." = "..ser(val) end return s.."\n}" else return real.tostring(v) end end
return ser(out) .. "\n\nRESULT: " .. (pass and "ALL PASS" or "FAIL")
'''
print(rt.execute(LUA))
