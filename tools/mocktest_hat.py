import os, sys
import lupa

SRC = os.path.join(os.path.dirname(__file__), "..", "src")
SRC = os.path.abspath(SRC)

def read_file(rel):
    # rel like "core.signal" -> src/core/signal.lua
    path = os.path.join(SRC, *rel.split(".")) + ".lua"
    with open(path, "r", encoding="utf-8") as f:
        return f.read()

rt = lupa.LuaRuntime(unpack_returned_tuples=True)
G = rt.globals()
G.python_read_file = read_file
print("Lua:", rt.eval("_VERSION"))

LUA = r"""
-- ============ Mock Roblox API ============
local real = { math=math, string=string, table=table, os=os, pcall=pcall, error=error,
  assert=assert, ipairs=ipairs, pairs=pairs, tostring=tostring, tonumber=tonumber,
  type=type, select=select, next=next, setmetatable=setmetatable, getmetatable=getmetatable,
  rawget=rawget, rawset=rawset, rawequal=rawequal, print=print, unpack=(table.unpack or unpack) }

local ERRORS = {}        -- captured errors from task.spawn (the swallowed ones!)
local NOTES  = {}
local function note(s) NOTES[#NOTES+1] = s end

-- ---- typeof ----
local function typeof(x)
  if real.type(x) == "table" then
    if x._isEnumItem then return "EnumItem" end
    if x._isInstance then return "Instance" end
    if x._udim2 then return "UDim2" end
    if x._color3 then return "Color3" end
    if x._vector then return "Vector3" end
  end
  return real.type(x)
end

-- ---- Enum (generic: Enum.Cat.Member -> EnumItem) ----
local EnumCatMT = { __index = function(cat, member)
  local item = { _isEnumItem=true, _cat=cat._name, _name=member }
  setmetatable(item, { __tostring=function(s) return "Enum."..s._cat.."."..s._name end })
  rawset(cat, member, item)
  return item
end }
local Enum = setmetatable({}, { __index=function(t, catName)
  local cat = setmetatable({ _name=catName }, EnumCatMT)
  rawset(t, catName, cat)
  return cat
end })

-- ---- UDim / UDim2 / Color3 / Vector ----
local function UDim2new(xs,xo,ys,yo)
  return { _udim2=true, X={Scale=xs or 0, Offset=xo or 0}, Y={Scale=ys or 0, Offset=yo or 0} }
end
local UDim2 = {
  new = function(xs,xo,ys,yo) return UDim2new(xs,xo,ys,yo) end,
  fromOffset = function(xo,yo) return UDim2new(0,xo,0,yo) end,
  fromScale  = function(xs,ys) return UDim2new(xs,0,ys,0) end,
}
local UDim = { new=function(s,o) return {Scale=s or 0, Offset=o or 0} end }
local Color3 = {
  new=function(r,g,b) return {_color3=true,R=r or 0,G=g or 0,B=b or 0} end,
  fromRGB=function(r,g,b) return {_color3=true,R=(r or 0)/255,G=(g or 0)/255,B=(b or 0)/255} end,
}
local function V(x,y,z) return {_vector=true,X=x or 0,Y=y or 0,Z=z or 0,Magnitude=0} end
local Vector3 = { new=function(x,y,z) return V(x,y,z) end }
local Vector2 = { new=function(x,y) return V(x,y,0) end }
local Rect = { new=function(a,b,c,d) return {a,b,c,d} end }
local CFrame = setmetatable({ new=function() return {_cf=true} end,
  lookAt=function() return {_cf=true} end, Angles=function() return {_cf=true} end },
  { __call=function() return {_cf=true} end })

-- ---- Event (signal) ----
local function newEvent(name)
  local handlers = {}
  local ev = { _event=true, _name=name }
  function ev:Connect(fn) handlers[#handlers+1]=fn; return { Disconnect=function() end } end
  function ev:Wait() return end
  function ev:Fire(...) for _,fn in real.ipairs(handlers) do fn(...) end end
  return ev
end

-- ---- Instance ----
local DEFAULT_VEC = {"AbsoluteSize","AbsolutePosition"}
local function isVecProp(k) for _,n in real.ipairs(DEFAULT_VEC) do if n==k then return true end end return false end

local EVENT_NAMES = { MouseButton1Click=true, MouseButton1Down=true, MouseButton1Up=true,
  MouseButton2Click=true, InputBegan=true, InputChanged=true, InputEnded=true, Activated=true,
  FocusLost=true, Focused=true, Changed=true, ChildAdded=true, ChildRemoved=true,
  MouseEnter=true, MouseLeave=true, MouseMoved=true, Touched=true }

local InstanceMT
local function newInstance(className)
  local self = {
    _isInstance=true, ClassName=className, Name=className,
    _children={}, _props={}, _events={}, _changedSignals={},
  }
  return setmetatable(self, InstanceMT)
end

local function methods(self)
  local M = {}
  function M.GetChildren() local t={} for i,c in real.ipairs(self._children) do t[i]=c end return t end
  function M.GetDescendants()
    local out={}
    local function rec(node) for _,c in real.ipairs(node._children) do out[#out+1]=c; rec(c) end end
    rec(self); return out
  end
  function M.FindFirstChild(name, recursive)
    for _,c in real.ipairs(self._children) do if c.Name==name then return c end end
    if recursive then for _,c in real.ipairs(M.GetDescendants()) do if c.Name==name then return c end end end
    return nil
  end
  function M.FindFirstChildOfClass(cls)
    for _,c in real.ipairs(self._children) do if c.ClassName==cls then return c end end
    return nil
  end
  function M.FindFirstChildWhichIsA(cls)
    for _,c in real.ipairs(self._children) do if c.ClassName==cls then return c end end
    return nil
  end
  function M.FindFirstAncestorWhichIsA(cls)
    local p=self._props.Parent
    while p do if p.ClassName==cls then return p end p=p._props and p._props.Parent end
    return nil
  end
  function M.IsA(cls) return self.ClassName==cls or cls=="GuiObject" or cls=="GuiBase2d" or cls=="Instance" or cls=="LayerCollector" end
  function M.Destroy()
    local p=self._props.Parent
    if p then for i,c in real.ipairs(p._children) do if c==self then real.table.remove(p._children,i) break end end end
    self._props.Parent=nil; self._destroyed=true
  end
  function M.ClearAllChildren() self._children={} end
  function M.Clone() return newInstance(self.ClassName) end
  function M.GetPropertyChangedSignal(prop)
    self._changedSignals[prop]=self._changedSignals[prop] or newEvent("Changed:"..prop)
    return self._changedSignals[prop]
  end
  function M.GetFullName() return self.Name end
  function M.PivotTo() end
  function M.GetBoundingBox() return CFrame.new(), V(2,5,1) end
  function M.SetPrimaryPartCFrame() end
  function M.GetJoints() return {} end
  function M.BreakJoints() end
  function M.TweenSize() end
  return M
end

local function setParent(self, parent)
  local old=self._props.Parent
  if old then for i,c in real.ipairs(old._children) do if c==self then real.table.remove(old._children,i) break end end end
  self._props.Parent=parent
  if parent then parent._children[#parent._children+1]=self end
end

InstanceMT = {
  __index = function(self, k)
    if k=="Parent" then return self._props.Parent end
    if EVENT_NAMES[k] then
      self._events[k]=self._events[k] or newEvent(k); return self._events[k]
    end
    local M=methods(self)
    if M[k] then return M[k] end
    if self._props[k]~=nil then return self._props[k] end
    if isVecProp(k) then return V(0,0,0) end
    return nil
  end,
  __newindex = function(self, k, v)
    if k=="Parent" then setParent(self, v); return end
    self._props[k]=v
  end,
}

local Instance = { new = function(cls, parent)
  local o=newInstance(cls); if parent then setParent(o, parent) end; return o
end }

-- ---- services ----
local PlayerGui = newInstance("PlayerGui"); PlayerGui.Name="PlayerGui"
local LocalPlayer = newInstance("Player"); LocalPlayer.Name="Tester"
setParent(PlayerGui, LocalPlayer)
local function svc_Players()
  local s=newInstance("Players"); s.LocalPlayer=LocalPlayer
  return s
end
local UIS = newInstance("UserInputService")
function UIS:GetMouseLocation() return V(100,100,0) end
function UIS:IsKeyDown() return false end
local RunService = newInstance("RunService")
function RunService:BindToRenderStep() end
function RunService:UnbindFromRenderStep() end
function RunService:IsStudio() return false end
local CurrentCamera = newInstance("Camera"); CurrentCamera.ViewportSize=V(1280,720,0)
local Workspace = newInstance("Workspace"); Workspace.CurrentCamera=CurrentCamera
local RS = newInstance("ReplicatedStorage")   -- no Knit -> scanner.moveServices empty (scanner is stubbed anyway)

local SERVICES = {
  Players=svc_Players(), UserInputService=UIS, RunService=RunService,
  Workspace=Workspace, ReplicatedStorage=RS, TweenService=newInstance("TweenService"),
  CoreGui=newInstance("CoreGui"), StarterGui=newInstance("StarterGui"),
  Lighting=newInstance("Lighting"), Stats=newInstance("Stats"),
}
local game = newInstance("DataModel")
function game:GetService(n) SERVICES[n]=SERVICES[n] or newInstance(n); return SERVICES[n] end
function game:FindService(n) return SERVICES[n] end
game.PlaceId=123; game.GameId=456
game.Workspace=Workspace
local workspace = Workspace

-- ---- task ----
local task = {}
function task.spawn(fn, ...)
  local ok, err = real.pcall(fn, ...)
  if not ok then ERRORS[#ERRORS+1]=real.tostring(err) end
end
function task.defer(fn, ...) return task.spawn(fn, ...) end
function task.delay(t, fn, ...) return end   -- no-op (drag guard etc.)
function task.wait(t) return t or 0 end

-- ============ require shim ============
local REAL_MODULES = {
  ["core.signal"]=true, ["ui.theme"]=true, ["ui.components"]=true,
  ["modules.tech.canvas_ui"]=true, ["modules.tech.builder_ui"]=true,
}

local STUB_SCANNER_MOVESET = {}    -- mutate from test
local cache = {}

local function makeStub(name)
  if name=="core.env" then
    return { guiParent=function() return newInstance("Folder") end, protectGui=function() end,
             newcclosure=function(f) return f end }
  elseif name=="modules.tech.scanner" then
    return {
      cached=function() if #STUB_SCANNER_MOVESET>0 then return {buttons=STUB_SCANNER_MOVESET, services={}, diag={}} end return nil end,
      scan=function() return {buttons=STUB_SCANNER_MOVESET, services={}, diag={}} end,
      clearCache=function() end, moveServices=function() return {} end,
    }
  elseif name=="ui.feature" then
    return { all=function() return {} end, setEnabled=function() end, getEnabled=function() return false end,
             fire=function() end, addInvokable=function() end, declare=function() end }
  elseif name=="modules.tech.engine" then
    return { animHistory=function() return {} end, targetAnimHistory=function() return {} end,
             captureAnim=function() end, captureTargetAnim=function() end, clearAnimHistory=function() end,
             get=function() return nil end, saveCustom=function() end, loadCustom=function() end,
             run=function() end, changed=(function() local e=newEvent("changed"); return e end)(),
             ACTIONS={}, EVENTS={}, CONDITIONS={} }
  elseif name=="core.persist" then
    return { slug=function(s) return (s or "x"):lower():gsub("%W","_") end, set=function() end,
             get=function() return nil end, flush=function() end }
  elseif name=="ui.notify" then
    return { info=function() end, success=function() end, warn=function() end, error=function() end }
  elseif name=="games.registry" then
    return { current=function() return nil end, register=function() end }
  elseif name=="core.log" then
    return { info=function() end, warn=function() end, error=function() end, debug=function() end }
  elseif name=="modules.aim.state" then
    return setmetatable({}, {__index=function() return function() end end})
  end
  -- generic permissive stub
  return setmetatable({}, {__index=function() return function() end end})
end

local ENV  -- the global env table for loaded chunks (set below)
local function myrequire(name)
  if cache[name]~=nil then return cache[name] end
  if REAL_MODULES[name] then
    local src = python_read_file(name)
    local chunk, err
    if setfenv then
      chunk = real.assert(loadstring(src, "@"..name))
      setfenv(chunk, ENV)
    else
      chunk = real.assert(load(src, "@"..name, "t", ENV))
    end
    local mod = chunk()
    cache[name]=mod
    return mod
  end
  local stub = makeStub(name)
  cache[name]=stub
  return stub
end

-- ============ assemble env ============
ENV = setmetatable({
  Instance=Instance, Enum=Enum, UDim2=UDim2, UDim=UDim, Color3=Color3,
  Vector3=Vector3, Vector2=Vector2, Rect=Rect, CFrame=CFrame,
  game=game, workspace=workspace, typeof=typeof, tick=os.clock, time=os.time,
  task=task, require=myrequire, warn=function(...) note("warn: "..real.tostring((...))) end,
  print=real.print, wait=function(t) return t end, spawn=function(f) task.spawn(f) end,
  delay=function(t,f) end, settings=function() return {} end,
}, { __index=_G })

-- expose helpers to drive the test
ENV.__ERRORS=ERRORS; ENV.__NOTES=NOTES
ENV.__setMoveset=function(t) STUB_SCANNER_MOVESET=t end
ENV.__Instance=Instance; ENV.__newEvent=newEvent

-- ============ run ============
-- We need the ScreenGui handle. Hook: track every ScreenGui created.
local SCREENGUIS = {}
do
  local origNew = Instance.new
  Instance.new = function(cls, parent)
    local o = origNew(cls, parent)
    if cls=="ScreenGui" then SCREENGUIS[#SCREENGUIS+1]=o end
    return o
  end
end

-- Build & drive
local out = { steps={} }
local function log(s) out.steps[#out.steps+1]=s end

local ok, Builder = real.pcall(myrequire, "modules.tech.builder_ui")
if not ok then out.fatal="require builder_ui failed: "..real.tostring(Builder)
else
  log("required builder_ui OK")
  local ok2, err2 = real.pcall(function() Builder.open() end)
  log("Builder.open ok="..real.tostring(ok2)..(ok2 and "" or (" THREW: "..real.tostring(err2))))
  for _,e in real.ipairs(ERRORS) do log("  [swallowed err during open] "..e) end

  local gui = SCREENGUIS[#SCREENGUIS]
  if not gui then out.fatal="no ScreenGui created";
  else
    log("ScreenGui created; ZIndexBehavior(prop)="..real.tostring(gui._props.ZIndexBehavior))
    -- find rootFrame (first Frame child of gui)
    local rootFrame
    for _,c in real.ipairs(gui._children) do if c.ClassName=="Frame" then rootFrame=c break end end
    log("rootFrame found="..real.tostring(rootFrame~=nil))

    -- locate the canvas frame + palette buttons by walking descendants
    local function descendants(node)
      local outd={}
      local function rec(n) for _,c in real.ipairs(n._children) do outd[#outd+1]=c; rec(c) end end
      rec(node); return outd
    end

    local function firePaletteAndConfig(hatType, label)
      -- clear errors
      while #ERRORS>0 do real.table.remove(ERRORS) end
      -- find the palette button. After the label fix hats read "+ When move" etc.
      -- (CanvasUI.STEP_LABEL); accept that OR the raw "+ <type>" for robustness.
      local labelMap = { event_move="+ When move", event_key="+ When key",
        event_anim="+ When my anim", event_target_anim="+ When target anim" }
      local want1, want2 = labelMap[hatType], "+ "..hatType
      local target
      for _,d in real.ipairs(descendants(rootFrame)) do
        if d.ClassName=="TextButton" and (d._props.Text==want1 or d._props.Text==want2) then target=d end
      end
      if not target then return {hat=hatType, found=false, note="palette button ('"..tostring(want1).."') not found"} end
      -- simulate click-without-drag: InputBegan(MB1) then InputEnded(MB1)
      local mb1 = { UserInputType=Enum.UserInputType.MouseButton1, Position=V(100,100,0) }
      target._events.InputBegan:Fire(mb1)
      UIS.InputEnded:Fire(mb1)   -- endConn was wired to UIS.InputEnded
      -- now a hat block should exist on canvas. Find its summary valBtn:
      -- it's a TextButton whose text is the hat summary ("(no move set)" etc.)
      -- Easiest: snapshot descendants count, then find new TextButtons with summary text.
      local summaryTexts = { event_move="(set move/key)", event_key="(no key set)",
        event_anim="(no anim set)", event_target_anim="(no anim set)" }
      local want = summaryTexts[hatType]
      local hatBtn
      for _,d in real.ipairs(descendants(rootFrame)) do
        if d.ClassName=="TextButton" and d._props.Text and tostring(d._props.Text):find(want, 1, true) then hatBtn=d end
      end
      local res = { hat=hatType, found=true, hatBlockSummaryBtn=(hatBtn~=nil) }
      if not hatBtn then res.note="hat block summary button not found (text~='"..want.."')"; return res end
      -- fire the summary click -> editHatRequested -> task.spawn(openHatEditor)
      while #ERRORS>0 do real.table.remove(ERRORS) end
      hatBtn._events.MouseButton1Click:Fire()
      -- capture swallowed errors from openHatEditor
      local errs={}
      for _,e in real.ipairs(ERRORS) do errs[#errs+1]=e end
      res.openHatEditorErrors = errs
      -- did a modal appear? modal = Frame with ZIndex 200 under rootFrame
      local modal
      for _,d in real.ipairs(descendants(rootFrame)) do
        if d.ClassName=="Frame" and d._props.ZIndex==200 then modal=d end
      end
      res.modalAppeared = (modal~=nil)
      if modal then
        -- count interactive controls + check for Done button + a picker
        local btns, boxes, doneBtn, pickerLabels = 0,0,false,{}
        for _,d in real.ipairs(descendants(modal)) do
          if d.ClassName=="TextButton" then btns=btns+1; if d._props.Text=="Done" then doneBtn=true end end
          if d.ClassName=="TextBox" then boxes=boxes+1 end
          if d.ClassName=="TextLabel" and d._props.Text then pickerLabels[#pickerLabels+1]=tostring(d._props.Text) end
        end
        res.modalButtons=btns; res.modalTextBoxes=boxes; res.modalHasDone=doneBtn
        res.modalLabels=pickerLabels
      end
      return res
    end

    out.cases = {}
    -- Case A: event_move with NO moves detected
    ENV.__setMoveset({})
    out.cases[#out.cases+1]=firePaletteAndConfig("event_move","no-moves")
    -- Case B: event_move WITH moves
    ENV.__setMoveset({ {name="FlashStrike", text="Flash Strike", key="1"},
                       {name="Whirlwind", text="Whirlwind Kick", key="2"} })
    out.cases[#out.cases+1]=firePaletteAndConfig("event_move","with-moves")
    -- Case C: event_key
    out.cases[#out.cases+1]=firePaletteAndConfig("event_key","key")
    -- Case D: event_anim
    out.cases[#out.cases+1]=firePaletteAndConfig("event_anim","anim")
  end
end

-- serialize out -> string
local function ser(v, ind)
  ind = ind or ""
  local tp=real.type(v)
  if tp=="table" then
    local s="{\n"
    for k,val in real.pairs(v) do
      s=s..ind.."  ["..real.tostring(k).."] = "..ser(val, ind.."  ").."\n"
    end
    return s..ind.."}"
  else return real.tostring(v) end
end
return ser(out)
"""

result = rt.execute(LUA)
print(result)
