-- Fake Tab: reproduces the PvP effect of alt-tabbing ("tabbing") without the
-- downside. When you really alt-tab, Roblox throttles the client to ~0 FPS, your
-- character stops replicating movement, and to everyone else you're frozen in
-- place (and you stop eating knockback / combos). The useful half of that is the
-- freeze-in-place desync; the painful half is that YOU can't see anything at 0
-- FPS. This gives you the freeze without the blackout.
--
-- How: while enabled, every Heartbeat (after physics, the last word before the
-- engine replicates us) it re-pins the HumanoidRootPart to the CFrame captured
-- when you toggled on, zeroes assembly velocity, and feeds the Humanoid a zero
-- move vector. The server keeps receiving that one frozen CFrame, so others see
-- you locked still and external forces can't shove you -- the same desync a real
-- tab gives, minus the 0 FPS. Your camera / vision / aim stay fully live. Toggle
-- off (or a keybind, like flicking alt-tab) to thaw and resume.
--
-- Why not just anchor the root: Anchored=true replicates as an obvious tell some
-- anti-cheats flag, and breaks games that drive the character through the
-- Humanoid. CFrame-hold + velocity-zero stays unanchored and still resists
-- knockback. See [[feedback_adonis_detection]] -- this makes no safety claims.

local RunService = game:GetService("RunService")
local Players    = game:GetService("Players")
local LP         = Players.LocalPlayer

local feature = require("ui.feature")
local log     = require("core.log")
local notify  = require("ui.notify")

local FakeTab = {}

local enabled  = false
local frozenCF = nil    -- the CFrame we hold the root at while frozen
local conn     = nil    -- the Heartbeat hold connection
local charConn = nil    -- CharacterAdded watcher (re-capture on respawn)

local function rootOf(char)
    if not char then return nil end
    return char:FindFirstChild("HumanoidRootPart")
        or char:FindFirstChild("Torso")
        or char:FindFirstChild("UpperTorso")
        or char:FindFirstChildWhichIsA("BasePart")
end

-- Re-pin the root to the frozen CFrame, kill velocity so nothing drifts or knocks
-- us out of place, and zero the Humanoid's move vector so we don't moonwalk the
-- run animation in place. Runs on Heartbeat (post-physics) so ours is the CFrame
-- that actually replicates.
local function hold()
    if not enabled then return end
    local char = LP.Character
    local root = rootOf(char)
    if not root then return end
    if not frozenCF then frozenCF = root.CFrame end   -- (re)capture after a respawn
    root.CFrame = frozenCF
    pcall(function()
        root.AssemblyLinearVelocity  = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end)
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then pcall(function() hum:Move(Vector3.zero, false) end) end
end

local function setActive(v)
    v = v and true or false
    if enabled == v then return end

    if v then
        local root = rootOf(LP.Character)
        if not root then
            notify.warn("Fake Tab: no character to freeze")
            return   -- leave disabled; toggling again once spawned works
        end
        enabled  = true
        frozenCF = root.CFrame                         -- capture where we "tabbed"
        if not conn then conn = RunService.Heartbeat:Connect(hold) end
        notify.success("Fake Tab ON -- frozen in place, FPS untouched")
    else
        enabled = false
        if conn then pcall(function() conn:Disconnect() end); conn = nil end
        frozenCF = nil
        local root = rootOf(LP.Character)
        if root then
            pcall(function()
                root.AssemblyLinearVelocity  = Vector3.zero
                root.AssemblyAngularVelocity = Vector3.zero
            end)
        end
        notify.info("Fake Tab OFF -- thawed")
    end
end

function FakeTab.register(box)
    box:add(feature.declare({
        id          = "misc.faketab",
        name        = "Fake Tab",
        description = "Reproduces alt-tab \"tabbing\": freezes your character in place and stops it replicating movement, so to everyone else you're stuck still and stop taking knockback / combos -- but WITHOUT dropping your own FPS to zero, so you keep full vision, camera and aim. Each Heartbeat it re-pins your root to where you toggled on and zeroes velocity (unanchored -- no Anchored tell, and forces can't shove you). Bind a key below to flick it on/off like real alt-tabbing. You can't move while frozen (just like a real tab) -- toggle off to resume.",
        default     = false,
        onToggle    = setActive,
    }).root)

    -- On respawn the old root is gone; drop the stale CFrame so hold() re-captures
    -- from the NEW body instead of teleporting it to where the old one froze.
    if not charConn then
        charConn = LP.CharacterAdded:Connect(function()
            if enabled then frozenCF = nil end
        end)
    end

    log.info("Fake Tab feature registered")
end

function FakeTab.destroy()
    enabled = false
    if conn     then pcall(function() conn:Disconnect()     end); conn = nil end
    if charConn then pcall(function() charConn:Disconnect() end); charConn = nil end
    frozenCF = nil
end

return FakeTab
