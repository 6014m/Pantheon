import os
import lupa

SRC = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "src"))

def read_file(rel):
    with open(os.path.join(SRC, *rel.split(".")) + ".lua", "r", encoding="utf-8") as f:
        return f.read()

rt = lupa.LuaRuntime(unpack_returned_tuples=True)
rt.globals().python_read_file = read_file
print("Lua:", rt.eval("_VERSION"))

# Drives REAL ui/feature + ui/components + modules/aesthetic to verify the new
# Custom FOV "Speed FOV" mode: the set FOV is the floor; the lens widens with
# HORIZONTAL speed toward Max FOV at the reference speed; vertical (fall) speed is
# ignored; Max below floor never dips below the floor; smoothing eases (dt>0);
# disabling reverts to the camera's original FOV. The feature def is captured so
# settings onChange can be driven exactly (the same callbacks production runs).
LUA = r"""
local real = { math=math, string=string, table=table, os=os, pcall=pcall, ipairs=ipairs,
  pairs=pairs, tostring=tostring, tonumber=tonumber, type=type, select=select, next=next,
  setmetatable=setmetatable, rawset=rawset, rawget=rawget, assert=assert, print=print, error=error }

local Enum = real.setmetatable({}, { __index=function(t,c)
  local cat=real.setmetatable({_name=c}, { __index=function(cc,m)
    local it={_isEnumItem=true,_cat=cc._name,_name=m}; real.rawset(cc,m,it); return it end })
  real.rawset(t,c,cat); return cat end })

local function U(xs,xo,ys,yo) return {X={Scale=xs or 0,Offset=xo or 0},Y={Scale=ys or 0,Offset=yo or 0}} end
local UDim2 = { new=function(a,b,c,d) return U(a,b,c,d) end, fromOffset=function(a,b) return U(0,a,0,b) end, fromScale=function(a,b) return U(a,0,b,0) end }
local UDim  = { new=function(s,o) return {Scale=s or 0,Offset=o or 0} end }
local Color3= { new=function(r,g,b) return {_c3=true,R=r or 0,G=g or 0,B=b or 0} end,
  fromRGB=function(r,g,b) return {_c3=true,R=(r or 0)/255,G=(g or 0)/255,B=(b or 0)/255} end }
local VMT={}
local function V(x,y,z) return real.setmetatable({_v=true,X=x or 0,Y=y or 0,Z=z or 0}, VMT) end
VMT.__sub=function(a,b) return V(a.X-b.X,a.Y-b.Y,a.Z-b.Z) end
VMT.__index=function(t,k) if k=="Magnitude" then return real.math.sqrt(t.X*t.X+t.Y*t.Y+t.Z*t.Z) end return nil end
local Vector2={new=function(x,y) return V(x,y,0) end}
local Vector3={new=function(x,y,z) return V(x,y,z) end}

local function newEvent() local h={}; local e={}; function e:Connect(fn) h[#h+1]=fn; return {Disconnect=function() end} end
  function e:Fire(...) for _,fn in real.ipairs(h) do fn(...) end end return e end
local EVT={MouseButton1Click=true,InputBegan=true,InputChanged=true,InputEnded=true,Changed=true,
  ChildAdded=true,ChildRemoved=true,Heartbeat=true,RenderStepped=true,Stepped=true,FocusLost=true}

local MT
local function newInst(cls) return real.setmetatable({_inst=true,ClassName=cls,Name=cls,_ch={},_p={},_e={}}, MT) end
local function setParent(s,p) s._p.Parent=p; if p then p._ch[#p._ch+1]=s end end
local METH={}
function METH:GetChildren() local t={} for i,c in real.ipairs(self._ch) do t[i]=c end return t end
function METH:FindFirstChild(n) for _,c in real.ipairs(self._ch) do if c.Name==n then return c end end return nil end
function METH:Destroy() self._destroyed=true; self._p.Parent=nil end
function METH:Connect() return {Disconnect=function() end} end
function METH:GetPropertyChangedSignal() return { Connect=function() return {Disconnect=function() end} end } end
MT={ __index=function(s,k)
    if k=="Parent" then return s._p.Parent end
    if EVT[k] then s._e[k]=s._e[k] or newEvent(); return s._e[k] end
    if METH[k] then return METH[k] end
    if s._p[k]~=nil then return s._p[k] end
    if k=="AbsoluteSize" or k=="AbsolutePosition" or k=="AbsoluteContentSize" then return V(0,0,0) end
    return nil end,
  __newindex=function(s,k,v) if k=="Parent" then setParent(s,v) else s._p[k]=v end end }
local ALL={}
local Instance={ new=function(cls,parent) local o=newInst(cls); if parent then setParent(o,parent) end; ALL[#ALL+1]=o; return o end }

local SERVICES={}
local function svc(n) SERVICES[n]=SERVICES[n] or newInst(n); return SERVICES[n] end
local Workspace=svc("Workspace")
local camera=newInst("Camera"); Workspace.CurrentCamera=camera
camera.FieldOfView = 80                         -- the ORIGINAL FOV (restore target)
camera.CFrame={LookVector=V(0,0,1)}; camera.ViewportSize=V(1280,720,0)

-- LocalPlayer with a velocity-settable HumanoidRootPart, set up BEFORE the module
-- loads (it captures Players.LocalPlayer at require time).
local Players=svc("Players")
local char=Instance.new("Model")
local hrp=Instance.new("Part", char); hrp.Name="HumanoidRootPart"; hrp.AssemblyLinearVelocity=V(0,0,0)
local player=newInst("Player"); player.Character=char
Players.LocalPlayer=player

local game=newInst("DataModel"); game.PlaceId=1; game.GameId=1
function game:GetService(n) if n=="Workspace" then return Workspace end return svc(n) end
local task={ spawn=function(fn,...) real.pcall(fn,...) end, delay=function() end, wait=function() end }

local CACHE={}; local GLOBALCACHE={}
local persist={}
persist.get=function(k,d) local v=CACHE[k]; if v==nil then return d end return v end
persist.set=function(k,v) CACHE[k]=v end
persist.getGlobal=function(k,d) local v=GLOBALCACHE[k]; if v==nil then return d end return v end
persist.setGlobal=function(k,v) GLOBALCACHE[k]=v end
persist.scheduleSave=function() end; persist.flush=function() end
persist.slug=function(s) s=real.string.lower(s or "_"); s=real.string.gsub(s,"[^%w]+","_"); s=real.string.gsub(s,"^_+",""); s=real.string.gsub(s,"_+$",""); if s=="" then return "_" end return s end
persist.keyToString=function(k) if not k then return nil end return real.tostring(k) end
persist.stringToKey=function(s) if s==nil then return nil end return Enum.KeyCode.Unknown end

local cache={}
local ENV
local REAL={ ["ui.theme"]=true, ["ui.components"]=true, ["ui.feature"]=true, ["modules.aesthetic"]=true }
local function stub(name)
  if name=="core.persist" then return persist end
  if name=="ui.hex" then return { build=function() return {} end, setColor=function() end, placed=function() return {} end } end
  if name=="core.keybinds" then return { set=function() end, clear=function() end, init=function() end } end
  if name=="core.log" then return { info=function() end, warn=function() end, err=function() end, error=function() end, debug=function() end } end
  if name=="ui.window" then return { parent=function() return newInst("Folder") end } end
  if name=="ui.container" then return { new=function() return { add=function() end } end } end
  return real.setmetatable({}, {__index=function() return function() end end})
end
local function myrequire(name)
  if cache[name]~=nil then return cache[name] end
  if REAL[name] then local chunk=real.assert(load(python_read_file(name), "@"..name, "t", ENV)); local m=chunk(); cache[name]=m; return m end
  local s=stub(name); cache[name]=s; return s
end
local mathShim=real.setmetatable({ clamp=function(x,lo,hi) if x<lo then return lo elseif x>hi then return hi else return x end end }, { __index=real.math })
ENV=real.setmetatable({ Instance=Instance, Enum=Enum, UDim2=UDim2, UDim=UDim, Color3=Color3,
  Vector2=Vector2, Vector3=Vector3, game=game, workspace=Workspace, task=task, require=myrequire,
  math=mathShim, warn=function() end, print=real.print, tick=os.clock }, { __index=_G })

local out={}

-- Load feature FIRST and capture every declared def so we can drive its settings.
local feature=myrequire("ui.feature")
local captured={}
local realDeclare=feature.declare
feature.declare=function(def) captured[def.id or "?"]=def; return realDeclare(def) end

local aesthetic=myrequire("modules.aesthetic")
local ok1,e1=real.pcall(function() aesthetic.register() end)
out.register_ok=ok1; if not ok1 then out.register_err=real.tostring(e1) end

local fov=captured["aesthetic.fov"]
out.fov_captured=fov~=nil
out.has_speed_setting=false
out.has_max_setting=false
out.has_ref_setting=false
if fov and fov.settings then
  for _,o in real.ipairs(fov.settings) do
    if o.key=="speed"    then out.has_speed_setting=true end
    if o.key=="maxfov"   then out.has_max_setting=true end
    if o.key=="refspeed" then out.has_ref_setting=true end
  end
end

local function setOpt(key,val) for _,o in real.ipairs(fov.settings) do if o.key==key then o.onChange(val) end end end
local function tick(dt) SERVICES.RunService.RenderStepped:Fire(dt) end
local function setVel(x,y,z) hrp.AssemblyLinearVelocity=V(x,y,z) end
local function approx(a,b) return real.math.abs(a-b) < 0.5 end

-- ---- static Custom FOV (no speed mode): forces the set FOV exactly ----
setOpt("value", 70)
real.pcall(function() feature.setEnabled("aesthetic.fov", true) end)
tick(); out.static_fov = approx(camera.FieldOfView, 70)

-- ---- enable Speed FOV mode; base 70, max 110, ref 50 ----
setOpt("speed", true); setOpt("maxfov", 110); setOpt("refspeed", 50)

setVel(0,0,0);     tick(); out.floor_at_rest   = approx(camera.FieldOfView, 70)   -- speed 0 -> floor
setVel(50,0,0);    tick(); out.max_at_refspeed = approx(camera.FieldOfView, 110)  -- speed 50 == ref -> max
setVel(25,0,0);    tick(); out.half_speed_mid  = approx(camera.FieldOfView, 90)   -- speed 25 -> midpoint
setVel(0,100,0);   tick(); out.vertical_ignored= approx(camera.FieldOfView, 70)   -- only falling -> floor
setVel(1000,0,0);  tick(); out.clamped_at_max  = approx(camera.FieldOfView, 110)  -- way over ref -> still max

-- ---- Max below floor must never dip below the floor ----
setOpt("maxfov", 50)        -- below base 70
setVel(1000,0,0); tick(); out.floor_enforced = approx(camera.FieldOfView, 70)
setOpt("maxfov", 110)

-- ---- smoothing: from floor, one dt=0.1 step toward max eases partway (~93.7) ----
setVel(0,0,0);    tick()                  -- snap cur to floor 70
setVel(50,0,0); tick(0.1)                 -- target 110, eased: 70 + 40*(1-e^-0.9) ~ 93.7
out.smoothing_eases = (camera.FieldOfView > 71) and (camera.FieldOfView < 109) and approx(camera.FieldOfView, 93.7)

-- ---- disable -> revert to the camera's ORIGINAL FOV (80), not floor/max ----
real.pcall(function() feature.setEnabled("aesthetic.fov", false) end)
out.revert_on_disable = approx(camera.FieldOfView, 80)

local okD,eD=real.pcall(function() aesthetic.destroy() end)
out.destroy_ok=okD; if not okD then out.destroy_err=real.tostring(eD) end

local pass = ok1 and out.fov_captured and out.has_speed_setting and out.has_max_setting and out.has_ref_setting
  and out.static_fov and out.floor_at_rest and out.max_at_refspeed and out.half_speed_mid
  and out.vertical_ignored and out.clamped_at_max and out.floor_enforced and out.smoothing_eases
  and out.revert_on_disable and okD
local lines={}
for k,v in real.pairs(out) do lines[#lines+1]="  "..k.." = "..real.tostring(v) end
real.table.sort(lines)
return real.table.concat(lines,"\n").."\n\nRESULT: "..(pass and "ALL PASS" or "FAIL")
"""
print(rt.execute(LUA))
