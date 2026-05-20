-- Root Pantheon window: draggable, sidebar + content, tab API.

local env   = require("core.env")
local theme = require("ui.theme")

local UIS = game:GetService("UserInputService")

local window = {}

function window.new(title)
    local sg = Instance.new("ScreenGui")
    sg.Name = "PantheonGui"
    sg.IgnoreGuiInset = true
    sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    sg.ResetOnSpawn = false
    sg.Parent = env.guiParent()
    env.protectGui(sg)

    local root = Instance.new("Frame")
    root.Size = theme.windowSize
    root.Position = UDim2.fromScale(0.5, 0.5)
    root.AnchorPoint = Vector2.new(0.5, 0.5)
    root.BackgroundColor3 = theme.bg
    root.BorderSizePixel = 0
    root.Parent = sg
    Instance.new("UICorner", root).CornerRadius = theme.cornerRadius

    local stroke = Instance.new("UIStroke", root)
    stroke.Color = theme.border
    stroke.Thickness = 1

    -- Header
    local header = Instance.new("Frame")
    header.Size = UDim2.new(1, 0, 0, 36)
    header.BackgroundColor3 = theme.bgAlt
    header.BorderSizePixel = 0
    header.Parent = root
    Instance.new("UICorner", header).CornerRadius = theme.cornerRadius

    local headerMask = Instance.new("Frame")
    headerMask.Size = UDim2.new(1, 0, 0.5, 0)
    headerMask.Position = UDim2.new(0, 0, 0.5, 0)
    headerMask.BackgroundColor3 = theme.bgAlt
    headerMask.BorderSizePixel = 0
    headerMask.Parent = header

    local titleLabel = Instance.new("TextLabel")
    titleLabel.Size = UDim2.new(1, -52, 1, 0)
    titleLabel.Position = UDim2.fromOffset(12, 0)
    titleLabel.BackgroundTransparency = 1
    titleLabel.Text = title or "Pantheon"
    titleLabel.TextColor3 = theme.fg
    titleLabel.Font = theme.fontBold
    titleLabel.TextSize = 14
    titleLabel.TextXAlignment = Enum.TextXAlignment.Left
    titleLabel.Parent = header

    local closeBtn = Instance.new("TextButton")
    closeBtn.Size = UDim2.fromOffset(28, 28)
    closeBtn.Position = UDim2.new(1, -32, 0, 4)
    closeBtn.BackgroundColor3 = theme.bgDark
    closeBtn.BorderSizePixel = 0
    closeBtn.Text = "X"
    closeBtn.TextColor3 = theme.fg
    closeBtn.Font = theme.font
    closeBtn.TextSize = 13
    closeBtn.Parent = header
    Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 4)

    -- Sidebar
    local sidebar = Instance.new("Frame")
    sidebar.Size = UDim2.new(0, theme.sidebarWidth, 1, -36)
    sidebar.Position = UDim2.new(0, 0, 0, 36)
    sidebar.BackgroundColor3 = theme.bgDark
    sidebar.BorderSizePixel = 0
    sidebar.Parent = root

    local sidebarList = Instance.new("UIListLayout", sidebar)
    sidebarList.FillDirection = Enum.FillDirection.Vertical
    sidebarList.SortOrder = Enum.SortOrder.LayoutOrder
    sidebarList.Padding = UDim.new(0, 4)
    sidebarList.HorizontalAlignment = Enum.HorizontalAlignment.Center

    local sidebarPad = Instance.new("UIPadding", sidebar)
    sidebarPad.PaddingTop = UDim.new(0, 8)

    -- Content area
    local content = Instance.new("Frame")
    content.Size = UDim2.new(1, -theme.sidebarWidth, 1, -36)
    content.Position = UDim2.new(0, theme.sidebarWidth, 0, 36)
    content.BackgroundColor3 = theme.bg
    content.BorderSizePixel = 0
    content.Parent = root

    -- Drag
    do
        local dragging, dragStart, startPos = false, nil, nil
        header.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
               or input.UserInputType == Enum.UserInputType.Touch then
                dragging  = true
                dragStart = input.Position
                startPos  = root.Position
            end
        end)
        UIS.InputChanged:Connect(function(input)
            if not dragging then return end
            if input.UserInputType == Enum.UserInputType.MouseMovement
               or input.UserInputType == Enum.UserInputType.Touch then
                local delta = input.Position - dragStart
                root.Position = UDim2.new(
                    startPos.X.Scale, startPos.X.Offset + delta.X,
                    startPos.Y.Scale, startPos.Y.Offset + delta.Y
                )
            end
        end)
        UIS.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
               or input.UserInputType == Enum.UserInputType.Touch then
                dragging = false
            end
        end)
    end

    -- Tab state
    local tabs = {}
    local activeTab = nil

    local function selectTab(name)
        if activeTab == name then return end
        if activeTab then
            tabs[activeTab].page.Visible = false
            tabs[activeTab].button.BackgroundColor3 = theme.bgDark
            tabs[activeTab].button.TextColor3 = theme.fgDim
        end
        activeTab = name
        tabs[name].page.Visible = true
        tabs[name].button.BackgroundColor3 = theme.bgAlt
        tabs[name].button.TextColor3 = theme.fg
    end

    local self = {
        ScreenGui = sg,
        Root      = root,
        Content   = content,
    }

    function self:AddTab(name)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1, -16, 0, 28)
        btn.BackgroundColor3 = theme.bgDark
        btn.AutoButtonColor = false
        btn.BorderSizePixel = 0
        btn.Text = name
        btn.TextColor3 = theme.fgDim
        btn.Font = theme.font
        btn.TextSize = 13
        btn.Parent = sidebar
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)

        local page = Instance.new("ScrollingFrame")
        page.Size = UDim2.new(1, -16, 1, -16)
        page.Position = UDim2.fromOffset(8, 8)
        page.BackgroundTransparency = 1
        page.BorderSizePixel = 0
        page.ScrollBarThickness = 4
        page.ScrollBarImageColor3 = theme.fgDim
        page.CanvasSize = UDim2.fromScale(0, 0)
        page.AutomaticCanvasSize = Enum.AutomaticSize.Y
        page.Visible = false
        page.Parent = content

        local pageList = Instance.new("UIListLayout", page)
        pageList.SortOrder = Enum.SortOrder.LayoutOrder
        pageList.Padding = UDim.new(0, 6)

        tabs[name] = { button = btn, page = page }
        btn.MouseButton1Click:Connect(function() selectTab(name) end)

        if not activeTab then selectTab(name) end

        return page
    end

    function self:Toggle()
        root.Visible = not root.Visible
    end

    function self:Destroy()
        sg:Destroy()
    end

    closeBtn.MouseButton1Click:Connect(function() self:Toggle() end)

    return self
end

return window
