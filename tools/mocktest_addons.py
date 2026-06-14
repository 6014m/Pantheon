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

local ERRORS = {}
local FLAGS = {}   -- addon-set flags we inspect (SETUP_UNIVERSAL, etc.)

local function typeof(x)
  if real.type(x)=="table" then if x._isEnumItem then return "EnumItem" end if x._isInstance then return "Instance" end end
  return real.type(x)
end
local EnumCatMT={__index=function(cat,m) local i={_isEnumItem=true,_cat=cat._name,_name=m}; real.rawset(cat,m,i); return i end}
local Enum=real.setmetatable({},{__index=function(t,c) local cat=real.setmetatable({_name=c},EnumCatMT); real.rawset(t,c,cat); return cat end})

local EVENT_NAMES={ChildAdded=true,Heartbeat=true,MouseButton1Click=true,Touched=true}
local function newEvent() local h={}; local ev={}; function ev:Connect(fn) h[#h+1]=fn; return {Disconnect=function() end} end; function ev:Fire(...) for _,fn in real.ipairs(h) do real.pcall(fn,...) end end; return ev end

local InstanceMT
local function newInstance(cls) return real.setmetatable({_isInstance=true,ClassName=cls,Name=cls,_children={},_props={},_events={}},InstanceMT) end
local METHODS={}
function METHODS:GetChildren() local t={} for i,c in real.ipairs(self._children) do t[i]=c end return t end
function METHODS:IsA(cl) return self.ClassName==cl or cl=="Instance" end
function METHODS:Destroy() self._destroyed=true end
InstanceMT={
  __index=function(self,k)
    if k=="Parent" then return self._props.Parent end
    if EVENT_NAMES[k] then self._events[k]=self._events[k] or newEvent(); return self._events[k] end
    if METHODS[k] then return METHODS[k] end
    return self._props[k]
  end,
  __newindex=function(self,k,v)
    if k=="Parent" then
      self._props.Parent=v
      if v then v._children[#v._children+1]=self end
    else self._props[k]=v end
  end,
}
local Instance={ new=function(cls,parent) local o=newInstance(cls); if parent then o.Parent=parent end; return o end }

local Workspace=newInstance("Workspace")
local game=newInstance("DataModel"); game.PlaceId=123; game.GameId=456
local SERVICES={}
function game:GetService(n) SERVICES[n]=SERVICES[n] or newInstance(n); return SERVICES[n] end

local task={}
function task.spawn(fn,...) real.pcall(fn,...) end
function task.defer(fn,...) real.pcall(fn,...) end
function task.delay() end
function task.wait(t) return t or 0 end

-- ===== in-memory filesystem for the addons folder =====
local FILES={}   -- path -> content
local FOLDERS={ ["Pantheon"]=true, ["Pantheon/addons"]=true }
local function envstub()
  return {
    HttpGet=function(url) return FILES["__url__"..url] or "" end,
    listfiles=function(folder) local t={} for p in real.pairs(FILES) do if p:match("^"..folder.."/[^/]+%.lua$") then t[#t+1]=p end end return t end,
    readfile=function(p) return FILES[p] end,
    writefile=function(p,c) FILES[p]=c end,
    isfile=function(p) return FILES[p]~=nil end,
    delfile=function(p) FILES[p]=nil end,
    makefolder=function(p) FOLDERS[p]=true end,
    isfolder=function(p) return FOLDERS[p]==true end,
  }
end

-- ===== UI / core stubs =====
local NEWCOUNT, DESTROYCOUNT, FEATCOUNT, NAVREFRESH = 0,0,0,0
local PERSIST, GLOBAL = {}, {}
local cache={}
local function stub(name)
  if name=="ui.window" then return { parent=function() return newInstance("Folder") end } end
  if name=="ui.container" then return {
    new=function(_,nm) NEWCOUNT=NEWCOUNT+1; local c={name=nm, features=newInstance("Frame"), _count=0}
        function c:add() self._count=self._count+1 end
        function c:destroy() DESTROYCOUNT=DESTROYCOUNT+1 end
        return c end,
    refreshNavigator=function() NAVREFRESH=NAVREFRESH+1 end,
    list=function() return {} end,
  } end
  if name=="ui.components" then
    local function frame() return newInstance("Frame") end
    local function box() local o={frame=frame()}; function o:Get() return "" end; function o:Set() end; return o end
    return {
      Section=function() return frame() end, Label=function() return frame() end,
      Button=function() return frame() end,
      TextBox=function() return box() end, Slider=function() return box() end,
      Dropdown=function() return box() end, KeybindSetter=function() return box() end,
      Toggle=function() return box() end,
    }
  end
  if name=="ui.feature" then return { declare=function(def) FEATCOUNT=FEATCOUNT+1; return {root=newInstance("Frame"), id=def.id} end } end
  if name=="ui.notify" then return { info=function() end, success=function() end, warn=function() end } end
  if name=="core.log" then return { info=function() end, warn=function() end, error=function() end, err=function() end } end
  if name=="core.env" then return envstub() end
  if name=="games.registry" then return { current=function() return nil end } end
  if name=="ui.theme" then return real.setmetatable({}, {__index=function() return 0 end}) end
  if name=="core.persist" then return {
    get=function(k,d) local v=PERSIST[k]; if v==nil then return d end return v end,
    set=function(k,v) PERSIST[k]=v end,
    getGlobal=function(k,d) local v=GLOBAL[k]; if v==nil then return d end return v end,
    setGlobal=function(k,v) GLOBAL[k]=v end,
    slug=function(s) s=real.tostring(s or "_"):lower():gsub("[^%w]+","_"); return s end,
    keyToString=function(k) return k and real.tostring(k) or nil end,
    stringToKey=function(s) return nil end,
  } end
  return real.setmetatable({}, {__index=function() return function() end end})
end

local myrequire
local ENV
-- loadstring shim: in 5.5 there's no setfenv, so bake ENV into the chunk; the addon
-- uses the vararg style (local Pantheon = ...), which the real loadFile also passes.
local function loadstring_(src, name) return real.load(src, name or "@addon", "t", ENV) end

local function udim() return real.setmetatable({}, {__index=function() return 0 end}) end
local UDim2={ new=udim, fromOffset=udim, fromScale=udim }
local UDim ={ new=udim }
local Vector2={ new=udim }
local Color3={ new=udim, fromRGB=udim }

ENV=real.setmetatable({ Instance=Instance, Enum=Enum, game=game, workspace=Workspace,
  UDim2=UDim2, UDim=UDim, Vector2=Vector2, Color3=Color3,
  typeof=typeof, task=task, os=os, print=real.print, warn=function() end,
  loadstring=loadstring_, setfenv=function(f) return f end, getfenv=function() return ENV end,
  math=real.math, string=real.string, table=real.table, pcall=real.pcall, error=real.error,
  assert=real.assert, ipairs=real.ipairs, pairs=real.pairs, tostring=real.tostring,
  tonumber=real.tonumber, type=real.type, select=real.select, next=real.next,
  setmetatable=real.setmetatable, rawget=real.rawget, rawset=real.rawset,
  FLAGS=FLAGS,
}, { __index=_G })

function myrequire(name)
  if cache[name]~=nil then return cache[name] end
  local mod
  if name=="modules.addons.api" or name=="modules.addons.init" then
    local src=python_read_file(name)
    local chunk=real.assert(real.load(src, "@"..name, "t", ENV))
    cache[name]=true
    mod=chunk()
  else
    mod=stub(name)
  end
  cache[name]=mod
  return mod
end
ENV.require=myrequire

-- ===== seed two addon files =====
FILES["Pantheon/addons/testaddon.lua"] = [[
local Pantheon = ...
Pantheon.register({
  name = "Test Addon", scope = "universal",
  setup = function(ctx)
    FLAGS.universal = true
    local m = ctx:menu("Test Menu")
    m:toggle("Toggle X", { default = false }, function(on) end)
    m:button("Btn", function() end)
    m:slider("Speed", { min=0, max=10, default=5 }, function(v) end)
    ctx:onUnload(function() FLAGS.unloaded = true end)
  end,
})
]]
FILES["Pantheon/addons/offscope.lua"] = [[
local Pantheon = ...
Pantheon.register({
  name = "Off Scope", scope = 999999,
  setup = function(ctx) FLAGS.offscope = true; ctx:menu("Nope") end,
})
]]

local addons = myrequire("modules.addons.init")

local out={}
out.loaded = (addons~=nil) and (addons.register~=nil)
local okR,errR = real.pcall(addons.register)
out.register_ok = okR; if not okR then out.register_err=real.tostring(errR) end

out.setup_universal = FLAGS.universal == true
out.setup_offscope_skipped = FLAGS.offscope == nil          -- off-scope addon must NOT activate
out.menus_created = NEWCOUNT                                  -- manager(1) + universal menu(1) = 2
out.feature_declares = FEATCOUNT                              -- the universal toggle

-- now reload, then destroy and confirm teardown ran the addon's onUnload
local okU,errU = real.pcall(addons.destroy)
out.destroy_ok = okU; if not okU then out.destroy_err=real.tostring(errU) end
out.unloaded = FLAGS.unloaded == true
out.menus_destroyed = DESTROYCOUNT >= 1

local function ser(v) if real.type(v)=="table" then local s="{" for k,val in real.pairs(v) do s=s.."\n  "..real.tostring(k).." = "..ser(val) end return s.."\n}" else return real.tostring(v) end end
return ser(out)
'''
print(rt.execute(LUA))
