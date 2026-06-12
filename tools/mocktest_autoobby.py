#!/usr/bin/env python3
"""Offline mock-test for modules/misc/autoobby.lua (PathfindingService version).

Checks (under a fake Roblox env): the feature declaration, the damage heuristic,
jumpVelocity/jumpHeight, computePath (returns waypoints on Success / nil on NoPath),
rayCollide (returns a collidable hit), and the setActive lifecycle.

The live nav loop / movement / pathfinding follow can only be checked in-game.
"""
import sys
from lupa import LuaRuntime

SRC = open(r"C:\Users\killt\Desktop\custom scripts\[Uni] Pantheon\src\modules\misc\autoobby.lua",
           "r", encoding="utf-8").read()

PREAMBLE = r"""
__DEF = nil
__SPAWNED = 0
__PATH_STATUS = nil
__WAYPOINTS = nil

local VMT = {}
function VMT.__add(a,b) return Vector3.new(a.X+b.X,a.Y+b.Y,a.Z+b.Z) end
function VMT.__sub(a,b) return Vector3.new(a.X-b.X,a.Y-b.Y,a.Z-b.Z) end
function VMT.__mul(a,b)
  if type(a)=="number" then return Vector3.new(b.X*a,b.Y*a,b.Z*a) end
  if type(b)=="number" then return Vector3.new(a.X*b,a.Y*b,a.Z*b) end
  return Vector3.new(a.X*b.X,a.Y*b.Y,a.Z*b.Z) end
function VMT.__div(a,b)
  if type(b)=="number" then return Vector3.new(a.X/b,a.Y/b,a.Z/b) end
  return Vector3.new(a.X/b.X,a.Y/b.Y,a.Z/b.Z) end
VMT.__index = function(self,k)
  if k=="Magnitude" then return math.sqrt(self.X*self.X+self.Y*self.Y+self.Z*self.Z) end
  if k=="Unit" then local m=math.sqrt(self.X*self.X+self.Y*self.Y+self.Z*self.Z)
    if m==0 then return Vector3.new(0,0,0) end return Vector3.new(self.X/m,self.Y/m,self.Z/m) end
  return nil end
Vector3 = { new=function(x,y,z) return setmetatable({X=x or 0,Y=y or 0,Z=z or 0}, VMT) end }
Vector2 = { new=function(x,y) return {X=x or 0,Y=y or 0} end }
UDim    = { new=function(s,o) return {Scale=s,Offset=o} end }
UDim2   = { new=function() return {} end, fromOffset=function() return {} end, fromScale=function() return {} end }
CFrame  = { lookAt=function(a,b) return { LookVector=(b-a).Unit } end, new=function() return {} end }
Color3  = { new=function(r,g,b) return {R=r or 0,G=g or 0,B=b or 0} end,
            fromRGB=function(r,g,b) return {R=(r or 0)/255,G=(g or 0)/255,B=(b or 0)/255} end }
Enum = setmetatable({}, { __index=function(t,cat)
  local c=rawget(t,cat)
  if not c then c=setmetatable({},{__index=function(t2,it)
    local v=rawget(t2,it); if not v then v={__enum=cat,__item=it}; rawset(t2,it,v) end; return v end})
    rawset(t,cat,c) end
  return c end })
RaycastParams = { new=function() return {} end }
os = { clock=function() return 0 end, time=function() return 0 end }

local function mkInstance(class)
  local props = { ClassName=class, Name=class }
  local inst = {}
  inst.Destroy = function() props.__destroyed=true end
  setmetatable(inst, { __index=function(_,k) return props[k] end, __newindex=function(_,k,v) props[k]=v end })
  return inst
end
Instance = { new=function(class,parent) local i=mkInstance(class); if parent then i.Parent=parent end; return i end }

local function newSignal() return { Connect=function() return {Disconnect=function() end} end } end

__CHAR = { Name="Char" }
function __CHAR:FindFirstChild(n) if n=="HumanoidRootPart" then return __HRP end return nil end
function __CHAR:FindFirstChildOfClass(c) if c=="Humanoid" then return __HUM end return nil end
__HRP = setmetatable({ Name="HumanoidRootPart" }, { __index=function(_,k)
  if k=="Position" then return Vector3.new(0,3,0) end
  if k=="CFrame" then return { LookVector=Vector3.new(1,0,0), Position=Vector3.new(0,3,0) } end
  if k=="AssemblyLinearVelocity" then return Vector3.new(0,0,0) end
  return nil end, __newindex=function() end })
__HUM = { UseJumpPower=true, JumpPower=50, JumpHeight=7.2, WalkSpeed=16, Health=100, AutoRotate=true }
function __HUM:GetState() return Enum.HumanoidStateType.Running end
function __HUM:Move() end
function __HUM:ChangeState() end
__MOUSE = { Target=nil, Hit={ Position=Vector3.new(20,0,0) }, TargetFilter=nil }

local Players = { LocalPlayer={ Character=__CHAR, GetMouse=function() return __MOUSE end,
  FindFirstChild=function() return nil end, WaitForChild=function() return nil end } }
local RunService = { Heartbeat={ Wait=function() return 1/60 end, Connect=function() return {Disconnect=function() end} end },
                     RenderStepped=newSignal() }
local UIS = { InputBegan=newSignal() }
local Pathfinder = { CreatePath=function(_, p)
  return { Status = (__PATH_STATUS or Enum.PathStatus.Success),
           ComputeAsync=function() end,
           GetWaypoints=function() return __WAYPOINTS or {} end } end }

workspace = { Gravity=196.2, CurrentCamera={ CFrame={ LookVector=Vector3.new(1,0,0) },
  WorldToViewportPoint=function() return Vector3.new(100,100,5), true end } }
__PLATFORMS = {}
function workspace:Raycast(origin, dir, params)
  if dir.Y >= 0 then return nil end
  local bottom = origin.Y + dir.Y
  local best
  for _,p in ipairs(__PLATFORMS) do
    if math.abs(origin.X-p.x)<=p.hx and math.abs(origin.Z-p.z)<=p.hz and p.topY<=origin.Y and p.topY>=bottom then
      if not best or p.topY>best.topY then best=p end end end
  if not best then return nil end
  return { Position=Vector3.new(origin.X,best.topY,origin.Z), Instance=best.part, Normal=Vector3.new(0,1,0) }
end

game = { GetService=function(_,n)
  if n=="Players" then return Players end
  if n=="RunService" then return RunService end
  if n=="UserInputService" then return UIS end
  if n=="PathfindingService" then return Pathfinder end
  return {} end }
task = { spawn=function() __SPAWNED=__SPAWNED+1; return {} end, wait=function() end, defer=function() end }

local notify = { info=function() end, success=function() end, warn=function() end }
local log    = { info=function() end, warn=function() end, err=function() end }
local env    = { guiParent=function() return mkInstance("CoreGui") end, protectGui=function() end }
local feature = { declare=function(def)
  __DEF = def
  if def.settings then for _,o in ipairs(def.settings) do if o.onChange then pcall(o.onChange, o.default) end end end
  return { root={} } end }
function require(name)
  if name=="ui.feature" then return feature end
  if name=="ui.notify" then return notify end
  if name=="core.log" then return log end
  if name=="core.env" then return env end
  error("unmocked require: "..tostring(name)) end

function mkPart(name, opts)
  opts = opts or {}
  local p = { Name=name, ClassName="Part", Material=opts.material or Enum.Material.Plastic,
    Color=opts.color or Color3.new(0.5,0.5,0.5), Parent=opts.parent }
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

ck("id misc.autoobby", __DEF.id=="misc.autoobby")
ck("default off", __DEF.default==false)
ck("keybind G", __DEF.defaultKey==Enum.KeyCode.G)
ck("has 3 settings", __DEF.settings and #__DEF.settings==3)

local D = AOB._diag
local humJP = { UseJumpPower=true, JumpPower=50, WalkSpeed=16 }
local humJH = { UseJumpPower=false, JumpHeight=7.2, WalkSpeed=16 }
ck("jumpVelocity uses JumpPower", D.jumpVelocity(humJP)==50)
ck("jumpVelocity from JumpHeight ~53.15", approx(D.jumpVelocity(humJH), 53.153))
ck("jumpHeight from JumpPower ~6.37", approx(D.jumpHeight(humJP), 6.371))
ck("jumpHeight from JumpHeight ==7.2", approx(D.jumpHeight(humJH), 7.2))

ck("name: KillBrick flagged", D.isDamage(mkPart("KillBrick"))==true)
ck("ancestor name flagged", D.isDamage(mkPart("Platform", {parent=mkPart("Killzone")}))==true)
ck("red colour flagged", D.isDamage(mkPart("Block", {color=Color3.new(0.9,0.1,0.1)}))==true)
ck("lava material flagged", D.isDamage(mkPart("Block", {material=Enum.Material.CrackedLava}))==true)
ck("plain grey platform safe", D.isDamage(mkPart("Platform"))==false)

-- computePath: Success -> waypoints, NoPath -> nil
__PATH_STATUS = Enum.PathStatus.Success
__WAYPOINTS = { {Position=Vector3.new(0,3,0), Action=Enum.PathWaypointAction.Walk},
                {Position=Vector3.new(6,3,0), Action=Enum.PathWaypointAction.Walk},
                {Position=Vector3.new(12,3,0), Action=Enum.PathWaypointAction.Jump} }
local wps = D.computePath(Vector3.new(0,3,0), Vector3.new(12,3,0), humJP)
ck("computePath returns waypoints on Success", wps ~= nil and #wps==3)
__PATH_STATUS = Enum.PathStatus.NoPath
ck("computePath returns nil on NoPath", D.computePath(Vector3.new(0,3,0), Vector3.new(99,3,0), humJP)==nil)

-- rayCollide returns a collidable hit (passes mock 'collidable' parts straight through)
__PLATFORMS = { { x=0, z=0, topY=0, hx=4, hz=4, part=mkPart("Floor") } }
local hit = D.rayCollide(Vector3.new(0,5,0), Vector3.new(0,-20,0))
ck("rayCollide finds the floor", hit ~= nil and approx(hit.Position.Y, 0))

-- reachable (distance judgement)
ck("reachable 6-stud flat jump", D.reachable(humJP, 6, 0)==true)
ck("reject 12-stud flat jump", D.reachable(humJP, 12, 0)==false)
ck("reject too-high jump (dy=10>peak)", D.reachable(humJP, 2, 10)==false)

-- gapJumpTarget: continuous ground -> no jump; reachable gap -> landing; too wide -> nil
__PLATFORMS = { { x=8, z=0, topY=0, hx=12, hz=4, part=mkPart("Floor") } }   -- x[-4,20]
ck("gapJumpTarget: no jump on continuous ground", D.gapJumpTarget(__HRP, humJP, Vector3.new(1,0,0), 0)==nil)
__PLATFORMS = { { x=-1.75, z=0, topY=0, hx=2.25, hz=4, part=mkPart("Foot") },     -- x[-4,0.5]
                { x=6,     z=0, topY=0, hx=2,    hz=4, part=mkPart("Landing") } } -- x[4,8]
local lj = D.gapJumpTarget(__HRP, humJP, Vector3.new(1,0,0), 0)
ck("gapJumpTarget: jumps a reachable gap to the landing", lj ~= nil and lj.X >= 4 and lj.X <= 8)
__PLATFORMS = { { x=-1.75, z=0, topY=0, hx=2.25, hz=4, part=mkPart("Foot") },
                { x=14,    z=0, topY=0, hx=2,    hz=4, part=mkPart("FarLanding") } }  -- too far
ck("gapJumpTarget: no jump when gap too wide", D.gapJumpTarget(__HRP, humJP, Vector3.new(1,0,0), 0)==nil)

-- lifecycle
local onToggle = __DEF.onToggle
onToggle(true)
ck("setActive(true) spawned nav loop", __SPAWNED>=1)
onToggle(false); ck("setActive(false) no error", true)
AOB.destroy(); ck("destroy no error", true)

print("")
print(("RESULT: %d passed, %d failed"):format(pass, fail))
if fail>0 then error("autoobby mocktest had failures") end
"""

lua = LuaRuntime(unpack_returned_tuples=True)
try:
    lua.execute(PREAMBLE + "\nlocal function __load()\n" + SRC + "\nend\nAOB = __load()\n" + DRIVER)
except Exception as e:
    print("RAISED:", repr(e)); sys.exit(1)
