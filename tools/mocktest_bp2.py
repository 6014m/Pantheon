import os
import lupa

SRC = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "src"))

def read_file(rel):
    with open(os.path.join(SRC, *rel.split(".")) + ".lua", "r", encoding="utf-8") as f:
        return f.read()

rt = lupa.LuaRuntime(unpack_returned_tuples=True)
rt.globals().python_read_file = read_file
print("Lua:", rt.eval("_VERSION"))

# Drives the REAL games.bp2 against a fake BP2:
#   * the namecall hook rewrites arg 6 (the aim point) of Blade "release" fires
#   * 3-throw cycle: 1-2 are land-chance rolls, 3 always lands; failed rolls and
#     wall throws (nobody in snap range) pass through untouched, walls don't count
#   * head/torso split, teammate / dead / forcefield / far players never picked,
#     other players' Blade remotes untouched, toggle off = inert
LUA = r"""
table.clear = table.clear or function(t) for k in pairs(t) do t[k] = nil end end
table.pack = table.pack or function(...) return { n = select('#', ...), ... } end
table.unpack = table.unpack or unpack

-- controllable randomness: a queue of [0,1) values
local randq = {}
_G.pushRand = function(v) randq[#randq + 1] = v end
math.random = function()
  assert(#randq > 0, "rand queue empty")
  return table.remove(randq, 1)
end

local function V(x, y, z)
  return setmetatable({ __vec = true, X = x, Y = y, Z = z }, { __index = function(t, k)
    if k == "Magnitude" then return math.sqrt(t.X^2 + t.Y^2 + t.Z^2) end
  end, __sub = function(a, b) return V(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end })
end
_G.V = V
typeof = function(v)
  if type(v) == "table" and v.__vec then return "Vector3" end
  return type(v)
end

-- instances -------------------------------------------------------------------
local INST = {}
INST.__index = INST
function INST:IsA(c) return self.ClassName == c end
function INST:FindFirstChild(n)
  for _, ch in ipairs(self._list) do if ch.Name == n then return ch end end
end
function INST:FindFirstChildOfClass(c)
  for _, ch in ipairs(self._list) do if ch.ClassName == c then return ch end end
end
function INST:IsDescendantOf(anc)
  local p = self.Parent
  while p do if p == anc then return true end; p = p.Parent end
  return false
end
local function new(cls, name, parent)
  local o = setmetatable({ ClassName = cls, Name = name or cls, _list = {} }, INST)
  if parent then o.Parent = parent; parent._list[#parent._list + 1] = o end
  return o
end
_G.newInst = new

local function makeChar(x, z, opts)
  opts = opts or {}
  local c = new("Model", opts.name or "Char")
  local hum = new("Humanoid", "Humanoid", c); hum.Health = opts.hp or 100
  local head = new("Part", "Head", c);  head.Position = V(x, 5, z)
  if not opts.noTorso then
    local torso = new("Part", "Torso", c); torso.Position = V(x, 3, z)
  end
  if opts.forcefield then new("ForceField", "ForceField", c) end
  return c
end
_G.makeChar = makeChar

local myChar = new("Model", "Me")
local blade = new("Tool", "Blade", myChar)
local myRemote = new("RemoteEvent", "RemoteEvent", blade)
_G.myRemote = myRemote
_G.myChar = myChar

local redTeam, blueTeam = { Name = "Red" }, { Name = "Blue" }
_G.redTeam, _G.blueTeam = redTeam, blueTeam

local LP = { Name = "Me", Character = myChar, Team = nil, Neutral = true }
_G.LP = LP
local others = {}
_G.others = others
local Players = { LocalPlayer = LP }
function Players:GetPlayers()
  local t = { LP }
  for _, p in ipairs(others) do t[#t + 1] = p end
  return t
end

game = { PlaceId = 6648893133, GameId = 2499076778 }
function game:GetService(n)
  if n == "Players" then return Players end
  error("no service " .. n)
end

-- executor hook api -------------------------------------------------------------
getgenv = function() return _G end
getnamecallmethod = function() return _G.ncm end
_G.fired = nil            -- what the ORIGINAL namecall finally receives
local hookFn = nil
hookmetamethod = function(obj, meta, fn)
  hookFn = fn
  _G.hookFn = fn
  return function(self, ...)
    _G.fired = table.pack(...)
    return "orig"
  end
end

-- module stubs --------------------------------------------------------------------
_G.toasts = {}
local registered = nil
local featDef = nil
local MODS = {
  ["games.registry"] = { register = function(ids, mod) registered = { ids = ids, mod = mod } end },
  ["ui.window"]    = { parent = function() return {} end },
  ["ui.container"] = { new = function() return { add = function() end } end },
  ["ui.feature"]   = { declare = function(def) featDef = def; return { root = {} } end },
  ["core.log"]     = { info = function() end },
  ["ui.notify"]    = { info = function(t) _G.toasts[#_G.toasts + 1] = t end, warn = function() end },
}
function require(name)
  if MODS[name] then return MODS[name] end
  local chunk = assert(load(python_read_file(name), "@" .. name))
  MODS[name] = chunk()
  return MODS[name]
end

BP2 = require("games.bp2")
assert(registered and registered.ids[1] == 2499076778, "registered under BP2 GameId")
BP2.register()
assert(featDef, "feature declared")
_G.featDef = featDef

-- fire a throw through the hook exactly like the game's namecall would
_G.throw = function(remote, aimX, aimZ)
  _G.ncm = "FireServer"
  _G.fired = nil
  local r = hookFn(remote, "release", 1, 12345.6, false,
      V(0, 2, 0), V(aimX, 3, aimZ),
      { Me = V(0, 2, 0) }, "aabbccdd11223344aabb", true)
  return r
end
"""
rt.execute(LUA)

g = rt.globals()
lua = rt.execute
checks = []
def check(name, cond):
    checks.append((name, bool(cond)))
    print(("PASS " if cond else "FAIL ") + name)

def aim():
    f = rt.eval("fired")
    v = f[6]
    return (v["X"], v["Z"])

# enemy 8 studs from the aim point
lua("""
  foe = { Name = 'Foe', Team = nil, Neutral = true, Character = makeChar(18, 0, { name = 'FoeChar' }) }
  others[1] = foe
""")

# -- 1. disabled: untouched
lua("throw(myRemote, 10, 0)")
check("disabled -> aim untouched", aim() == (10, 0))

# -- 2. enabled, throw 1, land roll passes, head roll passes -> Head position
lua("featDef.onToggle(true)")
lua("pushRand(0.10); pushRand(0.10)")   # land (0.10*100 < 50), head (0.10*100 < 50)
lua("throw(myRemote, 10, 0)")
fx = rt.eval("fired[6]")
check("throw 1 lands on the HEAD", (fx["X"], fx["Y"], fx["Z"]) == (18, 5, 0))

# -- 3. throw 2, land roll fails -> natural miss, untouched
lua("pushRand(0.90)")
lua("throw(myRemote, 10, 0)")
check("throw 2 rolls a natural miss", aim() == (10, 0))

# -- 4. throw 3 ALWAYS lands (no land roll consumed), body when head roll fails
lua("pushRand(0.90)")                   # only the head roll; land roll must not be drawn
lua("throw(myRemote, 10, 0)")
fx = rt.eval("fired[6]")
check("throw 3 guaranteed, body shot", (fx["X"], fx["Y"], fx["Z"]) == (18, 3, 0))

# -- 5. wall throw: nobody within snap range -> untouched AND cycle not advanced
lua("pushRand(0.90)")                   # would-be miss for the next counted throw (throw 1)
lua("throw(myRemote, 500, 500)")
check("wall throw untouched", aim() == (500, 500))
lua("throw(myRemote, 10, 0)")           # counted: this is throw 1 again (cycle reset after 3)
check("wall throw did not advance the cycle (throw 1 can miss)", aim() == (10, 0))

# -- 6. teammate never picked (team mode)
lua("""
  LP.Team = redTeam; LP.Neutral = false
  foe.Team = redTeam
""")
lua("throw(myRemote, 10, 0)")
check("teammate -> untouched", aim() == (10, 0))
lua("foe.Team = blueTeam")
lua("pushRand(0.10); pushRand(0.10)")
lua("throw(myRemote, 10, 0)")
fx = rt.eval("fired[6]")
check("enemy team -> landed", (fx["X"], fx["Z"]) == (18, 0))
lua("LP.Team = nil; LP.Neutral = true; foe.Team = nil")

# -- 7. dead / forcefield skipped
lua("foe.Character:FindFirstChildOfClass('Humanoid').Health = 0")
lua("throw(myRemote, 10, 0)")
check("dead enemy -> untouched", aim() == (10, 0))
lua("foe.Character = makeChar(18, 0, { forcefield = true })")
lua("throw(myRemote, 10, 0)")
check("spawn-protected -> untouched", aim() == (10, 0))
lua("foe.Character = makeChar(18, 0, {})")

# -- 8. head-only character (no torso) still works
lua("foe.Character = makeChar(18, 0, { noTorso = true })")
lua("pushRand(0.10)")                   # land roll for throw 3? cycle: last counted was throw 1 (6)
lua("pushRand(0.10)")
lua("throw(myRemote, 10, 0)")
fx = rt.eval("fired[6]")
check("no torso -> head used", fx["Y"] == 5)
lua("foe.Character = makeChar(18, 0, {})")

# -- 9. someone else's Blade remote -> untouched
lua("""
  foeBlade = newInst('Tool', 'Blade', foe.Character)
  foeRemote = newInst('RemoteEvent', 'RemoteEvent', foeBlade)
""")
lua("throw(foeRemote, 10, 0)")
check("other player's Blade -> untouched", aim() == (10, 0))

# -- 10. non-release namecall passes straight through
lua("_G.ncm = 'FireServer'; _G.fired = nil")
lua("hookFn(myRemote, 'equip', 1)")
check("non-release untouched", rt.eval("fired[1]") == "equip")

# -- 11. toggle off -> inert
lua("featDef.onToggle(false)")
lua("throw(myRemote, 10, 0)")
check("toggle off -> untouched", aim() == (10, 0))

failed = [n for n, ok in checks if not ok]
print(f"\n{len(checks) - len(failed)}/{len(checks)} checks passed")
if failed:
    raise SystemExit("FAILED: " + ", ".join(failed))
