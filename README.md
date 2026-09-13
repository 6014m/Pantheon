# Pantheon

Universal Roblox script hub with first-class game integration. Fires remotes, hooks events, and absorbs other people's scripts into a single framework — a combo project built modular from day one.

## Usage

```lua
local ok,r=pcall(function() return game:HttpGet("https://api.github.com/repos/6014m/Pantheon/commits/main") end);local sha=ok and type(r)=="string" and r:match('"sha"%s*:%s*"(%x+)"') or "main";loadstring(game:HttpGet("https://raw.githubusercontent.com/6014m/Pantheon/"..sha.."/dist/main.lua?v="..tick()))()
```

That one-liner asks GitHub for main's latest commit and loads the bundle **by commit SHA**.
Why: `raw.githubusercontent.com/.../main/...` is served by a CDN that caches the branch path
for up to 5 minutes and **ignores `?v=` query strings**, so the plain branch URL hands out the
previous build right after a push. A SHA path is immutable and never stale. If the API call
fails (rate limit: 60/hr unauthenticated) it falls back to the branch path.

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
  ui/                window, components, theme, notify (rolled from scratch)
  modules/           universal features
  games/             per-PlaceId hooks (registry pattern)
tools/build.py       concats src/*.lua -> dist/main.lua with a require shim
dist/main.lua        the bundled output users load
```

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
