import os
import lupa

SRC = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "src"))

def read_file(rel):
    with open(os.path.join(SRC, *rel.split(".")) + ".lua", "r", encoding="utf-8") as f:
        return f.read()

rt = lupa.LuaRuntime(unpack_returned_tuples=True)
rt.globals().python_read_file = read_file
print("Lua:", rt.eval("_VERSION"))

# Drives the REAL modules.aim.state + modules.aim.targeting + modules.aim.target_select
# + games.veil against a tiny fake Roblox world to verify:
#   * The Veil's Bot Mode filter hides "Runner" NPCs and NPCs that haven't moved
#     (anchored or never seen moving) and NPCs with a talk prompt, keeps an NPC once
#     it moves, and never hides mobs inside workspace.Monsters.
#   * Veil.destroy() removes the filter again.
#   * getRankedTargets orders by distance, and cycleTarget steps forward/back with
#     wrap-around (the scroll-wheel swap).
#   * Summons owned by you or a friendly are skipped (owner from an attribute, a
#     value object, a folder named after the player, or the name), enemies' are not,
#     and the "Skip your + friendlies' summons" toggle turns it off.
LUA = r"""
table.clear = table.clear or function(t) for k in pairs(t) do t[k] = nil end end

local Enum = setmetatable({}, { __index=function(t,c)
  local cat=setmetatable({_name=c}, { __index=function(cc,m)
    local it={_isEnumItem=true,_cat=cc._name,_name=m,Value=0}; rawset(cc,m,it); return it end })
  rawset(t,c,cat); return cat end })

local VMT = {}
local function V(x,y,z) return setmetatable({X=x or 0,Y=y or 0,Z=z or 0}, VMT) end
VMT.__add = function(a,b) return V(a.X+b.X,a.Y+b.Y,a.Z+b.Z) end
VMT.__sub = function(a,b) return V(a.X-b.X,a.Y-b.Y,a.Z-b.Z) end
VMT.__index = function(t,k)
  if k == "Magnitude" then return math.sqrt(t.X*t.X+t.Y*t.Y+t.Z*t.Z) end
  return nil
end
local Vector3 = { new=V, zero=V(0,0,0) }
local Vector2 = { new=function(x,y) return V(x,y,0) end }

local clock = 100
os.clock = function() return clock end

-- Instances ---------------------------------------------------------------
local VALUE_CLASSES = { ObjectValue=true, StringValue=true, IntValue=true, NumberValue=true }
local INST = {}
INST.__index = function(self, k)
  local m = rawget(INST, k); if m then return m end
  return rawget(self, "_kids")[k]
end
function INST:IsA(c)
  if c == "ValueBase" then return VALUE_CLASSES[self.ClassName] == true end
  return self.ClassName == c
end
function INST:FindFirstChild(n) return self._kids[n] end
function INST:FindFirstChildOfClass(c)
  for _, ch in ipairs(self._list) do if ch.ClassName == c then return ch end end
end
function INST:FindFirstAncestorOfClass(c)
  local p = self.Parent
  while p do if p.ClassName == c then return p end; p = p.Parent end
end
function INST:GetChildren() local t = {}; for i, ch in ipairs(self._list) do t[i] = ch end; return t end
function INST:GetAttributes() return self._attrs or {} end
function INST:GetDescendants()
  local out = {}
  local function walk(o) for _, ch in ipairs(o._list) do out[#out+1] = ch; walk(ch) end end
  walk(self); return out
end
function INST:IsDescendantOf(anc)
  local p = self.Parent
  while p do if p == anc then return true end; p = p.Parent end
  return false
end
local function new(cls, name, parent)
  local o = setmetatable({ ClassName=cls, Name=name or cls, _kids={}, _list={} }, INST)
  if parent then o.Parent = parent; parent._kids[o.Name] = o; parent._list[#parent._list+1] = o end
  return o
end

typeof = function(v)
  if type(v) == "table" and (getmetatable(v) == INST or v._isPlayer) then return "Instance" end
  return type(v)
end

local Workspace = new("Workspace", "Workspace")
local Monsters  = new("Folder", "Monsters", Workspace)

local function npc(name, pos, parent, opts)
  opts = opts or {}
  local m = new("Model", name, parent or Workspace)
  local hum = new("Humanoid", "Humanoid", m); hum.Health = 100; hum.MaxHealth = 100
  local root = new("Part", "HumanoidRootPart", m)
  root.Position = pos; root.Anchored = opts.anchored or false
  root.AssemblyLinearVelocity = V(0,0,0)
  if opts.prompt then new("ProximityPrompt", "Talk", root) end
  if opts.attrs then m._attrs = opts.attrs end
  return m, root
end

local me = new("Model", "Me", Workspace)
new("Humanoid", "Humanoid", me)
local myRoot = new("Part", "HumanoidRootPart", me); myRoot.Position = V(0,0,0)

local function player(name, id, char)
  return { _isPlayer = true, Name = name, DisplayName = name, UserId = id, Character = char,
           IsA = function(_, c) return c == "Player" end }
end
local LocalPlayer = player("Sable", 1, me)
local Buddy       = player("Buddy", 2, nil)
local Enemy       = player("Grifter", 3, nil)
local ALL = { LocalPlayer, Buddy, Enemy }
local Players = {
  LocalPlayer = LocalPlayer,
  GetPlayers = function() return ALL end,
  GetPlayerFromCharacter = function(_, c) if c == me then return LocalPlayer end end,
  GetPlayerByUserId = function(_, id) for _, p in ipairs(ALL) do if p.UserId == id then return p end end end,
  FindFirstChild = function(_, n) for _, p in ipairs(ALL) do if p.Name == n then return p end end end,
}
local function noopSignal() return { Connect=function() return { Disconnect=function() end } end } end
local services = {
  Players = Players, Workspace = Workspace,
  UserInputService = { GetMouseLocation=function() return V(0,0,0) end },
  GuiService = { GetGuiInset=function() return V(0,0,0) end },
  RunService = { Heartbeat = noopSignal(), RenderStepped = noopSignal() },
  ContextActionService = { BindActionAtPriority=function() end, UnbindAction=function() end },
  Stats = {},
}
game = { PlaceId = 125503525638054, GameId = 7970033072,
         GetService = function(_, n) return services[n] end }
Workspace.CurrentCamera = nil

RaycastParams = { new = function() return {} end }
_G.Enum, _G.Vector3, _G.Vector2 = Enum, Vector3, Vector2

-- require shim: real modules for aim + games, stubs for UI / log / signal ------
local loaded = {}
local registered = {}
local stubs = {
  ["core.signal"] = { new = function() return { Fire=function() end, Connect=function() end } end },
  ["core.log"] = { info=function() end, warn=function() end, err=function() end },
  ["ui.window"] = { parent = function() return {} end },
  ["ui.container"] = { new = function() return { add=function() end } end },
  ["ui.feature"] = { declare = function(def)
      _G.lastFeature = def
      return { root = {} } end },
  ["modules.aim.highlight"] = { update=function() end },
  ["games.registry"] = { register=function(ids, mod) registered[#registered+1] = mod end },
}
function require(name)
  if loaded[name] ~= nil then return loaded[name] end
  if stubs[name] then loaded[name] = stubs[name]; return stubs[name] end
  local chunk = assert(load(python_read_file(name), "=" .. name))
  local r = chunk()
  loaded[name] = r == nil and true or r
  return loaded[name]
end

local state     = require("modules.aim.state")
local targeting = require("modules.aim.targeting")
local ts        = require("modules.aim.target_select")
local veil      = require("games.veil")

local results = {}
local function check(label, cond) results[#results+1] = (cond and "PASS " or "FAIL ") .. label end

local function npcNames(filterFn)
  clock = clock + 3   -- past the 0.5 s NPC cache and the 2 s owner cache
  local out = {}
  for _, e in ipairs(targeting.getRankedTargets()) do
    if not filterFn or filterFn(e.target.Name) then out[#out+1] = e.target.Name end
  end
  return table.concat(out, ",")
end

state.botMode = true
state.checkHealthEnabled = true
state.rangeLimit = 0

local mob1          = npc("Hiveling", V(10,0,0), Monsters)            -- idle mob in Monsters folder
local runner, runnerRoot = npc("Runner", V(5,0,0))
local shop, shopRoot = npc("Shopkeeper", V(8,0,0), nil, { anchored = true })
local quest         = npc("Vesper", V(12,0,0), nil, { prompt = true })
local wander, wRoot = npc("Wraith", V(20,0,0))                          -- outside Monsters, idle at first
local mob2          = npc("Cambion", V(30,0,0), Monsters)

check("no filter: every npc is a target", npcNames() == "Runner,Shopkeeper,Hiveling,Vesper,Wraith,Cambion")

check("registry got the veil module", #registered >= 1)
veil.register()
local names = npcNames()
check("veil filter: runners, anchored, prompt and still NPCs hidden; Monsters kept (" .. names .. ")",
  names == "Hiveling,Cambion")

wRoot.Position = V(24,0,0)   -- the wraith moves 4 studs
names = npcNames()
check("an NPC that moves becomes a target (" .. names .. ")", names == "Hiveling,Wraith,Cambion")

wRoot.Position = V(20,0,0)   -- stands still again; stays a target
check("once moved it stays a target", npcNames() == "Hiveling,Wraith,Cambion")

-- settings toggles
local def = _G.lastFeature
for _, opt in ipairs(def.settings) do
  if opt.key == "skip_runners" then opt.onChange(false) end
end
names = npcNames()   -- an idle runner is still hidden by the "doesn't move" rule
check("Skip Runners off: an idle runner stays hidden as a still NPC (" .. names .. ")", names == "Hiveling,Wraith,Cambion")
runnerRoot.Position = V(3,0,0)   -- the runner walks 2 studs
names = npcNames()
check("Skip Runners off: a moving runner shows (" .. names .. ")", names == "Runner,Hiveling,Wraith,Cambion")
for _, opt in ipairs(def.settings) do
  if opt.key == "skip_runners" then opt.onChange(true) end
end
def.onToggle(false)
check("feature off disables the filter", npcNames() == "Runner,Shopkeeper,Hiveling,Vesper,Wraith,Cambion")
def.onToggle(true)

-- scroll-wheel cycling over Hiveling(10) < Wraith(20) < Cambion(30)
npcNames()
state.target_select_enabled = true
state.setTarget(mob1, "npc")
ts.cycleTarget(1);  check("wheel down: Hiveling -> Wraith", state.target == wander)
ts.cycleTarget(1);  check("wheel down: Wraith -> Cambion", state.target == mob2)
ts.cycleTarget(1);  check("wheel down wraps: Cambion -> Hiveling", state.target == mob1)
ts.cycleTarget(-1); check("wheel up wraps: Hiveling -> Cambion", state.target == mob2)
ts.cycleTarget(-1); check("wheel up: Cambion -> Wraith", state.target == wander)

state.setTarget(runner, "npc")   -- current target is filtered out of the ranking
ts.cycleTarget(1);  check("target not in ranking: wheel down picks the best", state.target == mob1)

veil.destroy()
check("destroy removes the filter", #state.npcFilters == 0)
check("after destroy every npc is back", npcNames() == "Runner,Shopkeeper,Hiveling,Vesper,Wraith,Cambion")

-- summons -------------------------------------------------------------------
local isImp = function(n) return n:find("Imp") ~= nil or n:find("Boulder") ~= nil end
npc("Imp", V(40,0,0), nil, { attrs = { Owner = "Sable" } })                  -- mine, by attribute (name)
local buddyImp = npc("Imp2", V(41,0,0))                                        -- Buddy's, by ObjectValue
local cv = new("ObjectValue", "Creator", buddyImp); cv.Value = Buddy
local folder = new("Folder", "Grifter", Workspace)                             -- enemy's, by folder name
npc("Boulder", V(42,0,0), folder)
npc("Sable's Imp", V(43,0,0))                                                  -- mine, by name
npc("ImpUid", V(44,0,0), nil, { attrs = { summoner_id = 3 } })                 -- unknown key: not an owner
npc("ImpById", V(45,0,0), nil, { attrs = { OwnerUserId = 1 } })               -- mine, by user id

names = npcNames(isImp)
check("summons: mine hidden, not-yet-friendly Buddy's shown, enemy's shown (" .. names .. ")",
  names == "Imp2,Boulder,ImpUid")
state.friendlies[2] = true
names = npcNames(isImp)
check("summons: marking Buddy friendly hides his summon (" .. names .. ")", names == "Boulder,ImpUid")
state.skipFriendlySummons = false
names = npcNames(isImp)
check("summons: toggle off shows all of them (" .. names .. ")",
  names == "Imp,Imp2,Boulder,Sable's Imp,ImpUid,ImpById")

return table.concat(results, "\n")
"""

out = rt.execute(LUA)
print(out)
fails = [l for l in out.splitlines() if l.startswith("FAIL")]
print(f"\n{len(out.splitlines()) - len(fails)} passed, {len(fails)} failed")
raise SystemExit(1 if fails else 0)
