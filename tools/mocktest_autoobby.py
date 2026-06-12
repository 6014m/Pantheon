#!/usr/bin/env python3
"""Offline mock-test for modules/misc/autoobby.lua.

Checks (under a fake Roblox env):
  * the feature declaration,
  * jump-physics reachability + jumpVelocity,
  * the damage-block heuristic (name / ancestor / colour / lava material),
  * findLanding picks a reachable SAFE platform, skips kill bricks / unreachable,
  * decideMove WALKS on continuous ground, JUMPS at a gap (to the safe platform),
    and reports STUCK when nothing safe is reachable,
  * setActive() lifecycle builds markers + wires/clears cleanly.

The live loops (task.spawn / RenderStepped) are stubbed; real obby behaviour and
the marker projection still need an in-game check.
"""
import sys
from lupa import LuaRuntime

SRC = open(r"C:\Users\killt\Desktop\custom scripts\[Uni] Pantheon\src\modules\misc\autoobby.lua",
           "r", encoding="utf-8").read()

PREAMBLE = r"""
__DEF = nil
__SPAWNED = 0

-- ---- Vector3 ----
local VMT = {}
function VMT.__add(a,b) return Vector3.new(a.X+b.X,a.Y+b.Y,a.Z+b.Z) end
function VMT.__sub(a,b) return Vector3.new(a.X-b.X,a.Y-b.Y,a.Z-b.Z) end
function VMT.__mul(a,b)
  if type(a)=="number" then return Vector3.new(b.X*a,b.Y*a,b.Z*a) end
  if type(b)=="number" then return Vector3.new(a.X*b,a.Y*b,a.Z*b) end
  return Vector3.new(a.X*b.X,a.Y*b.Y,a.Z*b.Z)
end
function VMT.__div(a,b)
  if type(b)=="number" then return Vector3.new(a.X/b,a.Y/b,a.Z/b) end
  return Vector3.new(a.X/b.X,a.Y/b.Y,a.Z/b.Z)
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
Vector2 = { new=function(x,y) return {X=x or 0,Y=y or 0} end }
UDim    = { new=function(s,o) return {Scale=s,Offset=o} end }
UDim2   = { new=function(...) return {} end, fromOffset=function() return {} end, fromScale=function() return {} end }
CFrame  = { lookAt=function(a,b) return { LookVector=(b-a).Unit } end, new=function() return {} end }
Color3  = { new=function(r,g,b) return {R=r or 0,G=g or 0,B=b or 0} end,
            fromRGB=function(r,g,b) return {R=(r or 0)/255,G=(g or 0)/255,B=(b or 0)/255} end }
Enum = setmetatable({}, { __index=function(t,cat)
  local c=rawget(t,cat)
  if not c then c=setmetatable({},{__index=function(t2,it)
    local v=rawget(t2,it); if not v then v={__enum=cat,__item=it}; rawset(t2,it,v) end; return v end})
    rawset(t,cat,c) end
  return c
end })
RaycastParams = { new=function() return {} end }
os = { clock=function() return 0 end, time=function() return 0 end }

-- generic Instance (markers / attachment / align)
local function mkInstance(class)
  local props = { ClassName=class, Name=class }
  local inst = {}
  inst.Destroy = function() props.__destroyed=true end
  inst.GetChildren = function() return {} end
  setmetatable(inst, {
    __index=function(_,k) return props[k] end,
    __newindex=function(_,k,v) props[k]=v end,
  })
  return inst
end
Instance = { new=function(class,parent) local i=mkInstance(class); if parent then i.Parent=parent end; return i end }

-- ---- services / instances ----
local function newSignal() return { Connect=function() return { Disconnect=function() end } end } end

__CHAR = { Name="Char" }
function __CHAR:FindFirstChild(n) if n=="HumanoidRootPart" then return __HRP end return nil end
function __CHAR:FindFirstChildOfClass(c) if c=="Humanoid" then return __HUM end return nil end
__HRP = setmetatable({ Name="HumanoidRootPart" }, { __index=function(_,k)
  if k=="Position" then return Vector3.new(0,3,0) end
  if k=="CFrame" then return { LookVector=Vector3.new(1,0,0), Position=Vector3.new(0,3,0) } end
  return nil end, __newindex=function() end })
__HUM = { UseJumpPower=true, JumpPower=50, JumpHeight=7.2, WalkSpeed=16, Health=100, AutoRotate=true }
function __HUM:GetState() return Enum.HumanoidStateType.Running end
function __HUM:Move() end
function __HUM:ChangeState() end
__MOUSE = { Target=nil, Hit={ Position=Vector3.new(20,0,0) }, TargetFilter=nil }

local Players = { LocalPlayer={ Character=__CHAR, GetMouse=function() return __MOUSE end,
  FindFirstChild=function() return nil end } }   -- no PlayerScripts -> controls unavailable (pcall'd)
local RunService = { Heartbeat={ Wait=function() return 1/60 end, Connect=function() return {Disconnect=function() end} end },
                     RenderStepped=newSignal() }
local UIS = { InputBegan=newSignal(), GetMouseLocation=function() return Vector3.new(0,0,0) end }

workspace = { Gravity=196.2, CurrentCamera={ CFrame={ LookVector=Vector3.new(1,0,0), Position=Vector3.new(0,5,-10) },
  WorldToViewportPoint=function(_,p) return Vector3.new(100,100,5), true end } }
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

game = { GetService=function(_,n)
  if n=="Players" then return Players end
  if n=="RunService" then return RunService end
  if n=="UserInputService" then return UIS end
  return {} end }

task = { spawn=function() __SPAWNED=__SPAWNED+1; return {} end, wait=function() end, defer=function() end }

-- ---- require shim ----
local notify = { info=function() end, success=function() end, warn=function() end }
local log    = { info=function() end, warn=function() end, err=function() end }
local env    = { guiParent=function() return mkInstance("CoreGui") end, protectGui=function() end }
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
  if name=="core.env"   then return env end
  error("unmocked require: "..tostring(name))
end

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
local function ck(n,c) if c then pass=pass+1; print("PASS  "..n) else fail=fail+1; print("FAIL  "..n) end end
local function approx(a,b) return math.abs(a-b) < 0.05 end

local box = { add=function(self) return self end }
AOB.register(box)

-- feature declaration
ck("def captured", __DEF ~= nil)
ck("id misc.autoobby", __DEF.id=="misc.autoobby")
ck("default off", __DEF.default==false)
ck("keybind G", __DEF.defaultKey==Enum.KeyCode.G)
ck("has 4 settings", __DEF.settings and #__DEF.settings==4)

local D = AOB._diag
-- jump physics
local humJP = { UseJumpPower=true,  JumpPower=50, WalkSpeed=16 }
local humJH = { UseJumpPower=false, JumpHeight=7.2, WalkSpeed=16 }
ck("jumpVelocity uses JumpPower", D.jumpVelocity(humJP)==50)
ck("jumpVelocity from JumpHeight ~= 53.15", approx(D.jumpVelocity(humJH), 53.153))
ck("reachable 6-stud flat jump", D.reachable(humJP, 6, 0)==true)
ck("reject 12-stud flat jump", D.reachable(humJP, 12, 0)==false)
ck("reject too-high jump (10>peak)", D.reachable(humJP, 2, 10)==false)
ck("reachable lower drop (dy=-20)", D.reachable(humJP, 6, -20)==true)

-- damage heuristic
ck("name: KillBrick flagged", D.isDamage(mkPart("KillBrick"))==true)
ck("ancestor name flagged",   D.isDamage(mkPart("Platform", {parent=mkPart("Killzone")}))==true)
ck("red colour flagged",      D.isDamage(mkPart("Block", {color=Color3.new(0.9,0.1,0.1)}))==true)
ck("lava material flagged",   D.isDamage(mkPart("Block", {material=Enum.Material.CrackedLava}))==true)
ck("plain grey platform safe",D.isDamage(mkPart("Platform"))==false)

-- findLanding
local platA, platB, kill, platD = mkPart("Start"), mkPart("PlatB"), mkPart("KillBrick"), mkPart("PlatD")
__PLATFORMS = {
  { x=0,  z=0, topY=0, hx=4, hz=4, part=platA },
  { x=6,  z=0, topY=0, hx=2, hz=2, part=platB },   -- reachable, safe
  { x=6,  z=4, topY=0, hx=2, hz=2, part=kill  },   -- reachable but KILL
  { x=14, z=0, topY=0, hx=2, hz=2, part=platD },   -- too far
}
local from = Vector3.new(0,3,0)
local r = D.findLanding(from, 0, 3, Vector3.new(1,0,0), humJP, Vector3.new(14,0,0))
ck("findLanding picked the safe platform B", r ~= nil and r.inst==platB)
ck("findLanding did NOT pick the kill brick", r == nil or r.inst~=kill)
ck("findLanding did NOT pick the too-far platform", r == nil or r.inst~=platD)
ck("landing keeps stand offset (Y~3)", r ~= nil and approx(r.hrpPos.Y, 3))

-- decideMove: WALK on continuous ground
__PLATFORMS = { { x=2, z=0, topY=0, hx=6, hz=4, part=platA } }   -- covers x[-4,8]
local a1 = D.decideMove(__HRP, humJP, 0, Vector3.new(1,0,0))
ck("decideMove WALKS on continuous ground", a1=="walk")

-- decideMove: JUMP at a gap to the safe platform
__PLATFORMS = {
  { x=0, z=0, topY=0, hx=0.5, hz=4, part=platA },  -- tiny pad: edge ~0.5
  { x=6, z=0, topY=0, hx=2,   hz=2, part=platB },  -- reachable across the gap
}
local a2, land2 = D.decideMove(__HRP, humJP, 0, Vector3.new(1,0,0))
ck("decideMove JUMPS at a gap", a2=="jump")
ck("decideMove jump targets the safe platform B", a2=="jump" and land2 and land2.inst==platB)

-- decideMove: STUCK when nothing safe is reachable ahead
__PLATFORMS = { { x=0, z=0, topY=0, hx=0.5, hz=4, part=platA } }
local a3 = D.decideMove(__HRP, humJP, 0, Vector3.new(1,0,0))
ck("decideMove STUCK with no reachable platform", a3=="stuck")

-- pathClear: clear when nothing blocks (mock has no vertical walls)
ck("pathClear true when unobstructed", D.pathClear(Vector3.new(0,3,0), Vector3.new(6,3,0), platB)==true)

-- lifecycle: build markers, wire, then clear
local onToggle = __DEF.onToggle
onToggle(true)
ck("setActive(true) spawned control loop", __SPAWNED>=1)
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
