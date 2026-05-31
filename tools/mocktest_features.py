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
local function V(x,y,z) return {_vector=true,X=x or 0,Y=y or 0,Z=z or 0,Magnitude=0} end
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
  FocusLost=true,Changed=true,ChildAdded=true,ChildRemoved=true,Heartbeat=true,RenderStepped=true,Stepped=true}
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
-- Method table in proper `self` style: colon calls (inst:Method(args)) pass the
-- instance as self, so params line up correctly (the earlier captured-self,
-- shifted-params version made inst:GetPropertyChangedSignal("X") see X as self).
local METHODS={}
function METHODS:GetChildren() local t={} for i,c in real.ipairs(self._children) do t[i]=c end return t end
function METHODS:FindFirstChild(n) for _,c in real.ipairs(self._children) do if c.Name==n then return c end end return nil end
function METHODS:FindFirstChildOfClass(cl) for _,c in real.ipairs(self._children) do if c.ClassName==cl then return c end end return nil end
function METHODS:IsA(cl) return self.ClassName==cl or cl=="GuiObject" or cl=="Instance" end
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

-- services
local LocalPlayer=newInstance("Player"); LocalPlayer.Name="Tester"; LocalPlayer.UserId=1
local function mkPlayer(name,disp,uid) local p=newInstance("Player"); p.Name=name; p.DisplayName=disp; p.UserId=uid; return p end
local Players=newInstance("Players"); Players.LocalPlayer=LocalPlayer
local roster={ LocalPlayer, mkPlayer("Alice","Alice",11), mkPlayer("Bob","Bobby",22), mkPlayer("Cara","Cara",33) }
function Players:GetPlayers() local t={} for i,p in real.ipairs(roster) do t[i]=p end return t end
Players.PlayerAdded=newEvent("PlayerAdded"); Players.PlayerRemoving=newEvent("PlayerRemoving")

local Workspace=newInstance("Workspace"); Workspace.CurrentCamera=newInstance("Camera"); Workspace.CurrentCamera.ViewportSize=V(1280,720,0)
local SERVICES={ Players=Players, UserInputService=newInstance("UserInputService"),
  RunService=newInstance("RunService"), Workspace=Workspace, TweenService=newInstance("TweenService"),
  VirtualInputManager=newInstance("VirtualInputManager"), Stats=newInstance("Stats"), ReplicatedStorage=newInstance("ReplicatedStorage") }
function SERVICES.RunService:BindToRenderStep() end
function SERVICES.RunService:UnbindFromRenderStep() end
function SERVICES.VirtualInputManager:SendMouseButtonEvent() end
local game=newInstance("DataModel"); game.PlaceId=123; game.GameId=456; game.Workspace=Workspace
function game:GetService(n) SERVICES[n]=SERVICES[n] or newInstance(n); return SERVICES[n] end
local workspace=Workspace

local task={}
function task.spawn(fn,...) local ok,e=real.pcall(fn,...); if not ok then ERRORS[#ERRORS+1]="spawn: "..real.tostring(e) end end
function task.delay(t,fn,...) return end
function task.wait(t) return t or 0 end

-- require shim: load these for real, stub the rest
local REAL={ ["core.signal"]=true, ["ui.theme"]=true, ["ui.components"]=true, ["ui.container"]=true,
  ["modules.aim.state"]=true, ["modules.aim.targeting"]=true,
  ["modules.friendlies"]=true, ["modules.aim.bot"]=true }
local cache={}
local ENV
local function stub(name)
  if name=="ui.window" then return { parent=function() return newInstance("Folder") end } end
  if name=="core.log" then return { info=function() end, warn=function() end, error=function() end, debug=function() end } end
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

ENV=real.setmetatable({ Instance=Instance, Enum=Enum, UDim2=UDim2, UDim=UDim, Color3=Color3,
  Vector2=Vector2, Vector3=Vector3, Rect=Rect, ColorSequence=ColorSequence,
  ColorSequenceKeypoint=ColorSequenceKeypoint, game=game, workspace=workspace, typeof=typeof,
  task=task, require=myrequire, warn=function() end, print=real.print,
  tick=os.clock, time=os.time }, { __index=_G })

local out={ steps={} }
local function log(s) out.steps[#out.steps+1]=s end
local function descendants(node) local o={}; local function rec(n) for _,c in real.ipairs(n._children) do o[#o+1]=c; rec(c) end end; rec(node); return o end

-- ============ FRIENDLIES ============
local state=myrequire("modules.aim.state")
local function countFriendlies()
  local n=0; for _,v in real.pairs(state.friendlies) do if v then n=n+1 end end; return n
end
local function scan()
  local avatars, allBtn, friendlyBtns = 0, nil, 0
  for _,o in real.ipairs(ALL_INSTANCES) do
    if not o._destroyed then
      if o.ClassName=="ImageLabel" and real.type(o._props.Image)=="string"
         and o._props.Image:find("rbxthumb",1,true) then avatars=avatars+1 end
      if o.ClassName=="TextButton" and o._props.Text then
        local t=real.tostring(o._props.Text)
        if t=="All" or t:find("ALL",1,true) then allBtn=o end
        if t=="FRIENDLY" or t=="neutral" then friendlyBtns=friendlyBtns+1 end
      end
    end
  end
  return avatars, allBtn, friendlyBtns
end

local okF, Friendlies = real.pcall(myrequire, "modules.friendlies")
if not okF then out.friendlies_require="THREW: "..real.tostring(Friendlies)
else
  local ok2,err2=real.pcall(function() Friendlies.register() end)
  out.register_ok=ok2; if not ok2 then out.register_err=real.tostring(err2) end
  for _,e in real.ipairs(ERRORS) do log("[swallowed] "..e) end

  local av, allBtn, fb = scan()
  out.avatars_shown=av                  -- expect 3 (Alice/Bob/Cara, not self)
  out.friendly_buttons=fb               -- expect 3
  out.all_button_present=(allBtn~=nil)
  out.friendlies_before=countFriendlies()  -- expect 0

  if allBtn then
    local okc,errc=real.pcall(function() allBtn._events.MouseButton1Click:Fire() end)
    out.all_click_ok=okc; if not okc then out.all_click_err=real.tostring(errc) end
    out.friendlies_after_all_on=countFriendlies()    -- expect 3

    local _,allBtn2=scan()  -- rebuild replaced the button; grab the fresh one
    if allBtn2 then allBtn2._events.MouseButton1Click:Fire() end
    out.friendlies_after_all_off=countFriendlies()   -- expect 0
  end
end

-- ============ BOT ============
local okB, Bot = real.pcall(myrequire, "modules.aim.bot")
if not okB then out.bot_require="THREW: "..real.tostring(Bot)
else
  local ok3,e3=real.pcall(function()
    Bot.init()
    Bot.setAutoAttack(true); Bot.setAttackInterval(0.25); Bot.setReacquire(true)
    Bot.setEnabled(true)
    -- fire Heartbeat a few times (no character -> getBestTarget returns nil -> safe)
    local hb=SERVICES.RunService.Heartbeat
    for i=1,3 do hb:Fire(1/60) end
    Bot.setEnabled(false)
  end)
  out.bot_ok=ok3; if not ok3 then out.bot_err=real.tostring(e3) end
  for _,e in real.ipairs(ERRORS) do log("[bot swallowed] "..e) end
end

local function ser(v,ind) ind=ind or ""
  if real.type(v)=="table" then local s="{\n"
    for k,val in real.pairs(v) do s=s..ind.."  ["..real.tostring(k).."]="..ser(val,ind.."  ").."\n" end
    return s..ind.."}" else return real.tostring(v) end end
return ser(out)
"""

print(rt.execute(LUA))
