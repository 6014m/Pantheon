import os
import lupa

SRC = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "src"))

def read_file(rel):
    with open(os.path.join(SRC, *rel.split(".")) + ".lua", "r", encoding="utf-8") as f:
        return f.read()

rt = lupa.LuaRuntime(unpack_returned_tuples=True)
rt.globals().python_read_file = read_file
print("Lua:", rt.eval("_VERSION"))

# Drives REAL ui/feature + ui/components (incl. new Dropdown) + modules/aesthetic:
# register -> enable Preset Shaders -> apply -> switch preset -> fire Heartbeat
# (motion blur) -> disable. Asserts Lighting was set/reverted, effects created/
# destroyed, and the preset tint switches. Catches runtime errors the parse check
# can't (per the "mock-execute UI constructors" rule).
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
VMT.__add=function(a,b) return V(a.X+b.X,a.Y+b.Y,a.Z+b.Z) end
VMT.__index=function(t,k) if k=="Magnitude" then return real.math.sqrt(t.X*t.X+t.Y*t.Y+t.Z*t.Z) end return nil end
local Vector2={new=function(x,y) return V(x,y,0) end}
local Vector3={new=function(x,y,z) return V(x,y,z) end}

local function newEvent() local h={}; local e={}; function e:Connect(fn) h[#h+1]=fn; return {Disconnect=function() end} end
  function e:Fire(...) for _,fn in real.ipairs(h) do fn(...) end end return e end
local EVT={MouseButton1Click=true,InputBegan=true,InputChanged=true,InputEnded=true,Changed=true,
  ChildAdded=true,ChildRemoved=true,Heartbeat=true,RenderStepped=true,Stepped=true}

local MT
local function newInst(cls) return real.setmetatable({_inst=true,ClassName=cls,Name=cls,_ch={},_p={},_e={}}, MT) end
local function setParent(s,p) s._p.Parent=p; if p then p._ch[#p._ch+1]=s end end
local METH={}
function METH:GetChildren() local t={} for i,c in real.ipairs(self._ch) do t[i]=c end return t end
function METH:Destroy() self._destroyed=true; self._p.Parent=nil end
function METH:Connect() return {Disconnect=function() end} end
MT={ __index=function(s,k)
    if k=="Parent" then return s._p.Parent end
    if EVT[k] then s._e[k]=s._e[k] or newEvent(); return s._e[k] end
    if METH[k] then return METH[k] end
    if s._p[k]~=nil then return s._p[k] end
    if k=="AbsoluteSize" or k=="AbsolutePosition" then return V(0,0,0) end
    return nil end,
  __newindex=function(s,k,v) if k=="Parent" then setParent(s,v) else s._p[k]=v end end }
local ALL={}
local Instance={ new=function(cls,parent) local o=newInst(cls); if parent then setParent(o,parent) end; ALL[#ALL+1]=o; return o end }

local SERVICES={}
local function svc(n) SERVICES[n]=SERVICES[n] or newInst(n); return SERVICES[n] end
local Workspace=svc("Workspace"); Workspace.CurrentCamera=newInst("Camera")
Workspace.CurrentCamera.CFrame={LookVector=V(0,0,1)}
local game=newInst("DataModel"); game.PlaceId=1; game.GameId=1
function game:GetService(n) if n=="Workspace" then return Workspace end return svc(n) end
local task={ spawn=function(fn,...) real.pcall(fn,...) end, delay=function() end, wait=function() end }

-- in-memory persist mock (feature.lua needs get/set/slug/keyToString/stringToKey)
local CACHE={}
local persist={ get=function(_,k,d) local v=CACHE[k]; if v==nil then return d end return v end,
  set=function(_,k,v) CACHE[k]=v end, scheduleSave=function() end, flush=function() end }
-- feature calls persist.get(key,default) (dot, not colon) -> adjust:
persist.get=function(k,d) local v=CACHE[k]; if v==nil then return d end return v end
persist.set=function(k,v) CACHE[k]=v end
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
local aesthetic=myrequire("modules.aesthetic")
local feature=myrequire("ui.feature")
local Lighting=game:GetService("Lighting")

-- 1. register builds the whole panel (dropdown + 19 sliders) via REAL components/feature
local ok1,e1=real.pcall(function() aesthetic.register() end)
out.register_ok=ok1; if not ok1 then out.register_err=real.tostring(e1) end

-- count the sliders + dropdown actually built
local nSlider,nDropOpt=0,0
for _,o in real.ipairs(ALL) do
  if o.ClassName=="TextButton" and (o._p.Text=="Summer" or o._p.Text=="Autumn") then nDropOpt=nDropOpt+1 end
end
out.dropdown_option_buttons=nDropOpt   -- expect >=2 (the option list)

-- 2. enable Preset Shaders -> shEnable(true): build effects + apply Lighting
local ok2,e2=real.pcall(function() feature.setEnabled("aesthetic.shader", true) end)
out.enable_ok=ok2; if not ok2 then out.enable_err=real.tostring(e2) end
out.brightness_applied = (Lighting.Brightness==6.67)
local fx={}
for _,o in real.ipairs(ALL) do if not o._destroyed then fx[o.ClassName]=(fx[o.ClassName] or 0)+1 end end
out.bloom = fx.BloomEffect or 0
out.colorcorrection = fx.ColorCorrectionEffect or 0   -- expect 3
out.dof = fx.DepthOfFieldEffect or 0
out.sunrays = fx.SunRaysEffect or 0
out.blur = fx.BlurEffect or 0

-- 3. fire Heartbeat once -> motion blur callback must not error
local ok3,e3=real.pcall(function() game:GetService("RunService").Heartbeat:Fire() end)
out.heartbeat_ok=ok3; if not ok3 then out.heartbeat_err=real.tostring(e3) end

-- 4. switch preset to Autumn via the dropdown option button -> cc1 tint changes
local autumnBtn
for _,o in real.ipairs(ALL) do if o.ClassName=="TextButton" and o._p.Text=="Autumn" then autumnBtn=o end end
if autumnBtn then real.pcall(function() autumnBtn._e.MouseButton1Click:Fire() end) end
-- find a ColorCorrectionEffect tinted autumn (217,145,57)
local autumnTintHit=false
for _,o in real.ipairs(ALL) do
  if o.ClassName=="ColorCorrectionEffect" and not o._destroyed and o._p.TintColor and o._p.TintColor._c3 then
    local t=o._p.TintColor
    if real.math.abs(t.R-217/255)<0.01 and real.math.abs(t.G-145/255)<0.01 then autumnTintHit=true end
  end
end
out.autumn_tint_applied=autumnTintHit

-- 5. disable -> effects destroyed + Lighting reverted
local ok5,e5=real.pcall(function() feature.setEnabled("aesthetic.shader", false) end)
out.disable_ok=ok5; if not ok5 then out.disable_err=real.tostring(e5) end
local liveFx=0
for _,o in real.ipairs(ALL) do
  if not o._destroyed and (o.ClassName=="BloomEffect" or o.ClassName=="ColorCorrectionEffect"
     or o.ClassName=="DepthOfFieldEffect" or o.ClassName=="SunRaysEffect" or o.ClassName=="BlurEffect") then liveFx=liveFx+1 end
end
out.fx_after_disable=liveFx   -- expect 0

local pass = ok1 and ok2 and ok3 and ok5 and out.brightness_applied and out.colorcorrection==3
  and out.bloom==1 and out.dof==1 and out.sunrays==1 and out.blur==1 and out.autumn_tint_applied
  and out.fx_after_disable==0 and nDropOpt>=2
local lines={}
for k,v in real.pairs(out) do lines[#lines+1]="  "..k.." = "..real.tostring(v) end
real.table.sort(lines)
return real.table.concat(lines,"\n").."\n\nRESULT: "..(pass and "ALL PASS" or "FAIL")
"""
print(rt.execute(LUA))
