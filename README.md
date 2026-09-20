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
* **Hardware** - the same panels, machined. Pantheon's chamfered 9-slice IS the
  faceplate (the skin just repaints its gradient in metal), the header bar gains
  a milled rim, a groove and a lit lip, and hex bolt heads hold it down. The
  hexagons stay hexagons and gain depth instead: each one sits on a black
  hexagon one pixel low, so it stands proud of the plate, and its face is shaded
  top-lit rather than filled flat. ON/OFF is a latching hex key that drops onto
  its own shadow and backlights with a hex lamp; the cog and "i" are momentary
  keys. Toggles are rockers in a recessed well, sliders are faders riding a
  routed channel, readouts are inset, and headings are etched into the metal.

  Note for anyone extending it: a container is `AutomaticSize.Y`, so the panel
  hook must not add a child sized to the whole panel - that stretches every menu
  to the bottom of the screen. Panel furniture is parented into the header host,
  whose extent is fixed. `mocktest_skin.py` guards this.

`src/ui/skin.lua` is the whole implementation: a decoration layer the ui/*
modules call at fixed points while building. Flat's hooks are no-ops, so that
path is byte-identical to the pre-skin build; hardware's hooks add the bevels,
screws and wells. A new component is skinned once, there, rather than in every
module that builds one. The choice is stored in the **cross-game** settings file
(`Pantheon/settings/global.json`) so it follows you into every game.

Verify with `python tools/mocktest_skin.py` - it builds the real UI tree under
both skins, flips every control, and checks the structural rules: no child added
to an AutomaticSize container, no hexagon hidden or swapped for a rectangle, no
bevel Frames inside a UIListLayout/UIPadding parent, no doubled UIGradient, and
flat adding zero decoration instances.

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
