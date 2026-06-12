#!/usr/bin/env python3
"""Offline mock-test for modules/misc/autoobby.lua (A* node-graph pathfinder).

Validates the pure pieces under a fake Roblox env: feature def, jump physics
(getJumpPhysics / airTimeForDeltaY), hazard detection, the Heap priority queue,
A* over a hand-built graph, findNearestNode, rayCollide, and the setActive
lifecycle. The Roblox-only pipeline (scanParts/buildNodes/buildEdges/executor)
can only be checked in-game.
"""
import sys
from lupa import LuaRuntime

SRC = open(r"C:\Users\killt\Desktop\custom scripts\[Uni] Pantheon\src\modules\misc\autoobby.lua",
           "r", encoding="utf-8").read()

PREAMBLE = r"""
__DEF = nil
__SPAWNED = 0

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
CFrame  = { lookAt=function(a,b) return {} end, new=function() return {} end }
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
  if k=="AssemblyLinearVelocity" then return Vector3.new(0,0,0) end
  return nil end, __newindex=function() end })
__HUM = { UseJumpPower=true, JumpPower=50, JumpHeight=7.2, WalkSpeed=16, Health=100, AutoRotate=true }
function __HUM:GetState() return Enum.HumanoidStateType.Running end
function __HUM:Move() end
function __HUM:MoveTo() end
__MOUSE = { Target=nil, Hit={ Position=Vector3.new(20,0,0) }, TargetFilter=nil }

local Players = { LocalPlayer={ Character=__CHAR, GetMouse=function() return __MOUSE end,
  FindFirstChild=function() return nil end, WaitForChild=function() return nil end } }
local RunService = { Heartbeat={ Wait=function() return 1/60 end, Connect=function() return {Disconnect=function() end} end },
                     RenderStepped=newSignal() }
local UIS = { InputBegan=newSignal() }

workspace = { Gravity=196.2, CurrentCamera={ WorldToViewportPoint=function() return Vector3.new(100,100,5), true end } }
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

-- jump physics
local humJP = { UseJumpPower=true, JumpPower=50, WalkSpeed=16 }
local phys = D.getJumpPhysics(humJP)
ck("getJumpPhysics jumpVel==50", phys.jumpVel==50)
ck("getJumpPhysics maxJumpDist ~6.93", approx(phys.maxJumpDist, 6.93))
ck("airTimeForDeltaY flat ~0.51", approx(D.airTimeForDeltaY(phys, 0), 0.5097))
ck("airTimeForDeltaY above apex -> nil", D.airTimeForDeltaY(phys, 10)==nil)

-- hazard detection
ck("isHazard KillBrick", D.isHazard(mkPart("KillBrick"))==true)
ck("isHazard Lava name", D.isHazard(mkPart("Lava"))==true)
ck("isHazard CrackedLava material", D.isHazard(mkPart("X", {material=Enum.Material.CrackedLava}))==true)
ck("isHazard strong-red", D.isHazard(mkPart("X", {color=Color3.new(0.9,0.1,0.1)}))==true)
ck("isHazard grey platform safe", D.isHazard(mkPart("Platform"))==false)

-- Heap (binary min-heap priority queue)
local h = D.Heap.new()
h:push("c", 3); h:push("a", 1); h:push("b", 2)
ck("Heap pops min first (a)", h:pop()=="a")
ck("Heap pops next (b)", h:pop()=="b")
ck("Heap pops last (c)", h:pop()=="c")

-- A* over a hand-built graph A -> B -> C
local A = { pos=Vector3.new(0,0,0),  edges={} }
local B = { pos=Vector3.new(5,0,0),  edges={} }
local C = { pos=Vector3.new(10,0,0), edges={} }
A.edges = { { to=B, cost=5 } }
B.edges = { { to=C, cost=5 } }
local path = D.aStar(A, C)
ck("aStar finds a 3-node path", path ~= nil and #path == 3)
ck("aStar path runs A..C", path ~= nil and path[1].node == A and path[#path].node == C)
ck("findNearestNode picks B near (4,0,0)", D.findNearestNode({A,B,C}, Vector3.new(4,0,0)) == B)

-- rayCollide finds the floor (passes mock 'collidable' parts straight through)
__PLATFORMS = { { x=0, z=0, topY=0, hx=4, hz=4, part=mkPart("Floor") } }
local hit = D.rayCollide(Vector3.new(0,5,0), Vector3.new(0,-20,0))
ck("rayCollide finds the floor", hit ~= nil and approx(hit.Position.Y, 0))

-- lifecycle
local onToggle = __DEF.onToggle
onToggle(true);  ck("setActive(true) spawned nav loop", __SPAWNED>=1)
onToggle(false); ck("setActive(false) no error", true)
AOB.destroy();   ck("destroy no error", true)

print("")
print(("RESULT: %d passed, %d failed"):format(pass, fail))
if fail>0 then error("autoobby mocktest had failures") end
"""

lua = LuaRuntime(unpack_returned_tuples=True)
try:
    lua.execute(PREAMBLE + "\nlocal function __load()\n" + SRC + "\nend\nAOB = __load()\n" + DRIVER)
except Exception as e:
    print("RAISED:", repr(e)); sys.exit(1)
