import os
import lupa

SRC = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "src"))

def read_file(rel):
    path = os.path.join(SRC, *rel.split(".")) + ".lua"
    with open(path, "r", encoding="utf-8") as f:
        return f.read()

rt = lupa.LuaRuntime(unpack_returned_tuples=True)
G = rt.globals()
G.python_read_file = read_file
print("Lua:", rt.eval("_VERSION"))

# Mock-executes the REAL ui/feature.lua + ui/components.lua against an in-memory
# persist, proving the load path respects a saved `false` (the
# "Battlegrounds-safe doesn't save" bug). Buggy `(saved ~= nil) and saved or
# default` would resurrect default=true toggles to ON; resolveSaved must not.
LUA = r"""
local real = { math=math, string=string, table=table, os=os, pcall=pcall, error=error,
  assert=assert, ipairs=ipairs, pairs=pairs, tostring=tostring, tonumber=tonumber,
  type=type, select=select, next=next, setmetatable=setmetatable, getmetatable=getmetatable,
  rawget=rawget, rawset=rawset, print=print }

local EnumCatMT = { __index=function(cat, member)
  local item={_isEnumItem=true,_cat=cat._name,_name=member}
  real.setmetatable(item,{__tostring=function(s) return "Enum."..s._cat.."."..s._name end})
  real.rawset(cat, member, item); return item end }
local Enum = real.setmetatable({}, { __index=function(t,c)
  local cat=real.setmetatable({_name=c}, EnumCatMT); real.rawset(t,c,cat); return cat end })

local function UDim2new(xs,xo,ys,yo) return {_udim2=true,X={Scale=xs or 0,Offset=xo or 0},Y={Scale=ys or 0,Offset=yo or 0}} end
local UDim2 = { new=function(a,b,c,d) return UDim2new(a,b,c,d) end,
  fromOffset=function(a,b) return UDim2new(0,a,0,b) end, fromScale=function(a,b) return UDim2new(a,0,b,0) end }
local UDim = { new=function(s,o) return {Scale=s or 0,Offset=o or 0} end }
local Color3 = { new=function(r,g,b) return {_color3=true,R=r or 0,G=g or 0,B=b or 0} end,
  fromRGB=function(r,g,b) return {_color3=true,R=(r or 0)/255,G=(g or 0)/255,B=(b or 0)/255} end }
local function V(x,y,z) return {_vector=true,X=x or 0,Y=y or 0,Z=z or 0} end
local Vector2 = { new=function(x,y) return V(x,y,0) end }

local function newEvent(name)
  local handlers={}
  local ev={_event=true,_name=name}
  function ev:Connect(fn) handlers[#handlers+1]=fn; return {Disconnect=function() end} end
  function ev:Fire(...) for _,fn in real.ipairs(handlers) do fn(...) end end
  return ev
end
local EVENT_NAMES={MouseButton1Click=true,InputBegan=true,InputChanged=true,InputEnded=true,
  FocusLost=true,Changed=true,ChildAdded=true,ChildRemoved=true}

local InstanceMT
local function newInstance(cls)
  return real.setmetatable({_isInstance=true,ClassName=cls,Name=cls,_children={},_props={},_events={}}, InstanceMT)
end
local function setParent(self,parent)
  self._props.Parent=parent
  if parent then parent._children[#parent._children+1]=self end
end
InstanceMT={
  __index=function(self,k)
    if k=="Parent" then return self._props.Parent end
    if EVENT_NAMES[k] then self._events[k]=self._events[k] or newEvent(k); return self._events[k] end
    if self._props[k]~=nil then return self._props[k] end
    if k=="AbsoluteSize" or k=="AbsolutePosition" then return V(0,0,0) end
    return nil
  end,
  __newindex=function(self,k,v) if k=="Parent" then setParent(self,v) else self._props[k]=v end end,
}
local ALL={}
local Instance={ new=function(cls,parent) local o=newInstance(cls); if parent then setParent(o,parent) end; ALL[#ALL+1]=o; return o end }

local SERVICES={ UserInputService=newInstance("UserInputService") }
local game=newInstance("DataModel"); game.PlaceId=123
function game:GetService(n) SERVICES[n]=SERVICES[n] or newInstance(n); return SERVICES[n] end

-- ---- in-memory persist (mirrors core/persist.lua's API + key helpers) -------
local CACHE={}
local persist={}
function persist.get(k,d) local v=CACHE[k]; if v==nil then return d end; return v end
function persist.set(k,v) CACHE[k]=v end
function persist.scheduleSave() end
function persist.flush() end
function persist.keyToString(k) if not k then return nil end; if k==Enum.KeyCode.Unknown then return "" end; return (real.tostring(k):gsub("Enum.KeyCode.","")) end
function persist.stringToKey(s) if s==nil then return nil end; if s=="" then return Enum.KeyCode.Unknown end; return Enum.KeyCode[s] or Enum.KeyCode.Unknown end
function persist.slug(s) if not s or s=="" then return "_" end; s=real.string.lower(s); s=real.string.gsub(s,"[^%w]+","_"); s=real.string.gsub(s,"^_+",""); s=real.string.gsub(s,"_+$",""); if s=="" then return "_" end; return s end

local cache={}
local ENV
local function stub(name)
  if name=="core.persist" then return persist end
  if name=="ui.hex" then return { build=function() return {} end, setColor=function() end } end
  if name=="core.keybinds" then return { set=function() end, clear=function() end, init=function() end } end
  if name=="core.log" then return { info=function() end, warn=function() end, error=function() end, debug=function() end } end
  return real.setmetatable({}, {__index=function() return function() end end})
end
local REAL={ ["ui.theme"]=true, ["ui.components"]=true, ["ui.feature"]=true }
local function myrequire(name)
  if cache[name]~=nil then return cache[name] end
  if REAL[name] then
    local chunk=real.assert(load(python_read_file(name), "@"..name, "t", ENV))
    local mod=chunk(); cache[name]=mod; return mod
  end
  local s=stub(name); cache[name]=s; return s
end
local mathShim=real.setmetatable({ clamp=function(x,lo,hi) if x<lo then return lo elseif x>hi then return hi else return x end end }, { __index=real.math })

ENV=real.setmetatable({ Instance=Instance, Enum=Enum, UDim2=UDim2, UDim=UDim, Color3=Color3,
  Vector2=Vector2, game=game, math=mathShim, require=myrequire,
  warn=function() end, print=real.print, tick=os.clock }, { __index=_G })

local feature=myrequire("ui.feature")

local function makeDef(idp)
  local cap={}
  local def={ id=idp, name="LockOnTest", default=true,
    onToggle=function(v) cap.master=v end,
    settings={
      { type="toggle", name="Battlegrounds-safe", key="bg_safe", default=true, onChange=function(v) cap.bg=v end },
      { type="toggle", name="Camera Lock",        key="cam",     default=true, onChange=function(v) cap.cam=v end },
      { type="toggle", name="Self-fade",          key="fade",    default=false,onChange=function(v) cap.fade=v end },
      { type="slider", name="Range", key="rng", min=0, max=10, step=1, default=5, onChange=function(v) cap.rng=v end },
    } }
  return def, cap
end

local out={}

-- CASE 1: nothing saved -> declared defaults apply
do
  for k in real.pairs(CACHE) do CACHE[k]=nil end
  local def,cap=makeDef("c1")
  feature.declare(def)
  out.c1_master=cap.master; out.c1_bg=cap.bg; out.c1_cam=cap.cam; out.c1_fade=cap.fade; out.c1_rng=cap.rng
end

-- CASE 2: user turned the default=true things OFF (and slider to 0) -> must stick
do
  for k in real.pairs(CACHE) do CACHE[k]=nil end
  CACHE["c2.enabled"]=false
  CACHE["c2.bg_safe"]=false
  CACHE["c2.cam"]=false
  CACHE["c2.fade"]=true     -- a default=false toggle turned ON must also stick
  CACHE["c2.rng"]=0
  local def,cap=makeDef("c2")
  feature.declare(def)
  out.c2_master=cap.master; out.c2_bg=cap.bg; out.c2_cam=cap.cam; out.c2_fade=cap.fade; out.c2_rng=cap.rng
end

local function eq(a,b) return a==b end
local checks={
  {"c1 master default ON", eq(out.c1_master,true)},
  {"c1 bg default ON",     eq(out.c1_bg,true)},
  {"c1 fade default OFF",  eq(out.c1_fade,false)},
  {"c1 rng default 5",     eq(out.c1_rng,5)},
  {"c2 master saved OFF",  eq(out.c2_master,false)},
  {"c2 bg saved OFF",      eq(out.c2_bg,false)},
  {"c2 cam saved OFF",     eq(out.c2_cam,false)},
  {"c2 fade saved ON",     eq(out.c2_fade,true)},
  {"c2 rng saved 0",       eq(out.c2_rng,0)},
}
local allok=true
local lines={}
for _,c in real.ipairs(checks) do
  local ok=c[2]; if not ok then allok=false end
  lines[#lines+1]=(ok and "PASS " or "FAIL ")..c[1]
end
lines[#lines+1]=allok and "\nRESULT: ALL PASS" or "\nRESULT: FAILURES PRESENT"
return real.table.concat(lines,"\n")
"""

print(rt.execute(LUA))
