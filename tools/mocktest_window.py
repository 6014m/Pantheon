import os
import lupa

SRC = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "src"))

def read_file(rel):
    with open(os.path.join(SRC, *rel.split(".")) + ".lua", "r", encoding="utf-8") as f:
        return f.read()

rt = lupa.LuaRuntime(unpack_returned_tuples=True)
rt.globals().python_read_file = read_file
print("Lua:", rt.eval("_VERSION"))

# Drives REAL ui/window: simulate the open/close TOGGLE happening DURING the
# staggered slide (task.delay queued, not run; TweenService stubbed) -- the exact
# case that corrupted "home" and made panels reopen overlapping. The settle step
# must snap mid-stagger containers to their target so home is captured correctly.
LUA = r"""
local real = { math=math, string=string, table=table, os=os, pcall=pcall, ipairs=ipairs,
  pairs=pairs, tostring=tostring, type=type, setmetatable=setmetatable, rawset=rawset, assert=assert, print=print }

local Enum = real.setmetatable({}, { __index=function(t,c)
  local cat=real.setmetatable({_name=c}, { __index=function(cc,m)
    local it={_isEnumItem=true,_cat=cc._name,_name=m}; real.rawset(cc,m,it); return it end })
  real.rawset(t,c,cat); return cat end })
local function U(xs,xo,ys,yo) return {X={Scale=xs or 0,Offset=xo or 0},Y={Scale=ys or 0,Offset=yo or 0}} end
local UDim2 = { new=function(a,b,c,d) return U(a,b,c,d) end, fromOffset=function(a,b) return U(0,a,0,b) end, fromScale=function(a,b) return U(a,0,b,0) end }
local UDim  = { new=function(s,o) return {Scale=s or 0,Offset=o or 0} end }
local Color3= { new=function() return {} end, fromRGB=function() return {} end }
local Vector2= { new=function(x,y) return {X=x or 0,Y=y or 0} end }
local function newEvent() local h={}; local e={}; function e:Connect(fn) h[#h+1]=fn; return {Disconnect=function() end} end
  function e:Fire(...) for _,fn in real.ipairs(h) do fn(...) end end return e end
local EVT={MouseButton1Click=true,InputBegan=true,InputChanged=true,InputEnded=true,WindowFocusReleased=true,Changed=true}
local MT
local function newInst(cls) return real.setmetatable({_inst=true,ClassName=cls,Name=cls,_ch={},_p={},_e={}}, MT) end
local function setParent(s,p) s._p.Parent=p; if p then p._ch[#p._ch+1]=s end end
local METH={}
function METH:GetChildren() local t={} for i,c in real.ipairs(self._ch) do t[i]=c end return t end
function METH:IsA() return true end
function METH:Destroy() self._destroyed=true end
MT={ __index=function(s,k)
    if k=="Parent" then return s._p.Parent end
    if EVT[k] then s._e[k]=s._e[k] or newEvent(); return s._e[k] end
    if METH[k] then return METH[k] end
    if s._p[k]~=nil then return s._p[k] end
    return nil end,
  __newindex=function(s,k,v) if k=="Parent" then setParent(s,v) else s._p[k]=v end end }
local Instance={ new=function(cls,parent) local o=newInst(cls); if parent then setParent(o,parent) end; return o end }

local SERVICES={}
local function svc(n) SERVICES[n]=SERVICES[n] or newInst(n); return SERVICES[n] end
local Workspace=svc("Workspace"); Workspace.CurrentCamera=newInst("Camera")
local game=newInst("DataModel"); game.PlaceId=1; game.GameId=1
function game:GetService(n) if n=="Workspace" then return Workspace end return svc(n) end

-- task.delay QUEUES (doesn't run) so we can hold the animation mid-stagger.
local QUEUE={}
local task={ delay=function(_,fn) QUEUE[#QUEUE+1]=fn end, spawn=function(fn) real.pcall(fn) end, wait=function() return 0 end }
-- TweenService stub: Play() applies props instantly + fires Completed; Cancel() no-op.
local TweenInfo={ new=function() return {} end }
local TweenService={}
function TweenService:Create(obj, info, props)
    local ev=newEvent()
    return { Play=function() for k,v in real.pairs(props) do obj[k]=v end; ev:Fire(Enum.PlaybackState.Completed) end,
             Cancel=function() end, Completed=ev }
end

local cache={}
local ENV
local theme={ slideSoundId="", slideVolume=0.5, fg={}, accent={}, headerBand={}, bgDark={}, font=Enum.Font.A,
  fontBold=Enum.Font.B, logoStroke={}, logoStrokeThickness=1.5, gridSize=48 }
local persistCache={}
local persist={ get=function(k,d) local v=persistCache[k]; if v==nil then return d end return v end,
  set=function(k,v) persistCache[k]=v end, clearPrefix=function() end, flush=function() end }
local function stub(name)
  if name=="core.env" then return { guiParent=function() return newInst("Folder") end, protectGui=function() end, getcustomasset=nil, request=nil, HttpGet=function() return "" end } end
  if name=="ui.theme" then return theme end
  if name=="ui.hex" then return { build=function() return {} end, setColor=function() end } end
  if name=="core.keybinds" then return { set=function() end, clear=function() end } end
  if name=="ui.container" then return { cleanup=function() end } end
  if name=="core.persist" then return persist end
  return real.setmetatable({}, {__index=function() return function() end end})
end
local function myrequire(name)
  if cache[name]~=nil then return cache[name] end
  if name=="ui.window" then local chunk=real.assert(load(python_read_file(name), "@"..name, "t", ENV)); local m=chunk(); cache[name]=m; return m end
  local s=stub(name); cache[name]=s; return s
end
local mathShim=real.setmetatable({ clamp=function(x,lo,hi) if x<lo then return lo elseif x>hi then return hi else return x end end }, { __index=real.math })
ENV=real.setmetatable({ Instance=Instance, Enum=Enum, UDim2=UDim2, UDim=UDim, Color3=Color3, Vector2=Vector2, game=game, workspace=Workspace,
  task=task, require=myrequire, math=mathShim, warn=function() end, print=real.print, tick=os.clock,
  TweenInfo=TweenInfo, TweenService=TweenService }, { __index=_G })
-- window does `game:GetService("TweenService")` -> return our stub
SERVICES.TweenService=TweenService

local out={}
local window=myrequire("ui.window")
window.init()
local host=window.parent()
local function mkC(x) local f=Instance.new("Frame"); f.Visible=true; f.Position=UDim2.fromOffset(x,52); f.Parent=host; return f end
local A,B,C = mkC(100), mkC(340), mkC(580)
local function runQueue() local q=QUEUE; QUEUE={}; for _,fn in real.ipairs(q) do real.pcall(fn) end end
local function px(f) return f._p.Position and f._p.Position.X.Offset or nil end

-- establish home, then fully hide
window.setVisible(false); runQueue()
out.hidden_off = (px(A) ~= nil and px(A) < -100)

-- show (queued, mid-stagger) ... then HIDE during the stagger ... then show again
window.setVisible(true)       -- queued (not run) -> A/B/C pre-positioned off-screen, animating
window.setVisible(false)      -- THE BUG TRIGGER: settle must snap them back to home before capturing
window.setVisible(true)
runQueue()

out.ax, out.bx, out.cx = px(A), px(B), px(C)
out.no_corrupt = (px(A)==100 and px(B)==340 and px(C)==580)

local pass = out.hidden_off and out.no_corrupt
local lines={}
for k,v in real.pairs(out) do lines[#lines+1]="  "..k.." = "..real.tostring(v) end
real.table.sort(lines)
return real.table.concat(lines,"\n").."\n\nRESULT: "..(pass and "ALL PASS" or "FAIL")
"""
print(rt.execute(LUA))
