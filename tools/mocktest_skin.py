"""Builds the REAL ui/* tree under BOTH skins and exercises every control.

The skin hooks run during construction, so the failure mode they invite is a
build-time one: a nil call, a property Roblox doesn't have, a bevel Frame
parented into a UIListLayout. This harness constructs a container, a navigator,
a feature row with one of every setting type, and each bare component, then
flips every state (toggle on/off, cog open, info open, slider set, dropdown
pick) -- once as "Flat", once as "Hardware" -- and reports anything that threw.

It also asserts the structural rules the hardware skin lives by:
  * a container is AutomaticSize.Y, so the skin must add NO direct child to one
    -- a full-bleed background child is what stretched every menu to the bottom
    of the screen in the first cut. Panel furniture goes in the header host,
    whose extent is fixed.
  * the hexagons stay: no Hex may be hidden, and hardware must add more of them
    (shadows, lamps, bolt heads) rather than replacing them with rectangles
  * socket parts (Cap/Lip/Foot/SocketShade) must never land inside a
    UIListLayout parent (they would become list items) or a UIPadding one
  * every latching indicator must end up reflecting its feature's state

Run: python tools/mocktest_skin.py
"""
import os
import lupa

SRC = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "src"))


def read_file(rel):
    with open(os.path.join(SRC, *rel.split(".")) + ".lua", "r", encoding="utf-8") as f:
        return f.read()


rt = lupa.LuaRuntime(unpack_returned_tuples=True)
rt.globals().python_read_file = read_file
print("Lua:", rt.eval("_VERSION"))

LUA = r"""
local real = { math=math, string=string, table=table, os=os, pcall=pcall, error=error,
  assert=assert, ipairs=ipairs, pairs=pairs, tostring=tostring, tonumber=tonumber,
  type=type, select=select, next=next, setmetatable=setmetatable, rawget=rawget,
  rawset=rawset, print=print, load=load, unpack=unpack or table.unpack }

local ERRORS = {}
local function note(where, e) ERRORS[#ERRORS+1] = where..": "..real.tostring(e) end
local function try(where, fn, ...)
  local ok, e = real.pcall(fn, ...)
  if not ok then note(where, e) end
  return ok, e
end

-- ---- Roblox datatypes ------------------------------------------------------

local EnumCatMT = { __index=function(cat, member)
  local item={_isEnumItem=true,_cat=cat._name,_name=member}
  real.setmetatable(item,{__tostring=function(s) return "Enum."..s._cat.."."..s._name end})
  real.rawset(cat, member, item); return item end }
local Enum = real.setmetatable({}, { __index=function(t,c)
  local cat=real.setmetatable({_name=c}, EnumCatMT); real.rawset(t,c,cat); return cat end })

-- UDim2 needs real arithmetic: the skin nudges labels with `pos + fromOffset`.
local U2MT = {}
local function UDim2new(xs,xo,ys,yo)
  return real.setmetatable({_udim2=true,X={Scale=xs or 0,Offset=xo or 0},Y={Scale=ys or 0,Offset=yo or 0}}, U2MT)
end
U2MT.__add=function(a,b) return UDim2new(a.X.Scale+b.X.Scale,a.X.Offset+b.X.Offset,a.Y.Scale+b.Y.Scale,a.Y.Offset+b.Y.Offset) end
U2MT.__sub=function(a,b) return UDim2new(a.X.Scale-b.X.Scale,a.X.Offset-b.X.Offset,a.Y.Scale-b.Y.Scale,a.Y.Offset-b.Y.Offset) end
U2MT.__eq=function(a,b) return a.X.Scale==b.X.Scale and a.X.Offset==b.X.Offset and a.Y.Scale==b.Y.Scale and a.Y.Offset==b.Y.Offset end
local UDim2 = { new=function(a,b,c,d) return UDim2new(a,b,c,d) end,
  fromOffset=function(a,b) return UDim2new(0,a,0,b) end,
  fromScale=function(a,b) return UDim2new(a,0,b,0) end }
local UDim = { new=function(s,o) return {Scale=s or 0,Offset=o or 0} end }

-- Color3 needs :Lerp (the backlight blends the lamp color toward black/white).
local C3MT = {}
local function C3(r,g,b) return real.setmetatable({_color3=true,R=r or 0,G=g or 0,B=b or 0}, C3MT) end
C3MT.__index = { Lerp=function(self,other,a) return C3(self.R+(other.R-self.R)*a, self.G+(other.G-self.G)*a, self.B+(other.B-self.B)*a) end }
local Color3 = { new=function(r,g,b) return C3(r,g,b) end,
  fromRGB=function(r,g,b) return C3((r or 0)/255,(g or 0)/255,(b or 0)/255) end }

local VMT={}
local function V(x,y,z) return real.setmetatable({_vector=true,X=x or 0,Y=y or 0,Z=z or 0}, VMT) end
VMT.__sub=function(a,b) return V(a.X-b.X,a.Y-b.Y,a.Z-b.Z) end
VMT.__add=function(a,b) return V(a.X+b.X,a.Y+b.Y,a.Z+b.Z) end
VMT.__index=function(t,k) if k=="Magnitude" then return real.math.sqrt(t.X*t.X+t.Y*t.Y+t.Z*t.Z) end return nil end
local Vector2 = { new=function(x,y) return V(x,y,0) end }
local Vector3 = { new=function(x,y,z) return V(x,y,z) end }
local Rect = { new=function(a,b,c,d) return {_rect=true,a,b,c,d} end }
local ColorSequenceKeypoint = { new=function(t,c) return {_csk=true,Time=t,Value=c} end }
local ColorSequence = { new=function(a,b)
  if real.type(a)=="table" and a._csk==nil and a[1]~=nil then return {_cs=true,stops=a} end
  return {_cs=true,stops={a,b}} end }
local NumberSequenceKeypoint = { new=function(t,v) return {_nsk=true,Time=t,Value=v} end }
local NumberSequence = { new=function(a,b)
  if real.type(a)=="table" then return {_ns=true,stops=a} end
  return {_ns=true,stops={a,b}} end }

-- ---- Instances -------------------------------------------------------------

local function newEvent(name)
  local handlers={}
  local ev={_event=true,_name=name}
  function ev:Connect(fn) handlers[#handlers+1]=fn; return {Disconnect=function() end} end
  function ev:Fire(...) for _,fn in real.ipairs(handlers) do local ok,e=real.pcall(fn, ...)
    if not ok then note("event "..real.tostring(name), e) end end end
  return ev
end

local EVENT_NAMES={MouseButton1Click=true,MouseButton1Down=true,MouseButton1Up=true,
  MouseEnter=true,MouseLeave=true,InputBegan=true,InputChanged=true,InputEnded=true,
  FocusLost=true,Changed=true,ChildAdded=true,ChildRemoved=true,Heartbeat=true,
  RenderStepped=true,Stepped=true,OnTeleport=true}
local VEC_PROPS={AbsoluteSize=true,AbsolutePosition=true,AbsoluteContentSize=true}
-- Roblox hands back a default for a property nobody assigned; returning nil
-- instead would make the harness throw on arithmetic that is fine live.
local PROP_DEFAULTS={ZIndex=1,Visible=true,BorderSizePixel=1,BackgroundTransparency=0,
  TextTransparency=0,Rotation=0,LayoutOrder=0}

local ALL={}
local InstanceMT
local function newInstance(cls)
  local o = real.setmetatable({_isInstance=true,ClassName=cls,Name=cls,_children={},
    _props={},_events={},_changed={}}, InstanceMT)
  ALL[#ALL+1]=o
  return o
end
local function setParent(self,parent)
  local old=self._props.Parent
  if old then for i,c in real.ipairs(old._children) do if c==self then real.table.remove(old._children,i) break end end end
  self._props.Parent=parent
  if parent then parent._children[#parent._children+1]=self end
end
local METHODS={}
function METHODS:GetChildren() local t={} for i,c in real.ipairs(self._children) do t[i]=c end return t end
function METHODS:FindFirstChildOfClass(cl) for _,c in real.ipairs(self._children) do if c.ClassName==cl then return c end end return nil end
function METHODS:IsA(cl) return self.ClassName==cl or cl=="GuiObject" or cl=="Instance" end
function METHODS:Destroy() setParent(self,nil); self._destroyed=true end
function METHODS:GetPropertyChangedSignal(p)
  self._changed[p]=self._changed[p] or newEvent("chg:"..real.tostring(p)); return self._changed[p] end
-- engrave() clones a label to make its etched shadow, so Clone must be real.
function METHODS:Clone()
  local o=newInstance(self.ClassName); o.Name=self.Name
  for k,v in real.pairs(self._props) do if k~="Parent" then o._props[k]=v end end
  for _,c in real.ipairs(self._children) do local cc=c:Clone(); setParent(cc,o) end
  return o
end
InstanceMT={
  __index=function(self,k)
    if k=="Parent" then return self._props.Parent end
    if EVENT_NAMES[k] then self._events[k]=self._events[k] or newEvent(k); return self._events[k] end
    if METHODS[k] then return METHODS[k] end
    if self._props[k]~=nil then return self._props[k] end
    if VEC_PROPS[k] then return V(0,0,0) end
    if k=="Position" or k=="Size" then return UDim2new(0,0,0,0) end
    if PROP_DEFAULTS[k]~=nil then return PROP_DEFAULTS[k] end
    return nil
  end,
  __newindex=function(self,k,v)
    if k=="Parent" then setParent(self,v)
    else
      self._props[k]=v
      if self._changed[k] then self._changed[k]:Fire() end
    end
  end,
}
local Instance={ new=function(cls,parent) local o=newInstance(cls); if parent then setParent(o,parent) end; return o end }

-- ---- services --------------------------------------------------------------

local Workspace=newInstance("Workspace")
Workspace.CurrentCamera=newInstance("Camera"); Workspace.CurrentCamera.ViewportSize=V(1280,720,0)
local LocalPlayer=newInstance("Player"); LocalPlayer.Name="Tester"
local Players=newInstance("Players"); Players.LocalPlayer=LocalPlayer
local GuiService=newInstance("GuiService"); function GuiService:GetGuiInset() return V(0,36,0) end
local SERVICES={ Players=Players, Workspace=Workspace, GuiService=GuiService,
  UserInputService=newInstance("UserInputService"), RunService=newInstance("RunService"),
  TweenService=newInstance("TweenService"), SoundService=newInstance("SoundService"),
  HttpService=newInstance("HttpService") }
local game=newInstance("DataModel"); game.PlaceId=1; game.GameId=1
function game:GetService(n) SERVICES[n]=SERVICES[n] or newInstance(n); return SERVICES[n] end
function game:HttpGet() return "" end
local workspace=Workspace

local task={}
function task.spawn(fn,...) local ok,e=real.pcall(fn,...); if not ok then note("task.spawn", e) end end
function task.delay() end
function task.wait(t) return t or 0 end

-- ---- module wiring ---------------------------------------------------------

local SKIN_CHOICE = "Flat"     -- rebound per pass below
local REAL={ ["ui.theme"]=true, ["ui.hex"]=true, ["ui.skin"]=true, ["ui.components"]=true,
  ["ui.feature"]=true, ["ui.container"]=true }
local cache, ENV
local PERSISTED={}
local function stub(name)
  if name=="core.persist" then return {
    init=function() end, flush=function() end,
    get=function(_,d) return d end, set=function() end, clearPrefix=function() end,
    -- Global store: the skin choice lives here, so it has to be a real cell.
    getGlobal=function(k,d) if k=="ui.skin" then return SKIN_CHOICE end
      local v=PERSISTED[k]; if v==nil then return d end return v end,
    setGlobal=function(k,v) PERSISTED[k]=v end,
    slug=function(s) return (real.tostring(s):lower():gsub("[^%w]+","_")) end,
    keyToString=function() return nil end, stringToKey=function() return nil end } end
  if name=="core.log" then return { info=function() end, warn=function() end, err=function() end,
    error=function() end, debug=function() end } end
  if name=="core.keybinds" then return { set=function() end, init=function() end, destroy=function() end } end
  if name=="ui.notify" then return { success=function() end, warn=function() end, info=function() end } end
  if name=="ui.window" then return { parent=function() return newInstance("Folder") end } end
  return real.setmetatable({}, {__index=function() return function() end end})
end
local function myrequire(name)
  if cache[name]~=nil then return cache[name] end
  if REAL[name] then
    local chunk=real.assert(real.load(python_read_file(name), "@"..name, "t", ENV))
    local mod=chunk(); cache[name]=mod; return mod
  end
  local s=stub(name); cache[name]=s; return s
end

local mathShim=real.setmetatable({ clamp=function(x,lo,hi)
  if x<lo then return lo elseif x>hi then return hi else return x end end }, { __index=real.math })

ENV=real.setmetatable({ Instance=Instance, Enum=Enum, UDim2=UDim2, UDim=UDim, Color3=Color3,
  Vector2=Vector2, Vector3=Vector3, Rect=Rect,
  ColorSequence=ColorSequence, ColorSequenceKeypoint=ColorSequenceKeypoint,
  NumberSequence=NumberSequence, NumberSequenceKeypoint=NumberSequenceKeypoint,
  game=game, workspace=workspace, math=mathShim, task=task, require=myrequire,
  warn=function() end, print=real.print, tick=real.os.clock, time=real.os.time },
  { __index=_G })

-- ---- one build pass --------------------------------------------------------

local function findAll(pred)
  local out={}
  for _,o in real.ipairs(ALL) do if not o._destroyed and pred(o) then out[#out+1]=o end end
  return out
end

local function pass(choice)
  SKIN_CHOICE = choice
  cache = {}
  ALL = {}
  ERRORS = {}
  local r = { skin=choice }

  local skin = myrequire("ui.skin")
  r.skin_name = skin.name
  r.skin_current = skin.current()

  local components = myrequire("ui.components")
  local feature    = myrequire("ui.feature")
  local container  = myrequire("ui.container")

  local root = newInstance("Frame")

  -- Navigator + a feature container, the way init.lua wires them.
  local nav = container.buildNavigator(root, "Menu")
  container.startHidden = true
  local box
  try("container.new", function() box = container.new(root, "Test Menu") end)

  -- One feature with a description AND one of every setting type.
  local toggled = {}
  local decl
  try("feature.declare", function()
    decl = feature.declare({
      id="test.everything", name="Everything", description="A row with every control on it.",
      default=false, onToggle=function(v) toggled[#toggled+1]=v end,
      settings={
        { type="section",  name="Group" },
        { type="toggle",   name="A toggle", default=true, onChange=function() end },
        { type="slider",   name="A slider", min=0, max=10, step=1, default=3, onChange=function() end },
        { type="dropdown", name="A dropdown", options={"One","Two"}, default="One", onChange=function() end },
        { type="textbox",  name="A textbox", default="hi", onChange=function() end },
        { type="button",   name="A button", onClick=function() end },
        { type="keybind",  name="A keybind", id="test.key" },
      },
    })
  end)
  if box and decl then try("box:add", function() box:add(decl.root) end) end
  try("nav.populate", function() nav.populate() end)

  -- Bare components, outside a feature panel.
  local host = newInstance("Frame")
  try("components.Button",   function() components.Button(host, {text="Go", onClick=function() end}) end)
  local tg, sl, dd, tb
  try("components.Toggle",   function() tg = components.Toggle(host, {text="T", default=false, onChange=function() end}) end)
  try("components.Slider",   function() sl = components.Slider(host, {text="S", min=0, max=100, default=50}) end)
  try("components.Dropdown", function() dd = components.Dropdown(host, {label="D", options={"a","b"}, default="a"}) end)
  try("components.TextBox",  function() tb = components.TextBox(host, {label="N", default="x"}) end)
  try("components.Keybind",  function() components.KeybindSetter(host, {label="K"}) end)
  try("components.Section",  function() components.Section(host, "Section") end)

  -- Flip every state the skin has to repaint.
  if decl then
    try("feature on",  function() decl.setEnabled(true) end)
    try("feature off", function() decl.setEnabled(false) end)
    try("feature on2", function() decl.setEnabled(true) end)
  end
  r.toggle_callbacks = #toggled

  local function fireOn(pred, event)
    for _,o in real.ipairs(findAll(pred)) do
      if o._events[event] then o._events[event]:Fire() end
    end
  end
  -- cog + info keys, nav rows, dropdown options, and a press on every keycap.
  fireOn(function(o) return o.ClassName=="TextButton" end, "MouseButton1Down")
  fireOn(function(o) return o.ClassName=="TextButton" end, "MouseButton1Up")
  fireOn(function(o) return o.ClassName=="TextButton" end, "MouseLeave")
  if tg then try("toggle set", function() tg:Set(true); tg:Set(false) end) end
  if sl then try("slider set", function() sl:Set(90); sl:Set(0) end) end
  if dd then try("dropdown set", function() dd:Set("b") end) end
  if tb then try("textbox set", function() tb:Set("y") end) end
  if box then try("container show", function() box:setVisible(true); box:setVisible(false) end) end

  -- The "P" opener, built straight from the skin hook (ui/window's own init
  -- drags in sound + teleport plumbing this harness has no business faking).
  local hex = myrequire("ui.hex")
  try("skin.logo", function()
    local h = newInstance("Frame"); h.Size = UDim2.fromOffset(46, 40)
    local hx = hex.build(h, 46, 40, Color3.fromRGB(60,63,70), 10)
    local lb = newInstance("TextLabel"); lb.Text="P"; lb.Parent=h
    skin.logo(h, hx, lb)
  end)

  -- ---- structural assertions ----
  r.instances = #findAll(function() return true end)

  -- Socket parts must never land in a layout/padding parent: they'd become
  -- list items or get inset, which is how a "physical" skin quietly breaks
  -- every panel it touches.
  local DECOR={Cap=true,Lip=true,Foot=true,SocketShade=true,WellShade=true,WellLip=true}
  local bad = {}
  for _,o in real.ipairs(findAll(function(o) return DECOR[o.Name]==true end)) do
    local p = o._props.Parent
    if p then
      for _,c in real.ipairs(p._children) do
        if c.ClassName=="UIListLayout" or c.ClassName=="UIPadding" then
          bad[#bad+1] = real.tostring(p.Name).."/"..real.tostring(c.ClassName)
        end
      end
    end
  end
  r.caps = #findAll(function(o) return o.Name=="Cap" end)
  r.decor_in_layout = #bad
  r.decor_in_layout_where = real.table.concat(bad, ", ")

  r.faders   = #findAll(function(o) return o.Name=="FaderCap" end)

  -- The panel-height regression: a container grows to fit its children, so a
  -- child the skin adds can push it down the screen. Hardware must add none.
  local cchild = 0
  for _,c in real.ipairs(findAll(function(o)
      return real.type(o.Name)=="string" and o.Name:sub(1,10)=="Container_" end)) do
    for _,ch in real.ipairs(c._children) do
      -- UIStroke/UICorner/UIGradient/UIPadding/UIListLayout are not GuiObjects
      -- and take no part in the parent's automatic size.
      if ch.ClassName:sub(1,2)~="UI" then cchild = cchild + 1 end
    end
  end
  r.container_children = cchild
  -- Panel furniture belongs in the header host instead, where it cannot.
  local hchild = 0
  for _,c in real.ipairs(findAll(function(o) return o.Name=="Header" end)) do
    hchild = hchild + #c._children
  end
  r.header_children = hchild

  -- "Hex" is a hexagon carrying a control; the skin's own decoration hexes are
  -- named (HexShadow / Lamp / Bolt), so the two are counted apart.
  r.hexes = #findAll(function(o) return o.Name=="Hex" end)
  r.hexes_hidden = #findAll(function(o) return o.Name=="Hex" and o._props.Visible==false end)
  r.hex_decor = #findAll(function(o)
    return o.Name=="HexShadow" or o.Name=="HexSocket"
        or o.Name=="Lamp" or o.Name=="Bolt" end)
  r.etches   = #findAll(function(o) return o.Name=="Etch" end)
  r.gradients= #findAll(function(o) return o.ClassName=="UIGradient" end)

  -- No GuiObject may carry two UIGradients (Roblox keeps only one).
  local dbl = 0
  for _,o in real.ipairs(findAll(function() return true end)) do
    local n=0
    for _,c in real.ipairs(o._children) do if c.ClassName=="UIGradient" then n=n+1 end end
    if n>1 then dbl=dbl+1 end
  end
  r.double_gradients = dbl

  -- The feature's ON/OFF legend must match the feature's actual state.
  local legends = {}
  for _,o in real.ipairs(findAll(function(o) return o.ClassName=="TextLabel"
      and (o._props.Text=="ON" or o._props.Text=="OFF") end)) do
    legends[#legends+1] = o._props.Text
  end
  r.legends = real.table.concat(legends, ",")

  r.errors = {}
  for i,e in real.ipairs(ERRORS) do r.errors[i]=e end
  r.error_count = #ERRORS
  return r
end

local flatR = pass("Flat")
local hwR   = pass("Hardware")

local function ser(v, ind)
  ind = ind or ""
  if real.type(v)=="table" then
    local s="{\n"
    for k,val in real.pairs(v) do s=s..ind.."  ["..real.tostring(k).."]="..ser(val,ind.."  ").."\n" end
    return s..ind.."}"
  end
  return real.tostring(v)
end

-- ---- verdict ---------------------------------------------------------------
-- Reported as pass/fail rather than raw numbers so a regression is obvious
-- without having to remember what each count is supposed to be.
local checks = {}
local function check(name, ok, detail)
  checks[#checks+1] = (ok and "PASS  " or "FAIL  ")..name..(detail and ("  ("..detail..")") or "")
end
check("flat builds clean",       flatR.error_count==0, flatR.error_count.." errors")
check("hardware builds clean",   hwR.error_count==0,   hwR.error_count.." errors")
-- Flat must stay a true no-op layer: not one instance of skin furniture.
check("flat adds no decoration",
  flatR.caps==0 and flatR.etches==0 and flatR.faders==0)
check("hardware sinks its controls into sockets",
  hwR.caps>0 and hwR.etches>0 and hwR.faders>0,
  hwR.caps.." caps, "..hwR.etches.." etches, "..hwR.faders.." faders")
-- The panel-height regression guard.
check("hardware adds no child to an AutomaticSize container",
  hwR.container_children==flatR.container_children,
  hwR.container_children.." vs flat "..flatR.container_children)
check("panel furniture goes in the header host",
  hwR.header_children>flatR.header_children,
  hwR.header_children.." vs flat "..flatR.header_children)
check("hexagons kept, none hidden, none swapped for a rectangle",
  hwR.hexes==flatR.hexes and hwR.hexes_hidden==0,
  hwR.hexes.." control hexes vs flat "..flatR.hexes..", "..hwR.hexes_hidden.." hidden")
check("hardware builds ON the hexagons",
  hwR.hex_decor>0 and flatR.hex_decor==0,
  hwR.hex_decor.." shadow/lamp/bolt hexes")
check("no socket part inside a layout/padding parent",
  hwR.decor_in_layout==0, hwR.decor_in_layout_where)
check("no double UIGradient", hwR.double_gradients==0 and flatR.double_gradients==0)
check("indicator legends track state",
  flatR.legends==hwR.legends and flatR.legends=="ON,OFF", hwR.legends)
check("onToggle fires the same either way",
  flatR.toggle_callbacks==hwR.toggle_callbacks, flatR.toggle_callbacks.." vs "..hwR.toggle_callbacks)

return ser({ FLAT=flatR, HARDWARE=hwR }) .. "\n\n" .. real.table.concat(checks, "\n")
"""

print(rt.execute(LUA))
