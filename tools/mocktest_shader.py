import os
import lupa

SRC = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "src"))

def read_file(rel):
    with open(os.path.join(SRC, *rel.split(".")) + ".lua", "r", encoding="utf-8") as f:
        return f.read()

rt = lupa.LuaRuntime(unpack_returned_tuples=True)
rt.globals().python_read_file = read_file
print("Lua:", rt.eval("_VERSION"))

# Drives REAL ui/feature + ui/components (incl. Dropdown) + modules/aesthetic:
# register -> enable each modular RTX effect feature -> verify the effect was
# created + Lighting applied -> switch Color Grade tint -> fire Heartbeat (motion
# blur) -> disable all -> verify cleanup. Catches runtime errors the parse check
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
local Workspace=svc("Workspace"); Workspace.CurrentCamera=newInst("Camera")
Workspace.CurrentCamera.CFrame={LookVector=V(0,0,1)}; Workspace.CurrentCamera.ViewportSize=V(1280,720,0)
local game=newInst("DataModel"); game.PlaceId=1; game.GameId=1
function game:GetService(n) if n=="Workspace" then return Workspace end return svc(n) end
local task={ spawn=function(fn,...) real.pcall(fn,...) end, delay=function() end, wait=function() end }

local CACHE={}
local GLOBALCACHE={}
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
local aesthetic=myrequire("modules.aesthetic")
local feature=myrequire("ui.feature")
local Lighting=game:GetService("Lighting")

local ok1,e1=real.pcall(function() aesthetic.register() end)
out.register_ok=ok1; if not ok1 then out.register_err=real.tostring(e1) end

local function enable(id)
  local ok,e=real.pcall(function() feature.setEnabled(id, true) end)
  if not ok then out[id.."_err"]=real.tostring(e) end
  return ok
end
local function countLive(cls) local n=0 for _,o in real.ipairs(ALL) do if not o._destroyed and o.ClassName==cls then n=n+1 end end return n end
local function findBtn(txt) for _,o in real.ipairs(ALL) do if not o._destroyed and o.ClassName=="TextButton" and o._p.Text==txt then return o end end end
local function countBtn(txt) local n=0 for _,o in real.ipairs(ALL) do if not o._destroyed and o.ClassName=="TextButton" and o._p.Text==txt then n=n+1 end end return n end

-- enable the MASTER -> cascade every effect on + apply the lighting
out.preset_ok = enable("aesthetic.preset")
out.brightness_applied = (Lighting.Brightness==6.67)
out.n_bloom=countLive("BloomEffect"); out.n_dof=countLive("DepthOfFieldEffect")
out.n_sun=countLive("SunRaysEffect"); out.n_cc=countLive("ColorCorrectionEffect"); out.n_blur=countLive("BlurEffect")

-- ENFORCE: the game overwrites Brightness -> a RenderStepped tick restores it
Lighting.Brightness = 99
real.pcall(function() game:GetService("RunService").RenderStepped:Fire() end)
out.enforce_restores = (Lighting.Brightness==6.67)

local okH,eH=real.pcall(function() game:GetService("RunService").Heartbeat:Fire() end)
out.heartbeat_ok=okH; if not okH then out.heartbeat_err=real.tostring(eH) end

-- Summer/Autumn removed; only "Default" (+ saved customs)
out.has_default = findBtn("Default") ~= nil
out.no_summer = findBtn("Summer") == nil
out.no_autumn = findBtn("Autumn") == nil

-- NAME + SAVE: type a name into the TextBox, hit Save -> option added + GLOBAL store
for _,o in real.ipairs(ALL) do if o.ClassName=="TextBox" then o._p.Text="MyShader" end end
local sb=findBtn("Save current as new preset"); if sb then real.pcall(function() sb._e.MouseButton1Click:Fire() end) end
out.save_named = findBtn("MyShader") ~= nil
local g = persist.getGlobal("aesthetic.shaderPresets")
out.save_global = (real.type(g)=="table" and g["MyShader"]~=nil)

-- a child toggles off without disabling the master
real.pcall(function() feature.setEnabled("aesthetic.bloom", false) end)
out.master_still_on = (feature.getEnabled("aesthetic.preset")==true)
out.bloom_off_independently = (countLive("BloomEffect")==0)

-- disable master -> all effects off + reset (Shader dropdown back to "Default")
real.pcall(function() feature.setEnabled("aesthetic.preset", false) end)
out.fx_after_disable = countLive("BloomEffect")+countLive("DepthOfFieldEffect")+countLive("SunRaysEffect")+countLive("ColorCorrectionEffect")+countLive("BlurEffect")
out.reset_dropdown = (countBtn("MyShader")==1)   -- cur reset to Default; only the option remains

-- re-enable -> defaults applied
real.pcall(function() feature.setEnabled("aesthetic.preset", true) end)
out.reenable_default = (Lighting.Brightness==6.67)
real.pcall(function() feature.setEnabled("aesthetic.preset", false) end)

local pass = ok1 and out.preset_ok and out.brightness_applied and out.n_bloom==1 and out.n_dof==1
  and out.n_sun==1 and out.n_cc==3 and out.n_blur==1 and out.enforce_restores and okH
  and out.has_default and out.no_summer and out.no_autumn and out.save_named and out.save_global
  and out.master_still_on and out.bloom_off_independently and out.fx_after_disable==0
  and out.reset_dropdown and out.reenable_default
local lines={}
for k,v in real.pairs(out) do lines[#lines+1]="  "..k.." = "..real.tostring(v) end
real.table.sort(lines)
return real.table.concat(lines,"\n").."\n\nRESULT: "..(pass and "ALL PASS" or "FAIL")
"""
print(rt.execute(LUA))
