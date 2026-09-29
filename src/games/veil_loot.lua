-- The Veil: Auto Pickup + Auto Trash.
--
-- How the game does it (decompiled InteractHandler / InventoryGui.Handler, 2026-09-29):
--   * Drops are models in workspace.Drops named after the item: attribute Rarity, Folder
--     IsInteractable, StringValue Argument = "PickupDrop" (or "PickupSilver"), and
--     AtTrinketSpawn = true for the world trinkets (rings, goblets...).
--   * E only ever targets the NEAREST drop within 10 studs, then fires
--     Remotes.InteractPromptEvent:FireServer(argument, model). Chest loot lands in a pile,
--     so the item you want is often not the nearest one (user: "you have to pick up a
--     different item to get the item you want"). This fires that same event for the exact
--     model the filter picked, so the pile doesn't matter.
--   * Trash = Remotes.TrashItemsEvent:FireServer({ tool, tool, ... }) with your Backpack
--     Tools, the same call the inventory's trash slot makes.
--
-- Filters (both features): comma / semicolon / new-line separated rules.
--   Tomes Elite+        every tome of Elite grade or better
--   Weapons Legendary   weapons of exactly Legendary grade
--   Evasion Scarf       that item, any grade
--   Elite+              anything Elite or better (same as "any Elite+")
-- Categories are the inventory tabs: Weapons, Summons, Accessories, Outfits, Potions,
-- Tomes, Gems, Items, Trinkets. A drop on the ground only carries its name + rarity, so the
-- category comes from a name table (fan Trello lists) plus whatever this learns from items
-- landing in your Backpack (the game's own IsAccessory / IsOutfit / ... tags).

local Players   = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RS        = game:GetService("ReplicatedStorage")

local log     = require("core.log")
local persist = require("core.persist")

local LP = Players.LocalPlayer

local Loot = {}

local CFG = {
    pickup      = false,
    pickRules   = {},      -- empty = everything
    skipRules   = {},
    silver      = true,
    range       = 10,      -- the game's own prompt reach
    trash       = false,
    trashRules  = {},
    onlyNew     = true,    -- trash only items that arrive after Auto Trash is on
}

-- the game's own tier order (InventoryGui.Handler sort table). The prompt's name colour is
-- generated from this same Rarity value (InteractHandler: GetAttribute("Rarity") -> RarityAnim
-- colour: white / #1EFF00 / #0070FF / #A335EE / #FF8000 / red), so reading it = reading the colour.
local RANK = { common = 1, uncommon = 2, rare = 3, elite = 4, legendary = 5, mythic = 6, godly = 7,
               christmas = 8, unobtainable = 9 }

local CATS = {
    weapon = "Weapons", weapons = "Weapons", summon = "Summons", summons = "Summons",
    accessory = "Accessories", accessories = "Accessories", outfit = "Outfits", outfits = "Outfits",
    potion = "Potions", potions = "Potions", tome = "Tomes", tomes = "Tomes", gem = "Gems", gems = "Gems",
    item = "Items", items = "Items", trinket = "Trinkets", trinkets = "Trinkets",
}

-- name -> category, from the fan Trello's lists (Melee + Magic = Weapons). Learned
-- categories (from real Backpack tools) win over this.
local KNOWN = {
    Weapons = { ["Armageddon"]=1, ["Auroran Lance"]=1, ["Bare Blade"]=1, ["Basher"]=1, ["Biome Blade"]=1, ["Bladecrest Oathsword"]=1, ["Bonesaber"]=1, ["Breaker Blade"]=1, ["Brimlash"]=1, ["Butcherer"]=1, ["Candlewick"]=1, ["Carnage"]=1, ["Cobalt Kunai"]=1, ["Crescent Vigil"]=1, ["Cursed Hammer"]=1, ["Dagger"]=1, ["Deadlight"]=1, ["Diamond Staff"]=1, ["Dread's Decree"]=1, ["Elegy Of The Tides"]=1, ["Emerald Staff"]=1, ["Enchanted Sword"]=1, ["Flare Bolt"]=1, ["Flint Cutlass"]=1, ["Fork Of Doom"]=1, ["Frigid Mallet"]=1, ["Frost Dancer"]=1, ["Gem Crusher"]=1, ["Geode Dagger"]=1, ["Gloomhook"]=1, ["Greatsword"]=1, ["Hellspiller"]=1, ["Hexed Wraithblade"]=1, ["Hiveling Arm"]=1, ["Ice Bolt"]=1, ["Icepiercer"]=1, ["Inferno Fork"]=1, ["Influx Waver"]=1, ["Jolly Striper"]=1, ["Keblade"]=1, ["Kiribachi"]=1, ["Magicial Harp"]=1, ["Malignant Bane"]=1, ["Melting Pot"]=1, ["Midnight Fractal"]=1, ["Mindbreaker"]=1, ["Mourning Wake"]=1, ["Mournmight"]=1, ["Muramasa"]=1, ["Navy Tuskblade"]=1, ["Noble Longsword"]=1, ["Pillarfall"]=1, ["Quicksilver"]=1, ["Rapier"]=1, ["Rimeblade"]=1, ["Rosespike Staff"]=1, ["Ruby Staff"]=1, ["Sahara Slicer"]=1, ["Sanguine Dirk"]=1, ["Sapphire Staff"]=1, ["Scourge Of Disease"]=1, ["Seraphim"]=1, ["Shadowbeam Staff"]=1, ["Shadowflame Knife"]=1, ["Shatterpoint"]=1, ["Shrouded Tanto"]=1, ["Soul Ringer"]=1, ["Soul Silencer"]=1, ["Sovereign"]=1, ["Spear"]=1, ["Spellweaver"]=1, ["Staff Of Sparkling"]=1, ["Staff Of The False Sun"]=1, ["Starfury"]=1, ["Storm Ruler"]=1, ["Suniron"]=1, ["Sword"]=1, ["Testament's Edge"]=1, ["Tidal Anchor"]=1, ["Topaz Staff"]=1, ["Veering Wind"]=1, ["Venom Fang"]=1, ["Verdant Thorn"]=1, ["Viperpoint"]=1, ["Voidlance"]=1, ["Wanderer's Blade"]=1, ["Water Bolt"]=1, ["Weeping Sore"]=1, ["Wind Blade"]=1, ["Witchlight"]=1, ["Withersting"]=1 },
    Summons = { ["Catapult"]=1, ["Extraterrestrial Transmitter"]=1, ["Goblin Scepter"]=1, ["Heaven's Lament"]=1, ["Imp Staff"]=1, ["Necronomical Skull"]=1, ["Nimbus Rod"]=1, ["Rot Polyp Wand"]=1, ["Staff Of Voidmending"]=1, ["Suspicious Boulder"]=1, ["Willow Lantern"]=1 },
    Accessories = { ["Aglet"]=1, ["Anklet Of Wind"]=1, ["Arcane Rune"]=1, ["Backpack"]=1, ["Balloon"]=1, ["Band Of Stamina"]=1, ["Band of Efficiency"]=1, ["Black Belt"]=1, ["Blood Pact"]=1, ["Bone Gauntlet"]=1, ["Brain of Confusion"]=1, ["Chaos Stone"]=1, ["Chestplate"]=1, ["Cloud In A Bottle"]=1, ["Cowl"]=1, ["Cyst Worm"]=1, ["DPS Meter"]=1, ["Dark Amulet"]=1, ["Deadweight"]=1, ["Decaying Spine"]=1, ["Disco Ball"]=1, ["Evasion Scarf"]=1, ["Explorer Hat"]=1, ["Fabled Crown"]=1, ["Fairy Light"]=1, ["Festered Shield"]=1, ["Flesh Knuckles"]=1, ["Floaty"]=1, ["Furystone"]=1, ["Gentleman's Fedora"]=1, ["Gilded Diamond Timepiece"]=1, ["Gladiator's Locket"]=1, ["Golden Beetle"]=1, ["Hell pauldron"]=1, ["Hermes Boots"]=1, ["Lantern"]=1, ["Lifeform Analyzer"]=1, ["Lucky Coin"]=1, ["Magma Stone"]=1, ["Mana Flower"]=1, ["Necronomical Scroll"]=1, ["Negative Cap"]=1, ["Night Stone"]=1, ["Occult Skull Crown"]=1, ["Philosopher's Stone"]=1, ["Portable Harmonic Fleshing"]=1, ["Power Cell"]=1, ["Power Glove"]=1, ["Prosthetic Arm"]=1, ["Putrid Scent"]=1, ["Pygmy Necklace"]=1, ["Radar"]=1, ["Ragged Cloth"]=1, ["Rampaging Ribcage"]=1, ["Ring Of Retribution"]=1, ["Rover Drive"]=1, ["Runner Helmet"]=1, ["Runner's Handbook"]=1, ["Shackles"]=1, ["Shades"]=1, ["Shako"]=1, ["Shiny Stone"]=1, ["Spore Sac"]=1, ["Starfish"]=1, ["Summon Rune"]=1, ["Tainted Elixir"]=1, ["The Angry Mask"]=1, ["The Bell"]=1, ["The Convergence"]=1, ["The Dice"]=1, ["The Laughing Mask"]=1, ["The Sleeping Mask"]=1, ["The Weeping Mask"]=1, ["The Weightless Crown"]=1, ["Tophat"]=1, ["Tribal Visage"]=1, ["Turtle Shell"]=1, ["Vampiric Talisman"]=1 },
    Outfits = { ["Accursed Robes"]=1, ["Blacksmith's Kit"]=1, ["Burdenmail"]=1, ["Collared Tunic"]=1, ["Crimson Cowl"]=1, ["Crusader Curiass"]=1, ["Desecrated Carapace"]=1, ["Ebon Cloak"]=1, ["Ember Cloak"]=1, ["Experimental Chemist"]=1, ["Fighter Gi"]=1, ["Fissure's Agility"]=1, ["Fissure's Protection"]=1, ["Formal Attire"]=1, ["Formal Finery"]=1, ["Hardened Cloak"]=1, ["Heavy Scale"]=1, ["Hoarapace"]=1, ["Ivory Shell"]=1, ["Miasmic Blight"]=1, ["Night Raiment"]=1, ["Night Weave"]=1, ["Nimble Ward"]=1, ["Pale Vanguard"]=1, ["Rage Pelt"]=1, ["Rags"]=1, ["Ranger Tunic"]=1, ["Runner's Outfit"]=1, ["Sanctifying Luminousness"]=1, ["Sanguine Garb"]=1, ["Sanguine Vestments"]=1, ["Silver Aegis"]=1, ["Sky Garments"]=1, ["Sorcerer's Mantle"]=1, ["Soul Shroud"]=1, ["Spider Silk"]=1, ["Suite"]=1, ["Surgecloth"]=1, ["Thick Cloak"]=1, ["Thief's Gear"]=1, ["Thin Hide"]=1, ["Unyielding Darkness"]=1, ["Veil's Aberration"]=1 },
    Potions = { ["Flask Of Grace"]=1, ["Health Potion"]=1, ["Ironskin Potion"]=1, ["Nightcall Potion"]=1, ["Regeneration Potion"]=1, ["Sanity Potion"]=1, ["Stamina Regeneration Potion"]=1, ["Swiftness Potion"]=1, ["Wrath Potion"]=1 },
    Gems = { ["Aquamarine"]=1, ["Azure Ruby"]=1, ["Blood"]=1, ["Diamond"]=1, ["Divine Topaz"]=1, ["Emerald"]=1, ["Iridescent Gem"]=1, ["Onyx"]=1, ["Opal"]=1, ["Rot Gem"]=1, ["Ruby"]=1, ["Saphire"]=1, ["Shadow Diamond"]=1, ["Star Gem"]=1, ["Topaz"]=1 },
    Items = { ["Aegis Banner"]=1, ["Bag"]=1, ["Brewery Staff"]=1, ["Festered Meat"]=1, ["Fire Essence"]=1, ["Firework"]=1, ["Giant Smiley Bomb"]=1, ["Idol of Hatred"]=1, ["Omniwarp"]=1, ["Smoldering Horn"]=1, ["Star Fruit"]=1, ["Stone Accord"]=1, ["Suspicious Invitation"]=1, ["Tesla"]=1, ["The First Light"]=1, ["Thunder Quartz"]=1, ["Whoopie Cushion"]=1 },
    Trinkets = { ["Amulet"]=1, ["Goblet"]=1, ["Old Amulet"]=1, ["Old Ring"]=1, ["Ring"]=1 },
}
local learnedCat = {}   -- lowercased name -> category

-- Never trashed unless a rule names them exactly: class currencies.
local PROTECT = { ["stone accord"] = true, ["idol of hatred"] = true }

------------------------------------------------------------------ rules
local function trim(s) return (string.gsub(s, "^%s*(.-)%s*$", "%1")) end

local function parseRules(text)
    local rules = {}
    for raw in string.gmatch((text or "") .. ",", "([^,;\n]*)[,;\n]") do
        local r = trim(raw)
        if r ~= "" then
            local rule = { text = r }
            local body, grade, plus = string.match(r, "^(.-)%s*(%a+)(%+?)$")
            if body and RANK[string.lower(grade)] then
                rule.rank = RANK[string.lower(grade)]
                rule.orBetter = plus == "+"
                r = trim(body)
            end
            local l = string.lower(r)
            if l == "" or l == "any" or l == "all" or l == "*" or l == "everything" then
                rule.any = true
            elseif CATS[l] then
                rule.cat = CATS[l]
            else
                rule.name = l
            end
            rules[#rules + 1] = rule
        end
    end
    return rules
end

local function baseName(name)
    local l = string.lower(name)
    return (string.gsub(l, "^enhanced ", ""))
end

local function ruleMatches(rule, name, cat, rank)
    if rule.rank then
        if rule.orBetter then if rank < rule.rank then return false end
        elseif rank ~= rule.rank then return false end
    end
    if rule.any then return true end
    if rule.cat then return cat == rule.cat end
    return rule.name == baseName(name)
end

local function anyMatch(rules, name, cat, rank)
    for _, r in ipairs(rules) do
        if ruleMatches(r, name, cat, rank) then return r end
    end
    return nil
end

------------------------------------------------------------------ categories
local itemStacking
pcall(function() itemStacking = require(RS.Assets.Scripts.ItemStacking) end)

local function boolChild(t, n)
    local v = t:FindFirstChild(n)
    if not v then return false end
    if v:IsA("BoolValue") then return v.Value end
    return true
end

-- the game's own getCategory (InventoryGui.Handler), for a Tool in your Backpack
local function toolCategory(t)
    if t:FindFirstChild("IsEnchant") then return "Gems" end
    local sword = false
    if itemStacking and itemStacking.IsSword then pcall(function() sword = itemStacking.IsSword(t) end)
    else sword = boolChild(t, "IsSword") end
    if sword then return "Weapons" end
    if t:FindFirstChild("IsAccessory") then return "Accessories" end
    if t:FindFirstChild("IsOutfit") then return "Outfits" end
    if t:FindFirstChild("IsPotion") then return "Potions" end
    local cast = false
    if itemStacking and itemStacking.IsCastWeapon then pcall(function() cast = itemStacking.IsCastWeapon(t) end)
    else cast = t:FindFirstChild("IsCastWeapon") ~= nil or t:GetAttribute("IsCastWeapon") == true end
    if cast then return "Weapons" end
    if t:FindFirstChild("IsSummonItem") then return "Summons" end
    if t:FindFirstChild("EnhancementId") or string.find(t.Name, "Enhancement Tome", 1, true) then return "Tomes" end
    if t:FindFirstChild("IsItem") then return "Items" end
    if boolChild(t, "IsTrinket") then return "Trinkets" end
    return "Items"
end

local function saveLearned()
    local parts = {}
    for n, c in pairs(learnedCat) do parts[#parts + 1] = n .. "=" .. c end
    table.sort(parts)
    pcall(persist.set, "veil.loot.learned_cats", table.concat(parts, ";"))
end

local function learnTool(t)
    if not t:IsA("Tool") then return end
    local n, c = baseName(t.Name), toolCategory(t)
    if learnedCat[n] ~= c then learnedCat[n] = c; saveLearned() end
end

local knownLower
local function dropCategory(m)
    local at = m:FindFirstChild("AtTrinketSpawn")
    if at and at:IsA("BoolValue") and at.Value then return "Trinkets" end
    local n = baseName(m.Name)
    if learnedCat[n] then return learnedCat[n] end
    if string.find(n, "tome", 1, true) then return "Tomes" end
    if not knownLower then
        knownLower = {}
        for cat, set in pairs(KNOWN) do
            for name in pairs(set) do knownLower[string.lower(name)] = cat end
        end
    end
    return knownLower[n] or "Unknown"
end

------------------------------------------------------------------ helpers
local function rootPos(m)
    if m:IsA("BasePart") then return m.Position end
    local p = m.PrimaryPart or m:FindFirstChild("Handle") or m:FindFirstChildWhichIsA("BasePart")
    return p and p.Position or nil
end

local function myRoot()
    local c = LP.Character
    local h = c and c:FindFirstChildOfClass("Humanoid")
    if not h or h.Health <= 0 then return nil end
    return c:FindFirstChild("HumanoidRootPart")
end

local function remote(name)
    local r = RS:FindFirstChild("Remotes")
    return r and r:FindFirstChild(name)
end

------------------------------------------------------------------ auto pickup
local conns = {}
local running = false
local firstSeen = setmetatable({}, { __mode = "k" })
local tries     = setmetatable({}, { __mode = "k" })   -- model -> { n, last }
local ignored   = setmetatable({}, { __mode = "k" })   -- drops you let go of yourself
local lostAt    = {}                                   -- lowercased name -> time it left your bag
local lastFire  = 0

local function wantDrop(m)
    local arg = m:FindFirstChild("Argument")
    if not (arg and m:FindFirstChild("IsInteractable")) then return nil end
    if arg.Value == "PickupSilver" then return CFG.silver and 0 or nil end
    if arg.Value ~= "PickupDrop" then return nil end
    local rv = m:GetAttribute("Rarity")
    if rv == nil then
        local c = m:FindFirstChild("Rarity")
        rv = c and c:IsA("StringValue") and c.Value or "Common"
    end
    local rank = RANK[string.lower(tostring(rv))] or 1
    local cat = dropCategory(m)
    if anyMatch(CFG.skipRules, m.Name, cat, rank) then return nil end
    if #CFG.pickRules > 0 and not anyMatch(CFG.pickRules, m.Name, cat, rank) then return nil end
    return rank
end

local function pickupStep()
    if not CFG.pickup then return end
    local drops = Workspace:FindFirstChild("Drops")
    local root = myRoot()
    if not (drops and root) then return end
    local t = os.clock()
    if t - lastFire < 0.2 then return end
    if LP:GetAttribute("GearRestoring") == true then return end
    local best, bestRank, bestD
    for _, m in ipairs(drops:GetChildren()) do
        if not ignored[m] then
            local seen = firstSeen[m]
            if not seen then firstSeen[m] = t; seen = t end
            local tr = tries[m]
            -- 0.3 s for the Rarity attribute to settle; 5 tries, then rest 10 s (full bag etc.)
            if t - seen >= 0.3 and not (tr and ((tr.n >= 5 and t - tr.last < 10) or t - tr.last < 0.6)) then
                local p = rootPos(m)
                local d = p and (p - root.Position).Magnitude
                if d and d <= CFG.range then
                    local rank = wantDrop(m)
                    if rank and (not best or rank > bestRank or (rank == bestRank and d < bestD)) then
                        best, bestRank, bestD = m, rank, d
                    end
                end
            end
        end
    end
    if not best then return end
    local ev = remote("InteractPromptEvent")
    if not ev then return end
    local tr = tries[best] or { n = 0, last = 0 }
    if tr.n >= 5 then tr.n = 0 end
    tr.n += 1; tr.last = t
    tries[best] = tr
    lastFire = t
    local arg = best:FindFirstChild("Argument")
    pcall(function() ev:FireServer(arg.Value, best) end)
end

-- a drop that shows up right where you just let go of that same item is yours: leave it
local function onDropAdded(m)
    local n = baseName(m.Name)
    local at = lostAt[n]
    if at and os.clock() - at < 4 then
        task.defer(function()
            local root = myRoot()
            local p = rootPos(m)
            if root and p and (p - root.Position).Magnitude < 25 then ignored[m] = true end
        end)
    end
end

------------------------------------------------------------------ auto trash
local trashOk   = setmetatable({}, { __mode = "k" })   -- tools that arrived while Auto Trash was on
local seenTool  = setmetatable({}, { __mode = "k" })   -- every tool ever seen (equipping re-adds it)
local lastTrash = 0

local function toolRank(t)
    local r = t:FindFirstChild("Rarity")
    local s = r and r:IsA("StringValue") and r.Value or t:GetAttribute("Rarity") or "Common"
    return RANK[string.lower(tostring(s))] or 1
end

local function shouldTrash(t)
    if not t:IsA("Tool") then return false end
    if CFG.onlyNew and not trashOk[t] then return false end
    if t:GetAttribute("Favorited") then return false end
    if t:FindFirstChild("CannotBeDropped") then return false end
    local enh = t:GetAttribute("Enhancements")
    if type(enh) == "string" and enh ~= "" then return false end
    local rank, cat = toolRank(t), toolCategory(t)
    local rule = anyMatch(CFG.trashRules, t.Name, cat, rank)
    if not rule then return false end
    -- Legendary+ and class currencies only go when a rule names the item itself
    if (rank >= 5 or PROTECT[baseName(t.Name)]) and not rule.name then return false end
    return true
end

local function trashStep()
    if not CFG.trash or #CFG.trashRules == 0 then return end
    local t = os.clock()
    if t - lastTrash < 1 then return end
    if LP:GetAttribute("GearRestoring") == true then return end
    local bag = LP:FindFirstChild("Backpack")
    local ev = remote("TrashItemsEvent")
    if not (bag and ev) then return end
    local list, names = {}, {}
    for _, tool in ipairs(bag:GetChildren()) do     -- Backpack only: never what you're holding
        if #list >= 20 then break end
        if shouldTrash(tool) then list[#list + 1] = tool; names[#names + 1] = tool.Name end
    end
    if #list == 0 then return end
    lastTrash = t
    pcall(function() ev:FireServer(list) end)
    log.info("[Loot] trashed " .. table.concat(names, ", "))
end

------------------------------------------------------------------ lifecycle
local function hookBag(bag)
    if not bag then return end
    for _, t in ipairs(bag:GetChildren()) do seenTool[t] = true; pcall(learnTool, t) end
    if LP.Character then for _, t in ipairs(LP.Character:GetChildren()) do seenTool[t] = true end end
    conns[#conns + 1] = bag.ChildAdded:Connect(function(t)
        if not seenTool[t] then
            seenTool[t] = true
            if CFG.trash then trashOk[t] = true end
        end
        task.delay(0.5, function() pcall(learnTool, t) end)   -- Rarity / tags settle a beat later
    end)
    conns[#conns + 1] = bag.ChildRemoved:Connect(function(t)
        if t:IsA("Tool") and not (LP.Character and t.Parent == LP.Character) then
            lostAt[baseName(t.Name)] = os.clock()
        end
    end)
end

local function anyOn() return CFG.pickup or CFG.trash end

function Loot.start()
    if running then return end
    running = true
    hookBag(LP:FindFirstChild("Backpack"))
    conns[#conns + 1] = LP.ChildAdded:Connect(function(c)
        if c.Name == "Backpack" then hookBag(c) end
    end)
    conns[#conns + 1] = LP.CharacterAdded:Connect(function(ch)
        conns[#conns + 1] = ch.ChildRemoved:Connect(function(t)
            if t:IsA("Tool") and t.Parent ~= LP:FindFirstChild("Backpack") then
                lostAt[baseName(t.Name)] = os.clock()    -- dropped from your hand (Backspace)
            end
        end)
    end)
    if LP.Character then
        conns[#conns + 1] = LP.Character.ChildRemoved:Connect(function(t)
            if t:IsA("Tool") and t.Parent ~= LP:FindFirstChild("Backpack") then
                lostAt[baseName(t.Name)] = os.clock()
            end
        end)
    end
    local drops = Workspace:FindFirstChild("Drops")
    if drops then conns[#conns + 1] = drops.ChildAdded:Connect(onDropAdded) end
    task.spawn(function()
        while running do
            pcall(pickupStep)
            pcall(trashStep)
            task.wait(0.1)
        end
    end)
end

function Loot.stop()
    running = false
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)
end

local function refresh()
    if anyOn() then Loot.start() else Loot.stop() end
end

function Loot.loadSaved()
    local ok, s = pcall(persist.get, "veil.loot.learned_cats")
    if ok and type(s) == "string" then
        for n, c in string.gmatch(s, "([^=;]+)=([^;]+)") do learnedCat[n] = c end
    end
end

function Loot.pickupFeature()
    return {
        id          = "veil.auto_pickup",
        name        = "Auto Pickup",
        description = "Picks up drops within reach for you, and it picks the exact item your filter wants even when it's buried in a pile (the game's E only grabs the nearest one). Pickup filter = what to grab; leave it empty to grab everything. Rules are separated by commas: a category (Weapons, Summons, Accessories, Outfits, Potions, Tomes, Gems, Items, Trinkets), an item name, or 'any', each optionally followed by a grade: 'Elite' = exactly Elite, 'Elite+' = Elite or better. Example: Tomes Elite+, Evasion Scarf, Legendary+. Never pick up = same rules, for things to leave on the ground (wins over the pickup filter). Anything you drop yourself is left alone. Reach = how close a drop has to be (10 = the game's own prompt reach).",
        default     = false,
        onToggle    = function(v) CFG.pickup = v and true or false; refresh() end,
        settings = {
            { type = "textbox", name = "Pickup filter (empty = everything)", key = "rules",
              placeholder = "Tomes Elite+, Evasion Scarf, Legendary+", default = "",
              onChange = function(v) CFG.pickRules = parseRules(v) end },
            { type = "textbox", name = "Never pick up", key = "skip",
              placeholder = "Trinkets Common, Hiveling Arm", default = "",
              onChange = function(v) CFG.skipRules = parseRules(v) end },
            { type = "toggle", name = "Pick up silver", key = "silver", default = true,
              onChange = function(v) CFG.silver = v and true or false end },
            { type = "slider", name = "Reach (studs)", key = "range", min = 4, max = 10, step = 0.5, default = 10,
              onChange = function(v) CFG.range = v end },
        },
    }
end

function Loot.trashFeature()
    return {
        id          = "veil.auto_trash",
        name        = "Auto Trash",
        description = "Trashes Backpack items that match your trash filter, the same way the inventory's trash slot does (a few at a time, once a second). Uses the same rules as Auto Pickup, e.g. Trinkets Common, Weapons Uncommon, Hiveling Arm. Never touches favourited items, enhanced items, whatever you're holding, or items the game won't let you drop. Legendary+ items, Stone Accords and Idols of Hatred only go if a rule names that exact item. Only new items = only trash things you get after turning this on, so nothing already in your bag is at risk.",
        default     = false,
        onToggle    = function(v) CFG.trash = v and true or false; refresh() end,
        settings = {
            { type = "textbox", name = "Trash filter", key = "rules",
              placeholder = "Trinkets Common, Weapons Uncommon", default = "",
              onChange = function(v) CFG.trashRules = parseRules(v) end },
            { type = "toggle", name = "Only new items", key = "only_new", default = true,
              onChange = function(v) CFG.onlyNew = v and true or false end },
        },
    }
end

Loot._parseRules = parseRules     -- mocktest hooks
Loot._anyMatch   = anyMatch
Loot._dropCategory = dropCategory

return Loot
