-- The Veil: Auto Pickup + Auto Trash, with their own "Veil Loot" menu.
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
--   * The prompt's name colour is generated from the drop's Rarity value (RarityAnim), so
--     reading Rarity = reading the colour.
--
-- The menu (user: "select from a list of known items instead of typing it in"):
--   * By category: one grade picker per inventory tab (Tomes -> Elite+ etc.).
--   * Items: a searchable list of every known item; click one to cycle its state
--     (pickup list: Pick / Never, trash list: Trash / Keep). An item's own state beats
--     its category's grade.
-- Known items = the fan Trello's item lists (name, tab, grade) plus everything this sees on
-- the ground or in your Backpack (saved), so the list grows as you play.

local Players   = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RS        = game:GetService("ReplicatedStorage")

local log        = require("core.log")
local persist    = require("core.persist")
local window     = require("ui.window")
local container  = require("ui.container")
local feature    = require("ui.feature")
local components = require("ui.components")
local theme      = require("ui.theme")

local LP = Players.LocalPlayer

local Loot = {}

local CFG = {
    pickup  = false,
    silver  = true,
    range   = 10,      -- the game's own prompt reach
    trash   = false,
    onlyNew = true,    -- trash only items that arrive after Auto Trash is on
}

-- the game's own tier order (InventoryGui.Handler sort table)
local TIERS = { "Common", "Uncommon", "Rare", "Elite", "Legendary", "Mythic", "Godly", "Christmas", "Unobtainable" }
local RANK = {}
for i, t in ipairs(TIERS) do RANK[string.lower(t)] = i end
-- RarityAnim colours (prompt text)
local TIER_COLOR = {
    Common = Color3.fromRGB(255, 255, 255), Uncommon = Color3.fromRGB(30, 255, 0),
    Rare = Color3.fromRGB(0, 112, 255), Elite = Color3.fromRGB(163, 53, 238),
    Legendary = Color3.fromRGB(255, 128, 0), Mythic = Color3.fromRGB(255, 0, 0),
    Godly = Color3.fromRGB(255, 0, 0),
}

local CATEGORIES = { "Weapons", "Summons", "Accessories", "Outfits", "Potions", "Tomes", "Gems",
                     "Items", "Trinkets", "Other" }

-- Grade pickers. Pickup: "Off" / "Any" / "<tier>+". Trash: "Off" / "<tier> & below" (never
-- above Elite: Legendary+ only goes when you mark that exact item).
local PICK_GRADES  = { "Any", "Off", "Uncommon+", "Rare+", "Elite+", "Legendary+", "Mythic+" }
local TRASH_GRADES = { "Off", "Common", "Uncommon & below", "Rare & below", "Elite & below" }

-- fan Trello item lists: { name, tab, grade } (Melee + Magic = Weapons)
local KNOWN = {
    { "Accursed Robes", "Outfits", "Elite" },
    { "Aegis Banner", "Items", "Rare" },
    { "Aglet", "Accessories", "Common" },
    { "Amulet", "Trinkets", "Common" },
    { "Anklet Of Wind", "Accessories", "Rare" },
    { "Aquamarine", "Gems", "Elite" },
    { "Arcane Rune", "Accessories", "Rare" },
    { "Armageddon", "Weapons", "Legendary" },
    { "Auroran Lance", "Weapons", "Rare" },
    { "Azure Ruby", "Gems", "Elite" },
    { "Backpack", "Accessories", "Uncommon" },
    { "Bag", "Items", "Common" },
    { "Balloon", "Accessories", "Uncommon" },
    { "Band Of Stamina", "Accessories", "Uncommon" },
    { "Band of Efficiency", "Accessories", "Rare" },
    { "Bare Blade", "Weapons", "Uncommon" },
    { "Basher", "Weapons", "Uncommon" },
    { "Biome Blade", "Weapons", "Elite" },
    { "Black Belt", "Accessories", "Rare" },
    { "Blacksmith's Kit", "Outfits", "Rare" },
    { "Bladecrest Oathsword", "Weapons", "Rare" },
    { "Blood", "Gems", "Rare" },
    { "Blood Pact", "Accessories", "Elite" },
    { "Bone Gauntlet", "Accessories", "Uncommon" },
    { "Bonesaber", "Weapons", "Uncommon" },
    { "Brain of Confusion", "Accessories", "Elite" },
    { "Breaker Blade", "Weapons", "Elite" },
    { "Brewery Staff", "Items", "Elite" },
    { "Brimlash", "Weapons", "Elite" },
    { "Burdenmail", "Outfits", "Elite" },
    { "Butcherer", "Weapons", "Rare" },
    { "Candlewick", "Weapons", "Elite" },
    { "Carnage", "Weapons", "Legendary" },
    { "Catapult", "Summons", "Uncommon" },
    { "Chaos Stone", "Accessories", "Legendary" },
    { "Chestplate", "Accessories", "Uncommon" },
    { "Cloud In A Bottle", "Accessories", "Uncommon" },
    { "Cobalt Kunai", "Weapons", "Rare" },
    { "Collared Tunic", "Outfits", "Rare" },
    { "Cowl", "Accessories", "Common" },
    { "Crescent Vigil", "Weapons", "Rare" },
    { "Crimson Cowl", "Outfits", "Elite" },
    { "Crusader Curiass", "Outfits", "Elite" },
    { "Cursed Hammer", "Weapons", "Elite" },
    { "Cyst Worm", "Accessories", "Rare" },
    { "DPS Meter", "Accessories", "Rare" },
    { "Dagger", "Weapons", "Common" },
    { "Dark Amulet", "Accessories", "Rare" },
    { "Deadlight", "Weapons", "Elite" },
    { "Deadweight", "Accessories", "Elite" },
    { "Decaying Spine", "Accessories", "Rare" },
    { "Desecrated Carapace", "Outfits", "Elite" },
    { "Diamond", "Gems", "Uncommon" },
    { "Diamond Staff", "Weapons", "Uncommon" },
    { "Disco Ball", "Accessories", "Rare" },
    { "Divine Topaz", "Gems", "Legendary" },
    { "Dread's Decree", "Weapons", "Elite" },
    { "Ebon Cloak", "Outfits", "Rare" },
    { "Elegy Of The Tides", "Weapons", "Legendary" },
    { "Ember Cloak", "Outfits", "Rare" },
    { "Emerald", "Gems", "Uncommon" },
    { "Emerald Staff", "Weapons", "" },
    { "Enchanted Sword", "Weapons", "Elite" },
    { "Evasion Scarf", "Accessories", "Elite" },
    { "Experimental Chemist", "Outfits", "Elite" },
    { "Explorer Hat", "Accessories", "" },
    { "Extraterrestrial Transmitter", "Summons", "Elite" },
    { "Fabled Crown", "Accessories", "Elite" },
    { "Fairy Light", "Accessories", "Rare" },
    { "Festered Meat", "Items", "Elite" },
    { "Festered Shield", "Accessories", "Rare" },
    { "Fighter Gi", "Outfits", "Rare" },
    { "Fire Essence", "Items", "Rare" },
    { "Firework", "Items", "Uncommon" },
    { "Fissure's Agility", "Outfits", "Rare" },
    { "Fissure's Protection", "Outfits", "Rare" },
    { "Flare Bolt", "Weapons", "Rare" },
    { "Flask Of Grace", "Potions", "Rare" },
    { "Flesh Knuckles", "Accessories", "Elite" },
    { "Flint Cutlass", "Weapons", "Uncommon" },
    { "Floaty", "Accessories", "Uncommon" },
    { "Fork Of Doom", "Weapons", "Rare" },
    { "Formal Attire", "Outfits", "" },
    { "Formal Finery", "Outfits", "Rare" },
    { "Frigid Mallet", "Weapons", "Uncommon" },
    { "Frost Dancer", "Weapons", "Elite" },
    { "Furystone", "Accessories", "Rare" },
    { "Gem Crusher", "Weapons", "Rare" },
    { "Gentleman's Fedora", "Accessories", "Uncommon" },
    { "Geode Dagger", "Weapons", "Uncommon" },
    { "Giant Smiley Bomb", "Items", "Elite" },
    { "Gilded Diamond Timepiece", "Accessories", "Legendary" },
    { "Gladiator's Locket", "Accessories", "Rare" },
    { "Gloomhook", "Weapons", "Rare" },
    { "Goblet", "Trinkets", "Common" },
    { "Goblin Scepter", "Summons", "Elite" },
    { "Golden Beetle", "Accessories", "Rare" },
    { "Greatsword", "Weapons", "Common" },
    { "Hardened Cloak", "Outfits", "Uncommon" },
    { "Health Potion", "Potions", "Common" },
    { "Heaven's Lament", "Summons", "" },
    { "Heavy Scale", "Outfits", "Rare" },
    { "Hell pauldron", "Accessories", "Elite" },
    { "Hellspiller", "Weapons", "Elite" },
    { "Hermes Boots", "Accessories", "Uncommon" },
    { "Hexed Wraithblade", "Weapons", "Elite" },
    { "Hiveling Arm", "Weapons", "Uncommon" },
    { "Hoarapace", "Outfits", "Elite" },
    { "Ice Bolt", "Weapons", "Rare" },
    { "Icepiercer", "Weapons", "Rare" },
    { "Idol of Hatred", "Items", "Uncommon" },
    { "Imp Staff", "Summons", "Rare" },
    { "Inferno Fork", "Weapons", "Elite" },
    { "Influx Waver", "Weapons", "Elite" },
    { "Iridescent Gem", "Gems", "Legendary" },
    { "Ironskin Potion", "Potions", "Uncommon" },
    { "Ivory Shell", "Outfits", "Elite" },
    { "Jolly Striper", "Weapons", "Rare" },
    { "Keblade", "Weapons", "Rare" },
    { "Kiribachi", "Weapons", "Rare" },
    { "Lantern", "Accessories", "Common" },
    { "Lifeform Analyzer", "Accessories", "Rare" },
    { "Lucky Coin", "Accessories", "Legendary" },
    { "Magicial Harp", "Weapons", "Elite" },
    { "Magma Stone", "Accessories", "Rare" },
    { "Malignant Bane", "Weapons", "Elite" },
    { "Mana Flower", "Accessories", "Uncommon" },
    { "Melting Pot", "Weapons", "Rare" },
    { "Miasmic Blight", "Outfits", "Elite" },
    { "Midnight Fractal", "Weapons", "Rare" },
    { "Mindbreaker", "Weapons", "Elite" },
    { "Mourning Wake", "Weapons", "Elite" },
    { "Mournmight", "Weapons", "Elite" },
    { "Muramasa", "Weapons", "Uncommon" },
    { "Navy Tuskblade", "Weapons", "Uncommon" },
    { "Necronomical Scroll", "Accessories", "Elite" },
    { "Necronomical Skull", "Summons", "Rare" },
    { "Negative Cap", "Accessories", "Elite" },
    { "Night Raiment", "Outfits", "Elite" },
    { "Night Stone", "Accessories", "Rare" },
    { "Night Weave", "Outfits", "Elite" },
    { "Nightcall Potion", "Potions", "Rare" },
    { "Nimble Ward", "Outfits", "Rare" },
    { "Nimbus Rod", "Summons", "Rare" },
    { "Noble Longsword", "Weapons", "Uncommon" },
    { "Occult Skull Crown", "Accessories", "Elite" },
    { "Old Amulet", "Trinkets", "Common" },
    { "Old Ring", "Trinkets", "Common" },
    { "Omniwarp", "Items", "Mythic" },
    { "Onyx", "Gems", "Elite" },
    { "Opal", "Gems", "Elite" },
    { "Pale Vanguard", "Outfits", "Elite" },
    { "Philosopher's Stone", "Accessories", "Elite" },
    { "Pillarfall", "Weapons", "Elite" },
    { "Portable Harmonic Fleshing", "Accessories", "Elite" },
    { "Power Cell", "Accessories", "Rare" },
    { "Power Glove", "Accessories", "Elite" },
    { "Prosthetic Arm", "Accessories", "Elite" },
    { "Putrid Scent", "Accessories", "Rare" },
    { "Pygmy Necklace", "Accessories", "Rare" },
    { "Quicksilver", "Weapons", "Rare" },
    { "Radar", "Accessories", "Rare" },
    { "Rage Pelt", "Outfits", "Rare" },
    { "Ragged Cloth", "Accessories", "Common" },
    { "Rags", "Outfits", "Common" },
    { "Rampaging Ribcage", "Accessories", "Legendary" },
    { "Ranger Tunic", "Outfits", "Rare" },
    { "Rapier", "Weapons", "Common" },
    { "Regeneration Potion", "Potions", "Uncommon" },
    { "Rimeblade", "Weapons", "Rare" },
    { "Ring", "Trinkets", "Common" },
    { "Ring Of Retribution", "Accessories", "Legendary" },
    { "Rosespike Staff", "Weapons", "" },
    { "Rot Gem", "Gems", "Rare" },
    { "Rot Polyp Wand", "Summons", "Rare" },
    { "Rover Drive", "Accessories", "Rare" },
    { "Ruby", "Gems", "Uncommon" },
    { "Ruby Staff", "Weapons", "Uncommon" },
    { "Runner Helmet", "Accessories", "Uncommon" },
    { "Runner's Handbook", "Accessories", "Rare" },
    { "Runner's Outfit", "Outfits", "Uncommon" },
    { "Sahara Slicer", "Weapons", "Uncommon" },
    { "Sanctifying Luminousness", "Outfits", "Legendary" },
    { "Sanguine Dirk", "Weapons", "Uncommon" },
    { "Sanguine Garb", "Outfits", "Rare" },
    { "Sanguine Vestments", "Outfits", "Elite" },
    { "Sanity Potion", "Potions", "Uncommon" },
    { "Saphire", "Gems", "Uncommon" },
    { "Sapphire Staff", "Weapons", "" },
    { "Scourge Of Disease", "Weapons", "Legendary" },
    { "Seraphim", "Weapons", "Legendary" },
    { "Shackles", "Accessories", "Rare" },
    { "Shades", "Accessories", "Uncommon" },
    { "Shadow Diamond", "Gems", "Legendary" },
    { "Shadowbeam Staff", "Weapons", "Elite" },
    { "Shadowflame Knife", "Weapons", "Elite" },
    { "Shako", "Accessories", "Elite" },
    { "Shatterpoint", "Weapons", "Elite" },
    { "Shiny Stone", "Accessories", "Rare" },
    { "Shrouded Tanto", "Weapons", "Elite" },
    { "Silver Aegis", "Outfits", "Elite" },
    { "Sky Garments", "Outfits", "Rare" },
    { "Smoldering Horn", "Items", "Elite" },
    { "Sorcerer's Mantle", "Outfits", "Rare" },
    { "Soul Ringer", "Weapons", "Elite" },
    { "Soul Shroud", "Outfits", "Legendary" },
    { "Soul Silencer", "Weapons", "Rare" },
    { "Sovereign", "Weapons", "Rare" },
    { "Spear", "Weapons", "Common" },
    { "Spellweaver", "Weapons", "Legendary" },
    { "Spider Silk", "Outfits", "Elite" },
    { "Spore Sac", "Accessories", "Elite" },
    { "Staff Of Sparkling", "Weapons", "Common" },
    { "Staff Of The False Sun", "Weapons", "Legendary" },
    { "Staff Of Voidmending", "Summons", "Legendary" },
    { "Stamina Regeneration Potion", "Potions", "Uncommon" },
    { "Star Fruit", "Items", "Rare" },
    { "Star Gem", "Gems", "Rare" },
    { "Starfish", "Accessories", "Uncommon" },
    { "Starfury", "Weapons", "Rare" },
    { "Stone Accord", "Items", "Uncommon" },
    { "Storm Ruler", "Weapons", "Rare" },
    { "Suite", "Outfits", "Elite" },
    { "Summon Rune", "Accessories", "Rare" },
    { "Suniron", "Weapons", "Rare" },
    { "Surgecloth", "Outfits", "Elite" },
    { "Suspicious Boulder", "Summons", "Elite" },
    { "Suspicious Invitation", "Items", "Elite" },
    { "Swiftness Potion", "Potions", "Uncommon" },
    { "Sword", "Weapons", "Common" },
    { "Tainted Elixir", "Accessories", "Elite" },
    { "Tesla", "Items", "Rare" },
    { "Testament's Edge", "Weapons", "Rare" },
    { "The Angry Mask", "Accessories", "Elite" },
    { "The Bell", "Accessories", "Elite" },
    { "The Convergence", "Accessories", "Mythic" },
    { "The Dice", "Accessories", "Legendary" },
    { "The First Light", "Items", "" },
    { "The Laughing Mask", "Accessories", "Elite" },
    { "The Sleeping Mask", "Accessories", "Elite" },
    { "The Weeping Mask", "Accessories", "Elite" },
    { "The Weightless Crown", "Accessories", "Legendary" },
    { "Thick Cloak", "Outfits", "Uncommon" },
    { "Thief's Gear", "Outfits", "Uncommon" },
    { "Thin Hide", "Outfits", "Common" },
    { "Thunder Quartz", "Items", "Rare" },
    { "Tidal Anchor", "Weapons", "Rare" },
    { "Topaz", "Gems", "Uncommon" },
    { "Topaz Staff", "Weapons", "Uncommon" },
    { "Tophat", "Accessories", "Uncommon" },
    { "Tribal Visage", "Accessories", "Elite" },
    { "Trinkets", "Items", "" },
    { "Turtle Shell", "Accessories", "Elite" },
    { "Unyielding Darkness", "Outfits", "Legendary" },
    { "Vampiric Talisman", "Accessories", "Legendary" },
    { "Veering Wind", "Weapons", "Rare" },
    { "Veil's Aberration", "Outfits", "Legendary" },
    { "Venom Fang", "Weapons", "Rare" },
    { "Verdant Thorn", "Weapons", "" },
    { "Viperpoint", "Weapons", "Rare" },
    { "Voidlance", "Weapons", "Elite" },
    { "Wanderer's Blade", "Weapons", "Uncommon" },
    { "Water Bolt", "Weapons", "Rare" },
    { "Weeping Sore", "Weapons", "Elite" },
    { "Whoopie Cushion", "Items", "Common" },
    { "Willow Lantern", "Summons", "Rare" },
    { "Wind Blade", "Weapons", "Uncommon" },
    { "Witchlight", "Weapons", "Elite" },
    { "Withersting", "Weapons", "Elite" },
    { "Wrath Potion", "Potions", "Uncommon" },
}

------------------------------------------------------------------ item catalogue
local items = {}          -- lower name -> { name, cat, rarity }
local function baseName(name) return (string.gsub(string.lower(name), "^enhanced ", "")) end
local function displayBase(name) return (string.gsub(name, "^Enhanced ", "")) end

for _, k in ipairs(KNOWN) do
    items[string.lower(k[1])] = { name = k[1], cat = k[2], rarity = k[3] ~= "" and k[3] or nil, known = true }
end

local SAVE_ITEMS = "veil.loot.items"
local saveQueued = false
local function saveItems()
    if saveQueued then return end
    saveQueued = true
    task.delay(2, function()
        saveQueued = false
        local parts = {}
        for _, it in pairs(items) do
            if it.learned then parts[#parts + 1] = it.name .. "|" .. (it.cat or "") .. "|" .. (it.rarity or "") end
        end
        table.sort(parts)
        pcall(persist.set, SAVE_ITEMS, table.concat(parts, ";"))
    end)
end

local listDirty = false
-- learn/refresh an item; cat or rarity may be nil (unknown)
local function noteItem(name, cat, rarity)
    local n = baseName(name)
    local it = items[n]
    if not it then
        it = { name = displayBase(name) }
        items[n] = it
        listDirty = true
    end
    local changed = false
    if cat and cat ~= "Other" and it.cat ~= cat then it.cat = cat; changed = true end
    if rarity and it.rarity ~= rarity then it.rarity = rarity; changed = true end
    if changed then it.learned = true; listDirty = true; saveItems() end
    return it
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

local function toolRarity(t)
    local r = t:FindFirstChild("Rarity")
    local s = r and r:IsA("StringValue") and r.Value or t:GetAttribute("Rarity")
    return (s and s ~= "") and tostring(s) or "Common"
end

local function dropRarity(m)
    local rv = m:GetAttribute("Rarity")
    if rv == nil then
        local c = m:FindFirstChild("Rarity")
        rv = c and c:IsA("StringValue") and c.Value or "Common"
    end
    return tostring(rv)
end

local function dropCategory(m)
    local at = m:FindFirstChild("AtTrinketSpawn")
    if at and at:IsA("BoolValue") and at.Value then return "Trinkets" end
    local it = items[baseName(m.Name)]
    if it and it.cat then return it.cat end
    if string.find(string.lower(m.Name), "tome", 1, true) then return "Tomes" end
    return "Other"
end

------------------------------------------------------------------ rules (menu state)
-- lists.pick / lists.trash = { cats = { [cat] = grade }, items = { [lower name] = state } }
local lists = {
    pick  = { cats = {}, items = {} },
    trash = { cats = {}, items = {} },
}
for _, c in ipairs(CATEGORIES) do lists.pick.cats[c] = "Any"; lists.trash.cats[c] = "Off" end

local function saveList(which)
    local l = lists[which]
    local cp, ip = {}, {}
    for c, g in pairs(l.cats) do cp[#cp + 1] = c .. "=" .. g end
    for n, st in pairs(l.items) do ip[#ip + 1] = n .. "=" .. st end
    pcall(persist.set, "veil.loot." .. which .. ".cats", table.concat(cp, ";"))
    pcall(persist.set, "veil.loot." .. which .. ".items", table.concat(ip, ";"))
end

local function loadList(which)
    local l = lists[which]
    local ok, s = pcall(persist.get, "veil.loot." .. which .. ".cats")
    if ok and type(s) == "string" then
        for c, g in string.gmatch(s, "([^=;]+)=([^;]+)") do l.cats[c] = g end
    end
    local ok2, s2 = pcall(persist.get, "veil.loot." .. which .. ".items")
    if ok2 and type(s2) == "string" then
        for n, st in string.gmatch(s2, "([^=;]+)=([^;]+)") do l.items[n] = st end
    end
end

-- "Rare+" -> 3 ; "Any" -> 1 ; "Off" -> nil
local function pickMin(g)
    if g == "Any" then return 1 end
    local t = g and string.match(g, "^(%a+)%+$")
    return t and RANK[string.lower(t)] or nil
end
-- "Uncommon & below" -> 2 ; "Common" -> 1 ; "Off" -> nil
local function trashMax(g)
    if g == "Common" then return 1 end
    local t = g and string.match(g, "^(%a+) & below$")
    return t and RANK[string.lower(t)] or nil
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

-- -> rank to grab it with, or nil
local function wantDrop(m)
    local arg = m:FindFirstChild("Argument")
    if not (arg and m:FindFirstChild("IsInteractable")) then return nil end
    if arg.Value == "PickupSilver" then return CFG.silver and 0 or nil end
    if arg.Value ~= "PickupDrop" then return nil end
    local rarity = dropRarity(m)
    local rank = RANK[string.lower(rarity)] or 1
    local st = lists.pick.items[baseName(m.Name)]
    if st == "never" then return nil end
    if st == "pick" then return rank + 100 end           -- marked items first
    local min = pickMin(lists.pick.cats[dropCategory(m)])
    return (min and rank >= min) and rank or nil
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

local function onDropAdded(m)
    -- learn its name + grade for the menu (after the Rarity attribute settles)
    task.delay(0.5, function()
        if m.Parent then
            local arg = m:FindFirstChild("Argument")
            if arg and arg.Value == "PickupDrop" then
                local cat = dropCategory(m)
                noteItem(m.Name, cat ~= "Other" and cat or nil, dropRarity(m))
            end
        end
    end)
    -- a drop that shows up right where you just let go of that same item is yours: leave it
    local at = lostAt[baseName(m.Name)]
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

-- Never trashed by a category grade, only when you mark the item itself: class currencies.
local PROTECT = { ["stone accord"] = true, ["idol of hatred"] = true }

local function shouldTrash(t)
    if not t:IsA("Tool") then return false end
    if CFG.onlyNew and not trashOk[t] then return false end
    if t:GetAttribute("Favorited") then return false end
    if t:FindFirstChild("CannotBeDropped") then return false end
    local enh = t:GetAttribute("Enhancements")
    if type(enh) == "string" and enh ~= "" then return false end
    local n = baseName(t.Name)
    local st = lists.trash.items[n]
    if st == "keep" then return false end
    if st == "trash" then return true end
    if PROTECT[n] then return false end
    local max = trashMax(lists.trash.cats[toolCategory(t)])
    local rank = RANK[string.lower(toolRarity(t))] or 1
    return max ~= nil and rank <= max and rank <= RANK.elite
end

local function trashStep()
    if not CFG.trash then return end
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
local function learnTool(t)
    if t:IsA("Tool") then noteItem(t.Name, toolCategory(t), toolRarity(t)) end
end

local function watchLostFrom(parent, isBag)
    conns[#conns + 1] = parent.ChildRemoved:Connect(function(t)
        if not t:IsA("Tool") then return end
        local bag = LP:FindFirstChild("Backpack")
        -- moving between hand and bag isn't losing it
        if (isBag and LP.Character and t.Parent == LP.Character) or (not isBag and t.Parent == bag) then return end
        lostAt[baseName(t.Name)] = os.clock()
    end)
end

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
    watchLostFrom(bag, true)
end

local function anyOn() return CFG.pickup or CFG.trash end

function Loot.start()
    if running then return end
    running = true
    hookBag(LP:FindFirstChild("Backpack"))
    conns[#conns + 1] = LP.ChildAdded:Connect(function(c)
        if c.Name == "Backpack" then hookBag(c) end
    end)
    conns[#conns + 1] = LP.CharacterAdded:Connect(function(ch) watchLostFrom(ch, false) end)
    if LP.Character then watchLostFrom(LP.Character, false) end
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

------------------------------------------------------------------ menu
local STATE_CYCLE = { pick = { false, "pick", "never" }, trash = { false, "trash", "keep" } }
local STATE_LOOK = {
    pick  = { label = "PICK",  color = Color3.fromRGB(60, 222, 60) },
    never = { label = "NEVER", color = Color3.fromRGB(222, 60, 60) },
    trash = { label = "TRASH", color = Color3.fromRGB(222, 60, 60) },
    keep  = { label = "KEEP",  color = Color3.fromRGB(60, 222, 60) },
}
local MAX_ROWS = 40

local ui = { mode = "pick", search = "", catFilter = "All", show = "All items" }

-- none -> first mark -> second mark -> none
local function nextState(which, cur)
    local cyc = STATE_CYCLE[which]
    local i = 1
    for k = 1, 3 do if (cyc[k] or nil) == cur then i = k end end
    return cyc[(i % 3) + 1] or nil
end

local function newList(parent)
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, 0, 0, 0)
    f.AutomaticSize = Enum.AutomaticSize.Y
    f.BackgroundTransparency = 1
    f.Parent = parent
    local l = Instance.new("UIListLayout", f)
    l.SortOrder = Enum.SortOrder.LayoutOrder
    l.Padding = UDim.new(0, theme.rowGap or 1)
    return f
end

-- give each row of a list its creation order (components don't set LayoutOrder)
local function stamp(parent, obj)
    local root = type(obj) == "table" and obj.frame or obj
    local n = 0
    for _, c in ipairs(parent:GetChildren()) do if c:IsA("GuiObject") then n += 1 end end
    if root then root.LayoutOrder = n end
    return obj
end

local catHost, itemHost, countLabel
local rebuildItems

local function rebuildCats()
    if not catHost then return end
    for _, c in ipairs(catHost:GetChildren()) do if c:IsA("GuiObject") then c:Destroy() end end
    local which = ui.mode
    local opts = which == "pick" and PICK_GRADES or TRASH_GRADES
    for _, cat in ipairs(CATEGORIES) do
        stamp(catHost, components.Dropdown(catHost, {
            label = cat == "Other" and "Other / unknown" or cat,
            options = opts,
            default = lists[which].cats[cat],
            onChange = function(v)
                lists[which].cats[cat] = v
                saveList(which)
            end,
        }))
    end
end

local function itemRow(parent, it, which, idx)
    local n = string.lower(it.name)
    local row = Instance.new("TextButton")
    row.Size = UDim2.new(1, 0, 0, 22)
    row.BackgroundColor3 = theme.bgAlt
    row.BorderSizePixel = 0
    row.AutoButtonColor = true
    row.Text = ""
    row.LayoutOrder = idx
    row.Parent = parent

    local name = Instance.new("TextLabel")
    name.Size = UDim2.new(1, -60, 1, 0)
    name.Position = UDim2.fromOffset(8, 0)
    name.BackgroundTransparency = 1
    name.Font = theme.font
    name.TextSize = 11
    name.TextXAlignment = Enum.TextXAlignment.Left
    name.TextTruncate = Enum.TextTruncate.AtEnd
    name.Text = it.name
    name.TextColor3 = TIER_COLOR[it.rarity or ""] or theme.fgDim
    name.Parent = row

    local tag = Instance.new("TextLabel")
    tag.Size = UDim2.new(0, 50, 1, 0)
    tag.Position = UDim2.new(1, -54, 0, 0)
    tag.BackgroundTransparency = 1
    tag.Font = theme.fontBold
    tag.TextSize = 10
    tag.TextXAlignment = Enum.TextXAlignment.Right
    tag.Parent = row

    local function paint()
        local st = lists[which].items[n]
        local look = st and STATE_LOOK[st]
        tag.Text = look and look.label or ""
        tag.TextColor3 = look and look.color or theme.fgDim
    end
    paint()
    row.MouseButton1Click:Connect(function()
        lists[which].items[n] = nextState(which, lists[which].items[n])
        saveList(which)
        paint()
    end)
end

rebuildItems = function()
    if not itemHost then return end
    listDirty = false
    for _, c in ipairs(itemHost:GetChildren()) do if c:IsA("GuiObject") then c:Destroy() end end
    local which = ui.mode
    local q = string.lower(ui.search or "")
    local matches = {}
    for n, it in pairs(items) do
        local okCat = ui.catFilter == "All" or (it.cat or "Other") == ui.catFilter
        local okQ = q == "" or string.find(n, q, 1, true) ~= nil
        local okShow = ui.show == "All items" or lists[which].items[n] ~= nil
        if okCat and okQ and okShow then matches[#matches + 1] = it end
    end
    table.sort(matches, function(a, b)
        local ra, rb = RANK[string.lower(a.rarity or "")] or 0, RANK[string.lower(b.rarity or "")] or 0
        if ra ~= rb then return ra > rb end
        return a.name < b.name
    end)
    for i = 1, math.min(#matches, MAX_ROWS) do itemRow(itemHost, matches[i], which, i) end
    if countLabel then
        countLabel.Text = #matches > MAX_ROWS
            and ("showing " .. MAX_ROWS .. " of " .. #matches .. ", search to narrow")
            or (#matches .. " item" .. (#matches == 1 and "" or "s"))
    end
end

local function buildEditor(parent)
    local root = newList(parent)

    stamp(root, components.Section(root, "Editing"))
    stamp(root, components.Dropdown(root, {
        label = "List", options = { "Pickup", "Trash" }, default = "Pickup",
        onChange = function(v)
            ui.mode = v == "Trash" and "trash" or "pick"
            rebuildCats(); rebuildItems()
        end,
    }))

    stamp(root, components.Section(root, "By category"))
    catHost = stamp(root, newList(root))

    stamp(root, components.Section(root, "Items (click to mark)"))
    local search = stamp(root, components.TextBox(root, { label = "Search", placeholder = "item name" }))
    local box = search.frame:FindFirstChildWhichIsA("TextBox")
    if box then
        box:GetPropertyChangedSignal("Text"):Connect(function()
            ui.search = box.Text
            rebuildItems()
        end)
    end
    local catOpts = { "All" }
    for _, c in ipairs(CATEGORIES) do catOpts[#catOpts + 1] = c end
    stamp(root, components.Dropdown(root, {
        label = "Category", options = catOpts, default = "All",
        onChange = function(v) ui.catFilter = v; rebuildItems() end,
    }))
    stamp(root, components.Dropdown(root, {
        label = "Show", options = { "All items", "Marked only" }, default = "All items",
        onChange = function(v) ui.show = v; rebuildItems() end,
    }))
    countLabel = stamp(root, components.Label(root, ""))
    itemHost = stamp(root, newList(root))

    rebuildCats()
    rebuildItems()
    -- new items seen in play show up in the list
    task.spawn(function()
        while itemHost and itemHost.Parent do
            task.wait(3)
            if listDirty then pcall(rebuildItems) end
        end
    end)
    return root
end

local function pickupFeature()
    return {
        id          = "veil.auto_pickup",
        name        = "Auto Pickup",
        description = "Picks up drops within reach for you, and grabs the exact item your list wants even when it's buried in a pile (the game's E only grabs the nearest one). What it grabs is set below in this menu: a grade per category (e.g. Tomes -> Elite+) and single items you mark PICK or NEVER (an item's mark beats its category). Marked items are grabbed first, then the highest grade. Anything you drop yourself is left alone. Reach = how close a drop has to be (10 = the game's own prompt reach).",
        default     = false,
        onToggle    = function(v) CFG.pickup = v and true or false; refresh() end,
        settings = {
            { type = "toggle", name = "Pick up silver", key = "silver", default = true,
              onChange = function(v) CFG.silver = v and true or false end },
            { type = "slider", name = "Reach (studs)", key = "range", min = 4, max = 10, step = 0.5, default = 10,
              onChange = function(v) CFG.range = v end },
        },
    }
end

local function trashFeature()
    return {
        id          = "veil.auto_trash",
        name        = "Auto Trash",
        description = "Trashes Backpack items the same way the inventory's trash slot does (a few at a time, once a second). What it trashes is set below in this menu (switch List to Trash): a grade per category (e.g. Trinkets -> Common) and single items you mark TRASH or KEEP. Never touches favourited items, enhanced items, whatever you're holding, or items the game won't let you drop. Categories only ever trash up to Elite; Legendary+ items, Stone Accords and Idols of Hatred only go if you mark that exact item TRASH. Only new items = only trash things you get after turning this on, so nothing already in your bag is at risk.",
        default     = false,
        onToggle    = function(v) CFG.trash = v and true or false; refresh() end,
        settings = {
            { type = "toggle", name = "Only new items", key = "only_new", default = true,
              onChange = function(v) CFG.onlyNew = v and true or false end },
        },
    }
end

function Loot.register()
    local ok, s = pcall(persist.get, SAVE_ITEMS)
    if ok and type(s) == "string" then
        for name, cat, rar in string.gmatch(s, "([^|;]+)|([^|;]*)|([^|;]*)") do
            local it = noteItem(name, cat ~= "" and cat or nil, rar ~= "" and rar or nil)
            it.learned = true
        end
    end
    loadList("pick")
    loadList("trash")
    local box = container.new(window.parent(), "Veil Loot")
    box:add(feature.declare(pickupFeature()).root)
    box:add(feature.declare(trashFeature()).root)
    box:add(buildEditor(box.features))
end

function Loot.destroy()
    Loot.stop()
    catHost, itemHost, countLabel = nil, nil, nil
end

Loot._nextState = nextState    -- mocktest hooks
Loot._pickMin   = pickMin
Loot._trashMax  = trashMax

return Loot
