-- Target Select: picks and holds a target, triggers Highlight. Lock-On and
-- Rotation Lock read state.target to know who to aim at. Owns the toggle/hold
-- hotkey (default X) and the scroll-wheel target swap.

local state     = require("modules.aim.state")
local targeting = require("modules.aim.targeting")
local highlight = require("modules.aim.highlight")

local RunService = game:GetService("RunService")
local CAS        = game:GetService("ContextActionService")

local TargetSelect = {}

local s = {
    holdMode    = false,
    holdActive  = false,
    heartConn   = nil,
    lastStep    = 0,
    scrollBound = false,
    lastScroll  = 0,
}

-- Target validity + highlight/swap-target recompute run on a throttle, not every
-- frame. getBestTarget() loops every player (and raycasts per player when the
-- visibility check is on) -- doing that 240x/s in a crowded server is the main
-- source of the "choppy sometimes" hitching. 30 Hz keeps the health bar and
-- target-release responsive while cutting the scan rate ~8x. The actual aim
-- (lockon camera + rotation_lock body) stays per-frame and is untouched.
local STEP_INTERVAL = 1 / 30

local function releaseTarget()
    state.setTarget(nil, nil)
    s.holdActive = false
    highlight.update(nil, nil)
end

local function engageTarget()
    local t, ty = targeting.getBestTarget()
    if not t then return false end
    state.setTarget(t, ty)
    return true
end

function TargetSelect.swapTarget()
    if not state.swap_enabled then return end
    if not state.target_select_enabled or not state.target then return end
    local next_, ty = targeting.getBestTarget(state.target)
    if next_ then state.setTarget(next_, ty) end
end

-- Step through targets ranked best-first (nearest, or nearest the cursor in cursor
-- mode). dir = 1 moves to the next one down the ranking, -1 back up; wraps at the
-- ends. If the current target isn't in the ranking any more (out of range, hidden),
-- 1 picks the best target and -1 the last.
function TargetSelect.cycleTarget(dir)
    if not state.target_select_enabled or not state.target then return false end
    local list = targeting.getRankedTargets()
    local n = #list
    if n == 0 then return false end
    local idx
    for i, e in ipairs(list) do
        if e.target == state.target then idx = i; break end
    end
    local nextIdx
    if idx then
        if n == 1 then return false end
        nextIdx = ((idx - 1 + dir) % n) + 1
    else
        nextIdx = (dir > 0) and 1 or n
    end
    local e = list[nextIdx]
    state.setTarget(e.target, e.type)
    return true
end

-- Scroll wheel swap: bound through ContextActionService ABOVE the camera's wheel
-- zoom, so while you're locked on a notch swaps target instead of zooming. When
-- you're not locked on the handler passes and zoom works as normal.
local SCROLL_ACTION   = "PantheonScrollSwap"
local SCROLL_PRIORITY = Enum.ContextActionPriority.High.Value + 50
local SCROLL_DEBOUNCE = 0.12   -- trackpads fire a burst of wheel events per swipe

local function scrollHandler(_, inputState, input)
    if inputState ~= Enum.UserInputState.Change then return Enum.ContextActionResult.Pass end
    if not (state.scrollSwapEnabled and state.swap_enabled and state.lockon_enabled
            and state.target_select_enabled and state.target) then
        return Enum.ContextActionResult.Pass
    end
    local z = input.Position.Z
    if z == 0 then return Enum.ContextActionResult.Pass end
    local now = os.clock()
    if now - s.lastScroll >= SCROLL_DEBOUNCE then
        s.lastScroll = now
        TargetSelect.cycleTarget(z < 0 and 1 or -1)   -- wheel down = next, wheel up = previous
    end
    return Enum.ContextActionResult.Sink
end

function TargetSelect.setScrollSwap(v)
    state.scrollSwapEnabled = v and true or false
    if state.scrollSwapEnabled and not s.scrollBound then
        local ok = pcall(function()
            CAS:BindActionAtPriority(SCROLL_ACTION, scrollHandler, false, SCROLL_PRIORITY, Enum.UserInputType.MouseWheel)
        end)
        s.scrollBound = ok
    elseif not state.scrollSwapEnabled and s.scrollBound then
        pcall(function() CAS:UnbindAction(SCROLL_ACTION) end)
        s.scrollBound = false
    end
end

local function step()
    if not state.target_select_enabled then return end
    if not state.target then return end

    local now = os.clock()
    if now - s.lastStep < STEP_INTERVAL then return end
    s.lastStep = now

    local t = state.target
    -- "Skip dead / shielded" (state.checkHealthEnabled) governs RETENTION too:
    -- when it's OFF, keep the target locked through death (and respawn) -- only
    -- drop them when they leave entirely (player left the game / NPC model gone)
    -- or become friendly. When it's ON, a dead/removed target is released as
    -- before so aim moves on to the next one.
    if state.target_type == "player" then
        if not t or not t.Parent or state.isFriendly(t) then  -- left game / friendly
            releaseTarget()
            return
        end
        if state.checkHealthEnabled then
            local char = t.Character
            local hum  = char and char:FindFirstChildOfClass("Humanoid")
            if not hum or hum.Health <= 0 or not char.Parent then
                releaseTarget()
                return
            end
        end
    elseif state.target_type == "npc" then
        if not t or not t.Parent then  -- model despawned entirely
            releaseTarget()
            return
        end
        if state.checkHealthEnabled then
            local hum = t:FindFirstChildOfClass("Humanoid")
            if not hum or hum.Health <= 0 then
                releaseTarget()
                return
            end
        end
    end

    highlight.update(t, function(exclude) return targeting.getBestTarget(exclude) end)
end

function TargetSelect.hotkeyPress()
    if not state.target_select_enabled then return end
    if s.holdMode then
        if not state.target then engageTarget() end
        s.holdActive = true
    else
        if state.target then releaseTarget() else engageTarget() end
    end
end

function TargetSelect.hotkeyRelease()
    if s.holdMode and s.holdActive and state.target then
        releaseTarget()
    end
end

function TargetSelect.setHoldMode(v)
    s.holdMode = v and true or false
end

function TargetSelect.setEnabled(v)
    state.target_select_enabled = v and true or false
    if not v then releaseTarget() end
end

function TargetSelect.init()
    s.heartConn = RunService.Heartbeat:Connect(step)
end

function TargetSelect.destroy()
    if s.heartConn then s.heartConn:Disconnect(); s.heartConn = nil end
    if s.scrollBound then
        pcall(function() CAS:UnbindAction(SCROLL_ACTION) end)
        s.scrollBound = false
    end
end

return TargetSelect
