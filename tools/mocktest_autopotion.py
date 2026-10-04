import os
import lupa

SRC = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "src"))

def read_file(rel):
    with open(os.path.join(SRC, *rel.split(".")) + ".lua", "r", encoding="utf-8") as f:
        return f.read()

rt = lupa.LuaRuntime(unpack_returned_tuples=True)
rt.globals().python_read_file = read_file
print("Lua:", rt.eval("_VERSION"))

# Drives the REAL games.veil_autopotion against a fake world:
#   * sanity under the slider -> equips the Sanity Potion, clicks, re-equips your weapon
#   * sip gap (no chugging), no potion -> one warn toast, blocked (ragdoll) -> no drink
#   * Nightcall: toggle-on drinks immediately, re-drinks when the 150 s clock runs out,
#     a manual drink (Backpack count drop) restarts the clock, out-of-stock warns once
LUA = r"""
table.clear = table.clear or function(t) for k in pairs(t) do t[k] = nil end end

local clock = 1000
os.clock = function() return clock end
_G.advance = function(dt) clock = clock + dt end

Enum = { UserInputType = { MouseButton1 = "MB1" } }

task = {
  spawn = function(fn) local co = coroutine.create(fn); assert(coroutine.resume(co)) end,
  wait  = function(dt) clock = clock + (dt or 0) end,   -- synchronous in the mock
}

local function signal()
  local s = { _fns = {} }
  function s:Connect(fn)
    local rec = { fn = fn, alive = true }
    self._fns[#self._fns + 1] = rec
    return { Disconnect = function() rec.alive = false end }
  end
  function s:Fire(...) for _, r in ipairs(self._fns) do if r.alive then r.fn(...) end end end
  return s
end

-- instances -------------------------------------------------------------------
local INST = {}
INST.__index = INST
function INST:IsA(c)
  if c == "ValueBase" then return self.ClassName == "NumberValue" end
  return self.ClassName == c
end
function INST:FindFirstChild(n)
  for _, ch in ipairs(self._list) do if ch.Name == n then return ch end end
end
function INST:FindFirstChildOfClass(c)
  for _, ch in ipairs(self._list) do if ch.ClassName == c then return ch end end
end
function INST:GetChildren()
  local t = {}; for i, ch in ipairs(self._list) do t[i] = ch end; return t
end
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
function INST:GetAttribute() return nil end
function INST:GetFullName() return self.Name end
local function new(cls, name, parent)
  local o = setmetatable({ ClassName = cls, Name = name or cls, _list = {} }, INST)
  if parent then o.Parent = parent; parent._list[#parent._list + 1] = o end
  return o
end
local function unparent(o)
  local p = o.Parent
  if not p then return end
  for i, ch in ipairs(p._list) do if ch == o then table.remove(p._list, i); break end end
  o.Parent = nil
end
_G.newInst, _G.unparent = new, unparent

-- world -----------------------------------------------------------------------
local char = new("Model", "Me")
local hum  = new("Humanoid", "Humanoid", char)
_G.sanity = new("NumberValue", "Sanity", char)
_G.sanity.Value = 100
_G.sword = new("Tool", "Scourge Of Disease")
sword.Parent = char; char._list[#char._list+1] = sword   -- equipped weapon

_G.equips = {}
function hum:EquipTool(tool)
  unparent(tool)
  tool.Parent = char; char._list[#char._list+1] = tool
  _G.equips[#_G.equips + 1] = tool.Name
end
function hum:UnequipTools() end

local Backpack = new("Backpack", "Backpack")
function _G.addPotion(name)
  local t = new("Tool", name, Backpack)
  new("BoolValue2", "IsPotion", t)   -- child named IsPotion (class irrelevant)
  return t
end

local LocalPlayer = { Name = "Me", Character = char }
function LocalPlayer:FindFirstChild(n) if n == "Backpack" then return Backpack end end
function LocalPlayer:GetAttribute() return nil end
_G.LocalPlayer = LocalPlayer

local heartbeat = signal()
_G.heartbeat = heartbeat
_G.clicks = 0
local UIS = {}
function UIS:GetMouseLocation() return { X = 1, Y = 1 } end
function UIS:IsMouseButtonPressed() return false end
local VIM = {}
function VIM:SendMouseButtonEvent(x, y, b, down)
  if not down then return end
  _G.clicks = _G.clicks + 1
  -- the game consumes a used potion: the equipped potion Tool vanishes on the click
  for _, t in ipairs(char:GetChildren()) do
    if t.ClassName == "Tool" and t:FindFirstChild("IsPotion") then unparent(t); break end
  end
end

game = {}
function game:GetService(n)
  if n == "Players" then return { LocalPlayer = LocalPlayer } end
  if n == "UserInputService" then return UIS end
  if n == "VirtualInputManager" then return VIM end
  if n == "RunService" then return { Heartbeat = heartbeat } end
  error("no service " .. n)
end

_G.m1stub = { blocked = false }
_G.toasts = {}
local MODS = {
  ["core.log"] = { info = function() end, warn = function() end },
  ["ui.notify"] = {
    info = function(t) end,
    warn = function(t) _G.toasts[#_G.toasts + 1] = t end,
  },
  ["games.veil_m1"] = {
    noteFake = function() end,
    isBlocked = function() return _G.m1stub.blocked end,
  },
}
function require(name)
  if MODS[name] then return MODS[name] end
  local chunk = assert(load(python_read_file(name), "@" .. name))
  MODS[name] = chunk()
  return MODS[name]
end

AP = require("games.veil_autopotion")
feat = AP.feature()
setCfg = {}
for _, s in ipairs(feat.settings) do setCfg[s.key] = s.onChange end
"""
rt.execute(LUA)

checks = []
def check(name, cond):
    checks.append((name, bool(cond)))
    print(("PASS " if cond else "FAIL ") + name)

lua = rt.execute

def step(n=1, dt=0.3):
    for _ in range(n):
        lua(f"advance({dt}); heartbeat:Fire()")

g = rt.globals()
equips = lambda: list(rt.eval("equips").values())
toasts = lambda: list(rt.eval("toasts").values())

# defaults: sanity watcher on at 30, nightcall off
lua("feat.onToggle(true)")

# -- 1. healthy sanity: nothing happens
lua("addPotion('Sanity Potion'); addPotion('Sanity Potion')")
step(2)
check("sanity fine -> no drink", equips() == [] and g.clicks == 0)

# -- 2. sanity drops under 30 -> drink: potion equipped, click, weapon back
lua("sanity.Value = 18")
step()
check("low sanity -> potion equipped then weapon back", equips() == ["Sanity Potion", "Scourge Of Disease"])
check("one click sent", g.clicks == 1)

# -- 3. still low straight after -> sip gap holds
lua("sanity.Value = 12")
step(2)
check("sip gap -> no second drink yet", g.clicks == 1)
step(dt=5)  # past SIP_GAP
step()
check("gap over + still low -> second drink", g.clicks == 2)

# -- 4. out of potions -> warn once, no drink (the two drinks consumed both)
lua("sanity.Value = 5")
step(dt=6); step()
check("no potion -> warned", len(toasts()) == 1 and "no Sanity Potions" in toasts()[0])
step(3)
check("warn only once, no drink", len(toasts()) == 1 and g.clicks == 2)

# -- 5. ragdolled -> no drink even with a potion and low sanity
lua("addPotion('Sanity Potion'); m1stub.blocked = true")
step(dt=6); step()
check("blocked -> no drink", g.clicks == 2)
lua("m1stub.blocked = false")
step(dt=6); step()
check("unblocked -> drinks", g.clicks == 3)

# -- 6. Nightcall: toggling on drinks immediately, then re-drinks at ~150 s
lua("sanity.Value = 100")
lua("for i = 1, 4 do addPotion('Nightcall Potion') end")
clicks0 = g.clicks
lua("setCfg.nightcall(true)")
step(dt=5); step()
check("nightcall on -> first drink", g.clicks == clicks0 + 1)
step(dt=100); step()
check("mid-effect -> no re-drink", g.clicks == clicks0 + 1)
step(dt=50); step()   # past 150 - REDRINK_EARLY
check("effect over -> re-drink", g.clicks == clicks0 + 2)

# -- 7. manual drink restarts the clock
step(dt=100); step()  # 100 s into our second drink
lua("""
  local bag = LocalPlayer:FindFirstChild('Backpack')
  for _, t in ipairs(bag:GetChildren()) do
    if t.Name == 'Nightcall Potion' then unparent(t); break end
  end
""")
step()                # count drop seen -> clock restarts
step(dt=60); step()   # 150-ish would be up on the OLD clock; new clock says no
check("manual drink restarted the clock", g.clicks == clicks0 + 2)
step(dt=95); step()   # new clock expires
check("new clock expiry -> re-drink", g.clicks == clicks0 + 3)

# -- 8. out of Nightcall -> warn once
lua("""
  local bag = LocalPlayer:FindFirstChild('Backpack')
  for i = #bag._list, 1, -1 do
    if bag._list[i].Name == 'Nightcall Potion' then unparent(bag._list[i]) end
  end
""")
step(dt=160); step(2)
check("no Nightcall left -> warned", any("Nightcall" in t for t in toasts()))

# -- 9. toggle off: nothing more
clicks1 = g.clicks
lua("addPotion('Sanity Potion'); sanity.Value = 3")
lua("feat.onToggle(false)")
step(dt=10); step(3)
check("feature off -> no drink", g.clicks == clicks1)

failed = [n for n, ok in checks if not ok]
print(f"\n{len(checks) - len(failed)}/{len(checks)} checks passed")
if failed:
    raise SystemExit("FAILED: " + ", ".join(failed))
