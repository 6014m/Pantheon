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

local animConn, animLines, animSeen
function Dumper.animActive() return animConn ~= nil end

-- Toggle animation logging. While on, every NEW animation you play is appended to
-- pantheon_anim_dump.txt (id + asset name). Use each move once to capture it.
function Dumper.toggleAnims()
    if animConn then pcall(function() animConn:Disconnect() end); animConn = nil; return false end
    animLines, animSeen = { "=== Pantheon animation dump (use each move once) ===" }, {}
    local function hook(char)
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        local animator = hum and hum:FindFirstChildOfClass("Animator")
        if not animator then return end
        animConn = animator.AnimationPlayed:Connect(function(track)
            local id = track.Animation and track.Animation.AnimationId
            if not id or id == "" or animSeen[id] then return end
            animSeen[id] = true
            local name = ""
            local num = tonumber(string.match(id, "%d+"))
            if num then
                local ok, info = pcall(function() return MPS:GetProductInfo(num) end)
                if ok and info and info.Name then name = info.Name end
            end
            animLines[#animLines + 1] = id .. "   " .. name
            if hasWrite then pcall(writefile, "pantheon_anim_dump.txt", table.concat(animLines, "\n")) end
            print("[anim] " .. id .. "  " .. name)
        end)
    end
    hook(LP.Character)
    return true
end

return Dumper
