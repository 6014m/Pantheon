# Self-check for games/jjs_flash: target pick (look-direction + range + recent bonus) and stand-off spot.
import os, lupa
SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "games", "jjs_flash.lua")
rt = lupa.LuaRuntime(unpack_returned_tuples=True)
rt.globals().SRC = open(SRC, encoding="utf-8").read()
rt.execute(r'''
local VMT = {}
local function V(x,y,z) return setmetatable({X=x,Y=y,Z=z}, VMT) end
VMT.__index = function(t,k)
  if k=="Magnitude" then return math.sqrt(t.X^2+t.Y^2+t.Z^2) end
  if k=="Unit" then local m=t.Magnitude; return V(t.X/m,t.Y/m,t.Z/m) end
  if k=="Dot" then return function(a,b) return a.X*b.X+a.Y*b.Y+a.Z*b.Z end end
end
VMT.__sub=function(a,b) return V(a.X-b.X,a.Y-b.Y,a.Z-b.Z) end
VMT.__add=function(a,b) return V(a.X+b.X,a.Y+b.Y,a.Z+b.Z) end
VMT.__mul=function(a,s) return V(a.X*s,a.Y*s,a.Z*s) end
Vector3 = { new=V, zero=V(0,0,0), yAxis=V(0,1,0) }
CFrame = { lookAt=function(p,at) return {Position=p, LookVector=(at-p).Unit} end }
Enum = setmetatable({}, {__index=function(t,c) local e=setmetatable({},{__index=function(_,m) return c.."."..m end}); rawset(t,c,e); return e end})
local function char(name,x,z,hp)
  local root={Position=V(x,0,z)}
  local hum={Health=hp or 100}
  return {Name=name, FindFirstChild=function(_,n) return n=="HumanoidRootPart" and root or nil end,
          FindFirstChildOfClass=function(_,c) return c=="Humanoid" and hum or nil end}
end
ME = char("me",0,0)
A, B, FAR, DEAD = char("A",10,2), char("B",2,10), char("FAR",0,400), char("DEAD",5,0,0)
local chars={GetChildren=function() return {ME,A,B,FAR,DEAD} end}
local services={
  Players={LocalPlayer={Character=ME}, GetPlayers=function() return {} end},
  UserInputService={}, RunService={}, PathfindingService={},
  Workspace={FindFirstChild=function(_,n) return n=="Characters" and chars or nil end},
}
game={GetService=function(_,n) return services[n] end}
Flash = load(SRC)()
''')
F = rt.globals().Flash
V = rt.eval("Vector3.new")
me = V(0, 0, 0)
assert F.pick(me, V(1, 0, 0), 0).Name == "A", "look +X -> A"
assert F.pick(me, V(0, 0, 1), 0).Name == "B", "look +Z -> B (FAR out of range, DEAD skipped)"
spot = F.spot(V(10, 3, 0), V(-6, 5, 0), 4.5)
assert abs(spot.Position.X - 5.5) < 1e-6 and spot.Position.Y == 3 and spot.Position.Z == 0, "spot 4.5 studs toward me, flat, at target height"
assert spot.LookVector.X > 0.99, "faces the target"
print("jjs_flash OK")
