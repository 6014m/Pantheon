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
SERVICES.RunService = newInstance("RunService"); local function evt() local e={fns={}}; e.Connect=function(_,fn) e.fns[#e.fns+1]=fn; return {Disconnect=function() for i,f in real.ipairs(e.fns) do if f==fn then real.table.remove(e.fns,i); break end end end} end; return e end
local HB=evt()
SERVICES.RunService.Heartbeat = HB; SERVICES.RunService.BindToRenderStep=function() end; SERVICES.RunService.UnbindFromRenderStep=function() end
local Players=newInstance("Players"); Players.LocalPlayer=newInstance("Player"); SERVICES.Players=Players; Players.LocalPlayer.CharacterAdded = fakeEvent()
SERVICES.VirtualInputManager=newInstance('VirtualInputManager'); SERVICES.VirtualInputManager.SendKeyEvent=function() end; SERVICES.VirtualInputManager.SendMouseButtonEvent=function() end
SERVICES.UserInputService=newInstance('UserInputService'); SERVICES.UserInputService.GetMouseLocation=function() return {X=0,Y=0} end; SERVICES.UserInputService.IsKeyDown=function() return false end
-- fake character with an Animator whose AnimationPlayed we can fire by hand
local AP=evt()
local PLAYING={}
local animator=newInstance('Animator'); animator.AnimationPlayed=AP; animator.GetPlayingAnimationTracks=function() return PLAYING end
local hum=newInstance('Humanoid'); hum.FindFirstChildOfClass=function(_,c) if c=='Animator' then return animator end end; hum.WaitForChild=function(_,n) if n=='Animator' then return animator end end; hum.ChildAdded=fakeEvent()
local char=newInstance('Model'); char.FindFirstChildOfClass=function(_,c) if c=='Humanoid' then return hum end end; char.WaitForChild=function(_,n) if n=='Humanoid' then return hum end end; char.FindFirstChild=function() return nil end
Players.LocalPlayer.Character=char

WAIT_HOOK=nil
local task={ spawn=function(f,...) real.pcall(f,...) end, delay=function() end, wait=function() if WAIT_HOOK then WAIT_HOOK() end end, defer=function(f,...) real.pcall(f,...) end }

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
local function tick() for _, fn in real.ipairs(HB.fns) do fn() end end
local function play(track) for _, fn in real.ipairs(AP.fns) do fn(track) end end
local function fakeTrack(id, len)
  local T = { IsPlaying=true, TimePosition=0, Length=len, Animation={ AnimationId="rbxassetid://"..id } }
  local ST={fns={}}; ST.Connect=function(_,fn) ST.fns[#ST.fns+1]=fn; return {Disconnect=function() end} end
  T.Stopped=ST
  function T.stop() T.IsPlaying=false; for _, fn in real.ipairs(ST.fns) do fn() end end
  return T
end
local function lastFired() return FIRED[#FIRED] end

Enum.RenderPriority.Camera.Value = 200
local E = freshEngine()
E.init()
out.A_anim_hook_connected = #AP.fns >= 1

-- 1. timed trigger: fires when the track CROSSES the time, not before, not at the end
E.saveCustom({ id="t1", name="At0.3", scope=100, enabled=true,
  trigger={ event="anim", animId="111", animAt=0.3, conditions={} }, actions={ { type="feature", feature="hit1" } } })
local tr = fakeTrack("111", 0.8)
play(tr)
tr.TimePosition = 0.10; tick()
out.B1_not_fired_before_time = lastFired() ~= "hit1"
tr.TimePosition = 0.31; tick()
out.B2_fired_on_crossing = lastFired() == "hit1"
tr.TimePosition = 0.79; tick(); tr.stop(); tick()
out.B3_fired_only_once = (#FIRED == 1)

-- 2. cancelled before the time: never fires
E.saveCustom({ id="t2", name="At0.5", scope=100, enabled=true,
  trigger={ event="anim", animId="222", animAt=0.5, conditions={} }, actions={ { type="feature", feature="hit2" } } })
E.setEnabled("t1", false)
local tr2 = fakeTrack("222", 0.8)
play(tr2); tr2.TimePosition = 0.2; tick(); tr2.stop(); tick()
tr2.TimePosition = 0.8; tick()
out.C_cancelled_never_fires = lastFired() ~= "hit2"

-- 3. END trigger still works
E.saveCustom({ id="t3", name="AtEnd", scope=100, enabled=true,
  trigger={ event="anim", animId="333", animEnd=true, conditions={} }, actions={ { type="feature", feature="hit3" } } })
local tr3 = fakeTrack("333", 0.8)
play(tr3); tick()
out.D1_end_not_fired_at_start = lastFired() ~= "hit3"
tr3.stop(); tick()
out.D2_end_fired_on_stop = lastFired() == "hit3"

-- 4. a save carrying BOTH animEnd and animAt: the time wins (deserialize heals it)
game.GameId = 100
FILES["100"]["tech.custom"].both = { id="both", name="Both", scope=100, enabled=true,
  trigger={ event="anim", animId="444", animEnd=true, animAt=0.25, conditions={} }, actions={ { type="feature", feature="hit4" } } }
local E2 = freshEngine(); E2.init(); E2.loadCustom()
out.E1_heal_animEnd_cleared = (E2.all().both.trigger.animEnd == nil) and (E2.all().both.trigger.animAt == 0.25)
FIRED = {}
local tr4 = fakeTrack("444", 0.8)
play(tr4); tick()                       -- (E2's hook + E's hook both see it; E has no tech for 444)
tr4.TimePosition = 0.3; tick()
out.E2_fires_at_time_not_end = lastFired() == "hit4"
E2.destroy()

-- 5. "Anim at" step on an anim-triggered tech waits on the triggering track
E.setEnabled("t2", false); E.setEnabled("t3", false)
E.saveCustom({ id="t5", name="AnimWait", scope=100, enabled=true,
  trigger={ event="anim", animId="555", conditions={} },
  actions={ { type="feature", feature="first" }, { type="animwait", at=0.5 }, { type="feature", feature="late" } } })
local tr5 = fakeTrack("555", 1.0)
local reachedAt
WAIT_HOOK = function() tr5.TimePosition = tr5.TimePosition + 0.1; if tr5.TimePosition >= 0.5 and not reachedAt then reachedAt = tr5.TimePosition end end
FIRED = {}
play(tr5); tick()
out.F1_first_step_ran_at_start = FIRED[1] == "first"
out.F2_late_step_after_animwait = FIRED[2] == "late" and reachedAt ~= nil and reachedAt >= 0.5
WAIT_HOOK = nil

-- 6. "Anim at" on a KEY-triggered tech binds to the move's own anim (the next one to play)
E.setEnabled("t5", false)
tr5.stop()   -- previous move ended; a leftover still-playing anim must NOT be picked up either (runStart gate)
local tr6 = fakeTrack("666", 1.0)
local pending = true
WAIT_HOOK = function()
  if pending then pending = false; play(tr6) end      -- the pressed move starts its anim one frame later
  tr6.TimePosition = tr6.TimePosition + 0.1
end
FIRED = {}
E.run({ id="k1", name="KeyCombo", trigger={ event="key" }, actions={ { type="animwait", at=0.4 }, { type="feature", feature="after" } } })
tick()
out.G_key_tech_animwait_binds_next_anim = FIRED[1] == "after" and tr6.TimePosition >= 0.4
WAIT_HOOK = nil
E.destroy()

local function ser(v) if real.type(v)=="table" then local s="{" local keys={} for k in real.pairs(v) do keys[#keys+1]=k end real.table.sort(keys) for _,k in real.ipairs(keys) do s=s.."\n  "..real.tostring(k).." = "..ser(v[k]) end return s.."\n}" else return real.tostring(v) end end
return ser(out)
'''
print(rt.execute(LUA))
