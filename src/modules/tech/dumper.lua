-- Raw GUI + animation dumps, written to files, so move-bar detection and
-- move->animation mapping can be set up CORRECTLY per game instead of guessed.
-- Run in-game, then send the files:
--   pantheon_gui_dump.txt   -- every on-screen button (name/text/size/pos/path/children)
--   pantheon_anim_dump.txt  -- each animation you play (id + asset name)

local Players = game:GetService("Players")
local MPS     = game:GetService("MarketplaceService")

local Dumper = {}
local LP = Players.LocalPlayer
local hasWrite = (typeof(writefile) == "function")

function Dumper.dumpGui()
    local pg = LP:FindFirstChildOfClass("PlayerGui")
    local lines = { "=== Pantheon GUI dump ===" }
    local n = 0
    if pg then
        for _, sg in ipairs(pg:GetChildren()) do
            if sg:IsA("LayerCollector") or sg:IsA("GuiObject") or sg:IsA("Folder") then
                lines[#lines + 1] = "[" .. sg.ClassName .. "] " .. sg.Name ..
                    (sg:IsA("ScreenGui") and (" enabled=" .. tostring(sg.Enabled)) or "")
                local ok, descs = pcall(function() return sg:GetDescendants() end)
                if ok then
                    for _, d in ipairs(descs) do
                        if d:IsA("TextButton") or d:IsA("ImageButton") then
                            n = n + 1
                            local parts, cur = {}, d
                            while cur and cur ~= sg do table.insert(parts, 1, cur.Name); cur = cur.Parent end
                            local kids = {}
                            for _, c in ipairs(d:GetDescendants()) do
                                if c:IsA("TextLabel") then kids[#kids + 1] = "Lbl:" .. c.Name .. "='" .. tostring(c.Text) .. "'"
                                elseif c:IsA("ImageLabel") then kids[#kids + 1] = "Img:" .. c.Name end
                            end
                            lines[#lines + 1] = ("  %s '%s' txt='%s' size=%s pos=%s vis=%s img=%s\n      path=%s\n      kids=[%s]")
                                :format(d.ClassName, d.Name, (d:IsA("TextButton") and d.Text or ""),
                                    tostring(d.AbsoluteSize), tostring(d.AbsolutePosition), tostring(d.Visible),
                                    (d:IsA("ImageButton") and d.Image or "-"),
                                    table.concat(parts, "/"), table.concat(kids, ", "))
                        end
                    end
                end
            end
        end
    end
    local out = table.concat(lines, "\n")
    if hasWrite then pcall(writefile, "pantheon_gui_dump.txt", out) end
    print(out)
    return n
end

-- Static scan: grab EVERY Animation instance in the game (+ StringValues that
-- hold an asset id) with its FULL path (name -> parents -> grandparents via
-- GetFullName), so each animation can be mapped to its move. Immediate, no
-- play-logging. Writes pantheon_anim_dump.txt.
function Dumper.dumpAnims()
    local roots = {}
    for _, svc in ipairs({ "ReplicatedStorage", "ReplicatedFirst", "StarterPlayer", "Lighting" }) do
        local ok, s = pcall(function() return game:GetService(svc) end)
        if ok and s then roots[#roots + 1] = s end
    end
    roots[#roots + 1] = workspace
    if LP.Character then roots[#roots + 1] = LP.Character end

    local lines, seen, n = { "=== Pantheon animation dump (all Animation instances + asset StringValues) ===" }, {}, 0
    for _, root in ipairs(roots) do
        local ok, descs = pcall(function() return root:GetDescendants() end)
        if ok then
            for _, d in ipairs(descs) do
                local id
                if d:IsA("Animation") then
                    id = d.AnimationId
                elseif d:IsA("StringValue") and d.Value and
                       (string.find(d.Value, "rbxassetid", 1, true) or string.find(d.Value, "/asset", 1, true)) then
                    id = d.Value
                end
                if id and id ~= "" then
                    local full = d:GetFullName()
                    local key = full .. "|" .. id
                    if not seen[key] then
                        seen[key] = true; n = n + 1
                        lines[#lines + 1] = id .. "   " .. full
                    end
                end
            end
        end
    end
    local out = table.concat(lines, "\n")
    if hasWrite then pcall(writefile, "pantheon_anim_dump.txt", out) end
    print(out)
    return n
end

return Dumper
