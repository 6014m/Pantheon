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
SERVICES.RunService = newInstance("RunService"); SERVICES.RunService.Heartbeat = fakeEvent()
local Players=newInstance("Players"); Players.LocalPlayer=newInstance("Player"); SERVICES.Players=Players

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
local feature = { getEnabled=function() return false end, setEnabled=function() end, fire=function() end,
  all=function() return {} end, addInvokable=function() end }
local keybinds = { set=function() end, clear=function() end, init=function() end, destroy=function() end }
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

-- GAME 100: build a universal tech and a game-scoped tech
game.GameId = 100
local E1 = freshEngine()
E1.saveCustom({ id="uni1", name="UniTech", scope="universal", enabled=true,
  trigger={ event="key", key="G", conditions={} }, actions={ {type="look", x=180} } })
E1.saveCustom({ id="g1", name="GameTech", scope=100, enabled=true,
  trigger={ event="key", key="H", conditions={} }, actions={ {type="look", x=90} } })

out.A_global_has_uni1 = gget(FILES.global, "uni1")
out.A_global_has_g1   = gget(FILES.global, "g1")
out.A_pg100_has_g1    = gget(FILES["100"], "g1")
out.A_pg100_has_uni1  = gget(FILES["100"], "uni1")

-- GAME 200: fresh load -> universal transfers, game-scoped does NOT
game.GameId = 200
local E2 = freshEngine(); E2.loadCustom()
out.B_g200_has_uni1 = E2.all().uni1 ~= nil
out.B_g200_has_g1   = E2.all().g1 ~= nil

-- MIGRATION: a legacy UNIVERSAL tech sitting in a per-game file (game 300)
game.GameId = 300
FILES["300"] = { ["tech.custom"] = { mig1 = { id="mig1", name="Legacy", scope="universal", enabled=true,
  trigger={ event="key", key="J", conditions={} }, actions={} } } }
local E3 = freshEngine(); E3.loadCustom()
out.C_loaded_mig1     = E3.all().mig1 ~= nil
out.C_mig1_to_global  = gget(FILES.global, "mig1")
out.C_mig1_off_pg300  = not gget(FILES["300"], "mig1")

-- GAME 400: migrated tech now transfers; game-100 tech still absent
game.GameId = 400
local E4 = freshEngine(); E4.loadCustom()
out.D_g400_has_mig1 = E4.all().mig1 ~= nil
out.D_g400_has_uni1 = E4.all().uni1 ~= nil
out.D_g400_has_g1   = E4.all().g1 ~= nil

-- setEnabled routing: toggling a universal tech updates the GLOBAL snapshot
E4.setEnabled("uni1", false)
out.E_uni1_global_off = (FILES.global["tech.custom"].uni1.enabled == false)

local function ser(v) if real.type(v)=="table" then local s="{" for k,val in real.pairs(v) do s=s.."\n  "..real.tostring(k).." = "..ser(val) end return s.."\n}" else return real.tostring(v) end end
return ser(out)
'''
print(rt.execute(LUA))

# bundle syntax check
chk = rt.eval(r'function(s) local f,e=load(s) if f then return "OK" else return "ERR: "..tostring(e) end end')
with open(os.path.join(os.path.dirname(__file__), "..", "dist", "main.lua"), "r", encoding="utf-8") as f:
    print("dist/main.lua ->", chk(f.read()))
