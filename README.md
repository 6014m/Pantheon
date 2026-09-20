# Pantheon

Universal Roblox script hub with first-class game integration. Fires remotes, hooks events, and absorbs other people's scripts into a single framework — a combo project built modular from day one.

## Usage

```lua
local ok,r=pcall(function() return game:HttpGet("https://api.github.com/repos/6014m/Pantheon/commits/main?t="..tick()) end);local sha=ok and type(r)=="string" and r:match('"sha"%s*:%s*"(%x+)"') or "main";loadstring(game:HttpGet("https://raw.githubusercontent.com/6014m/Pantheon/"..sha.."/dist/main.lua?v="..tick()))()
```

That one-liner asks GitHub for main's latest commit and loads the bundle **by commit SHA**.
Why: `raw.githubusercontent.com/.../main/...` is served by a CDN that caches the branch path
for up to 5 minutes and **ignores `?v=` query strings**, so the plain branch URL hands out the
previous build right after a push. A SHA path is immutable and never stale. If the API call
fails (rate limit: 60/hr unauthenticated) it falls back to the branch path.
The `?t=` on the API call matters: Wave caches `HttpGet` responses per URL, so without it every
reload in a session reuses the first lookup's SHA and keeps loading that build.

Plain form (may be up to 5 minutes stale after a push):

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/6014m/Pantheon/main/dist/main.lua"))()
```

## Layout

```
src/
  init.lua           entry point, wires modules together
  loader.lua         dev loader: HttpGets each src/*.lua live with cache-bust
  core/              env compat, signal, log, persist
  ui/                window, components, theme, skin, notify (rolled from scratch)
  modules/           universal features
  games/             per-PlaceId hooks (registry pattern)
tools/build.py       concats src/*.lua -> dist/main.lua with a require shim
dist/main.lua        the bundled output users load
```

## UI skins

`Pantheon menu -> cog -> UI Skin` picks the look, then **Re-Execute Now** applies it.

* **Flat** (default) - the original hex/HUD panels. Unchanged.
* **Hardware** - one moulded faceplate with the controls sunk into it.
  Pantheon's chamfered 9-slice IS the plate (the skin repaints its gradient in
  metal), the header rail gains a milled rim, a groove, a lit lip and hex bolt
  heads. Feature rows are not cards: they are stretches of that same plate,
  divided by hairline seams. What gets sunk in is the hardware - the hexagons
  stay hexagons and sit in hex-shaped cutouts, ON/OFF is a latching key that
  drops to the bottom of its cut and backlights through a hex lamp, toggles are
  rockers in a slot, sliders are faders on a routed channel, readouts are
  windows cut through, the settings tray is a compartment, and headings are
  etched.

  Three things it took three attempts to get right, worth knowing before
  editing it:

  1. **A `UIGradient` multiplies `BackgroundColor3`, it does not replace it.**
     Grey gradient over grey background squares down to near-black - which is
     why the first two cuts looked like unlit slabs. `gradient()` sets the base
     white unless you ask for the multiply.
  2. **Depth is lighting, and lighting needs value range.** The plate is a real
     mid grey (Pantheon's own header-band grey), cuts go to 13 and caps to 104.
     A 1px white lip on a near-black panel is invisible.
  3. **A container is `AutomaticSize.Y`**, so the panel hook must not add a
     child sized to the whole panel - that stretches every menu to the bottom of
     the screen. Panel furniture is parented into the header host, whose extent
     is fixed. `mocktest_skin.py` guards this.

`src/ui/skin.lua` is the whole implementation: a decoration layer the ui/*
modules call at fixed points while building. Flat's hooks are no-ops, so that
path is byte-identical to the pre-skin build; hardware's hooks add the bevels,
screws and wells. A new component is skinned once, there, rather than in every
module that builds one. The choice is stored in the **cross-game** settings file
(`Pantheon/settings/global.json`) so it follows you into every game.

Two tools cover it:

* `python tools/mocktest_skin.py` builds the real UI tree under both skins,
  flips every control, and checks the structural rules: no child added to an
  AutomaticSize container, no hexagon hidden or swapped for a rectangle, no
  socket part inside a UIListLayout/UIPadding parent, no doubled UIGradient,
  and flat adding zero decoration instances.
* `python tools/preview_skin.py` **renders** that tree to
  `scratch/preview_<skin>.png` (3x, nearest-neighbour). A skin is entirely
  about how it looks, and the mocktest cannot see that - the preview caught the
  gradient-multiply bug, section headings rendering twice, and button legends
  being swallowed by their own key caps, all without a reload.

## Build

```
python tools/build.py
```

Edit anything in `src/`, run the build, commit `dist/main.lua`. Users always load the bundle — single HttpGet, no module-name URLs for an anticheat to fingerprint.

## Dev loader (skip the rebuild)

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/6014m/Pantheon/main/src/loader.lua?v="..tick()))()
```

The dev loader pulls each `src/*.lua` live with a cache-bust query, then assembles the same `require` shim the bundle uses. Edit a module, push, reload — no build step. (Same CDN caveat: `?v=` only busts the executor's cache, not GitHub's; expect up to 5 minutes of staleness after a push.)
