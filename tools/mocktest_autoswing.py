import os
import lupa

SRC = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "src"))

def read_file(rel):
    with open(os.path.join(SRC, *rel.split(".")) + ".lua", "r", encoding="utf-8") as f:
        return f.read()

rt = lupa.LuaRuntime(unpack_returned_tuples=True)
rt.globals().python_read_file = read_file
print("Lua:", rt.eval("_VERSION"))

# Drives the REAL games.veil_autoswing against a tiny fake world:
#   * presses (and keeps) M1 while a living mob is in range, releases when it leaves
#   * mobs OUTSIDE workspace.Monsters count once they move (Ancient Bones report 10-04);
#     idle outsiders (townsfolk) never trigger
#   * front-only gate, Runner/Explorer/summon-container/nested-summon/dead-mob skips
#   * keeps swinging after alt-tab (tabbed-out farming report 10-04)
#   * backs off for Auto Weave's jump guard and ragdoll/stun; the user's hold wins
#   * textbox drops the hold; stop() releases; PvP toggle
LUA = r"""
table.clear = table.clear or function(t) for k in pairs(t) do t[k] = nil end end

local clock = 100
os.clock = function() return clock end
_G.tick = function(dt) clock = clock + (dt or 1.1) end

Enum = { UserInputType = { MouseButton1 = "MB1", MouseButton2 = "MB2" } }

-- signals -------------------------------------------------------------------
local function signal()
  local s = { _fns = {} }
  function s:Connect(fn)
    local rec = { fn = fn, alive = true }
    self._fns[#self._fns + 1] = rec
    return { Disconnect = function() rec.alive = false end }
  end
  function s:Fire(...)
    for _, r in ipairs(self._fns) do if r.alive then r.fn(...) end end
  end
  return s
end

-- world ---------------------------------------------------------------------
local function V(x, y, z)
  return setmetatable({ X = x, Y = y, Z = z }, { __index = function(t, k)
    if k == "Magnitude" then return math.sqrt(t.X * t.X + t.Y * t.Y + t.Z * t.Z) end
  end, __sub = function(a, b) return V(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end })
end
_G.V = V

local INST = {}
INST.__index = INST
function INST:IsA(c)
  if c == "ValueBase" then return self.ClassName == "StringValue" end
  return self.ClassName == c
end
function INST:FindFirstChild(n)
  for _, ch in ipairs(self._list) do if ch.Name == n then return ch end end
end
function INST:FindFirstChildOfClass(c)
  for _, ch in ipairs(self._list) do if ch.ClassName == c then return ch end end
end
function INST:GetChildren()
  local t = {}
  for i, ch in ipairs(self._list) do t[i] = ch end
  return t
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
local function new(cls, name, parent)
  local o = setmetatable({ ClassName = cls, Name = name or cls, _list = {} }, INST)
  if parent then o.Parent = parent; parent._list[#parent._list + 1] = o end
  return o
end
_G.newInst = new

local Workspace = new("Workspace", "Workspace")
local Monsters  = new("Folder", "Monsters", Workspace)
_G.Workspace, _G.Monsters = Workspace, Monsters

function _G.mob(name, x, z, hp, parent)
  local m = new("Model", name, parent or Monsters)
  local root = new("Part", "HumanoidRootPart", m)
  root.Position = V(x, 0, z)
  root.AssemblyLinearVelocity = V(0, 0, 0)
  root.CFrame = { LookVector = V(0, 0, 1) }
  local hum = new("Humanoid", "Humanoid", m)
  hum.Health = hp or 100
  m._root, m._hum = root, hum
  return m
end

-- services ------------------------------------------------------------------
local mouseDown = false
_G.sent = {}            -- every VIM event, in order: true=down false=up
local inputBegan, inputEnded = signal(), signal()
local focusLost = signal()
local heartbeat = signal()
_G.heartbeat = heartbeat

local UIS = {
  InputBegan = inputBegan, InputEnded = inputEnded,
  WindowFocusReleased = focusLost, WindowFocused = signal(),
  _textbox = nil,
}
function UIS:GetMouseLocation() return { X = 400, Y = 300 } end
function UIS:IsMouseButtonPressed(bt) return mouseDown end
function UIS:GetFocusedTextBox() return self._textbox end
_G.UIS = UIS

local VIM = {}
function VIM:SendMouseButtonEvent(x, y, btn, down, target, repeats)
  _G.sent[#_G.sent + 1] = down
  mouseDown = down
  -- the real pipeline echoes injected events back as input events
  if down then inputBegan:Fire({ UserInputType = Enum.UserInputType.MouseButton1 })
  else inputEnded:Fire({ UserInputType = Enum.UserInputType.MouseButton1 }) end
end

-- the USER physically pressing/releasing
function _G.userPress()
  mouseDown = true
  inputBegan:Fire({ UserInputType = Enum.UserInputType.MouseButton1 })
end
function _G.userRelease()
  mouseDown = false
  inputEnded:Fire({ UserInputType = Enum.UserInputType.MouseButton1 })
end

local myChar = new("Model", "Me")
local myRoot = new("Part", "HumanoidRootPart", myChar)
myRoot.Position = V(0, 0, 0)
myRoot.CFrame = { LookVector = V(0, 0, 1) }   -- facing +Z
_G.myChar = myChar

local LocalPlayer = { Name = "Me", Character = myChar }
local otherPlayers = {}
_G.otherPlayers = otherPlayers
local Players = { LocalPlayer = LocalPlayer }
function Players:GetPlayers()
  local t = { LocalPlayer }
  for _, p in ipairs(otherPlayers) do t[#t + 1] = p end
  return t
end
function Players:GetPlayerFromCharacter(model)
  if model == myChar then return LocalPlayer end
  for _, p in ipairs(otherPlayers) do if p.Character == model then return p end end
end

local RunService = { Heartbeat = heartbeat }

game = { PlaceId = 1, GameId = 1 }
function game:GetService(n)
  if n == "Players" then return Players end
  if n == "UserInputService" then return UIS end
  if n == "VirtualInputManager" then return VIM end
  if n == "RunService" then return RunService end
  if n == "Workspace" then return Workspace end
  error("no service " .. n)
end

-- module stubs ---------------------------------------------------------------
_G.m1stub = { blocked = false, fakes = 0 }
_G.weavestub = { guarded = false }
local MODS = {
  ["core.log"] = { info = function() end, warn = function() end },
  ["games.veil_m1"] = {
    noteFake = function(d) _G.m1stub.fakes = _G.m1stub.fakes + 1 end,
    isBlocked = function() return _G.m1stub.blocked end,
  },
  ["games.veil_weave"] = { m1Guarded = function() return _G.weavestub.guarded end },
  ["modules.aim.state"] = { isFriendly = function(p) return p._friendly == true end },
}
function require(name)
  if MODS[name] then return MODS[name] end
  local chunk = assert(load(python_read_file(name), "@" .. name))
  MODS[name] = chunk()
  return MODS[name]
end

AS = require("games.veil_autoswing")
feat = AS.feature()
"""
rt.execute(LUA)

g = rt.globals()
checks = []
def check(name, cond):
    checks.append((name, bool(cond)))
    print(("PASS " if cond else "FAIL ") + name)

lua = rt.execute

def step(n=1, dt=1.1):          # 1.1 s beats both the 0.1 eval throttle and the 1 s mob cache
    for _ in range(n):
        lua(f"tick({dt}); heartbeat:Fire()")

def sent():
    return list(rt.eval("sent").values())

def clear_sent():
    lua("for i = #sent, 1, -1 do sent[i] = nil end")

# -- 1. no enemies: toggle on, nothing happens
lua("feat.onToggle(true)")
step(2)
check("no enemy -> no press", sent() == [])

# -- 2. living Monsters mob in front at 5 studs -> press and hold
lua("wolf = mob('Wolf', 0, 5)")
step(2)
check("Monsters mob in range -> one press, held", sent() == [True])
check("noteFake announced to M1 Continuation", g.m1stub.fakes == 1)

# -- 3. mob walks out of range -> release
lua("wolf._root.Position = V(0, 0, 50)")
step(2)
check("enemy left -> released", sent() == [True, False])

# -- 4. mob OUTSIDE Monsters (Ancient Bones report): idle = ignored, moving = enemy
clear_sent()
lua("bones = mob('Ancient Bones', 0, 6, 100, Workspace)")
step(2)
check("outside Monsters + never moved -> ignored", sent() == [])
lua("bones._root.AssemblyLinearVelocity = V(0, 0, 8)")
step(2)
check("outside Monsters + moving -> press", sent() == [True])
lua("bones._root.Position = V(0, 0, 80); bones._root.AssemblyLinearVelocity = V(0,0,0)")
step(2)
check("moved-once mob stays an enemy (release = out of range only)", sent() == [True, False])

# -- 5. keeps swinging while tabbed out (report 10-04)
clear_sent()
lua("wolf._root.Position = V(0, 0, 5)")
step()
check("held again", sent() == [True])
lua("UIS.WindowFocusReleased:Fire()")
step(2)
check("alt-tab -> hold kept, no release", sent() == [True])

# -- 6. behind + frontOnly on -> ignored; frontOnly off -> press
lua("wolf._root.Position = V(0, 0, 50)")
step()
clear_sent()
lua("wolf._root.Position = V(0, 0, -5)")
step(2)
check("behind + front-only -> no press", sent() == [])
lua("feat.settings[2].onChange(false)")   # Only enemies in front = off
step(2)
check("front-only off -> press", sent() == [True])
lua("feat.settings[2].onChange(true); wolf._root.Position = V(0, 0, 50)")
step()

# -- 7. skips: Runner, Explorer, summon container, nested summon, dead mob
clear_sent()
lua("""
  mob('Runner', 0, 4); mob('Explorer', 0, 4); mob('12345678', 0, 3)
  mob('Imp', 0, 4, 0)                                        -- dead
  local box = newInst('Model', '555666777', Monsters)        -- digits container
  mob('Tortor', 0, 3, 100, box)                              -- nested summon
""")
step(2)
check("Runner/Explorer/summons/nested/dead all skipped", sent() == [])

# -- 8. weave jump guard: no press while guarded; resync after guard's own release
lua("weavestub.guarded = true; wolf._root.Position = V(0, 0, 5)")
step(2)
check("guarded -> no press", sent() == [])
lua("weavestub.guarded = false")
step()
check("guard over -> press", sent() == [True])

# -- 9. ragdoll/stun (m1.isBlocked) -> release, back after
clear_sent()
lua("m1stub.blocked = true")
step()
check("blocked -> released", sent() == [False])
lua("m1stub.blocked = false")
step()
check("unblocked -> press again", sent() == [False, True])

# -- 10. user's real hold wins: no injected events while their finger is down
lua("wolf._root.Position = V(0, 0, 50)")
step()
clear_sent()
lua("userPress()")
lua("wolf._root.Position = V(0, 0, 5)")
step(2)
check("user holding -> nothing injected", sent() == [])
lua("userRelease()")
step()
check("user let go, enemy still there -> we take over", sent() == [True])

# -- 11. textbox focus drops the hold
clear_sent()
lua("UIS._textbox = {}")
step()
check("textbox -> released", sent() == [False])
lua("UIS._textbox = nil")
step()

# -- 12. PvP toggle: enemy player only counts when on
lua("wolf._root.Position = V(0, 0, 50)")
step()
clear_sent()
lua("""
  foe = { Name = 'Foe', _friendly = false }
  foe.Character = newInst('Model', 'FoeChar')
  local r = newInst('Part', 'HumanoidRootPart', foe.Character)
  r.Position = V(0, 0, 6); r.CFrame = { LookVector = V(0, 0, 1) }
  r.AssemblyLinearVelocity = V(0, 0, 0)
  local h = newInst('Humanoid', 'Humanoid', foe.Character); h.Health = 100
  otherPlayers[1] = foe
""")
step(2)
check("player + PvP off -> ignored", sent() == [])
lua("feat.settings[3].onChange(true)")
step()
check("player + PvP on -> press", sent() == [True])
lua("foe._friendly = true")
lua("tick(6)")  # outlive caches
step()
check("Pantheon friend -> released", sent() == [True, False])

# -- 13. toggle off releases and stops
clear_sent()
lua("foe._friendly = false; tick(6)")
step()
check("hostile again -> held", sent() == [True])
lua("feat.onToggle(false)")
check("toggle off -> released", sent() == [True, False])
step(2)
check("off -> no more presses", sent() == [True, False])

failed = [n for n, ok in checks if not ok]
print(f"\n{len(checks) - len(failed)}/{len(checks)} checks passed")
if failed:
    raise SystemExit("FAILED: " + ", ".join(failed))
