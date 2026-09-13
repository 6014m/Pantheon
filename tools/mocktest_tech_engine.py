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
  type=type, setmetatable=setmetatable, rawget=rawget, rawset=rawset, print=print, load=load, select=select }

-- minimal Roblox-ish env --------------------------------------------------
local function typeof(x) if real.type(x)=="table" and x._enum then return "EnumItem" end return real.type(x) end
local Enum = real.setmetatable({}, { __index=function(t,c)
  local cat=real.setmetatable({}, { __index=function(tt,k) local i={_enum=true,_n=k}; real.rawset(tt,k,i); return i end })
  real.rawset(t,c,cat); return cat end })

local InstanceMT
local function newInstance(cls) return real.setmetatable({_inst=true,ClassName=cls,Name=cls,_p={},_c={}}, InstanceMT) end
InstanceMT={ __index=function(self,k)
    if k=="Parent" then return self._p.Parent end
    if self._p[k]~=nil then return self._p[k] end
    return nil
  end, __newindex=function(self,k,v) self._p[k]=v end }

local game=newInstance("DataModel"); game.PlaceId=1; game.GameId=100
local SERVICES={}
function game:GetService(n) SERVICES[n]=SERVICES[n] or newInstance(n); return SERVICES[n] end
-- events some services expose (RunService.Heartbeat etc.) -- only Connect needed
local function fakeEvent() return { Connect=function() return {Disconnect=function() end} end } end
SERVICES.RunService = newInstance("RunService"); local HB={fns={}}; HB.Connect=function(_,fn) HB.fns[#HB.fns+1]=fn; return {Disconnect=function() end} end
SERVICES.RunService.Heartbeat = HB; SERVICES.RunService.BindToRenderStep=function() end; SERVICES.RunService.UnbindFromRenderStep=function() end
local Players=newInstance("Players"); Players.LocalPlayer=newInstance("Player"); SERVICES.Players=Players; Players.LocalPlayer.CharacterAdded = fakeEvent()
SERVICES.VirtualInputManager=newInstance('VirtualInputManager'); SERVICES.VirtualInputManager.SendKeyEvent=function() end; SERVICES.VirtualInputManager.SendMouseButtonEvent=function() end
SERVICES.UserInputService=newInstance('UserInputService'); SERVICES.UserInputService.GetMouseLocation=function() return {X=0,Y=0} end; SERVICES.UserInputService.IsKeyDown=function() return false end

local task={ spawn=function(f,...) real.pcall(f,...) end, delay=function() end, wait=function() end, defer=function(f,...) real.pcall(f,...) end }

-- Signal stub
local Signal={ new=function() local h={}; return {
  Connect=function(_,fn) h[#h+1]=fn; return {Disconnect=function() end} end,
  Fire=function(_,...) for _,fn in real.ipairs(h) do real.pcall(fn,...) end end } end }

-- PERSIST MOCK: per-game store keyed by game.GameId + one global store ----------
local FILES = { global = {} }     -- FILES[gameIdStr] = per-game tbl; FILES.global = cross-game
local function pg() local k=real.tostring(game.GameId); FILES[k]=FILES[k] or {}; return FILES[k] end
local persist = {
  init=function() end, flush=function() end, scheduleSave=function() end,
  get=function(key,d) local v=pg()[key]; if v==nil then return d end return v end,
  set=function(key,v) local s=pg(); if s[key]==v then return end s[key]=v end,    -- same-ref dedup like the real one
  getGlobal=function(key,d) local v=FILES.global[key]; if v==nil then return d end return v end,
  setGlobal=function(key,v) FILES.global[key]=v end,
  keyToString=function(k) if k==nil then return nil end return real.tostring(k) end,
  stringToKey=function(s) return s end,
  slug=function(s) return s end,
}

-- other engine deps: stubs
local state = { target=nil, target_type=nil, target_select_enabled=false, lockon_enabled=false,
  techCamOverride=false, techBodyOverride=false, techIgnoreWelds=false, onTargetChanged=Signal.new() }
local FIRED={}; local feature = { getEnabled=function() return false end, setEnabled=function() end, fire=function(id) FIRED[#FIRED+1]=id end,
  all=function() return {} end, addInvokable=function() end }
local KB={}; local keybinds = { set=function(id) KB[id]=true end, clear=function(id) KB[id]=nil end, init=function() end, destroy=function() end }
local log = { info=function() end, warn=function() end, err=function() end, error=function() end, debug=function() end }
local scanner = { scan=function() return { buttons={} } end }

local cache={ ["modules.aim.state"]=state, ["ui.feature"]=feature, ["core.keybinds"]=keybinds,
  ["core.persist"]=persist, ["core.log"]=log, ["core.signal"]=Signal, ["modules.tech.scanner"]=scanner }
local function myrequire(name)
  if cache[name]~=nil then return cache[name] end
  return real.setmetatable({}, { __index=function() return function() end end })
end

local ENV = real.setmetatable({ Instance={new=newInstance}, Enum=Enum, game=game, workspace=SERVICES.Workspace,
  typeof=typeof, task=task, require=myrequire, os=real.os, print=real.print, warn=function() end,
  math=real.math, string=real.string, table=real.table, pcall=real.pcall, ipairs=real.ipairs,
  pairs=real.pairs, tostring=real.tostring, tonumber=real.tonumber, type=real.type,
  setmetatable=real.setmetatable, error=real.error, assert=real.assert, select=real.select,
}, { __index=_G })

local engineSrc = python_read_file("modules.tech.engine")
local function freshEngine()
  local chunk = real.assert(real.load(engineSrc, "@engine", "t", ENV))   -- also a syntax check
  return chunk()
end
local function gget(store, id) local m = store and store["tech.custom"]; return (m and m[id]~=nil) or false end

local out = {}
local function tick() for _, fn in real.ipairs(HB.fns) do fn() end end

Enum.RenderPriority.Camera.Value = 200   -- fake enum items have no .Value
local E = freshEngine()
E.init()
out.A_heartbeat_hooked = #HB.fns >= 1

-- 1. an AND branch that THROWS must not wedge the runner (old code: infinite wait, every tech dead after)
local t0 = real.os.clock()
E.run({ id="andboom", name="AndBoom", trigger={event="key"}, actions={
  { type="and", branches={ { { type="feature", feature="ok1" } }, { { type="and", branches=5 } } } },
  { type="feature", feature="after" } } })
tick()
out.B_and_error_returns_fast = (real.os.clock() - t0) < 5
out.B_steps_after_and_ran = FIRED[#FIRED] == "after"

-- 2. runner is free again: the next tech runs
E.run({ id="next", name="Next", trigger={event="key"}, actions={ { type="feature", feature="second" } } })
tick()
out.C_runner_not_stuck = FIRED[#FIRED] == "second"

-- 3. Press step with a DIGIT key name must not error (Enum.KeyCode["1"] throws in Roblox)
local okp = real.pcall(E.ACTIONS.key, { key = "1" })
out.D_press_digit_ok = okp

-- 4. remove() clears the per-trigger keybind (it used to stay bound and keep firing)
E.saveCustom({ id="kb1", name="KB", scope=100, enabled=true, trigger={ event="key", key="G", conditions={} }, actions={} })
out.E_bound_after_save = KB["tech.kb1.1"] == true
E.remove("kb1")
out.F_unbound_after_remove = KB["tech.kb1.1"] == nil

-- 5. destroy() clears every remaining tech keybind
E.saveCustom({ id="kb2", name="KB2", scope=100, enabled=true, trigger={ event="key", key="H", conditions={} }, actions={} })
E.destroy()
out.G_unbound_after_destroy = KB["tech.kb2.1"] == nil

local function ser(v) if real.type(v)=="table" then local s="{" for k,val in real.pairs(v) do s=s.."\n  "..real.tostring(k).." = "..ser(val) end return s.."\n}" else return real.tostring(v) end end
return ser(out)
'''
print(rt.execute(LUA))
