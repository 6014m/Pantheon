-- Raw GUI dump, written to file, so per-game hotbar/menu detection can be set
-- up CORRECTLY instead of guessed. Run in-game and send the file:
--   pantheon_gui_dump.txt   -- every on-screen button (name/text/size/pos/path/children/conn counts)
-- (The old static anim dumper has been removed -- the Tech Builder editor's
-- live anim logging covers it; see Engine.animHistory / captureAnim.)

local Players = game:GetService("Players")

local Dumper = {}
local LP = Players.LocalPlayer
local hasWrite = (typeof(writefile) == "function")

-- How many handlers are connected to a signal (so we can see what the game ACTUALLY
-- listens on -- Activated vs MouseButton1Down vs ... -- and fire the right one).
local function connCount(sig)
    if typeof(getconnections) ~= "function" then return "?" end
    local ok, cs = pcall(getconnections, sig)
    if ok and type(cs) == "table" then return tostring(#cs) end
    return "?"
end
local function btnConns(b)
    local out = {}
    pcall(function()
        out[#out + 1] = "Act=" .. connCount(b.Activated)
        out[#out + 1] = "MB1Click=" .. connCount(b.MouseButton1Click)
        out[#out + 1] = "MB1Down=" .. connCount(b.MouseButton1Down)
        out[#out + 1] = "InputBegan=" .. connCount(b.InputBegan)
    end)
    return table.concat(out, " ")
end

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
                                elseif c:IsA("ImageLabel") then kids[#kids + 1] = "Img:" .. c.Name
                                -- nested buttons + what THEY listen on (the real handler may be in here)
                                elseif c:IsA("TextButton") or c:IsA("ImageButton") then
                                    kids[#kids + 1] = "BTN:" .. c.ClassName .. ":" .. c.Name .. "{" .. btnConns(c) .. "}"
                                end
                            end
                            lines[#lines + 1] = ("  %s '%s' txt='%s' active=%s size=%s pos=%s vis=%s conns={%s}\n      path=%s\n      kids=[%s]")
                                :format(d.ClassName, d.Name, (d:IsA("TextButton") and d.Text or ""),
                                    tostring(d.Active), tostring(d.AbsoluteSize), tostring(d.AbsolutePosition),
                                    tostring(d.Visible), btnConns(d),
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

return Dumper
