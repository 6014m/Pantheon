#!/usr/bin/env python3
"""Offline mock-test for modules/misc/autoobby.lua.

Loads the module under a fake Roblox env and checks:
  * the feature declaration (id / name / default / keybind / settings),
  * jump-physics reachability + jumpVelocity math,
  * the damage-block heuristic (name / ancestor name / colour / material),
  * findLanding picks a reachable SAFE platform and skips a kill brick / unreachable,
  * setActive() lifecycle wires + tears down the click hook cleanly.

The hop loop itself (task.spawn) is stubbed out so we test decisions, not the
live coroutine; real obby behaviour still needs an in-game check.
"""
import sys
from lupa import LuaRuntime

SRC = open(r"C:\Users\killt\Desktop\custom scripts\[Uni] Pantheon\src\modules\misc\autoobby.lua",
           "r", encoding="utf-8").read()

PREAMBLE = r"""
__DEF = nil
__SPAWNED = 0

-- math.clamp isn't used, but Vector3 needs sqrt etc (std lib present)

-- ---- Vector3 ----
local VMT = {}
function VMT.__add(a,b) return Vector3.new(a.X+b.X,a.Y+b.Y,a.Z+b.Z) end
function VMT.__sub(a,b) return Vector3.new(a.X-b.X,a.Y-b.Y,a.Z-b.Z) end
function VMT.__mul(a,b)
  if type(a)=="number" then return Vector3.new(b.X*a,b.Y*a,b.Z*a) end
  if type(b)=="number" then return Vector3.new(a.X*b,a.Y*b,a.Z*b) end
  return Vector3.new(a.X*b.X,a.Y*b.Y,a.Z*b.Z)
end
VMT.__index = function(self,k)
  if k=="Magnitude" then return math.sqrt(self.X*self.X+self.Y*self.Y+self.Z*self.Z) end
  if k=="Unit" then local m=math.sqrt(self.X*self.X+self.Y*self.Y+self.Z*self.Z)
    if m==0 then return Vector3.new(0,0,0) end
    return Vector3.new(self.X/m,self.Y/m,self.Z/m) end
  if k=="Dot" then return function(s,o) return s.X*o.X+s.Y*o.Y+s.Z*o.Z end end
  return nil
end
Vector3 = { new=function(x,y,z) return setmetatable({X=x or 0,Y=y or 0,Z=z or 0}, VMT) end }

CFrame = { lookAt=function(a,b) return { LookVector=(b-a).Unit } end, new=function(p) return {} end }
Color3 = { new=function(r,g,b) return {R=r or 0,G=g or 0,B=b or 0} end,
           fromRGB=function(r,g,b) return {R=(r or 0)/255,G=(g or 0)/255,B=(b or 0)/255} end }

-- interned Enum (stable tokens so == and table keys work)
Enum = setmetatable({}, { __index=function(t,cat)
  local c=rawget(t,cat)
  if not c then c=setmetatable({},{__index=function(t2,it)
    local v=rawget(t2,it); if not v then v={__enum=cat,__item=it}; rawset(t2,it,v) end; return v end})
    rawset(t,cat,c) end
  return c
end })

RaycastParams = { new=function() return {} end }

os = { clock=function() return 0 end, time=function() return 0 end }

-- ---- services / instances ----
local function newSignal() return { Connect=function(self,fn) return { Disconnect=function() end } end } end

__CHAR = { Name="Char" }
function __CHAR:FindFirstChild(n) if n=="HumanoidRootPart" then return __HRP end return nil end
function __CHAR:FindFirstChildOfClass(c) if c=="Humanoid" then return __HUM end return nil end
__HRP = setmetatable({ Name="HumanoidRootPart" }, { __index=function(s,k)
  if k=="Position" then return Vector3.new(0,3,0) end
  if k=="CFrame" then return { LookVector=Vector3.new(1,0,0), Position=Vector3.new(0,3,0) } end
  return rawget(s,k) end })
__HUM = { UseJumpPower=true, JumpPower=50, JumpHeight=7.2, WalkSpeed=16, Health=100, AutoRotate=true }
function __HUM:GetState() return Enum.HumanoidStateType.Running end
function __HUM:Move() end
function __HUM:ChangeState() end

__MOUSE = { Target=nil, Hit={ Position=Vector3.new(20,0,0) }, TargetFilter=nil }

local Players = { LocalPlayer={ Character=__CHAR, GetMouse=function() return __MOUSE end } }
local RunService = { Heartbeat={ Wait=function() return 1/60 end },
                     RenderStepped={ Connect=function() return {Disconnect=function() end} end } }
local UIS = { InputBegan=newSignal(), GetMouseLocation=function() return Vector3.new(0,0,0) end }

workspace = { Gravity=196.2, CurrentCamera={ CFrame={ LookVector=Vector3.new(1,0,0), Position=Vector3.new(0,5,-10) } } }
-- Raycast against a configurable fake obby (__PLATFORMS); only handles down-rays.
__PLATFORMS = {}
function workspace:Raycast(origin, dir, params)
  if dir.Y >= 0 then return nil end
  local bottom = origin.Y + dir.Y
  local best
  for _,p in ipairs(__PLATFORMS) do
    if math.abs(origin.X-p.x)<=p.hx and math.abs(origin.Z-p.z)<=p.hz
       and p.topY<=origin.Y and p.topY>=bottom then
      if not best or p.topY>best.topY then best=p end
    end
  end
  if not best then return nil end
  return { Position=Vector3.new(origin.X,best.topY,origin.Z), Instance=best.part, Normal=Vector3.new(0,1,0) }
end

game = { GetService=function(self,n)
  if n=="Players" then return Players end
  if n=="RunService" then return RunService end
  if n=="UserInputService" then return UIS end
  return {} end }

-- task: spawn records but does NOT run (we test decisions, not the live loop)
task = { spawn=function(fn) __SPAWNED=__SPAWNED+1; return {} end, wait=function() end, defer=function(fn) end }

-- ---- require shim ----
local notify = { info=function() end, success=function() end, warn=function() end }
local log    = { info=function() end, warn=function() end, err=function() end }
local feature = { declare=function(def)
  __DEF = def
  if def.settings then for _,opt in ipairs(def.settings) do
    if opt.onChange then pcall(opt.onChange, opt.default) end
  end end
  return { root={} }
end }
function require(name)
  if name=="ui.feature" then return feature end
  if name=="ui.notify"  then return notify end
  if name=="core.log"   then return log end
  error("unmocked require: "..tostring(name))
end

-- helpers to build mock parts for isDamage / findLanding
function mkPart(name, opts)
  opts = opts or {}
  local p = { Name=name, ClassName="Part",
    Material=opts.material or Enum.Material.Plastic,
    Color=opts.color or Color3.new(0.5,0.5,0.5),
    Parent=opts.parent }
  function p:IsA(c) return c=="BasePart" or c=="Part" end
  return p
end
"""

DRIVER = r"""
local pass, fail = 0, 0
local function ck(name, cond) if cond then pass=pass+1; print("PASS  "..name) else fail=fail+1; print("FAIL  "..name) end end
local function approx(a,b) return math.abs(a-b) < 0.05 end

-- register (fires setting defaults into the module's state)
local box = { add=function(self) return self end }
AOB.register(box)

-- ---- feature declaration ----
ck("def captured", __DEF ~= nil)
ck("id misc.autoobby", __DEF.id=="misc.autoobby")
ck("name Auto Obby", __DEF.name=="Auto Obby")
ck("default off", __DEF.default==false)
ck("keybind G", __DEF.defaultKey==Enum.KeyCode.G)
ck("has 4 settings", __DEF.settings and #__DEF.settings==4)
local hasMode, hasAvoid = false, false
for _,o in ipairs(__DEF.settings or {}) do
  if o.key=="mode" and o.type=="dropdown" then hasMode=true end
  if o.key=="avoid" and o.type=="toggle" then hasAvoid=true end
end
ck("Mode dropdown present", hasMode)
ck("Avoid-damage toggle present", hasAvoid)

local D = AOB._diag
-- ---- jump physics ----
local humJP = { UseJumpPower=true,  JumpPower=50, WalkSpeed=16 }
local humJH = { UseJumpPower=false, JumpHeight=7.2, WalkSpeed=16 }
ck("jumpVelocity uses JumpPower", D.jumpVelocity(humJP)==50)
ck("jumpVelocity from JumpHeight ~= 53.15", approx(D.jumpVelocity(humJH), 53.153))
-- peak ~6.37, equal-height reach*0.85 ~6.93
ck("reachable 6-stud flat jump", D.reachable(humJP, 6, 0)==true)
ck("reject 12-stud flat jump", D.reachable(humJP, 12, 0)==false)
ck("reject too-high jump (10>peak)", D.reachable(humJP, 2, 10)==false)
ck("reachable lower drop (dy=-20)", D.reachable(humJP, 6, -20)==true)

-- ---- damage heuristic ----
ck("name: KillBrick flagged", D.isDamage(mkPart("KillBrick"))==true)
ck("name: Lava flagged",      D.isDamage(mkPart("Lava"))==true)
ck("ancestor name flagged",   D.isDamage(mkPart("Platform", {parent=mkPart("Killzone")}))==true)
ck("red colour flagged",      D.isDamage(mkPart("Block", {color=Color3.new(0.9,0.1,0.1)}))==true)
ck("lava material flagged",   D.isDamage(mkPart("Block", {material=Enum.Material.CrackedLava}))==true)
ck("plain grey platform safe",D.isDamage(mkPart("Platform", {color=Color3.new(0.5,0.5,0.5)}))==false)

-- ---- findLanding: pick reachable safe platform, skip kill brick + unreachable ----
local platA = mkPart("Start")
local platB = mkPart("PlatB")
local kill  = mkPart("KillBrick")
local platD = mkPart("PlatD")
__PLATFORMS = {
  { x=0,  z=0, topY=0, hx=4, hz=4, part=platA },   -- where we stand
  { x=6,  z=0, topY=0, hx=2, hz=2, part=platB },   -- reachable, safe
  { x=6,  z=4, topY=0, hx=2, hz=2, part=kill  },   -- reachable but KILL
  { x=14, z=0, topY=0, hx=2, hz=2, part=platD },   -- safe but too far (1 hop)
}
local from = Vector3.new(0,3,0)
local goal = Vector3.new(14,0,0)
local r = D.findLanding(from, 0, 3, Vector3.new(1,0,0), humJP, goal)
ck("findLanding returns a candidate", r ~= nil)
ck("findLanding picked the safe platform B", r ~= nil and r.inst==platB)
ck("findLanding did NOT pick the kill brick", r == nil or r.inst~=kill)
ck("findLanding did NOT pick the too-far platform", r == nil or r.inst~=platD)
ck("landing hrpPos keeps stand offset (Y~3)", r ~= nil and approx(r.hrpPos.Y, 3))

-- only a kill brick reachable -> stuck (nil)
__PLATFORMS = {
  { x=0, z=0, topY=0, hx=1, hz=1, part=platA },     -- tiny start pad
  { x=6, z=0, topY=0, hx=2, hz=2, part=kill  },     -- only forward option is KILL
}
local r2 = D.findLanding(from, 0, 3, Vector3.new(1,0,0), humJP, goal)
ck("findLanding returns nil when only a kill brick is ahead", r2 == nil)

-- ---- lifecycle ----
local onToggle = __DEF.onToggle
onToggle(true)
ck("setActive(true) spawned the hop loop", __SPAWNED>=1)
onToggle(false)
ck("setActive(false) no error", true)
AOB.destroy()
ck("destroy no error", true)

print("")
print(("RESULT: %d passed, %d failed"):format(pass, fail))
if fail>0 then error("autoobby mocktest had failures") end
"""

lua = LuaRuntime(unpack_returned_tuples=True)
wrapped = PREAMBLE + "\nlocal function __load()\n" + SRC + "\nend\nAOB = __load()\n" + DRIVER
try:
    lua.execute(wrapped)
except Exception as e:
    print("RAISED:", repr(e)); sys.exit(1)
