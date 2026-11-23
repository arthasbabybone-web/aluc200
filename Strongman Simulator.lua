-- Strongman Simulator | World 2 Teleport Fix
-- Direct World 2 destination, verified in game: 89627999455868

local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local VirtualUser = game:GetService("VirtualUser")
local CoreGui = game:GetService("CoreGui")

local player = Players.LocalPlayer
local WORLD_2_PLACE_ID = 89627999455868
local SAVE_FILE = "StrongmanSimulator_World2Fix.json"
local KEY = "__StrongmanSimulatorWorld2Fix"
local env = (type(getgenv) == "function" and getgenv()) or _G

-- Repeat Execute: unload the old instance first (no duplicate UI or listeners).
if env[KEY] and type(env[KEY].Unload) == "function" then
    pcall(env[KEY].Unload)
end

local settings = { AutoFallback = true }
if type(readfile) == "function" then
    local ok, contents = pcall(readfile, SAVE_FILE)
    if ok and type(contents) == "string" then
        local parsedOK, parsed = pcall(HttpService.JSONDecode, HttpService, contents)
        if parsedOK and type(parsed) == "table" and type(parsed.AutoFallback) == "boolean" then
            settings.AutoFallback = parsed.AutoFallback
        end
    end
end

local function saveSettings()
    if type(writefile) ~= "function" then return end
    pcall(function()
        writefile(SAVE_FILE, HttpService:JSONEncode(settings))
    end)
end

local alive = true
local connections = {}
local screenGui
local statusText
local statusBar
local autoButton
local teleportButton
local lastTravelDestination = nil
local lastTravelAt = -math.huge
local lastDirectAt = -math.huge

local function connect(signal, handler)
    local connection = signal:Connect(handler)
    connections[#connections + 1] = connection
    return connection
end

local function setStatus(message)
    if statusText and statusText.Parent then
        statusText.Text = message
    end
end

local function refreshAuto()
    if not alive then return end
    local enabled = settings.AutoFallback
    if statusBar then
        statusBar.BackgroundColor3 = enabled and Color3.fromRGB(47, 210, 101) or Color3.fromRGB(111, 116, 127)
    end
    if autoButton then
        autoButton.Text = "AUTO-FIX: " .. (enabled and "ON" or "OFF")
        autoButton.BackgroundColor3 = enabled and Color3.fromRGB(29, 110, 69) or Color3.fromRGB(60, 65, 76)
    end
    setStatus(enabled and "Готов | автоисправление включено" or "Готов | автоисправление выключено")
end

local function directTeleport(reason)
    if not alive then return end
    local now = os.clock()
    if now - lastDirectAt < 8 then
        setStatus("Подожди перед повторной попыткой")
        return
    end
    lastDirectAt = now
    setStatus(reason == "automatic" and "Обычный вход сломался. Перехожу..." or "Перехожу в World 2...")
    if teleportButton then teleportButton.Text = "ПЕРЕХОД..." end

    -- This direct TeleportService call was tested successfully in this game.
    local ok, err = pcall(function()
        TeleportService:Teleport(WORLD_2_PLACE_ID, player)
    end)
    if not ok then
        setStatus("Ошибка: " .. tostring(err):sub(1, 66))
        if teleportButton then teleportButton.Text = "TELEPORT WORLD 2" end
    end
end

local root
if type(gethui) == "function" then
    local ok, result = pcall(gethui)
    if ok and typeof(result) == "Instance" then root = result end
end
if not root then root = CoreGui end

local function make(className, props, parent)
    local instance = Instance.new(className)
    for key, value in pairs(props) do
        instance[key] = value
    end
    instance.Parent = parent
    return instance
end

screenGui = make("ScreenGui", {
    Name = "StrongmanSimulatorWorld2Fix",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    DisplayOrder = 700,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling
}, nil)
local okParent = pcall(function() screenGui.Parent = root end)
if not okParent then
    screenGui.Parent = player:WaitForChild("PlayerGui")
end

local frame = make("Frame", {
    Name = "Window",
    Size = UDim2.fromOffset(260, 158),
    Position = UDim2.new(0.5, -130, 0.35, 0),
    BackgroundColor3 = Color3.fromRGB(23, 26, 33),
    BorderSizePixel = 0,
    Active = true
}, screenGui)
make("UICorner", { CornerRadius = UDim.new(0, 9) }, frame)
make("UIStroke", { Color = Color3.fromRGB(63, 70, 84), Thickness = 1 }, frame)

local titleBar = make("Frame", {
    Name = "DragTitle",
    BackgroundTransparency = 1,
    Size = UDim2.new(1, 0, 0, 37),
    Active = true
}, frame)
make("TextLabel", {
    Text = "STRONGMAN | WORLD 2",
    Font = Enum.Font.GothamBold,
    TextSize = 13,
    TextColor3 = Color3.fromRGB(245, 247, 250),
    TextXAlignment = Enum.TextXAlignment.Left,
    BackgroundTransparency = 1,
    Position = UDim2.fromOffset(11, 0),
    Size = UDim2.new(1, -52, 1, 0)
}, titleBar)
local unloadButton = make("TextButton", {
    Text = "X",
    Font = Enum.Font.GothamBold,
    TextSize = 15,
    TextColor3 = Color3.fromRGB(255, 170, 170),
    BackgroundColor3 = Color3.fromRGB(60, 40, 45),
    BorderSizePixel = 0,
    Position = UDim2.new(1, -34, 0, 6),
    Size = UDim2.fromOffset(26, 25)
}, titleBar)
make("UICorner", { CornerRadius = UDim.new(0, 5) }, unloadButton)

-- Green = live auto-fix; grey = auto-fix paused. Removed on Unload.
statusBar = make("Frame", {
    Name = "StatusBar",
    Position = UDim2.fromOffset(8, 37),
    Size = UDim2.new(1, -16, 0, 4),
    BorderSizePixel = 0
}, frame)
make("UICorner", { CornerRadius = UDim.new(1, 0) }, statusBar)

autoButton = make("TextButton", {
    Name = "AutoFix",
    Font = Enum.Font.GothamBold,
    TextSize = 13,
    TextColor3 = Color3.fromRGB(246, 250, 248),
    BorderSizePixel = 0,
    Position = UDim2.fromOffset(10, 52),
    Size = UDim2.new(1, -20, 0, 28)
}, frame)
make("UICorner", { CornerRadius = UDim.new(0, 6) }, autoButton)

teleportButton = make("TextButton", {
    Name = "DirectWorld2",
    Text = "TELEPORT WORLD 2",
    Font = Enum.Font.GothamBold,
    TextSize = 13,
    TextColor3 = Color3.fromRGB(255, 255, 255),
    BackgroundColor3 = Color3.fromRGB(58, 100, 205),
    BorderSizePixel = 0,
    Position = UDim2.fromOffset(10, 87),
    Size = UDim2.new(1, -20, 0, 33)
}, frame)
make("UICorner", { CornerRadius = UDim.new(0, 6) }, teleportButton)

statusText = make("TextLabel", {
    Name = "Hint",
    Text = "",
    Font = Enum.Font.Gotham,
    TextSize = 11,
    TextColor3 = Color3.fromRGB(185, 195, 208),
    TextXAlignment = Enum.TextXAlignment.Center,
    TextTruncate = Enum.TextTruncate.AtEnd,
    BackgroundTransparency = 1,
    Position = UDim2.fromOffset(10, 125),
    Size = UDim2.new(1, -20, 0, 21)
}, frame)

local function unload()
    if not alive then return end
    alive = false
    for _, c in ipairs(connections) do
        pcall(function() c:Disconnect() end)
    end
    table.clear(connections)
    if screenGui then
        screenGui:Destroy()
        screenGui = nil
    end
    if env[KEY] and env[KEY].Unload == unload then
        env[KEY] = nil
    end
end

env[KEY] = { Unload = unload }

connect(unloadButton.MouseButton1Click, unload)
connect(autoButton.MouseButton1Click, function()
    settings.AutoFallback = not settings.AutoFallback
    saveSettings()
    refreshAuto()
end)
connect(teleportButton.MouseButton1Click, function()
    directTeleport("manual")
end)

-- Listen only to the game's WorldTravel feature, not unrelated teleports.
local worldTravel = ReplicatedStorage:FindFirstChild("WorldTravel")
local statusRemote = worldTravel and worldTravel:FindFirstChild("Status")
if statusRemote and statusRemote:IsA("RemoteEvent") then
    connect(statusRemote.OnClientEvent, function(status, destination)
        if not alive then return end
        if status == "Traveling" then
            lastTravelDestination = destination or worldTravel:GetAttribute("Destination")
            lastTravelAt = os.clock()
        elseif status == "Failed" then
            local recentWorld2 = lastTravelDestination == "World2" and os.clock() - lastTravelAt <= 30
            lastTravelDestination = nil
            if recentWorld2 and settings.AutoFallback then
                task.defer(function()
                    if alive then directTeleport("automatic") end
                end)
            end
        end
    end)
else
    setStatus("Портал не найден | ручной вход работает")
end

connect(TeleportService.TeleportInitFailed, function(failedPlayer, result, message)
    if not alive or failedPlayer ~= player then return end
    setStatus("Roblox: " .. tostring(message or result):sub(1, 75))
    if teleportButton then teleportButton.Text = "TELEPORT WORLD 2" end
end)
connect(player.OnTeleport, function(state)
    if not alive then return end
    if state == Enum.TeleportState.Started then
        setStatus("Телепортация запущена")
    elseif state == Enum.TeleportState.Failed then
        setStatus("Телепортация не удалась. Повтори")
        if teleportButton then teleportButton.Text = "TELEPORT WORLD 2" end
    end
end)

-- Anti-AFK (disconnects on Unload).
connect(player.Idled, function()
    if not alive then return end
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new(0, 0))
    end)
end)

-- Drag ONLY by the title bar.
local dragging = false
local dragInput, dragStart, startPosition
connect(titleBar.InputBegan, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPosition = frame.Position
        connect(input.Changed, function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
            end
        end)
    end
end)
connect(titleBar.InputChanged, function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
        dragInput = input
    end
end)
connect(UserInputService.InputChanged, function(input)
    if dragging and input == dragInput and dragStart and startPosition then
        local delta = input.Position - dragStart
        frame.Position = UDim2.new(
            startPosition.X.Scale, startPosition.X.Offset + delta.X,
            startPosition.Y.Scale, startPosition.Y.Offset + delta.Y
        )
    end
end)

refreshAuto()
print("[Strongman Simulator] World 2 teleport fix loaded. PlaceId=" .. WORLD_2_PLACE_ID)
