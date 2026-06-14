import os, lupa

SRC = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "src"))
def read_file(rel):
    path = os.path.join(SRC, *rel.split(".")) + ".lua"
    with open(path, "r", encoding="utf-8") as f:
        return f.read()

rt = lupa.LuaRuntime(unpack_returned_tuples=True)
G = rt.globals()
G.python_read_file = read_file
print("Lua:", rt.eval("_VERSION"))

LUA = r'''
local real = { math=math, string=string, table=table, os=os, pcall=pcall, error=error,
  assert=assert, ipairs=ipairs, pairs=pairs, tostring=tostring, tonumber=tonumber,
  type=type, select=select, next=next, setmetatable=setmetatable, rawget=rawget,
  rawset=rawset, print=print, load=load }

local ERRORS, NOTIFY, FTI, FIRED = {}, {}, {}, {}

local function typeof(x)
  if real.type(x)=="table" then if x._isEnumItem then return "EnumItem" end if x._isInstance then return "Instance" end end
  return real.type(x)
end
local EnumCatMT={__index=function(cat,m) local i={_isEnumItem=true,_cat=cat._name,_name=m}; real.rawset(cat,m,i); return i end}
local Enum=real.setmetatable({},{__index=function(t,c) local cat=real.setmetatable({_name=c},EnumCatMT); real.rawset(t,c,cat); return cat end})

local function newEvent(name)
  local h={}
  local ev={_event=true,_name=name}
  function ev:Connect(fn) h[#h+1]=fn; return {Disconnect=function() for i,x in real.ipairs(h) do if x==fn then real.table.remove(h,i) break end end end} end
  function ev:Fire(...) for _,fn in real.ipairs(h) do local ok,e=real.pcall(fn,...); if not ok then ERRORS[#ERRORS+1]=name..": "..real.tostring(e) end end end
  return ev
end
local EVENT_NAMES={ChildAdded=true,ChildRemoved=true,DescendantAdded=true,Heartbeat=true,CharacterAdded=true,InputBegan=true,Touched=true}

local VMT={}
local function V(x,y,z) return real.setmetatable({_vector=true,X=x or 0,Y=y or 0,Z=z or 0},VMT) end
VMT.__sub=function(a,b) return V(a.X-b.X,a.Y-b.Y,a.Z-b.Z) end
VMT.__index=function(t,k) if k=="Magnitude" then return real.math.sqrt(t.X*t.X+t.Y*t.Y+t.Z*t.Z) end return nil end

local BASEPARTS={Part=true,MeshPart=true,HumanoidRootPart=true}
local InstanceMT
local function newInstance(cls) return real.setmetatable({_isInstance=true,ClassName=cls,Name=cls,_children={},_props={},_attrs={},_events={}},InstanceMT) end
local function setParent(self,parent)
  local old=self._props.Parent
  if old then for i,c in real.ipairs(old._children) do if c==self then real.table.remove(old._children,i) break end end
    if old._events.ChildRemoved then old._events.ChildRemoved:Fire(self) end end
  self._props.Parent=parent
  if parent then parent._children[#parent._children+1]=self
    if parent._events.ChildAdded then parent._events.ChildAdded:Fire(self) end end
end
local METHODS={}
function METHODS:GetChildren() local t={} for i,c in real.ipairs(self._children) do t[i]=c end return t end
function METHODS:GetDescendants() local o={}; local function rec(n) for _,c in real.ipairs(n._children) do o[#o+1]=c; rec(c) end end; rec(self); return o end
function METHODS:FindFirstChild(n) for _,c in real.ipairs(self._children) do if c.Name==n then return c end end return nil end
function METHODS:FindFirstChildOfClass(cl) for _,c in real.ipairs(self._children) do if c.ClassName==cl then return c end end return nil end
function METHODS:FindFirstChildWhichIsA(cl) for _,c in real.ipairs(self._children) do if c:IsA(cl) then return c end end return nil end
function METHODS:IsA(cl) return self.ClassName==cl or cl=="Instance" or (cl=="BasePart" and BASEPARTS[self.ClassName]==true) end
function METHODS:GetAttributes() local t={} for k,v in real.pairs(self._attrs) do t[k]=v end return t end
function METHODS:GetFullName() local n=self.Name local p=self._props.Parent while p do n=p.Name.."."..n; p=p._props.Parent end return n end
function METHODS:GetPropertyChangedSignal(prop) self._propSignals=self._propSignals or {}; self._propSignals[prop]=self._propSignals[prop] or newEvent("Prop:"..prop); return self._propSignals[prop] end
function METHODS:EquipTool(tool) setParent(tool, self._props.Parent) end
function METHODS:Destroy() setParent(self,nil); self._destroyed=true end
InstanceMT={
  __index=function(self,k)
    if k=="Parent" then return self._props.Parent end
    if EVENT_NAMES[k] then self._events[k]=self._events[k] or newEvent(k); return self._events[k] end
    if METHODS[k] then return METHODS[k] end
    if self._props[k]~=nil then return self._props[k] end
    return nil
  end,
  __newindex=function(self,k,v) if k=="Parent" then setParent(self,v) else self._props[k]=v end end,
}
local Instance={ new=function(cls,parent) local o=newInstance(cls); if parent then setParent(o,parent) end; return o end }

local Workspace=newInstance("Workspace")
local function mkChar(name,pos)
  local m=newInstance("Model"); m.Name=name; setParent(m,Workspace)
  local hrp=newInstance("Part"); hrp.Name="HumanoidRootPart"; hrp.Position=pos; setParent(hrp,m)
  local hum=newInstance("Humanoid"); hum.Health=100; hum.MaxHealth=100; setParent(hum,m)
  return m
end
local LocalPlayer=newInstance("Player"); LocalPlayer.Name="Tester"; LocalPlayer.UserId=1
LocalPlayer.Character=mkChar("TesterChar", V(0,0,0))
local backpack=newInstance("Backpack"); setParent(backpack, LocalPlayer)
local function mkPlayer(name,uid,pos) local p=newInstance("Player"); p.Name=name; p.UserId=uid; if pos then p.Character=mkChar(name.."Char",pos) end return p end
local Players=newInstance("Players"); Players.LocalPlayer=LocalPlayer
local pAlice=mkPlayer("Alice",11, V(10,0,0))
local pBob=mkPlayer("Bob",22, V(40,0,0))
-- parent players to the Players service so Player.Parent ~= nil (real in-game
-- players are parented; nil only after they leave -- which the engine treats as
-- "giver left game"). Without this the giver-left guard trips in the test.
setParent(LocalPlayer,Players); setParent(pAlice,Players); setParent(pBob,Players)
local roster={ LocalPlayer, pAlice, pBob }
function Players:GetPlayers() local t={} for i,p in real.ipairs(roster) do t[i]=p end return t end
function Players:GetPlayerFromCharacter(ch) for _,p in real.ipairs(roster) do if p.Character==ch then return p end end return nil end
function Players:GetPlayerByUserId(uid) for _,p in real.ipairs(roster) do if p.UserId==uid then return p end end return nil end

local SERVICES={ Players=Players, RunService=newInstance("RunService"), Workspace=Workspace, UserInputService=newInstance("UserInputService") }
local game=newInstance("DataModel"); game.PlaceId=123; game.GameId=456
function game:GetService(n) SERVICES[n]=SERVICES[n] or newInstance(n); return SERVICES[n] end

local CLOCK={t=100}
local fakeos={ clock=function() return CLOCK.t end, time=function() return 0 end }
local task={}
function task.spawn(fn,...) local ok,e=real.pcall(fn,...); if not ok then ERRORS[#ERRORS+1]="spawn: "..real.tostring(e) end end
function task.defer(fn,...) local ok,e=real.pcall(fn,...); if not ok then ERRORS[#ERRORS+1]="defer: "..real.tostring(e) end end
function task.delay() end
function task.wait(t) return t or 0 end
local function firetouchinterest(a,b,toggle)
  FTI[#FTI+1]={ src=(a and a.Name) or "?", dst=(b and b.Name) or "?", dstParent=(b and b._props and b._props.Parent and b._props.Parent.Name) or "?", toggle=toggle }
end
local function fireproximityprompt(p) FIRED[#FIRED+1]="prompt:"..((p and p.Name) or "?") end
local function fireclickdetector(c)   FIRED[#FIRED+1]="click:"..((c and c.Name) or "?") end

local capturedDefs={}
local function defById(id) for _,d in real.ipairs(capturedDefs) do if d.id==id then return d end end return nil end
local cache={}
local function stub(name)
  if name=="games.registry" then return { register=function() end, current=function() return nil end, all=function() return {} end } end
  if name=="ui.window" then return { parent=function() return newInstance("Folder") end } end
  if name=="ui.container" then return { new=function() local t={}; function t:add() end; return t end } end
  if name=="ui.feature" then return { declare=function(def) capturedDefs[#capturedDefs+1]=def; return {root=newInstance("Frame")} end } end
  if name=="core.log" then return { info=function() end, warn=function() end, error=function() end, err=function() end, debug=function() end } end
  if name=="ui.notify" then return {
    info=function(m) NOTIFY[#NOTIFY+1]="info:"..real.tostring(m) end,
    success=function(m) NOTIFY[#NOTIFY+1]="success:"..real.tostring(m) end,
    warn=function(m) NOTIFY[#NOTIFY+1]="warn:"..real.tostring(m) end } end
  return real.setmetatable({}, {__index=function() return function() end end})
end
local function myrequire(name) if cache[name]~=nil then return cache[name] end local s=stub(name); cache[name]=s; return s end

local ENV=real.setmetatable({ Instance=Instance, Enum=Enum, game=game, workspace=Workspace,
  typeof=typeof, task=task, require=myrequire, os=fakeos, firetouchinterest=firetouchinterest,
  fireproximityprompt=fireproximityprompt, fireclickdetector=fireclickdetector,
  print=real.print, warn=function() end, math=real.math, string=real.string, table=real.table,
  pcall=real.pcall, ipairs=real.ipairs, pairs=real.pairs, tostring=real.tostring, tonumber=real.tonumber,
  type=real.type, select=real.select, next=real.next, setmetatable=real.setmetatable, error=real.error, assert=real.assert,
}, { __index=_G })

local src = python_read_file("games.evilplate")
local chunk = real.assert(real.load(src, "@games.evilplate", "t", ENV))
local mod = chunk()

local out={}
out.loaded = (mod~=nil) and (mod.register~=nil) and (mod.destroy~=nil)

local okR,errR = real.pcall(function() mod.register() end)
out.register_ok=okR; if not okR then out.register_err=real.tostring(errR) end
local potatoDef = defById("evilplate.hotpotato_return")
local crateDef  = defById("evilplate.auto_crate")
out.feature_count = #capturedDefs
out.has_potato = potatoDef ~= nil
out.has_crate  = crateDef ~= nil

-- toggle Hot Potato Auto-Return on (crate stays OFF so it can't perturb the bomb test)
if potatoDef and potatoDef.onToggle then real.pcall(function() potatoDef.onToggle(true) end) end

-- Alice TOUCHES us (the pass) so recentToucher is set, THEN the bomb arrives.
-- Giver is now identified by who touched us, not by distance-at-receipt.
CLOCK.t=100
local lpHrp    = LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
local aliceHrp = pAlice.Character:FindFirstChild("HumanoidRootPart")
lpHrp.Touched:Fire(aliceHrp)

-- receive the bomb into the backpack (fires ChildAdded -> onReceive)
local bomb=newInstance("Tool"); bomb.Name="HotPotatoBomb"
local handle=newInstance("Part"); handle.Name="Handle"; setParent(handle,bomb)
setParent(bomb, backpack)
out.bomb_parent_after_receive = bomb._props.Parent and bomb._props.Parent.Name or "nil"

-- advance past return delay and tick heartbeat -> onHeartbeat -> attemptReturn
CLOCK.t=102
SERVICES.RunService.Heartbeat:Fire(0.016)

out.fti_count=#FTI
local tgt=""
for _,c in real.ipairs(FTI) do tgt=tgt..("[%s->%s@%s t=%s]"):format(c.src,c.dst,c.dstParent,real.tostring(c.toggle)) end
out.fti=tgt
out.notifies=real.table.concat(NOTIFY," | ")

-- ---- Auto Crate phase: a near crate fires, a far one (outside clickRange) is ignored ----
local airdrop=newInstance("Model"); airdrop.Name="Airdrop"; setParent(airdrop, Workspace)
local cratePart=newInstance("Part"); cratePart.Name="CrateBox"; cratePart.Position=V(5,0,0); setParent(cratePart, airdrop)
local nearPrompt=newInstance("ProximityPrompt"); nearPrompt.Name="OpenPrompt"; nearPrompt.HoldDuration=0.5; setParent(nearPrompt, cratePart)
local far=newInstance("Model"); far.Name="SupplyCrate"; setParent(far, Workspace)
local farPart=newInstance("Part"); farPart.Name="FarBox"; farPart.Position=V(500,0,0); setParent(farPart, far)
local farPrompt=newInstance("ProximityPrompt"); farPrompt.Name="FarPrompt"; farPrompt.HoldDuration=0.5; setParent(farPrompt, farPart)

if crateDef and crateDef.onToggle then real.pcall(function() crateDef.onToggle(true) end) end
SERVICES.RunService.Heartbeat:Fire(0.016)
out.crate_fired = (#FIRED>0) and real.table.concat(FIRED,",") or "none"

-- ---- regression: "started with the potato" -- stale touch AND nobody within
-- giverRadius (everyone scattered far), so no giver is identified -> no auto-pass. ----
pAlice.Character:FindFirstChild("HumanoidRootPart").Position = V(80,0,0)   -- > giverRadius (30)
pBob.Character:FindFirstChild("HumanoidRootPart").Position   = V(90,0,0)
local ftiBefore=#FTI
local bomb2=newInstance("Tool"); bomb2.Name="HotPotatoBomb"
local h2=newInstance("Part"); h2.Name="Handle"; setParent(h2,bomb2)
CLOCK.t=110                   -- 10s after the only touch (t=100) -> stale, beyond giverMemory
setParent(bomb2, backpack)    -- fires onReceive; no toucher + nearest >30 -> should bail
CLOCK.t=112
SERVICES.RunService.Heartbeat:Fire(0.016)
out.no_giver_fti = #FTI - ftiBefore        -- expect 0 (no auto-pass when we started with it)

local okD,errD=real.pcall(function() mod.destroy() end)
out.destroy_ok=okD; if not okD then out.destroy_err=real.tostring(errD) end
out.errors = (#ERRORS>0) and real.table.concat(ERRORS," ;; ") or "none"

local function ser(v) if real.type(v)=="table" then local s="{" for k,val in real.pairs(v) do s=s.."\n  "..real.tostring(k).." = "..ser(val) end return s.."\n}" else return real.tostring(v) end end
return ser(out)
'''
print(rt.execute(LUA))
