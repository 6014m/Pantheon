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

LUA = r"""
local real = { math=math, string=string, table=table, os=os, pcall=pcall, error=error,
  assert=assert, ipairs=ipairs, pairs=pairs, tostring=tostring, tonumber=tonumber,
  type=type, select=select, next=next, setmetatable=setmetatable, getmetatable=getmetatable,
  rawget=rawget, rawset=rawset, print=print }

local ERRORS = {}
local function typeof(x)
  if real.type(x)=="table" then
    if x._isEnumItem then return "EnumItem" end
    if x._isInstance then return "Instance" end
  end
  return real.type(x)
end

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

-- Vectors WITH arithmetic (targeting does distance math: (a-b).Magnitude).
local VMT={}
local function V(x,y,z) return real.setmetatable({_vector=true,X=x or 0,Y=y or 0,Z=z or 0}, VMT) end
VMT.__sub=function(a,b) return V(a.X-b.X,a.Y-b.Y,a.Z-b.Z) end
VMT.__add=function(a,b) return V(a.X+b.X,a.Y+b.Y,a.Z+b.Z) end
VMT.__index=function(t,k)
  if k=="Magnitude" then return real.math.sqrt(t.X*t.X+t.Y*t.Y+t.Z*t.Z) end
  if k=="Unit" then local m=real.math.sqrt(t.X*t.X+t.Y*t.Y+t.Z*t.Z); if m<=0 then return V(0,0,0) end return V(t.X/m,t.Y/m,t.Z/m) end
  return nil
end
local Vector2 = { new=function(x,y) return V(x,y,0) end }
local Vector3 = { new=function(x,y,z) return V(x,y,z) end }
local Rect = { new=function(a,b,c,d) return {_rect=true,a,b,c,d} end }
local ColorSequenceKeypoint = { new=function(t,c) return {_csk=true,Time=t,Value=c} end }
local ColorSequence = { new=function(a) return {_cs=true,a} end }

local function newEvent(name)
  local handlers={}
  local ev={_event=true,_name=name}
  function ev:Connect(fn) handlers[#handlers+1]=fn; return {Disconnect=function() end} end
  function ev:Fire(...) for _,fn in real.ipairs(handlers) do fn(...) end end
  return ev
end

local EVENT_NAMES={MouseButton1Click=true,InputBegan=true,InputChanged=true,InputEnded=true,
  FocusLost=true,Changed=true,ChildAdded=true,ChildRemoved=true,Heartbeat=true,RenderStepped=true,
  Stepped=true,CharacterAdded=true}
local VEC_PROPS={AbsoluteSize=true,AbsolutePosition=true,AbsoluteContentSize=true}

local InstanceMT
local function newInstance(cls)
  return real.setmetatable({_isInstance=true,ClassName=cls,Name=cls,_children={},_props={},_events={},_changed={}}, InstanceMT)
end
local function setParent(self,parent)
  local old=self._props.Parent
  if old then for i,c in real.ipairs(old._children) do if c==self then real.table.remove(old._children,i) break end end end
  self._props.Parent=parent
  if parent then parent._children[#parent._children+1]=self end
end
local METHODS={}
function METHODS:GetChildren() local t={} for i,c in real.ipairs(self._children) do t[i]=c end return t end
function METHODS:GetDescendants() local o={}; local function rec(n) for _,c in real.ipairs(n._children) do o[#o+1]=c; rec(c) end end; rec(self); return o end
function METHODS:FindFirstChild(n) for _,c in real.ipairs(self._children) do if c.Name==n then return c end end return nil end
function METHODS:FindFirstChildOfClass(cl) for _,c in real.ipairs(self._children) do if c.ClassName==cl then return c end end return nil end
function METHODS:IsA(cl) return self.ClassName==cl or cl=="GuiObject" or cl=="Instance" end
function METHODS:IsDescendantOf(anc) local p=self._props.Parent; while p do if p==anc then return true end p=p._props.Parent end return false end
function METHODS:Destroy() setParent(self,nil); self._destroyed=true end
function METHODS:GetPropertyChangedSignal(p) self._changed[p]=self._changed[p] or newEvent("chg:"..real.tostring(p)); return self._changed[p] end
InstanceMT={
  __index=function(self,k)
    if k=="Parent" then return self._props.Parent end
    if EVENT_NAMES[k] then self._events[k]=self._events[k] or newEvent(k); return self._events[k] end
    if METHODS[k] then return METHODS[k] end
    if self._props[k]~=nil then return self._props[k] end
    if VEC_PROPS[k] then return V(0,0,0) end
    return nil
  end,
  __newindex=function(self,k,v) if k=="Parent" then setParent(self,v) else self._props[k]=v end end,
}
local ALL_INSTANCES={}
local Instance={ new=function(cls,parent) local o=newInstance(cls); if parent then setParent(o,parent) end; ALL_INSTANCES[#ALL_INSTANCES+1]=o; return o end }

-- world + services
local Workspace=newInstance("Workspace"); Workspace.CurrentCamera=newInstance("Camera"); Workspace.CurrentCamera.ViewportSize=V(1280,720,0)
Workspace.CurrentCamera.CFrame={Position=V(0,5,-15),LookVector=V(0,0,1)}
local function mkChar(name,pos)
  local m=newInstance("Model"); m.Name=name; setParent(m,Workspace)
  local hrp=newInstance("Part"); hrp.Name="HumanoidRootPart"; hrp.Position=pos; setParent(hrp,m)
  local hum=newInstance("Humanoid"); hum.Health=100; hum.MaxHealth=100; setParent(hum,m)
  return m
end

local LocalPlayer=newInstance("Player"); LocalPlayer.Name="Tester"; LocalPlayer.UserId=1
LocalPlayer.Character=mkChar("TesterChar", V(0,0,0))
local function mkPlayer(name,disp,uid,pos)
  local p=newInstance("Player"); p.Name=name; p.DisplayName=disp; p.UserId=uid
  if pos then p.Character=mkChar(name.."Char", pos) end
  return p
end
local Players=newInstance("Players"); Players.LocalPlayer=LocalPlayer
local pAlice=mkPlayer("Alice","Alice",11, V(10,0,0))
local roster={ LocalPlayer, pAlice, mkPlayer("Bob","Bobby",22,nil), mkPlayer("Cara","Cara",33,nil) }
function Players:GetPlayers() local t={} for i,p in real.ipairs(roster) do t[i]=p end return t end
function Players:GetPlayerFromCharacter(ch) for _,p in real.ipairs(roster) do if p.Character==ch then return p end end return nil end
Players.PlayerAdded=newEvent("PlayerAdded"); Players.PlayerRemoving=newEvent("PlayerRemoving")

-- NPCs in the workspace (Models with Humanoid + HRP, not owned by a player)
local mob1=mkChar("Mob1", V(5,0,0))    -- closest overall
local mob2=mkChar("Mob2", V(50,0,0))

local SERVICES={ Players=Players, UserInputService=newInstance("UserInputService"),
  RunService=newInstance("RunService"), Workspace=Workspace, TweenService=newInstance("TweenService"),
  VirtualInputManager=newInstance("VirtualInputManager"), Stats=newInstance("Stats"), ReplicatedStorage=newInstance("ReplicatedStorage") }
local game=newInstance("DataModel"); game.PlaceId=123; game.GameId=456; game.Workspace=Workspace
function game:GetService(n) SERVICES[n]=SERVICES[n] or newInstance(n); return SERVICES[n] end
local workspace=Workspace

local task={}
function task.spawn(fn,...) local ok,e=real.pcall(fn,...); if not ok then ERRORS[#ERRORS+1]="spawn: "..real.tostring(e) end end
function task.delay(t,fn,...) return end
function task.wait(t) return t or 0 end

local REAL={ ["core.signal"]=true, ["ui.theme"]=true, ["ui.components"]=true, ["ui.container"]=true,
  ["modules.aim.state"]=true, ["modules.aim.targeting"]=true, ["modules.aim.highlight"]=true,
  ["modules.friendlies"]=true }
local cache={}
local ENV
local FEATURE_CALLS={}
local function stub(name)
  if name=="ui.window" then return { parent=function() return newInstance("Folder") end } end
  if name=="core.log" then return { info=function() end, warn=function() end, error=function() end, debug=function() end } end
  if name=="core.env" then return { guiParent=function() return newInstance("Folder") end, protectGui=function() end } end
  if name=="ui.feature" then return {
    setEnabled=function(id,v) FEATURE_CALLS[#FEATURE_CALLS+1]=real.tostring(id).."="..real.tostring(v) end,
    getEnabled=function() return false end, declare=function() return {root=newInstance("Frame")} end,
    addInvokable=function() end, all=function() return {} end, fire=function() end } end
  return real.setmetatable({}, {__index=function() return function() end end})
end
local function myrequire(name)
  if cache[name]~=nil then return cache[name] end
  if REAL[name] then
    local chunk=real.assert(load(python_read_file(name), "@"..name, "t", ENV))
    local mod=chunk(); cache[name]=mod; return mod
  end
  local s=stub(name); cache[name]=s; return s
end

-- Roblox adds math.clamp (Lua 5.5 lacks it); shim it, fall through for the rest.
local mathShim=real.setmetatable({ clamp=function(x,lo,hi) if x<lo then return lo elseif x>hi then return hi else return x end end }, { __index=real.math })

ENV=real.setmetatable({ Instance=Instance, Enum=Enum, UDim2=UDim2, UDim=UDim, Color3=Color3,
  Vector2=Vector2, Vector3=Vector3, Rect=Rect, ColorSequence=ColorSequence,
  ColorSequenceKeypoint=ColorSequenceKeypoint, RaycastParams=real.setmetatable({new=function() return {} end},{}),
  game=game, workspace=workspace, typeof=typeof, math=mathShim,
  task=task, require=myrequire, warn=function() end, print=real.print,
  tick=os.clock, time=os.time }, { __index=_G })

local out={ steps={} }
local function log(s) out.steps[#out.steps+1]=s end

-- ============ TARGETING: bot mode (npc) ============
local state=myrequire("modules.aim.state")
local targeting=myrequire("modules.aim.targeting")

-- defaults: realistic/visibility off, so isInFront/isVisible short-circuit true
local t1,ty1 = targeting.getBestTarget()
out.botoff_target = t1 and t1.Name or "nil"
out.botoff_type   = ty1 or "nil"          -- expect Alice / player (npcs ignored)

state.botMode = true
local t2,ty2 = targeting.getBestTarget()
out.boton_target = t2 and t2.Name or "nil"
out.boton_type   = ty2 or "nil"           -- expect Mob1 / npc (closest at 5)

-- swap should exclude current + return the next-best (Alice, player)
local t3,ty3 = targeting.getBestTarget(t2)
out.swap_target = t3 and t3.Name or "nil"
out.swap_type   = ty3 or "nil"

-- isFriendly must NOT throw on an NPC model, and must be false
local okf, fr = real.pcall(function() return state.isFriendly(t2) end)
out.isfriendly_npc_ok = okf
out.isfriendly_npc_val = okf and fr or real.tostring(fr)

-- ============ HIGHLIGHT on an NPC target (the outline bug) ============
local highlight=myrequire("modules.aim.highlight")
state.target = t2; state.target_type = "npc"   -- mirror what setTarget would do
local okh, errh = real.pcall(function()
  highlight.update(t2, function(ex) return targeting.getBestTarget(ex) end)
end)
out.highlight_npc_ok = okh
if not okh then out.highlight_npc_err = real.tostring(errh) end
-- did the NPC actually get a Highlight adorned to its model?
local adorned=false
for _,o in real.ipairs(ALL_INSTANCES) do
  if o.ClassName=="Highlight" and o._props.Adornee==t2 then adorned=true end
end
out.npc_outline_adorned = adorned
for _,e in real.ipairs(ERRORS) do log("[swallowed] "..e) end

-- ============ FRIENDLIES panel still builds + All button ============
local function countFriendlies() local n=0 for _,v in real.pairs(state.friendlies) do if v then n=n+1 end end return n end
local function scanAll()
  local av, allBtn = 0, nil
  for _,o in real.ipairs(ALL_INSTANCES) do
    if not o._destroyed then
      if o.ClassName=="ImageLabel" and real.type(o._props.Image)=="string" and o._props.Image:find("rbxthumb",1,true) then av=av+1 end
      if o.ClassName=="TextButton" and o._props.Text then local t=real.tostring(o._props.Text)
        if t=="All" or t:find("ALL",1,true) then allBtn=o end end
    end
  end
  return av, allBtn
end
local okF, Friendlies = real.pcall(myrequire, "modules.friendlies")
if not okF then out.friendlies_require="THREW: "..real.tostring(Friendlies)
else
  local ok2,err2=real.pcall(function() Friendlies.register() end)
  out.friendlies_register_ok=ok2; if not ok2 then out.friendlies_register_err=real.tostring(err2) end
  local av, allBtn = scanAll()
  out.avatars_shown=av; out.all_button=(allBtn~=nil)
  if allBtn then
    real.pcall(function() allBtn._events.MouseButton1Click:Fire() end)
    out.friendlies_after_all=countFriendlies()
  end

  -- Target button: clicking it sets state.target to that player + enables Target Select
  state.setTarget(nil,nil)
  local tgtBtn
  for _,o in real.ipairs(ALL_INSTANCES) do
    if not o._destroyed and o.ClassName=="TextButton" and o._props.Text=="Target" then tgtBtn=o; break end
  end
  out.target_button_present=(tgtBtn~=nil)
  if tgtBtn then
    real.pcall(function() tgtBtn._events.MouseButton1Click:Fire() end)
    out.after_target_click = state.target and (state.target.Name or "set") or "nil"
    out.after_target_type  = state.target_type or "nil"
    local sawEnable=false
    for _,c in real.ipairs(FEATURE_CALLS) do if c=="aim.target_select=true" then sawEnable=true end end
    out.target_enabled_select = sawEnable
  end
end

local function ser(v,ind) ind=ind or ""
  if real.type(v)=="table" then local s="{\n"
    for k,val in real.pairs(v) do s=s..ind.."  ["..real.tostring(k).."]="..ser(val,ind.."  ").."\n" end
    return s..ind.."}" else return real.tostring(v) end end
return ser(out)
"""

print(rt.execute(LUA))
