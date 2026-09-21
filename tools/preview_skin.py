"""Render the real UI tree to a PNG, so a skin can be judged without a reload.

The mocktests prove the tree BUILDS. They say nothing about whether it looks
like anything, and a skin is entirely about how it looks -- which cost two
rounds of "push, reload, screenshot, wrong" before this existed.

So: build the actual ui/* tree under the mock Roblox (same approach as
mocktest_skin.py), walk it through a small layout pass -- UIListLayout,
UIPadding, AutomaticSize, AnchorPoint, Scale+Offset -- and draw it with PIL,
honouring UICorner, UIGradient, UIStroke, ZIndex and transparency.

It is an approximation, not an emulator. What it is faithful about is the part
that matters here: values, edges and geometry, i.e. whether a control reads as
sunk into a plate or as a card floating on a void.

    python tools/preview_skin.py            -> scratch/preview_<skin>.png
    python tools/preview_skin.py hardware   -> just that one

Output is upscaled 3x with nearest-neighbour, because the whole skin is 1px
lips and 2px cuts and none of that is judgeable at 1:1.
"""
import os
import sys
import lupa
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.abspath(os.path.join(HERE, "..", "src"))
OUT = os.path.abspath(os.path.join(HERE, "..", "scratch"))
ASSETS = os.path.abspath(os.path.join(HERE, "..", "assets"))
SCALE = 3

# Roblox asset ids mapped back to the source art in assets/, so a tiled overlay
# renders as the real weave. Without this the preview silently dropped the
# carbon texture -- and a texture that is invisible here but shouting in game is
# exactly the kind of thing this tool exists to catch.
ASSET_FILES = {
    "rbxassetid://83752823743620": "carbon_fiber.png",
}


def read_file(rel):
    with open(os.path.join(SRC, *rel.split(".")) + ".lua", "r", encoding="utf-8") as f:
        return f.read()


# --------------------------------------------------------------------------
# The mock Roblox. Same shape as mocktest_skin.py's, trimmed to what building a
# container + a few feature rows touches, and with every property recorded so
# the renderer can read it back.
# --------------------------------------------------------------------------

LUA = r"""
local real = { math=math, string=string, table=table, os=os, pcall=pcall, error=error,
  assert=assert, ipairs=ipairs, pairs=pairs, tostring=tostring, tonumber=tonumber,
  type=type, setmetatable=setmetatable, rawget=rawget, rawset=rawset, print=print,
  load=load }

local ERRORS = {}
local function note(w,e) ERRORS[#ERRORS+1]=w..": "..real.tostring(e) end

local EnumCatMT = { __index=function(cat, m)
  local it={_isEnumItem=true,_cat=cat._name,_name=m}
  real.setmetatable(it,{__tostring=function(s) return "Enum."..s._cat.."."..s._name end})
  real.rawset(cat,m,it); return it end }
local Enum = real.setmetatable({}, { __index=function(t,c)
  local cat=real.setmetatable({_name=c}, EnumCatMT); real.rawset(t,c,cat); return cat end })

local U2MT = {}
local function UDim2new(xs,xo,ys,yo)
  return real.setmetatable({_udim2=true,X={Scale=xs or 0,Offset=xo or 0},
                            Y={Scale=ys or 0,Offset=yo or 0}}, U2MT) end
U2MT.__add=function(a,b) return UDim2new(a.X.Scale+b.X.Scale,a.X.Offset+b.X.Offset,
                                         a.Y.Scale+b.Y.Scale,a.Y.Offset+b.Y.Offset) end
U2MT.__sub=function(a,b) return UDim2new(a.X.Scale-b.X.Scale,a.X.Offset-b.X.Offset,
                                         a.Y.Scale-b.Y.Scale,a.Y.Offset-b.Y.Offset) end
local UDim2 = { new=function(a,b,c,d) return UDim2new(a,b,c,d) end,
  fromOffset=function(a,b) return UDim2new(0,a,0,b) end,
  fromScale=function(a,b) return UDim2new(a,0,b,0) end }
local UDim = { new=function(s,o) return {_udim=true,Scale=s or 0,Offset=o or 0} end }

local C3MT = {}
local function C3(r,g,b) return real.setmetatable({_color3=true,R=r or 0,G=g or 0,B=b or 0}, C3MT) end
C3MT.__index = { Lerp=function(s,o,a) return C3(s.R+(o.R-s.R)*a, s.G+(o.G-s.G)*a, s.B+(o.B-s.B)*a) end }
local Color3 = { new=function(r,g,b) return C3(r,g,b) end,
  fromRGB=function(r,g,b) return C3((r or 0)/255,(g or 0)/255,(b or 0)/255) end }

local VMT={}
local function V(x,y,z) return real.setmetatable({_vector=true,X=x or 0,Y=y or 0,Z=z or 0}, VMT) end
VMT.__sub=function(a,b) return V(a.X-b.X,a.Y-b.Y,a.Z-b.Z) end
VMT.__add=function(a,b) return V(a.X+b.X,a.Y+b.Y,a.Z+b.Z) end
VMT.__index=function(t,k) if k=="Magnitude" then return real.math.sqrt(t.X*t.X+t.Y*t.Y+t.Z*t.Z) end end
local Vector2 = { new=function(x,y) return V(x,y,0) end }
local Vector3 = { new=function(x,y,z) return V(x,y,z) end }
local Rect = { new=function(a,b,c,d) return {_rect=true,a,b,c,d} end }
local ColorSequenceKeypoint = { new=function(t,c) return {_csk=true,Time=t,Value=c} end }
local ColorSequence = { new=function(a,b)
  if real.type(a)=="table" and a._csk==nil and a[1]~=nil then return {_cs=true,stops=a} end
  return {_cs=true,stops={{_csk=true,Time=0,Value=a},{_csk=true,Time=1,Value=b or a}}} end }
local NumberSequenceKeypoint = { new=function(t,v) return {_nsk=true,Time=t,Value=v} end }
local NumberSequence = { new=function(a,b)
  if real.type(a)=="table" then return {_ns=true,stops=a} end
  return {_ns=true,stops={{_nsk=true,Time=0,Value=a},{_nsk=true,Time=1,Value=b or a}}} end }

local function newEvent(name)
  local h={}
  local ev={_event=true}
  function ev:Connect(fn) h[#h+1]=fn; return {Disconnect=function() end} end
  function ev:Fire(...) for _,fn in real.ipairs(h) do local ok,e=real.pcall(fn,...)
    if not ok then note("event",e) end end end
  return ev
end
local EVENTS={MouseButton1Click=true,MouseButton1Down=true,MouseButton1Up=true,
  MouseEnter=true,MouseLeave=true,InputBegan=true,InputChanged=true,InputEnded=true,
  FocusLost=true,Changed=true}
local VEC={AbsoluteSize=true,AbsolutePosition=true,AbsoluteContentSize=true}
local DEFAULTS={ZIndex=1,Visible=true,BorderSizePixel=1,BackgroundTransparency=0,
  TextTransparency=0,Rotation=0,LayoutOrder=0,TextSize=12,Text=""}

local ALL={}
local MT
local function newInstance(cls)
  -- Seed the property defaults rather than serving them from the metatable:
  -- the Python renderer walks _props directly, so anything only the metatable
  -- knows about would come back nil there.
  local o=real.setmetatable({_isInstance=true,ClassName=cls,Name=cls,_children={},
    _props={ Position=UDim2new(0,0,0,0), Size=UDim2new(0,0,0,0), ZIndex=1,
             Visible=true, BackgroundTransparency=0, TextTransparency=0,
             LayoutOrder=0, TextSize=12, Text="" },
    _events={},_changed={}}, MT)
  ALL[#ALL+1]=o; return o
end
local function setParent(self,parent)
  local old=self._props.Parent
  if old then for i,c in real.ipairs(old._children) do if c==self then real.table.remove(old._children,i) break end end end
  self._props.Parent=parent
  if parent then parent._children[#parent._children+1]=self end
end
local M={}
function M:GetChildren() local t={} for i,c in real.ipairs(self._children) do t[i]=c end return t end
function M:FindFirstChildOfClass(cl) for _,c in real.ipairs(self._children) do if c.ClassName==cl then return c end end end
function M:IsA(cl) return self.ClassName==cl or cl=="GuiObject" or cl=="Instance" end
function M:Destroy() setParent(self,nil); self._destroyed=true end
function M:GetPropertyChangedSignal(p) self._changed[p]=self._changed[p] or newEvent(p); return self._changed[p] end
function M:Clone()
  local o=newInstance(self.ClassName); o.Name=self.Name
  for k,v in real.pairs(self._props) do if k~="Parent" then o._props[k]=v end end
  for _,c in real.ipairs(self._children) do setParent(c:Clone(), o) end
  return o
end
MT={ __index=function(s,k)
    if k=="Parent" then return s._props.Parent end
    if EVENTS[k] then s._events[k]=s._events[k] or newEvent(k); return s._events[k] end
    if M[k] then return M[k] end
    if s._props[k]~=nil then return s._props[k] end
    if VEC[k] then return V(0,0,0) end
    if k=="Position" or k=="Size" then return UDim2new(0,0,0,0) end
    if DEFAULTS[k]~=nil then return DEFAULTS[k] end
    return nil end,
  __newindex=function(s,k,v)
    if k=="Parent" then setParent(s,v)
    else s._props[k]=v; if s._changed[k] then s._changed[k]:Fire() end end end }
local Instance={ new=function(cls,parent) local o=newInstance(cls); if parent then setParent(o,parent) end; return o end }

local Workspace=newInstance("Workspace")
Workspace.CurrentCamera=newInstance("Camera"); Workspace.CurrentCamera.ViewportSize=V(1600,900,0)
local LocalPlayer=newInstance("Player")
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

local task={ spawn=function(fn,...) real.pcall(fn,...) end, delay=function() end, wait=function(t) return t or 0 end }

local SKIN_CHOICE = SKIN or "Flat"
local REAL={ ["ui.theme"]=true, ["ui.hex"]=true, ["ui.skin"]=true, ["ui.components"]=true,
  ["ui.feature"]=true, ["ui.container"]=true }
local cache, ENV = {}, nil
local function stub(name)
  if name=="core.persist" then return {
    init=function() end, flush=function() end, get=function(_,d) return d end,
    set=function() end, clearPrefix=function() end,
    getGlobal=function(k,d) if k=="ui.skin" then return SKIN_CHOICE end return d end,
    setGlobal=function() end,
    slug=function(s) return (real.tostring(s):lower():gsub("[^%w]+","_")) end,
    keyToString=function() end, stringToKey=function() end } end
  if name=="core.log" then return { info=function() end, warn=function() end,
    err=function() end, error=function() end, debug=function() end } end
  if name=="core.keybinds" then return { set=function() end } end
  if name=="ui.notify" then return { success=function() end, warn=function() end } end
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
  Vector2=Vector2, Vector3=Vector3, Rect=Rect, ColorSequence=ColorSequence,
  ColorSequenceKeypoint=ColorSequenceKeypoint, NumberSequence=NumberSequence,
  NumberSequenceKeypoint=NumberSequenceKeypoint, game=game, workspace=workspace,
  math=mathShim, task=task, require=myrequire, warn=function() end, print=real.print,
  tick=real.os.clock, time=real.os.time }, { __index=_G })

-- ---- build a representative panel ----------------------------------------

local components = myrequire("ui.components")
local feature    = myrequire("ui.feature")
local container  = myrequire("ui.container")

local root = newInstance("Frame")
root.Size = UDim2.fromOffset(1600, 900)
root.BackgroundTransparency = 1

-- The navigator first, exactly as init.lua wires it, so the preview shows the
-- menu list (its rows and lamps) next to a feature panel.
local nav = container.buildNavigator(root, "Menu")
local box = container.new(root, "Combat")

local function add(def) box:add(feature.declare(def).root) end
add({ id="a", name="Target Select", description="d", default=true })
add({ id="b", name="Lock-On",       description="d", default=false,
      settings={
        { type="section",  name="Tuning" },
        { type="toggle",   name="Camera Lock", default=true },
        { type="slider",   name="Smoothing", min=0, max=100, step=1, default=45 },
        { type="dropdown", name="Part", options={"Head","Torso"}, default="Head" },
        { type="button",   name="Reset" },
      } })
add({ id="c", name="Swap Target", description="d", default=true })

nav.populate()
box:setVisible(true)

-- Open one settings tray so the preview covers the components too. The cog is
-- the TextButton whose host frame also holds the gear glyph.
local GEAR = real.string.char(0xE2, 0x9A, 0x99)
for _,o in real.ipairs(ALL) do
  if not o._destroyed and o.ClassName=="TextButton" and o.Parent then
    local isCog = false
    for _,sib in real.ipairs(o.Parent._children) do
      if sib.ClassName=="TextLabel" and real.tostring(sib._props.Text)==GEAR then isCog=true end
    end
    -- Only the second feature's, so the preview shows both states.
    local anc, name = o.Parent, nil
    while anc do name = real.tostring(anc.Name); if name=="Feature_b" then break end; anc = anc.Parent end
    if isCog and anc then o._events.MouseButton1Click:Fire() end
  end
end

return {
  root = root,
  errors = #ERRORS,
  mkvec = function(x, y) return V(x, y, 0) end,
  setprop = function(inst, name, value) inst._props[name] = value end,
  fire = function(inst, name) if inst._changed[name] then inst._changed[name]:Fire() end end,
}
"""


# --------------------------------------------------------------------------
# Layout + paint
# --------------------------------------------------------------------------

LAYOUT_CLASSES = {"UIListLayout", "UIPadding", "UICorner", "UIGradient", "UIStroke"}


def prop(inst, name, default=None):
    v = inst["_props"][name]
    return default if v is None else v


def kids(inst):
    out, i = [], 1
    ch = inst["_children"]
    while True:
        c = ch[i]
        if c is None:
            break
        out.append(c)
        i += 1
    return out


def child_of_class(inst, cls):
    for c in kids(inst):
        if c["ClassName"] == cls:
            return c
    return None


def rgb(c, default=(0, 0, 0)):
    if c is None:
        return default
    return (int(c["R"] * 255 + 0.5), int(c["G"] * 255 + 0.5), int(c["B"] * 255 + 0.5))


def udim2(v):
    return (v["X"]["Scale"], v["X"]["Offset"], v["Y"]["Scale"], v["Y"]["Offset"])


def measure(inst, avail_w, avail_h):
    """Absolute size of `inst` given the space its parent offers it."""
    xs, xo, ys, yo = udim2(prop(inst, "Size"))
    w = xs * avail_w + xo
    h = ys * avail_h + yo

    auto = prop(inst, "AutomaticSize")
    layout = child_of_class(inst, "UIListLayout")
    pad = child_of_class(inst, "UIPadding")
    px0, py0, px1, py1 = padding(pad)

    if auto is not None or layout is not None:
        content = 0
        if layout is not None:
            gap = udim_offset(prop(layout, "Padding"))
            items = [c for c in kids(inst) if c["ClassName"] not in LAYOUT_CLASSES
                     and prop(c, "Visible", True)]
            for i, c in enumerate(items):
                _, ch_ = measure(c, max(0, w - px0 - px1), max(0, h - py0 - py1))
                content += ch_ + (gap if i else 0)
        name = str(auto["_name"]) if auto is not None else ""
        if layout is not None and (name in ("Y", "XY") or ys == 0 and yo == 0):
            h = content + py0 + py1
        elif auto is not None and name in ("Y", "XY"):
            # No layout: the content box is the furthest child edge. Children
            # sized or positioned by SCALE are excluded -- they are relative to
            # the very size being computed, and Roblox leaves them out for that
            # reason. It is also what keeps a full-bleed decoration from
            # stretching a panel forever.
            extent = 0
            for c in kids(inst):
                if c["ClassName"] in LAYOUT_CLASSES:
                    continue
                cxs, cxo, cys, cyo = udim2(prop(c, "Size"))
                pxs, pxo, pys, pyo = udim2(prop(c, "Position"))
                if cys or pys:
                    continue
                extent = max(extent, pyo + cyo)
            h = max(h, extent + py0 + py1)
    return w, h


def udim_offset(u):
    return 0 if u is None else u["Offset"]


def padding(pad):
    if pad is None:
        return 0, 0, 0, 0
    return (udim_offset(prop(pad, "PaddingLeft")), udim_offset(prop(pad, "PaddingTop")),
            udim_offset(prop(pad, "PaddingRight")), udim_offset(prop(pad, "PaddingBottom")))


def walk(inst, px, py, pw, ph, out, key=()):
    """Flatten the tree into (sortkey, inst, rect) draw records.

    ZIndexBehavior.Sibling means a child is ordered against its SIBLINGS, and
    its whole subtree travels with it. That is exactly a lexicographic sort on
    the tuple of (ZIndex, sibling index) collected down from the root.
    """
    if not prop(inst, "Visible", True):
        return
    cls = inst["ClassName"]
    if cls in LAYOUT_CLASSES or cls == "Folder":
        return

    w, h = measure(inst, pw, ph)
    xs, xo, ys, yo = udim2(prop(inst, "Position"))
    ax, ay = 0.0, 0.0
    anchor = prop(inst, "AnchorPoint")
    if anchor is not None:
        ax, ay = anchor["X"], anchor["Y"]
    x = px + xs * pw + xo - ax * w
    y = py + ys * ph + yo - ay * h

    out.append((key, inst, (x, y, w, h)))

    pad = child_of_class(inst, "UIPadding")
    px0, py0, px1, py1 = padding(pad)
    cx, cy = x + px0, y + py0
    cw, chh = max(0, w - px0 - px1), max(0, h - py0 - py1)

    layout = child_of_class(inst, "UIListLayout")
    children = [c for c in kids(inst) if c["ClassName"] not in LAYOUT_CLASSES]
    order = {id(c): i for i, c in enumerate(children)}
    if layout is not None:
        gap = udim_offset(prop(layout, "Padding"))
        items = [c for c in children if prop(c, "Visible", True)]
        items.sort(key=lambda c: prop(c, "LayoutOrder", 0))
        content = sum(measure(c, cw, chh)[1] for c in items)
        content += gap * max(0, len(items) - 1)
        MEASURED.append((layout, cw, content))
        cursor = cy
        for c in items:
            _, ch_ = measure(c, cw, chh)
            walk(c, cx, cursor, cw, ch_, out,
                 key + ((prop(c, "ZIndex", 1), order[id(c)]),))
            cursor += ch_ + gap
    else:
        for c in children:
            walk(c, cx, cy, cw, chh, out,
                 key + ((prop(c, "ZIndex", 1), order[id(c)]),))


MEASURED = []      # (instance, width, height) collected during a walk


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t + 0.5) for i in range(3))


def sequence_stops(seq):
    out, i = [], 1
    stops = seq["stops"]
    while True:
        s = stops[i]
        if s is None:
            break
        out.append((s["Time"], s["Value"]))
        i += 1
    return out


def sample_color_seq(seq, t):
    stops = sequence_stops(seq)
    if not stops:
        return (255, 255, 255)
    prev = stops[0]
    for s in stops:
        if s[0] >= t:
            if s[0] == prev[0]:
                return rgb(s[1])
            f = (t - prev[0]) / (s[0] - prev[0])
            return lerp(rgb(prev[1]), rgb(s[1]), f)
        prev = s
    return rgb(stops[-1][1])


def sample_number_seq(seq, t):
    stops = sequence_stops(seq)
    if not stops:
        return 0.0
    prev = stops[0]
    for s in stops:
        if s[0] >= t:
            if s[0] == prev[0]:
                return s[1]
            f = (t - prev[0]) / (s[0] - prev[0])
            return prev[1] + (s[1] - prev[1]) * f
        prev = s
    return stops[-1][1]


def rounded_mask(size, radius):
    m = Image.new("L", size, 0)
    d = ImageDraw.Draw(m)
    if radius > 0:
        d.rounded_rectangle([0, 0, size[0] - 1, size[1] - 1], radius=radius, fill=255)
    else:
        d.rectangle([0, 0, size[0] - 1, size[1] - 1], fill=255)
    return m


def paint(img, records, font, font_bold):
    draw = ImageDraw.Draw(img, "RGBA")
    records.sort(key=lambda r: r[0])
    for _, inst, (x, y, w, h) in records:
        if w < 1 or h < 1:
            continue
        x, y, w, h = int(round(x)), int(round(y)), int(round(w)), int(round(h))
        cls = inst["ClassName"]
        alpha = 1.0 - float(prop(inst, "BackgroundTransparency", 0))

        scale_type = prop(inst, "ScaleType")
        scale_name = str(scale_type["_name"]) if scale_type is not None else ""
        if cls == "ImageLabel" and prop(inst, "Image"):
            if scale_name == "Tile":
                src = ASSET_FILES.get(str(prop(inst, "Image", "")))
                path = os.path.join(ASSETS, src) if src else None
                if not path or not os.path.exists(path):
                    continue
                tsz = prop(inst, "TileSize")
                tw = int(tsz["X"]["Offset"]) if tsz is not None else 96
                th = int(tsz["Y"]["Offset"]) if tsz is not None else 96
                tex = Image.open(path).convert("RGBA").resize((max(1, tw), max(1, th)))
                tint = rgb(prop(inst, "ImageColor3"), (255, 255, 255))
                if tint != (255, 255, 255):
                    px = tex.load()
                    for yy in range(tex.height):
                        for xx in range(tex.width):
                            r, g, b, a = px[xx, yy]
                            px[xx, yy] = (r * tint[0] // 255, g * tint[1] // 255,
                                          b * tint[2] // 255, a)
                sheet = Image.new("RGBA", (w, h), (0, 0, 0, 0))
                for oy in range(0, h, tex.height):
                    for ox in range(0, w, tex.width):
                        sheet.paste(tex, (ox, oy))
                ia = 1.0 - float(prop(inst, "ImageTransparency", 0))
                sheet.putalpha(sheet.getchannel("A").point(lambda v: int(v * ia)))
                corner = child_of_class(inst, "UICorner")
                radius = udim_offset(prop(corner, "CornerRadius")) if corner else 0
                if radius:
                    sheet.putalpha(Image.composite(sheet.getchannel("A"),
                                                   Image.new("L", (w, h), 0),
                                                   rounded_mask((w, h), min(radius, w // 2, h // 2))))
                img.alpha_composite(sheet, (x, y))
                continue
            # A 9-sliced chamfered panel, drawn as a rounded rect in its own
            # gradient. Corner shape differs (round vs chamfer); value does not,
            # and value is what this preview exists to judge.
            grad = child_of_class(inst, "UIGradient")
            ia = 1.0 - float(prop(inst, "ImageTransparency", 0))
            tile = Image.new("RGBA", (w, h), (0, 0, 0, 0))
            td = ImageDraw.Draw(tile)
            cseq = prop(grad, "Color") if grad is not None else None
            if cseq is not None:
                for i in range(max(1, h)):
                    t = i / max(1, h - 1)
                    col = sample_color_seq(cseq, t)
                    td.line([(0, i), (w, i)], fill=col + (int(ia * 255),))
            else:
                td.rectangle([0, 0, w - 1, h - 1],
                             fill=rgb(prop(inst, "ImageColor3"), (255, 255, 255)) + (int(ia * 255),))
            tile.putalpha(Image.composite(tile.getchannel("A"),
                                          Image.new("L", (w, h), 0),
                                          rounded_mask((w, h), min(22, w // 2, h // 2))))
            img.alpha_composite(tile, (x, y))

        if alpha > 0.004:
            base = rgb(prop(inst, "BackgroundColor3"), (255, 255, 255))
            grad = child_of_class(inst, "UIGradient")
            corner = child_of_class(inst, "UICorner")
            radius = udim_offset(prop(corner, "CornerRadius")) if corner else 0
            radius = min(radius, w // 2, h // 2)

            tile = Image.new("RGBA", (w, h), (0, 0, 0, 0))
            td = ImageDraw.Draw(tile)
            cseq = prop(grad, "Color") if grad is not None else None
            nseq = prop(grad, "Transparency") if grad is not None else None
            if grad is not None and (cseq is not None or nseq is not None):
                rot = prop(grad, "Rotation", 0)
                steps = h if rot else w
                for i in range(max(1, steps)):
                    t = i / max(1, steps - 1)
                    col = sample_color_seq(cseq, t) if cseq is not None else base
                    col = tuple(int(col[k] * base[k] / 255) for k in range(3))
                    a = alpha
                    if nseq is not None:
                        a = alpha * (1.0 - sample_number_seq(nseq, t))
                    px = (col[0], col[1], col[2], int(a * 255))
                    if rot:
                        td.line([(0, i), (w, i)], fill=px)
                    else:
                        td.line([(i, 0), (i, h)], fill=px)
            else:
                td.rectangle([0, 0, w - 1, h - 1], fill=base + (int(alpha * 255),))
            if radius > 0:
                tile.putalpha(Image.composite(tile.getchannel("A"),
                                              Image.new("L", (w, h), 0),
                                              rounded_mask((w, h), radius)))
            img.alpha_composite(tile, (x, y))

        st = child_of_class(inst, "UIStroke")
        text_only = (cls in ("TextLabel", "TextButton", "TextBox")
                     and float(prop(inst, "BackgroundTransparency", 0)) >= 1.0)
        if st is not None and not text_only:
            sa = 1.0 - float(prop(st, "Transparency", 0))
            col = rgb(prop(st, "Color"), (0, 0, 0)) + (int(sa * 255),)
            corner = child_of_class(inst, "UICorner")
            radius = min(udim_offset(prop(corner, "CornerRadius")) if corner else 0,
                         w // 2, h // 2)
            if radius > 0:
                draw.rounded_rectangle([x, y, x + w - 1, y + h - 1], radius=radius,
                                       outline=col, width=int(prop(st, "Thickness", 1)))
            else:
                draw.rectangle([x, y, x + w - 1, y + h - 1], outline=col,
                               width=int(prop(st, "Thickness", 1)))

        text = prop(inst, "Text", "")
        if cls in ("TextLabel", "TextButton", "TextBox") and text:
            tcol = rgb(prop(inst, "TextColor3"), (255, 255, 255))
            ta = 1.0 - float(prop(inst, "TextTransparency", 0))
            size = int(prop(inst, "TextSize", 12))
            f = font_bold if "Bold" in str(prop(inst, "Font", "")) else font
            f = f.font_variant(size=size) if hasattr(f, "font_variant") else f
            xal = str(prop(inst, "TextXAlignment", {"_name": "Center"})["_name"]) \
                if prop(inst, "TextXAlignment") is not None else "Center"
            bbox = draw.textbbox((0, 0), text, font=f)
            tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
            tx = x + (0 if xal == "Left" else (w - tw if xal == "Right" else (w - tw) // 2))
            ty = y + (h - th) // 2 - bbox[1]
            draw.text((tx, ty), text, font=f, fill=tcol + (int(ta * 255),))


def render(choice, path):
    rt = lupa.LuaRuntime(unpack_returned_tuples=True)
    rt.globals().python_read_file = read_file
    rt.globals().SKIN = choice
    res = rt.execute(LUA)
    root = res["root"]

    # Measure, write the sizes back, let the UI react, repeat. container.lua
    # recomputes its header seam from AbsoluteSize and its scroll height from
    # the layout's AbsoluteContentSize, so the tree only settles after a couple
    # of rounds -- exactly as it does in Roblox.
    records = []
    for _ in range(3):
        records, MEASURED[:] = [], []
        walk(root, 0, 0, 1600, 900, records)
        for _key, inst, (_x, _y, w, h) in records:
            res["setprop"](inst, "AbsoluteSize", res["mkvec"](w, h))
            res["fire"](inst, "AbsoluteSize")
        for inst, w, h in MEASURED:
            res["setprop"](inst, "AbsoluteContentSize", res["mkvec"](w, h))
            res["fire"](inst, "AbsoluteContentSize")
    records, MEASURED[:] = [], []
    walk(root, 0, 0, 1600, 900, records)

    # Crop to the panel with a margin of backdrop on each side.
    xs = [r[2][0] for r in records] + [0]
    ys = [r[2][1] for r in records] + [0]
    xe = [r[2][0] + r[2][2] for r in records]
    ye = [r[2][1] + r[2][3] for r in records]
    pad = 24
    x0, y0 = int(min(xs)) - pad, int(min(ys)) - pad
    x1, y1 = int(max(xe)) + pad, int(max(ye)) + pad

    img = Image.new("RGBA", (1600, 900), (96, 106, 118, 255))   # neutral backdrop
    try:
        font = ImageFont.truetype("segoeui.ttf", 12)
        font_bold = ImageFont.truetype("segoeuib.ttf", 12)
    except Exception:
        font = font_bold = ImageFont.load_default()
    paint(img, records, font, font_bold)

    shot = img.crop((max(0, x0), max(0, y0), min(1600, x1), min(900, y1)))
    shot = shot.resize((shot.width * SCALE, shot.height * SCALE), Image.NEAREST)
    shot.save(path)
    print("%-9s errors=%s  ->  %s" % (choice, res["errors"], path))


def main():
    os.makedirs(OUT, exist_ok=True)
    choices = sys.argv[1:] or ["Flat", "Hardware"]
    for c in choices:
        render(c.capitalize(), os.path.join(OUT, "preview_%s.png" % c.lower()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
