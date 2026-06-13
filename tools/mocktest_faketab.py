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

local ERRORS, NOTIFY = {}, {}

local function newEvent(name)
  local h={}
  local ev={_event=true,_name=name}
  function ev:Connect(fn) h[#h+1]=fn; return {Disconnect=function() for i,x in real.ipairs(h) do if x==fn then real.table.remove(h,i) break end end end} end
  function ev:Fire(...) for _,fn in real.ipairs(h) do local ok,e=real.pcall(fn,...); if not ok then ERRORS[#ERRORS+1]=name..": "..real.tostring(e) end end end
  return ev
end
local EVENT_NAMES={ChildAdded=true,ChildRemoved=true,Heartbeat=true,CharacterAdded=true}

local ZEROV = real.setmetatable({_v3zero=true}, {__tostring=function() return "V3.zero" end})
local Vector3 = { zero = ZEROV }

local BASEPARTS={Part=true,MeshPart=true,HumanoidRootPart=true}
local InstanceMT
local function newInstance(cls) return real.setmetatable({_isInstance=true,ClassName=cls,Name=cls,_children={},_props={},_events={}},InstanceMT) end
local function setParent(self,parent)
  local old=self._props.Parent
  if old then for i,c in real.ipairs(old._children) do if c==self then real.table.remove(old._children,i) break end end end
  self._props.Parent=parent
  if parent then parent._children[#parent._children+1]=self
    if parent._events.ChildAdded then parent._events.ChildAdded:Fire(self) end end
end
local METHODS={}
function METHODS:GetChildren() local t={} for i,c in real.ipairs(self._children) do t[i]=c end return t end
function METHODS:FindFirstChild(n) for _,c in real.ipairs(self._children) do if c.Name==n then return c end end return nil end
function METHODS:FindFirstChildOfClass(cl) for _,c in real.ipairs(self._children) do if c.ClassName==cl then return c end end return nil end
function METHODS:FindFirstChildWhichIsA(cl) for _,c in real.ipairs(self._children) do if c:IsA(cl) then return c end end return nil end
function METHODS:IsA(cl) return self.ClassName==cl or cl=="Instance" or (cl=="BasePart" and BASEPARTS[self.ClassName]==true) end
function METHODS:Move(_, _) self._moved=true end   -- Humanoid:Move stub
function METHODS:Destroy() setParent(self,nil) end
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

local Workspace=newInstance("Workspace")
-- R6-ish rig: Head (the part we anchor) + HumanoidRootPart + Humanoid
local function mkChar(name)
  local m=newInstance("Model"); m.Name=name; setParent(m,Workspace)
  local head=newInstance("Part"); head.Name="Head"; setParent(head,m)
  local hrp=newInstance("Part"); hrp.Name="HumanoidRootPart"; setParent(hrp,m)
  local hum=newInstance("Humanoid"); hum.Health=100; setParent(hum,m)
  return m, head, hum
end
local LocalPlayer=newInstance("Player"); LocalPlayer.Name="Tester"
local char0, head0, hum0 = mkChar("TesterChar")
LocalPlayer.Character=char0
local Players=newInstance("Players"); Players.LocalPlayer=LocalPlayer

local SERVICES={ Players=Players, RunService=newInstance("RunService") }
local game=newInstance("DataModel"); game.PlaceId=1; game.GameId=2
function game:GetService(n) SERVICES[n]=SERVICES[n] or newInstance(n); return SERVICES[n] end

local capturedDef=nil
local function stub(name)
  if name=="ui.feature" then return { declare=function(def) capturedDef=def; return {root=newInstance("Frame")} end } end
  if name=="core.log" then return { info=function() end, warn=function() end, error=function() end } end
  if name=="ui.notify" then return {
    info=function(m) NOTIFY[#NOTIFY+1]="info:"..real.tostring(m) end,
    success=function(m) NOTIFY[#NOTIFY+1]="success:"..real.tostring(m) end,
    warn=function(m) NOTIFY[#NOTIFY+1]="warn:"..real.tostring(m) end } end
  return real.setmetatable({}, {__index=function() return function() end end})
end
local cache={}
local function myrequire(name) if cache[name]~=nil then return cache[name] end local s=stub(name); cache[name]=s; return s end

local ENV=real.setmetatable({ game=game, workspace=Workspace, Vector3=Vector3,
  require=myrequire, print=real.print, warn=function() end,
  math=real.math, string=real.string, table=real.table, pcall=real.pcall,
  ipairs=real.ipairs, pairs=real.pairs, tostring=real.tostring, tonumber=real.tonumber,
  type=real.type, select=real.select, next=real.next, setmetatable=real.setmetatable,
  error=real.error, assert=real.assert,
}, { __index=_G })

local src = python_read_file("modules.misc.faketab")
local chunk = real.assert(real.load(src, "@faketab", "t", ENV))
local mod = chunk()

local out={}
out.loaded = (mod~=nil) and (mod.register~=nil) and (mod.destroy~=nil)

local box = { added=0 }
function box:add(_) self.added = self.added + 1 end
local okR,errR = real.pcall(function() mod.register(box) end)
out.register_ok=okR; if not okR then out.register_err=real.tostring(errR) end
out.box_added = box.added
out.feature_id = capturedDef and capturedDef.id or "nil"

-- ---- enable: the HEAD (not the root) must be anchored ----
real.pcall(function() capturedDef.onToggle(true) end)
out.head_anchored_on_enable = (head0.Anchored==true)
out.root_NOT_anchored       = (char0:FindFirstChild("HumanoidRootPart").Anchored~=true)

-- heartbeat maintains it + zeroes the humanoid move (no moonwalk)
SERVICES.RunService.Heartbeat:Fire(0.016)
out.head_still_anchored = (head0.Anchored==true)
out.hum_move_zeroed     = (hum0._moved==true)

-- ---- respawn while enabled: new head anchored, OLD head released ----
local char1, head1, hum1 = mkChar("TesterChar2")
LocalPlayer.Character=char1
SERVICES.RunService.Heartbeat:Fire(0.016)
out.new_head_anchored   = (head1.Anchored==true)
out.old_head_released   = (head0.Anchored==false)

-- ---- disable: head un-anchored, heartbeat goes inert ----
real.pcall(function() capturedDef.onToggle(false) end)
out.head_released_on_disable = (head1.Anchored==false)
head1.Anchored=false
SERVICES.RunService.Heartbeat:Fire(0.016)
out.thaw_inert = (head1.Anchored==false)   -- disabled tick must NOT re-anchor

local okD,errD=real.pcall(function() mod.destroy() end)
out.destroy_ok=okD; if not okD then out.destroy_err=real.tostring(errD) end
out.notifies = real.table.concat(NOTIFY," | ")
out.errors = (#ERRORS>0) and real.table.concat(ERRORS," ;; ") or "none"

local function ser(v) if real.type(v)=="table" then local s="{" for k,val in real.pairs(v) do s=s.."\n  "..real.tostring(k).." = "..ser(val) end return s.."\n}" else return real.tostring(v) end end
return ser(out)
'''
print(rt.execute(LUA))
