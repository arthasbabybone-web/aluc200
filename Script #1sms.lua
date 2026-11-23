-- Strongman Simulator (World2): мгновенная продажа предметов рядом с игроком
-- Персонажа НЕ перемещает. Двигает только зону Goal к предмету.
-- Только для своего аккаунта.
-- МАСКА: локально (видно только тебе) надеть на выбранного игрока ник+аватар alucthegreat200 и строку в табе.

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local TS = game:GetService("TweenService")

local lp = Players.LocalPlayer
local SAVE_FILE = "StrongmanWorld2_sell.txt"
local MASK_NAME = "alucthegreat200"
local HIDE_PERM = { "B", "C", "F", "G", "H", "I", "J", "K", "L", "M", "O", "P", "Q", "T", "U", "V", "X", "Y", "Z" }
local HIDE_KEY = Enum.KeyCode[HIDE_PERM[math.random(1, #HIDE_PERM)]]

-- Фейк под alucthegreat200: ребёрт в табе/неймтейбле = 542 и фикс. энергия за King
local FAKE_REBIRTH = 542
local FAKE_KING_B = 15.23 -- фикс. число: столько «капает» с King (только визуал)
local KING_BASE_COINS, KING_ZONE_MULT = 4500000, 21

local state = { enabled = false, interval = 0.06, target = 0, autoRebirth = false, energyTarget = 2e12, maskTarget = "" }
local hotkeySuppress = false
if getgenv and getgenv().__W2Sell_Hotkey then
    pcall(function() getgenv().__W2Sell_Hotkey:Disconnect() end)
    getgenv().__W2Sell_Hotkey = nil
end

-- Общий "стоп-кран" через атрибут игрока: работает между разными запусками/VM,
-- так что второй запуск скрипта или E гарантированно глушат любой висящий фарм.
local STOP_ATTR = "W2Sell_Stop"
local function stopStamp()
    local ok, v = pcall(function() return lp:GetAttribute(STOP_ATTR) end)
    return ok and tonumber(v) or 0
end
local function bumpStop()
    pcall(function() lp:SetAttribute(STOP_ATTR, stopStamp() + 1) end)
end
local thread = nil
local idledConn = nil
local gainStart = nil
local activeGoal = nil
local activeTargetName = nil
local lastArea10TP = 0
-- Авто-цикл: фармим энергию World2 до порога → x10 воркаут качает силу → авто-реберт → заново
local AUTO_ENERGY_TARGET = 2e12
local workoutMode = false
local lastUnanchor = 0
-- Живость инстанса: при перезапуске скрипта старые потоки видят другой токен и выходят
local autoToken = {}
if getgenv then getgenv().__W2SellAuto = autoToken end
local function stillAlive()
    if not getgenv then return true end
    return getgenv().__W2SellAuto == autoToken
end

local function log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    pcall(print, "[W2SELL] " .. table.concat(parts, " "))
end

local function fmt(n)
    if type(n) ~= "number" then return "?" end
    local sign = n < 0 and "-" or ""
    n = math.floor(math.abs(n) + 0.5)
    local s = tostring(n)
    local k
    repeat s, k = s:gsub("^(%d+)(%d%d%d)", "%1,%2") until k == 0
    return sign .. s
end

local function saveState()
    if not writefile then return end
    pcall(writefile, SAVE_FILE, string.format('{"interval":%.3f,"target":%d,"rebirth":%d,"energy":%.4f,"mask":"%s"}', state.interval, math.floor(state.target or 0), state.autoRebirth and 1 or 0, (state.energyTarget or 2e12) / 1e12, state.maskTarget or ""))
end

local function loadState()
    if not (isfile and readfile and isfile(SAVE_FILE)) then return end
    local ok, raw = pcall(readfile, SAVE_FILE)
    if not ok or type(raw) ~= "string" then return end
    local iv = raw:match('"interval":([%d%.]+)')
    if iv then state.interval = math.clamp(tonumber(iv) or 0.06, 0.02, 1) end
    local tg = raw:match('"target":(%d+)')
    if tg then state.target = tonumber(tg) or 0 end
    local rb = raw:match('"rebirth":(%d+)')
    if rb then state.autoRebirth = tonumber(rb) == 1 end
    local en = raw:match('"energy":([%d%.]+)')
    if en then state.energyTarget = math.clamp(tonumber(en) or 2, 0.001, 10000) * 1e12 end
    local mk = raw:match('"mask":"([^"]*)"')
    if mk then state.maskTarget = mk end
end

loadState()
bumpStop()

local dsMod
local function DS() if not dsMod then local ok, m = pcall(function() return require(workspace.Lib.Data.TGSDataStore) end); if ok then dsMod = m end end return dsMod end
local function getW2() local ds = DS(); local it = ds and ds.PlayerData and ds.PlayerData.Items; return it and it.Currency and it.Currency.World2 end

local smMod
local function SM()
    if not smMod then
        local ok, m = pcall(function() return require(workspace.Lib.StrongmanGame.StrongMan) end)
        if ok then smMod = m end
    end
    return smMod
end

-- World2: сила реберта = Stat.World2, цена уже пересчитана клиентским модулем под World2
local function rebirthReady()
    local sm = SM()
    local ds = DS()
    local stat = ds and ds.PlayerData and ds.PlayerData.Items and ds.PlayerData.Items.Stat
    if not sm or not stat then return false, nil, 0 end
    local strength = tonumber(stat.World2) or 0
    local ok, cost = pcall(sm.GetRebirthCost, lp, 0)
    if not ok or type(cost) ~= "number" then return false, nil, strength end
    return strength >= cost, cost, strength
end

-- Сколько силы нужно на N ребертов вперёд (цена каждого следующего +BASE*SCALE)
local function rebirthTargetStrength(n)
    local sm = SM()
    local ds = DS()
    if not sm then return math.huge end
    local R = (ds and ds.PlayerData.Items.Stat.World2Rebirth) or 0
    local base = sm.BASE_REBIRTH_COST
    local step = base * sm.REBIRTH_COST_SCALE
    return n * base + step * (R * n + n * (n - 1) / 2)
end

local function doRebirth()
    local sm = SM()
    if not sm then return false end
    local ok, res = pcall(sm.Rebirth, lp)
    return ok and res ~= false
end

-- Мульти-реберт: сервер считает пачку ребертов секундами (yield каждые 20 итераций),
-- а дебаунс у него 2 сек. Вызовы с шагом >2 сек заходят до обнуления силы — каждый начисляет свою пачку.
local MULTI_REBIRTH_SHOTS = 3
local MULTI_REBIRTH_GAP = 2.1
-- Порог "в запасе" ребертов. 1 = бить сразу, как хватает на 1 реберт (дубль ловится, когда сервер лагает)
local REBIRTH_DUPE_MIN = 1

local function fireRebirthRemote()
    -- Жмём родную кнопку реберта игры: она вызывает StrongMan.Rebirth из клиентского окружения игры,
    -- т.е. стреляет в тот remote, который сервер реально слушает.
    local ui = lp.PlayerGui:FindFirstChild("RebirthUI")
    local btn = ui and (ui:FindFirstChild("ConfirmButton", true) or ui:FindFirstChildWhichIsA("TextButton", true))
    if not btn or not btn:IsA("GuiButton") then return false end
    pcall(function()
        local cb = ui:FindFirstChild("ConfirmBox", true)
        if cb and cb:IsA("TextBox") then cb.Text = "ok" end
    end)
    local ok = pcall(firesignal, btn.Activated)
    return ok
end

local function areaOf(inst)
    local a = inst
    while a do
        if a.Parent and a.Parent.Name == "Areas_Stud_World" then return a end
        a = a.Parent
    end
    return nil
end

local function goalOf(inst)
    local area = areaOf(inst)
    local exit = area and area:FindFirstChild("Exit")
    return exit and (exit:FindFirstChild("Goal") or exit:FindFirstChild("GoalLine"))
end

local function collectItems()
    local root = workspace:FindFirstChild("World2")
    local folder = root and root:FindFirstChild("Areas_Stud_World")
    local out = {}
    if not folder then return out end
    for _, area in ipairs(folder:GetChildren()) do
        local drag = area:FindFirstChild("DraggableItems")
        if drag then
            for _, m in ipairs(drag:GetDescendants()) do
                if m:IsA("Model") and m.PrimaryPart then
                    local coins = m:FindFirstChild("Coins")
                    local prompt = m:FindFirstChildWhichIsA("ProximityPrompt", true)
                    if coins and prompt then
                        table.insert(out, {model = m, coins = coins.Value, prompt = prompt, area = area})
                    end
                end
            end
        end
    end
    return out
end

local function bestGlobal()
    local char = lp.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return nil end
    local best, bestCoins
    for _, e in ipairs(cachedItems()) do
        if not bestCoins or e.coins > bestCoins then best, bestCoins = e, e.coins end
    end
    if best then
        return {entry = best, dist = math.floor((best.model:GetPivot().Position - hrp.Position).Magnitude)}
    end
    return nil
end

local itemCache = nil
local itemCacheAt = 0

local function cachedItems()
    if not itemCache or os.clock() - itemCacheAt > 2 then
        itemCache = collectItems()
        itemCacheAt = os.clock()
    end
    return itemCache
end

local function pickTarget()
    local char = lp.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return nil end
    local pos = hrp.Position
    local best, bestScore
    for _, e in ipairs(cachedItems()) do
        local d = (e.model:GetPivot().Position - pos).Magnitude
        if d <= 38 then
            local score = e.coins
            if not bestScore or score > bestScore then best, bestScore = e, score end
        end
    end
    return best
end

-- Быстрый «автоклик» по промпту: несколько срабатываний подряд
local function burstPrompt(prompt, n)
    n = n or 5
    for i = 1, n do
        pcall(fireproximityprompt, prompt)
        if i < n then task.wait(0.008) end
    end
end

-- Реальное нажатие E (как автокликер): сервер считает его как отдельный воркаут
-- ЛКМ-клик (как автокликер): в этой игре клики ЛКМ увеличивают получаемую силу
local function clickLMB()
    local ok = false
    if mouse1click then
        ok = pcall(mouse1click)
    elseif mouse1press and mouse1release then
        ok = pcall(function() mouse1press(); task.wait(0.01); mouse1release() end)
    end
    if not ok then
        local vim = game:GetService("VirtualInputManager")
        local cam = workspace.CurrentCamera
        local vp = cam and cam.ViewportSize or Vector2.new(800, 600)
        local x, y = math.floor(vp.X / 2), math.floor(vp.Y / 2)
        pcall(function()
            vim:SendMouseButtonEvent(x, y, 0, true, game, 1)
            task.wait(0.01)
            vim:SendMouseButtonEvent(x, y, 0, false, game, 0)
        end)
    end
end

local function pressE()
    local vim = game:GetService("VirtualInputManager")
    hotkeySuppress = true
    pcall(function()
        vim:SendKeyEvent(true, Enum.KeyCode.E, false, game)
        task.wait(0.012)
        vim:SendKeyEvent(false, Enum.KeyCode.E, false, game)
    end)
    hotkeySuppress = false
end

local function hookGoal(goal)    if goal:GetAttribute("W2Sell_OrigSize") then return end
    goal:SetAttribute("W2Sell_OrigSize", goal.Size)
    goal:SetAttribute("W2Sell_OrigCFrame", goal.CFrame)
end

local function restoreGoal(goal)
    if not goal then return end
    local size = goal:GetAttribute("W2Sell_OrigSize")
    local cf = goal:GetAttribute("W2Sell_OrigCFrame")
    if size then goal.Size = size end
    if cf then goal.CFrame = cf end
end

local function placeGoal(entry)
    local goal = goalOf(entry.model)
    if not goal then return false end
    if activeGoal and activeGoal ~= goal then restoreGoal(activeGoal) end
    hookGoal(goal)
    goal.Size = Vector3.new(120, 80, 120)
    goal.CFrame = CFrame.new(entry.model:GetPivot().Position + Vector3.new(0, 8, 0))
    activeGoal = goal
    return true
end

local function stripClone(model)
    if not model:IsA("Model") then return end
    local keep = model.PrimaryPart
    if not keep then
        for _, d in ipairs(model:GetDescendants()) do
            if d:IsA("BasePart") then keep = d break end
        end
    end
    for _, d in ipairs(model:GetDescendants()) do
        if d ~= keep and not d:IsA("BasePart") then
            pcall(function() d:Destroy() end)
        elseif d:IsA("BasePart") and d ~= keep then
            pcall(function() d:Destroy() end)
        end
    end
    if keep and keep.Parent then
        pcall(function()
            keep.Size = Vector3.new(2, 2, 2)
            keep.Massless = true
            keep.CanCollide = false
            keep.CanTouch = true
            keep.Transparency = 1
            keep.CustomPhysicalProperties = PhysicalProperties.new(0.0001, 0, 0, 0, 0)
        end)
        pcall(function()
            local wr = model:FindFirstChildWhichIsA("RopeConstraint", true)
            if wr then wr:Destroy() end
        end)
    end
end

local function hookLightItems()
    local folder = workspace:FindFirstChild("PlayerDraggables")
    local my = folder and folder:FindFirstChild(tostring(lp.UserId))
    if not my or my:GetAttribute("W2Sell_LightHook") then return end
    my:SetAttribute("W2Sell_LightHook", true)
    for _, c in ipairs(my:GetChildren()) do task.spawn(stripClone, c) end
    my.ChildAdded:Connect(function(c) task.spawn(function() task.wait(0.05); pcall(stripClone, c) end) end)
end

local function getHRP()
    local c = lp.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

-- Слезть с воркаута: в игре, чтобы выйти из стойки, надо прыгнуть
local function leaveWorkout()
    local hrp = getHRP()
    if not hrp then return end
    local hum = hrp.Parent and hrp.Parent:FindFirstChildOfClass("Humanoid")
    if hum then pcall(function() hum.Jump = true end) end
    local vim = game:GetService("VirtualInputManager")
    hotkeySuppress = true
    pcall(function()
        vim:SendKeyEvent(true, Enum.KeyCode.Space, false, game)
        task.wait(0.06)
        vim:SendKeyEvent(false, Enum.KeyCode.Space, false, game)
    end)
    hotkeySuppress = false
    task.wait(0.25)
    if getHRP() and getHRP().Anchored then pcall(function() getHRP().Anchored = false end) end
end

local function findKing()
    local root = workspace:FindFirstChild("World2")
    local base = root and root:FindFirstChild("Areas_Stud_World")
    if not base then return nil end
    local areas = {}
    local a10 = base:FindFirstChild("Area10_BlackAndWhite")
    if a10 then table.insert(areas, a10) end
    for _, a in ipairs(base:GetChildren()) do if a ~= a10 then table.insert(areas, a) end end
    for _, area in ipairs(areas) do
        local drag = area:FindFirstChild("DraggableItems")
        if drag then
            for _, m in ipairs(drag:GetDescendants()) do
                if m:IsA("Model") and m.PrimaryPart then
                    local t = m:FindFirstChild("Title")
                    local isKing = (t and t:IsA("StringValue") and t.Value == "King") or (m.Name:find("King") ~= nil)
                    if isKing then
                        local prompt = m:FindFirstChildWhichIsA("ProximityPrompt", true)
                        if prompt then
                            return { model = m, prompt = prompt, pos = m:GetPivot().Position, area = area }
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function kingTemplateOnly()
    local base = workspace:FindFirstChild("World2") and workspace.World2:FindFirstChild("Areas_Stud_World")
    if not base then return nil end
    for _, area in ipairs(base:GetChildren()) do
        local drag = area:FindFirstChild("DraggableItems")
        if drag then
            for _, m in ipairs(drag:GetDescendants()) do
                if m:IsA("Model") then
                    local t = m:FindFirstChild("Title")
                    local isKing = (t and t:IsA("StringValue") and t.Value == "King") or m.Name:find("King")
                    if isKing and not m.PrimaryPart then
                        local hasPrompt = m:FindFirstChildWhichIsA("ProximityPrompt", true)
                        if not hasPrompt then return m end
                    end
                end
            end
        end
    end
    return nil
end

local function area10Anchor()
    local base = workspace:FindFirstChild("World2") and workspace.World2:FindFirstChild("Areas_Stud_World")
    local area = base and base:FindFirstChild("Area10_BlackAndWhite")
    if not area then return nil end
    local n, mn, mx = 0, Vector3.new(9e9, 9e9, 9e9), Vector3.new(-9e9, -9e9, -9e9)
    for _, d in ipairs(area:GetDescendants()) do
        if d:IsA("BasePart") then
            n += 1
            local p = d.Position
            mn = Vector3.new(math.min(mn.X, p.X), math.min(mn.Y, p.Y), math.min(mn.Z, p.Z))
            mx = Vector3.new(math.max(mx.X, p.X), math.max(mx.Y, p.Y), math.max(mx.Z, p.Z))
        end
    end
    if n > 0 then
        local c = (mn + mx) / 2
        return Vector3.new(c.X, mn.Y + 12, c.Z)
    end
    local drag = area:FindFirstChild("DraggableItems")
    if drag then
        for _, m in ipairs(drag:GetDescendants()) do
            if m:IsA("Model") then
                local t = m:FindFirstChild("Title")
                local nm = (t and t:IsA("StringValue") and t.Value) or m.Name
                if tostring(nm):find("King") then
                    local p = m:GetPivot().Position
                    if p.Magnitude > 1 then return p + Vector3.new(0, 12, 0) end
                end
            end
        end
    end
    return Vector3.new(68, 24, -2695)
end

local function myFolder()
    local f = workspace:FindFirstChild("PlayerDraggables")
    return f and f:FindFirstChild(tostring(lp.UserId))
end

local function flushHeld(goal)
    local my = myFolder()
    if not my or not goal then return 0 end
    local n = 0
    local gp = goal.Position + Vector3.new(0, 3, 0)
    for _, c in ipairs(my:GetChildren()) do
        if c:IsA("Model") then
            pcall(function() c:PivotTo(CFrame.new(gp)) end)
            n = n + 1
        end
    end
    return n
end

local parent = (gethui and gethui()) or lp:WaitForChild("PlayerGui")
local old = parent:FindFirstChild("W2Sell_GUI")
if old then old:Destroy() end
local oldCb = parent:FindFirstChild("W2Sell_Clickbox")
if oldCb then oldCb:Destroy() end

local gui = Instance.new("ScreenGui")
gui.Name = "W2Sell_GUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 2147483647
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = parent

local root = Instance.new("Frame")
root.Size = UDim2.fromOffset(330, 540)
root.Position = UDim2.new(0, 30, 0, 100)
root.BackgroundColor3 = Color3.fromRGB(24, 25, 30)
root.BorderSizePixel = 0
root.Active = true
root.Parent = gui
local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 10); corner.Parent = root
local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(90, 200, 255); stroke.Thickness = 1; stroke.Transparency = 0.35; stroke.Parent = root

local vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(800, 600)
local uiScale = Instance.new("UIScale")
uiScale.Scale = math.clamp(math.min(vp.X / 400, vp.Y / 560), 0.6, 1)
uiScale.Parent = root

local title = Instance.new("Frame")
title.Size = UDim2.new(1, 0, 0, 40)
title.BackgroundColor3 = Color3.fromRGB(18, 19, 23)
title.BorderSizePixel = 0
title.Active = true
title.Parent = root
local tc = Instance.new("UICorner"); tc.CornerRadius = UDim.new(0, 10); tc.Parent = title

local titleLabel = Instance.new("TextLabel")
titleLabel.Size = UDim2.new(1, -124, 1, 0)
titleLabel.Position = UDim2.fromOffset(14, 0)
titleLabel.BackgroundTransparency = 1
titleLabel.Font = Enum.Font.GothamBold
titleLabel.TextSize = 14
titleLabel.TextColor3 = Color3.fromRGB(232, 238, 245)
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.Text = "Instant Sell · World2"
titleLabel.Parent = title

local function makeButton(parentFrame, text, color, size, pos)
    local b = Instance.new("TextButton")
    b.Size = size
    b.Position = pos
    b.BackgroundColor3 = color
    b.BorderSizePixel = 0
    b.AutoButtonColor = true
    b.Font = Enum.Font.GothamSemibold
    b.TextSize = 13
    b.TextColor3 = Color3.fromRGB(235, 237, 243)
    b.Text = text
    b.Parent = parentFrame
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 8); c.Parent = b
    return b
end

local hideBtn = makeButton(title, HIDE_KEY.Name, Color3.fromRGB(40, 42, 50), UDim2.fromOffset(32, 26), UDim2.new(1, -112, 0, 7))
local minBtn = makeButton(title, "—", Color3.fromRGB(40, 42, 50), UDim2.fromOffset(32, 26), UDim2.new(1, -76, 0, 7))
local closeBtn = makeButton(title, "✕", Color3.fromRGB(40, 42, 50), UDim2.fromOffset(32, 26), UDim2.new(1, -40, 0, 7))

local uiHidden = false
local restoreBtn = Instance.new("TextButton")
restoreBtn.Name = "W2Sell_Restore"
restoreBtn.Size = UDim2.fromOffset(54, 40)
restoreBtn.Position = UDim2.new(0, 16, 1, -64, 0, 0)
restoreBtn.BackgroundColor3 = Color3.fromRGB(40, 42, 50)
restoreBtn.BackgroundTransparency = 0.15
restoreBtn.BorderSizePixel = 0
restoreBtn.Font = Enum.Font.GothamBold
restoreBtn.TextSize = 15
restoreBtn.TextColor3 = Color3.fromRGB(235, 237, 243)
restoreBtn.Text = HIDE_KEY.Name
restoreBtn.Visible = false
restoreBtn.ZIndex = 10
restoreBtn.AutoButtonColor = true
restoreBtn.Parent = gui
local restoreCorner = Instance.new("UICorner"); restoreCorner.CornerRadius = UDim.new(0, 8); restoreCorner.Parent = restoreBtn

local body = Instance.new("Frame")
body.Size = UDim2.new(1, -28, 1, -54)
body.Position = UDim2.fromOffset(14, 46)
body.BackgroundTransparency = 1
body.Parent = root

local w2Label = Instance.new("TextLabel")
w2Label.Size = UDim2.new(1, 0, 0, 22)
w2Label.BackgroundTransparency = 1
w2Label.Font = Enum.Font.GothamBold
w2Label.TextSize = 14
w2Label.TextXAlignment = Enum.TextXAlignment.Left
w2Label.TextColor3 = Color3.fromRGB(255, 220, 150)
w2Label.Text = "World2: ..."
w2Label.Parent = body

local gainedLabel = Instance.new("TextLabel")
gainedLabel.Size = UDim2.new(1, 0, 0, 20)
gainedLabel.Position = UDim2.fromOffset(0, 24)
gainedLabel.BackgroundTransparency = 1
gainedLabel.Font = Enum.Font.Gotham
gainedLabel.TextSize = 13
gainedLabel.TextXAlignment = Enum.TextXAlignment.Left
gainedLabel.TextColor3 = Color3.fromRGB(120, 220, 160)
gainedLabel.Text = "Заработано: 0"
gainedLabel.Parent = body

local targetLabel = Instance.new("TextLabel")
targetLabel.Size = UDim2.new(1, 0, 0, 20)
targetLabel.Position = UDim2.fromOffset(0, 44)
targetLabel.BackgroundTransparency = 1
targetLabel.Font = Enum.Font.Gotham
targetLabel.TextSize = 12
targetLabel.TextXAlignment = Enum.TextXAlignment.Left
targetLabel.TextColor3 = Color3.fromRGB(160, 200, 235)
targetLabel.Text = "Предмет: —"
targetLabel.Parent = body

local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, 0, 0, 32)
statusLabel.Position = UDim2.fromOffset(0, 66)
statusLabel.BackgroundTransparency = 1
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 12
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextYAlignment = Enum.TextYAlignment.Top
statusLabel.TextWrapped = true
statusLabel.TextColor3 = Color3.fromRGB(150, 155, 165)
statusLabel.Text = "Статус: ожидание"
statusLabel.Parent = body

local function makeField(y, labelText, value)
    local l = Instance.new("TextLabel")
    l.Size = UDim2.fromOffset(120, 30)
    l.Position = UDim2.fromOffset(0, y)
    l.BackgroundTransparency = 1
    l.Font = Enum.Font.Gotham
    l.TextSize = 13
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.TextColor3 = Color3.fromRGB(200, 203, 212)
    l.Text = labelText
    l.Parent = body
    local box = Instance.new("TextBox")
    box.Size = UDim2.new(1, -130, 0, 30)
    box.Position = UDim2.fromOffset(130, y)
    box.BackgroundColor3 = Color3.fromRGB(34, 36, 44)
    box.BorderSizePixel = 0
    box.Font = Enum.Font.GothamSemibold
    box.TextSize = 13
    box.TextColor3 = Color3.fromRGB(235, 237, 243)
    box.Text = value
    box.ClearTextOnFocus = false
    box.Parent = body
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 7); c.Parent = box
    return box
end

local intervalBox = makeField(104, "Интервал (сек)", string.format("%.2f", state.interval))
local targetBox = makeField(140, "Стоп при World2", tostring(math.floor(state.target or 0)))
local energyBox = makeField(176, "Энергия до (трлн)", string.format("%.2f", (state.energyTarget or 2e12) / 1e12))

-- значение кэшируем в обычную переменную: фоновым потокам нельзя читать свойства GUI
local energyTargetValue = state.energyTarget or 2e12
local function readEnergyBox()
    local t = tonumber(energyBox.Text)
    if t then energyTargetValue = math.clamp(t, 0.001, 10000) * 1e12 end
    return energyTargetValue
end
local function energyTargetNow()
    return energyTargetValue
end

energyBox.FocusLost:Connect(function()
    readEnergyBox()
    state.energyTarget = energyTargetValue
    energyBox.Text = string.format("%.2f", state.energyTarget / 1e12)
    saveState()
end)

local autoAllBtn = makeButton(body, "АВТО ВСЁ: ВЫКЛ", Color3.fromRGB(70, 90, 120), UDim2.new(1, 0, 0, 36), UDim2.fromOffset(0, 214))
local startBtn = makeButton(body, "СТАРТ", Color3.fromRGB(40, 110, 90), UDim2.new(1, 0, 0, 36), UDim2.fromOffset(0, 258))
local clickBtn = makeButton(body, "КЛИК-ПРОДАЖА: ВЫКЛ", Color3.fromRGB(60, 62, 70), UDim2.new(1, 0, 0, 32), UDim2.fromOffset(0, 302))
local workoutBtn = makeButton(body, "ТП ВОРКАУТ (x10)", Color3.fromRGB(60, 90, 150), UDim2.new(1, 0, 0, 32), UDim2.fromOffset(0, 338))
local autoRebirthBtn = makeButton(body, "АВТО-РЕБЕРТ: ВЫКЛ", Color3.fromRGB(60, 62, 70), UDim2.new(1, 0, 0, 32), UDim2.fromOffset(0, 374))
local unloadBtn = makeButton(body, "Выгрузить (unload)", Color3.fromRGB(150, 50, 50), UDim2.new(1, 0, 0, 32), UDim2.fromOffset(0, 410))
local maskBtn = makeButton(body, "МАСКА: ВЫКЛ", Color3.fromRGB(90, 60, 120), UDim2.new(1, 0, 0, 32), UDim2.fromOffset(0, 446))

local function refresh()
    local w = getW2()
    w2Label.Text = "World2: " .. (w and fmt(w) or "?")
    if gainStart and w then gainedLabel.Text = "Заработано: +" .. fmt(math.max(0, w - gainStart)) end
    local _, cost, strength = rebirthReady()
    local target = rebirthTargetStrength(REBIRTH_DUPE_MIN)
    if state.enabled and state.autoRebirth then
        autoAllBtn.Text = "АВТО ВСЁ: ВКЛ"
        autoAllBtn.BackgroundColor3 = Color3.fromRGB(40, 130, 90)
    else
        autoAllBtn.Text = "АВТО ВСЁ: ВЫКЛ"
        autoAllBtn.BackgroundColor3 = Color3.fromRGB(70, 90, 120)
    end
    if not state.autoRebirth then
        autoRebirthBtn.Text = "АВТО-РЕБЕРТ: ВЫКЛ"
        autoRebirthBtn.BackgroundColor3 = Color3.fromRGB(60, 62, 70)
    elseif strength >= target then
        autoRebirthBtn.Text = string.format("АВТО-РЕБЕРТ: ГОТОВ · %s ребертов", fmt(REBIRTH_DUPE_MIN))
        autoRebirthBtn.BackgroundColor3 = Color3.fromRGB(40, 130, 90)
    else
        autoRebirthBtn.Text = string.format("АВТО-РЕБЕРТ: ВКЛ · %s / %s", fmt(strength), fmt(target))
        autoRebirthBtn.BackgroundColor3 = Color3.fromRGB(110, 80, 40)
    end
    if state.maskTarget and state.maskTarget ~= "" then
        maskBtn.Text = "МАСКА: " .. state.maskTarget
        maskBtn.BackgroundColor3 = Color3.fromRGB(60, 140, 110)
    else
        maskBtn.Text = "МАСКА: ВЫБРАТЬ"
        maskBtn.BackgroundColor3 = Color3.fromRGB(90, 60, 120)
    end
end

local function setStatus(text, color)
    statusLabel.Text = "Статус: " .. text
    statusLabel.TextColor3 = color or Color3.fromRGB(150, 155, 165)
end

local function stop()
    state.enabled = false
    thread = nil
    bumpStop()
    startBtn.Text = "СТАРТ"
    startBtn.BackgroundColor3 = Color3.fromRGB(40, 110, 90)
    if activeGoal then restoreGoal(activeGoal); activeGoal = nil end
    activeTargetName = nil
    saveState()
end

local function start()
    state.interval = math.clamp(tonumber(intervalBox.Text) or state.interval, 0.02, 1)
    intervalBox.Text = string.format("%.2f", state.interval)
    state.target = math.max(0, math.floor(tonumber(targetBox.Text) or state.target or 0))
    targetBox.Text = tostring(state.target)
    readEnergyBox()
    state.energyTarget = energyTargetValue
    energyBox.Text = string.format("%.2f", state.energyTarget / 1e12)
    saveState()
    state.enabled = true
    startBtn.Text = "СТОП"
    startBtn.BackgroundColor3 = Color3.fromRGB(180, 70, 60)
    if gainStart == nil then gainStart = getW2() end
    if thread then return end
    local myStamp = stopStamp()
    thread = task.spawn(function()
        local lastTarget = nil
        while state.enabled and stopStamp() == myStamp do
            if workoutMode then
                task.wait(0.5)
            else
            -- если остались прикованными к воркауту (Anchored) — прыгаем, чтобы слезть
            local hA = getHRP()
            if hA and hA.Anchored and os.clock() - lastUnanchor > 3 then
                lastUnanchor = os.clock()
                leaveWorkout()
            end
            local wNow = getW2()
            if state.target and state.target > 0 and wNow and wNow >= state.target then
                setStatus("цель " .. fmt(state.target) .. " достигнута — стоп", Color3.fromRGB(120, 220, 160))
                stop(); break
            end
            local hrp = getHRP()
            local king = findKing()
            if not king and hrp and os.clock() - lastArea10TP > 6 then
                local anchor = area10Anchor()
                if anchor then
                    lastArea10TP = os.clock()
                    hrp.CFrame = CFrame.new(anchor)
                    setStatus("ТП в Area10: гружу арену и ищу King", Color3.fromRGB(255, 200, 120))
                    task.wait(0.7)
                    king = findKing()
                end
            end
            if king and hrp then
                -- телепорт к King и взятие промптом
                hrp.CFrame = CFrame.new(king.pos + Vector3.new(0, 6, 0))
                local goal = goalOf(king.model)
                if goal then
                    if activeGoal and activeGoal ~= goal then restoreGoal(activeGoal) end
                    hookGoal(goal)
                    goal.Size = Vector3.new(160, 100, 160)
                    goal.CFrame = CFrame.new(king.pos + Vector3.new(0, 8, 0))
                    activeGoal = goal
                end
                activeTargetName = king.model.Name
                targetLabel.Text = "King: " .. king.model.Name
                task.wait(0.03)
                burstPrompt(king.prompt, 5)
                -- сразу продаём всё, что висит: не копим King
                if activeGoal then flushHeld(activeGoal) end
                setStatus("King: телепорт, взял и продал", Color3.fromRGB(150, 235, 180))
                task.wait(state.interval)
            else
                local entry = pickTarget()
                if not entry then
                    local g = bestGlobal()
                    if g then
                        setStatus(string.format("рядом пусто; лучший: %s (Coins %s), %d студов", g.entry.model.Name, fmt(g.entry.coins), g.dist), Color3.fromRGB(255, 200, 120))
                    elseif kingTemplateOnly() then
                        setStatus("King есть в шаблоне, но без модели/промпта — нужен перезаход", Color3.fromRGB(255, 140, 120))
                    else
                        setStatus("предметов нет", Color3.fromRGB(240, 120, 120))
                    end
                    task.wait(0.5)
                else
                    if lastTarget ~= entry.model then
                        placeGoal(entry)
                        lastTarget = entry.model
                        activeTargetName = entry.model.Name
                        targetLabel.Text = string.format("Предмет: %s (Coins %s)", entry.model.Name, fmt(entry.coins))
                    end
                    burstPrompt(entry.prompt, 5)
                    local ok = true
                    if ok then
                        setStatus("продаю: " .. entry.model.Name, Color3.fromRGB(150, 235, 180))
                    else
                        setStatus("промпт не сработал", Color3.fromRGB(240, 120, 120))
                    end
                    task.wait(state.interval)
                end
            end
            end
        end
        -- вышли из цикла (локальный стоп или чужой стоп-кран) — прибраться
        if activeGoal then restoreGoal(activeGoal); activeGoal = nil end
        activeTargetName = nil
        state.enabled = false
        saveState()
        pcall(function()
            startBtn.Text = "СТАРТ"
            startBtn.BackgroundColor3 = Color3.fromRGB(40, 110, 90)
        end)
    end)
end

-- ============================================================
--  ВИЗУАЛЬНАЯ МАСКА ДЛЯ ИГРОКА (видно только тебе)
--  выбранного игрока показываем как MASK_NAME: ник над головой,
--  локальная копия его аватара и строка в табе.
--  Сервер и другие игроки этого не видят.
-- ============================================================
local maskActive = nil
local maskActiveDisplay = nil
local maskHeadModel = nil
local maskHeadChar = nil
local maskHeadSync = nil
local maskThread = nil
local maskFuncDesc = nil
local maskFuncDescTried = false
local maskCharConn = nil
local maskPlayerList = nil
local maskTabOrig = setmetatable({}, { __mode = "k" })
local maskPlateOrig = setmetatable({}, { __mode = "k" })
local maskVipOrig = {}
local maskRebirthOrig = setmetatable({}, { __mode = "k" })
local maskHidden = {}
local maskPartOrig = {}
local maskBCOrig = nil
local maskBCChar = nil
local maskPanel = nil
local maskApplyTo

local HEAD_ATT = { HatAttachment = true, HairAttachment = true, FaceFrontAttachment = true, FaceCenterAttachment = true }

local function maskFindPlayer(name)
    if not name or name == "" then return nil end
    for _, p in ipairs(Players:GetPlayers()) do
        if string.lower(p.Name) == string.lower(name) then return p end
    end
    return nil
end

local function maskCore()
    local ok, cg = pcall(function() return game:GetService("CoreGui") end)
    if ok then return cg end
    return nil
end

local function maskGetList()
    local cg = maskCore()
    if not cg then return nil end
    if maskPlayerList and maskPlayerList.Parent then return maskPlayerList end
    local pl = cg:FindFirstChild("PlayerList") or cg:FindFirstChild("PlayerList", true)
    if not pl then return nil end
    maskPlayerList = pl:FindFirstChild("PlayerScrollList", true) or pl
    return maskPlayerList
end

local function maskPatchTabOnce()
    if state.maskTarget == "" then return end
    local pl = maskGetList()
    local tp = maskFindPlayer(maskActive)
    if not pl or not tp then return end
    local names = { tp.Name, tp.DisplayName, "@" .. tp.Name }
    for _, d in ipairs(pl:GetDescendants()) do
        if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then
            local t = d.Text
            if t and t ~= "" and t ~= MASK_NAME and t ~= "@" .. MASK_NAME then
                for _, n in ipairs(names) do
                    if t == n then
                        maskTabOrig[d] = t
                        d.Text = (n:sub(1, 1) == "@") and ("@" .. MASK_NAME) or MASK_NAME
                        break
                    end
                end
            end
        end
    end
    -- ребёрт у записи маски: ставим 542, чтобы сходилось с «топом»
    for _, entry in ipairs(pl:GetDescendants()) do
        if entry.Name:match("^PlayerEntry_") then
            local hasMaskName = false
            for _, d in ipairs(entry:GetDescendants()) do
                if d:IsA("TextLabel") and (d.Text == MASK_NAME or d.Text == "@" .. MASK_NAME) then
                    hasMaskName = true
                    break
                end
            end
            if hasMaskName then
                local gs = entry:FindFirstChild("GameStat_Rebirths", true)
                local lbl = gs and gs:FindFirstChild("PlayerStatDisplay", true)
                if lbl and lbl:IsA("TextLabel") and lbl.Text ~= tostring(FAKE_REBIRTH) then
                    if maskRebirthOrig[lbl] == nil then maskRebirthOrig[lbl] = lbl.Text end
                    lbl.Text = tostring(FAKE_REBIRTH)
                end
            end
        end
    end
end

local function maskUnpatchTab()
    for inst, txt in pairs(maskRebirthOrig) do
        if typeof(inst) == "Instance" and inst.Parent then
            pcall(function() inst.Text = txt end)
        end
    end
    maskRebirthOrig = setmetatable({}, { __mode = "k" })
    for inst, txt in pairs(maskTabOrig) do
        if typeof(inst) == "Instance" and inst.Parent then
            pcall(function() inst.Text = txt end)
        end
    end
    maskTabOrig = setmetatable({}, { __mode = "k" })
    local lst = maskGetList()
    local repl = maskActiveDisplay or maskActive
    if lst and repl and repl ~= "" then
        for _, d in ipairs(lst:GetDescendants()) do
            if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then
                if d.Text == MASK_NAME or d.Text == "@" .. MASK_NAME then
                    d.Text = (d.Text:sub(1, 1) == "@") and ("@" .. repl) or repl
                end
            end
        end
    end
end

local function maskGetFuncDesc()
    if maskFuncDesc then return maskFuncDesc end
    if maskFuncDescTried then return nil end
    maskFuncDescTried = true
    local uid
    local online = maskFindPlayer(MASK_NAME)
    if online then uid = online.UserId end
    if not uid then
        local ok, id = pcall(function() return Players:GetUserIdFromNameAsync(MASK_NAME) end)
        if ok and type(id) == "number" then uid = id end
    end
    if not uid then return nil end
    local ok, d = pcall(function() return Players:GetHumanoidDescriptionFromUserIdAsync(uid) end)
    if ok and d then maskFuncDesc = d end
    return maskFuncDesc
end

local function maskPatchNameplateOnce()
    if state.maskTarget == "" then return false end
    local tp = maskFindPlayer(maskActive)
    local c = tp and tp.Character
    if not c then return false end
    local found = false
    for _, gui in ipairs(c:GetDescendants()) do
        if gui:IsA("BillboardGui") then
            local title = gui:FindFirstChild("Title", true)
            if title and (title:IsA("TextLabel") or title:IsA("TextButton")) then
                if title.Text ~= MASK_NAME then
                    if maskPlateOrig[title] == nil then maskPlateOrig[title] = title.Text end
                    title.Text = MASK_NAME
                end
                found = true
            end
            for _, d in ipairs(gui:GetDescendants()) do
                if (d:IsA("TextLabel") or d:IsA("TextButton")) and d ~= title then
                    local txt = d.Text
                    if txt == tp.Name or txt == tp.DisplayName then
                        if maskPlateOrig[d] == nil then maskPlateOrig[d] = txt end
                        d.Text = MASK_NAME
                        found = true
                    end
                end
            end
            -- ребёрт в неймтейбле «Rebirths: 580» -> «Rebirths: 542»
            for _, d in ipairs(gui:GetDescendants()) do
                if d:IsA("TextLabel") or d:IsA("TextButton") then
                    if d.Text and d.Text:match("^Rebirths: %d+$") then
                        if maskPlateOrig[d] == nil then maskPlateOrig[d] = d.Text end
                        local want = "Rebirths: " .. tostring(FAKE_REBIRTH)
                        if d.Text ~= want then d.Text = want end
                    end
                end
            end
            local vip = gui:FindFirstChild("VIP", true)
            if vip and vip:IsA("GuiObject") then
                if maskVipOrig[vip] == nil then maskVipOrig[vip] = vip.Visible end
                if not vip.Visible then pcall(function() vip.Visible = true end) end
            end
        end
    end
    return found
end

local function maskUnpatchNameplate()
    for inst, txt in pairs(maskPlateOrig) do
        if typeof(inst) == "Instance" and inst.Parent then
            pcall(function() inst.Text = txt end)
        end
    end
    maskPlateOrig = setmetatable({}, { __mode = "k" })
    local tp = maskFindPlayer(maskActive)
    local c = tp and tp.Character
    local repl = maskActiveDisplay or maskActive
    if c and repl and repl ~= "" then
        for _, d in ipairs(c:GetDescendants()) do
            if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text == MASK_NAME then
                pcall(function() d.Text = repl end)
            end
        end
    end
    for inst, vis in pairs(maskVipOrig) do
        if typeof(inst) == "Instance" and inst.Parent then
            pcall(function() inst.Visible = vis end)
        end
    end
    maskVipOrig = {}
end

local function maskIsHeadAccessory(acc)
    local h = acc:FindFirstChildWhichIsA("BasePart")
    if not h then return false end
    for _, a in ipairs(h:GetChildren()) do
        if a:IsA("Attachment") and HEAD_ATT[a.Name] then return true end
    end
    return false
end

local function maskSkinColor()
    local d = maskGetFuncDesc()
    if d and d.HeadColor then return d.HeadColor end
    return Color3.fromRGB(17, 17, 17)
end

local function maskBodyColorsOf(c)
    return c:FindFirstChildOfClass("BodyColors") or c:FindFirstChild("Body Colors")
end

local function maskTintBody()
    local tp = maskFindPlayer(maskActive)
    local c = tp and tp.Character
    if not c then return end
    local skin = maskSkinColor()
    local bc = maskBodyColorsOf(c)
    if bc then
        if maskBCChar ~= c then
            maskBCOrig = {
                Head = bc.HeadColor3, Torso = bc.TorsoColor3,
                LeftArm = bc.LeftArmColor3, RightArm = bc.RightArmColor3,
                LeftLeg = bc.LeftLegColor3, RightLeg = bc.RightLegColor3,
            }
            maskBCChar = c
        end
        pcall(function()
            bc.HeadColor3 = skin; bc.TorsoColor3 = skin
            bc.LeftArmColor3 = skin; bc.RightArmColor3 = skin
            bc.LeftLegColor3 = skin; bc.RightLegColor3 = skin
        end)
    end
    for _, d in ipairs(c:GetDescendants()) do
        if d:IsA("BasePart") and not d:FindFirstAncestorOfClass("Tool") then
            if maskPartOrig[d] == nil then maskPartOrig[d] = d.Color end
            if d.Color ~= skin then pcall(function() d.Color = skin end) end
        end
    end
end

local function maskRestoreColors()
    for inst, col in pairs(maskPartOrig) do
        if typeof(inst) == "Instance" and inst.Parent then
            pcall(function() inst.Color = col end)
        end
    end
    maskPartOrig = {}
    if maskBCOrig and maskBCChar and maskBCChar.Parent then
        local bc = maskBodyColorsOf(maskBCChar)
        if bc then
            pcall(function()
                bc.HeadColor3 = maskBCOrig.Head; bc.TorsoColor3 = maskBCOrig.Torso
                bc.LeftArmColor3 = maskBCOrig.LeftArm; bc.RightArmColor3 = maskBCOrig.RightArm
                bc.LeftLegColor3 = maskBCOrig.LeftLeg; bc.RightLegColor3 = maskBCOrig.RightLeg
            end)
        end
    end
    maskBCOrig = nil
    maskBCChar = nil
end

local function maskHideHeadOnce()
    local tp = maskFindPlayer(maskActive)
    local c = tp and tp.Character
    if not c then return end
    local function hide(d)
        if d:IsA("BasePart") or d:IsA("Decal") or d:IsA("Texture") then
            if maskHidden[d] == nil then maskHidden[d] = d.Transparency end
            pcall(function() d.Transparency = 1 end)
        end
    end
    local head = c:FindFirstChild("Head")
    if head then
        hide(head)
        for _, d in ipairs(head:GetDescendants()) do hide(d) end
    end
    for _, d in ipairs(c:GetDescendants()) do
        if d:IsA("Accessory") and maskIsHeadAccessory(d) then
            local h = d:FindFirstChildWhichIsA("BasePart")
            if h then
                hide(h)
                for _, t in ipairs(h:GetDescendants()) do hide(t) end
            end
        end
    end
end

local function maskUnhideHead()
    for inst, tr in pairs(maskHidden) do
        if typeof(inst) == "Instance" and inst.Parent then
            pcall(function() inst.Transparency = tr end)
        end
    end
    maskHidden = {}
end

local function maskRemoveHead()
    if maskHeadSync then pcall(function() maskHeadSync:Disconnect() end); maskHeadSync = nil end
    if maskHeadModel then pcall(function() maskHeadModel:Destroy() end); maskHeadModel = nil end
    maskHeadChar = nil
    maskUnhideHead()
end

local function maskBuildHead()
    maskRemoveHead()
    local tp = maskFindPlayer(maskActive)
    local c = tp and tp.Character
    local hum = c and c:FindFirstChildOfClass("Humanoid")
    local th = c and c:FindFirstChild("Head")
    if not c or not hum or not th then return false end
    local desc = maskGetFuncDesc()
    if not desc then return false end
    local ok, m = pcall(function() return Players:CreateHumanoidModelFromDescription(desc, hum.RigType) end)
    if not ok or not m then return false end
    local aHead = m:FindFirstChild("Head")
    if not aHead then pcall(function() m:Destroy() end); return false end
    for _, d in ipairs(m:GetChildren()) do
        if d ~= aHead and not (d:IsA("Accessory") and maskIsHeadAccessory(d)) then
            pcall(function() d:Destroy() end)
        end
    end
    local factor = th.Size.Y / math.max(aHead.Size.Y, 0.01)
    pcall(function() m:ScaleTo(factor) end)
    aHead = m:FindFirstChild("Head") or aHead
    if aHead.Size.Y < th.Size.Y * 0.8 then
        pcall(function() aHead.Size = th.Size end)
    end
    pcall(function()
        aHead.Anchored = true
        aHead.CanCollide = false
        aHead.CanQuery = false
        aHead.CanTouch = false
        aHead.Massless = true
    end)
    m.Name = "Mask_Head"
    m.Parent = workspace
    maskHeadModel = m
    maskHeadChar = c
    maskHeadSync = game:GetService("RunService").RenderStepped:Connect(function()
        if not maskHeadModel or not maskHeadModel.Parent then return end
        local cc = tp.Character
        local hh = cc and cc:FindFirstChild("Head")
        if not hh then return end
        local ah = maskHeadModel:FindFirstChild("Head")
        if ah then ah.CFrame = hh.CFrame end
    end)
    return true
end

local function maskClearVisuals()
    maskRemoveHead()
    maskRestoreColors()
    maskUnpatchNameplate()
end

-- Фейк энергии King: перехватываем вылет «+X B» и подменяем на +15.xxB (только визуал)
local function fmtFakeGain()
    return string.format("+%.2fB", FAKE_KING_B)
end

local function installFakeGain()
    local ps = lp:FindFirstChild("PlayerScripts")
    local holder = ps and ps:FindFirstChild("FloatingCombatTextClient")
    if not holder then return false end
    local orig = holder:FindFirstChild("DisplayText_orig")
    local cur = holder:FindFirstChild("DisplayText")
    if not orig then
        if not cur then return false end
        orig = cur
        orig.Name = "DisplayText_orig"
        cur = nil
    elseif cur and cur ~= orig then
        -- пересобираем обёртку (в т.ч. старую от прошлого запуска скрипта)
        cur:Destroy()
        cur = nil
    end
    local proxy = Instance.new("BindableFunction")
    proxy.Name = "DisplayText"
    proxy:SetAttribute("W2FakeGain", true)
    proxy.OnInvoke = function(adornee, text, color, icon, scale, useHolder)
        local newText = text
        if type(text) == "string" then
            local numS, unit = text:match("^%+([%d%.]+)([BMT]?)$")
            local num = tonumber(numS)
            if num then
                local u = ({ B = 1e9, M = 1e6, T = 1e12 })[unit] or 1
                local val = num * u
                local char = adornee and (adornee:IsA("BasePart") and adornee.Parent or adornee)
                local plr = char and char:IsA("Model") and Players:GetPlayerFromCharacter(char) or nil
                local watched = plr and (plr == lp or (maskActive and string.lower(plr.Name) == string.lower(maskActive)))
                if watched then
                    local okM, m = pcall(function()
                        local sm = SM()
                        return sm and sm.GetCoinMultiplier(lp) or nil
                    end)
                    if okM and type(m) == "number" and m > 0 then
                        -- King в Area10 = 4.5M Coins × множитель ребёртов × 21 (зона)
                        local expected = KING_BASE_COINS * m * KING_ZONE_MULT
                        if val >= expected * 0.9 and val <= expected * 1.1 then
                            newText = fmtFakeGain()
                        end
                    end
                end
            end
        end
        return orig:Invoke(adornee, newText, color, icon, scale, useHolder)
    end
    proxy.Parent = holder
    if getgenv then getgenv().__W2FakeGain = proxy end
    return true
end

local function maskEnsureLoop()
    if maskThread and coroutine.status(maskThread) ~= "dead" then return end
    maskThread = task.spawn(function()
        while state.maskTarget ~= "" and stillAlive() do
            local ok, err = pcall(function()
                local tp = maskFindPlayer(maskActive or state.maskTarget)
                if tp then
                    if not maskActive or string.lower(maskActive) ~= string.lower(tp.Name) then
                        maskApplyTo(tp.Name)
                    else
                        if not (maskHeadModel and maskHeadModel.Parent) or maskHeadChar ~= tp.Character then
                            maskBuildHead()
                        end
                        if tp.Character then
                            maskHideHeadOnce()
                            maskTintBody()
                        end
                        maskPatchNameplateOnce()
                        maskPatchTabOnce()
                    end
                elseif maskActive then
                    maskClearVisuals()
                    maskUnpatchTab()
                    maskActive = nil
                    maskActiveDisplay = nil
                end
            end)
            if not ok and getgenv then getgenv().__W2MaskLoopErr = tostring(err) end
            task.wait(0.4)
        end
        maskThread = nil
    end)
end

maskApplyTo = function(name)
    maskClearVisuals()
    maskUnpatchTab()
    local tp = maskFindPlayer(name)
    if not tp then return false end
    maskActive = tp.Name
    maskActiveDisplay = tp.DisplayName
    state.maskTarget = tp.Name
    local ok = maskBuildHead()
    maskHideHeadOnce()
    maskTintBody()
    maskPatchNameplateOnce()
    maskPatchTabOnce()
    if maskCharConn then pcall(function() maskCharConn:Disconnect() end) end
    maskCharConn = tp.CharacterAdded:Connect(function()
        if maskActive ~= tp.Name then return end
        task.wait(0.6)
        if maskActive ~= tp.Name then return end
        maskClearVisuals()
        pcall(maskBuildHead)
        pcall(maskHideHeadOnce)
        pcall(maskTintBody)
        pcall(maskPatchNameplateOnce)
        pcall(maskPatchTabOnce)
    end)
    maskEnsureLoop()
    saveState()
    refresh()
    setStatus(ok and ("маска: " .. tp.Name .. " -> голова " .. MASK_NAME .. " + тёмная кожа (видно только тебе)") or "маска: не удалось (нет аватара?)", ok and Color3.fromRGB(150, 235, 180) or Color3.fromRGB(255, 200, 120))
    return true
end

local function maskRemove()
    state.maskTarget = ""
    maskClearVisuals()
    maskUnpatchTab()
    if maskCharConn then pcall(function() maskCharConn:Disconnect() end); maskCharConn = nil end
    maskActive = nil
    maskActiveDisplay = nil
    saveState()
    refresh()
    setStatus("маска снята")
end

local function maskClosePanel()
    if maskPanel then pcall(function() maskPanel:Destroy() end); maskPanel = nil end
end

local function maskOpenPanel()
    maskClosePanel()
    local p = Instance.new("Frame")
    p.Name = "W2Sell_MaskPanel"
    p.Size = UDim2.fromOffset(240, 330)
    p.Position = UDim2.new(root.Position.X.Scale, root.Position.X.Offset + 340, root.Position.Y.Scale, root.Position.Y.Offset)
    p.BackgroundColor3 = Color3.fromRGB(24, 25, 30)
    p.BorderSizePixel = 0
    p.Active = true
    p.Parent = gui
    local pc = Instance.new("UICorner"); pc.CornerRadius = UDim.new(0, 10); pc.Parent = p
    local ps = Instance.new("UIStroke"); ps.Color = Color3.fromRGB(90, 200, 255); ps.Thickness = 1; ps.Transparency = 0.35; ps.Parent = p
    local t = Instance.new("TextLabel")
    t.Size = UDim2.new(1, -20, 0, 20)
    t.Position = UDim2.fromOffset(10, 8)
    t.BackgroundTransparency = 1
    t.Font = Enum.Font.GothamBold
    t.TextSize = 13
    t.TextXAlignment = Enum.TextXAlignment.Left
    t.TextColor3 = Color3.fromRGB(232, 238, 245)
    t.Text = "Маска: " .. MASK_NAME
    t.Parent = p
    local sub = Instance.new("TextLabel")
    sub.Size = UDim2.new(1, -20, 0, 18)
    sub.Position = UDim2.fromOffset(10, 28)
    sub.BackgroundTransparency = 1
    sub.Font = Enum.Font.Gotham
    sub.TextSize = 11
    sub.TextXAlignment = Enum.TextXAlignment.Left
    sub.TextColor3 = Color3.fromRGB(150, 155, 165)
    sub.Text = "кому надеть (видно только тебе)"
    sub.Parent = p
    local scroll = Instance.new("ScrollingFrame")
    scroll.Size = UDim2.new(1, -16, 1, -86)
    scroll.Position = UDim2.fromOffset(8, 50)
    scroll.BackgroundTransparency = 1
    scroll.BorderSizePixel = 0
    scroll.ScrollBarThickness = 5
    scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    scroll.Parent = p
    local list = Instance.new("UIListLayout")
    list.Padding = UDim.new(0, 4)
    list.SortOrder = Enum.SortOrder.LayoutOrder
    list.Parent = scroll

    local function addRow(text, color, order, onClick)
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(1, -6, 0, 28)
        b.BackgroundColor3 = color
        b.BorderSizePixel = 0
        b.Font = Enum.Font.GothamSemibold
        b.TextSize = 12
        b.TextColor3 = Color3.fromRGB(235, 237, 243)
        b.Text = text
        b.LayoutOrder = order
        b.Parent = scroll
        local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 7); c.Parent = b
        b.MouseButton1Click:Connect(onClick)
        return b
    end

    local order = 0
    if maskActive then
        order += 1
        addRow("СНЯТЬ МАСКУ (" .. maskActive .. ")", Color3.fromRGB(150, 50, 50), order, function()
            maskRemove()
            maskClosePanel()
        end)
    end
    local others = {}
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl ~= lp then table.insert(others, pl) end
    end
    table.sort(others, function(a, b) return a.Name:lower() < b.Name:lower() end)
    for _, pl in ipairs(others) do
        order += 1
        local pname = pl.Name
        local isCur = maskActive and string.lower(maskActive) == string.lower(pname)
        addRow((isCur and "✓ " or "") .. pname, isCur and Color3.fromRGB(40, 130, 90) or Color3.fromRGB(44, 46, 56), order, function()
            maskApplyTo(pname)
            maskClosePanel()
        end)
    end
    if #others == 0 then
        order += 1
        local l = Instance.new("TextLabel")
        l.Size = UDim2.new(1, -6, 0, 26)
        l.BackgroundTransparency = 1
        l.Font = Enum.Font.Gotham
        l.TextSize = 12
        l.TextColor3 = Color3.fromRGB(150, 155, 165)
        l.Text = "других игроков нет"
        l.LayoutOrder = order
        l.Parent = scroll
    end
    maskPanel = p
end

maskBtn.MouseButton1Click:Connect(function()
    if maskPanel then maskClosePanel() else maskOpenPanel() end
end)

startBtn.MouseButton1Click:Connect(function()
    if state.enabled then stop(); setStatus("остановлено") else start() end
end)

local setClickbox
unloadBtn.MouseButton1Click:Connect(function()
    setClickbox(false)
    stop()
    pcall(maskRemove)
    if idledConn then idledConn:Disconnect() end
    if getgenv then getgenv().__W2SellAuto = nil end
    gui:Destroy()
end)

local clickbox = nil
local lastSell = 0

local function findWorkoutCollider()
    local root = workspace:FindFirstChild("World2")
    local base = root and root:FindFirstChild("Areas_Stud_World")
    if not base then return nil end
    local function pickFrom(area)
        if not area then return nil end
        local colliders = {}
        for _, d in ipairs(area:GetDescendants()) do
            if d:IsA("ProximityPrompt") and d.ActionText == "Do Squats" and d.Parent and d.Parent:IsA("BasePart") then
                table.insert(colliders, d.Parent)
            end
        end
        if #colliders == 0 then return nil end
        local sign = area:FindFirstChild("World2MultiplierSign", true)
        local signPart = sign and sign:FindFirstChildWhichIsA("BasePart", true)
        if signPart then
            local best, bestD
            for _, c in ipairs(colliders) do
                local dd = (c.Position - signPart.Position).Magnitude
                if not bestD or dd < bestD then best, bestD = c, dd end
            end
            return best
        end
        return colliders[1]
    end
    for _, an in ipairs({ "Area10_BlackAndWhite", "Area5_MarbelGym", "Area1_Gym" }) do
        local c = pickFrom(base:FindFirstChild(an))
        if c then return c, an end
    end
    for _, a in ipairs(base:GetChildren()) do
        if a.Name:find("Gym") then
            local c = pickFrom(a)
            if c then return c, a.Name end
        end
    end
    return nil
end

local function startWorkoutTeleport()
    local part, areaName = findWorkoutCollider()
    local hrp = getHRP()
    if not hrp then return end
    if not part or areaName ~= "Area10_BlackAndWhite" then
        local anchor = area10Anchor()
        if anchor then
            hrp.CFrame = CFrame.new(anchor)
            setStatus("лечу в Area10 (x10): гружу арену", Color3.fromRGB(255, 200, 120))
            for _ = 1, 24 do
                task.wait(0.25)
                local p2, a2 = findWorkoutCollider()
                if p2 and a2 == "Area10_BlackAndWhite" then part, areaName = p2, a2 break end
                local an = area10Anchor()
                if an and (hrp.Position - an).Magnitude > 80 then hrp.CFrame = CFrame.new(an) end
            end
        end
    end
    if not part then
        setStatus("воркаут не найден", Color3.fromRGB(240, 120, 120))
        return
    end
    if activeGoal then restoreGoal(activeGoal); activeGoal = nil end
    hrp.CFrame = part.CFrame * CFrame.new(0, 6, 0)
    task.wait(0.35)
    local vim = game:GetService("VirtualInputManager")
    hotkeySuppress = true
    pcall(function()
        vim:SendKeyEvent(true, Enum.KeyCode.E, false, game)
        task.wait(0.25)
        vim:SendKeyEvent(false, Enum.KeyCode.E, false, game)
    end)
    hotkeySuppress = false
    setStatus("ТП на воркаут (" .. tostring(areaName) .. "): жми E, если не встал", Color3.fromRGB(150, 235, 180))
end

workoutBtn.MouseButton1Click:Connect(startWorkoutTeleport)

autoAllBtn.MouseButton1Click:Connect(function()
    if state.enabled and state.autoRebirth then
        stop()
        state.autoRebirth = false
        saveState()
        refresh()
        setStatus("авто всё: выключено")
    else
        state.autoRebirth = true
        saveState()
        if not state.enabled then start() end
        refresh()
        setStatus("авто всё: включено — фарм → x10 → реберт, иди занимайся", Color3.fromRGB(120, 220, 160))
    end
end)

autoRebirthBtn.MouseButton1Click:Connect(function()
    state.autoRebirth = not state.autoRebirth
    saveState()
    refresh()
    if state.autoRebirth then
        setStatus("авто-реберт включён", Color3.fromRGB(255, 220, 150))
    else
        setStatus("авто-реберт выключен")
    end
end)

task.spawn(function()
    setStatus("авто-реберт: поток запущен", Color3.fromRGB(150, 200, 255))
    local alive, err = pcall(function()
        while stillAlive() do
        if state.autoRebirth and SM() then
            local _, cost, strength = rebirthReady()
            local ready = strength >= rebirthTargetStrength(REBIRTH_DUPE_MIN)
            if ready then
                local fired = 0
                for i = 1, MULTI_REBIRTH_SHOTS do
                    if not stillAlive() then break end
                    if fired > 0 and not state.autoRebirth then break end
                    if fireRebirthRemote() then fired += 1 end
                    if i < MULTI_REBIRTH_SHOTS then task.wait(MULTI_REBIRTH_GAP) end
                end
                if fired > 0 then
                    setStatus(string.format("реберт: %d вызов(ов), сила была %s", fired, fmt(strength)), Color3.fromRGB(255, 220, 150))
                end
                task.wait(2.2)
            else
                task.wait(0.8)
            end
        else
            task.wait(0.5)
        end
    end
    end)
    if not alive then
        pcall(function() statusLabel.Text = "Статус: rebirth thread error: " .. tostring(err) end)
    end
end)

local function sellOnce()
    if os.clock() - lastSell < 0.05 then return end
    local e = pickTarget()
    if not e then return end
    lastSell = os.clock()
    if activeGoal == nil or activeTargetName ~= e.model.Name then
        placeGoal(e)
        activeTargetName = e.model.Name
    end
    burstPrompt(e.prompt, 5)
end

setClickbox = function(on)
    if clickbox then pcall(function() clickbox:Destroy() end); clickbox = nil end
    if not on then return end
    local sg = Instance.new("ScreenGui")
    sg.Name = "W2Sell_Clickbox"
    sg.ResetOnSpawn = false
    sg.IgnoreGuiInset = true
    sg.DisplayOrder = 1
    sg.Parent = parent
    local b = Instance.new("TextButton")
    b.Size = UDim2.fromOffset(150, 58)
    b.Position = UDim2.new(1, -160, 1, -74)
    b.BackgroundColor3 = Color3.fromRGB(40, 110, 90)
    b.BackgroundTransparency = 0.15
    b.Text = "ПРОДАТЬ"
    b.TextColor3 = Color3.fromRGB(255, 255, 255)
    b.Font = Enum.Font.GothamBold
    b.TextSize = 15
    b.AutoButtonColor = true
    b.Active = true
    b.ZIndex = 5
    b.Parent = sg
    local bc = Instance.new("UICorner"); bc.CornerRadius = UDim.new(0, 10); bc.Parent = b
    b.MouseButton1Click:Connect(sellOnce)
    clickbox = sg
end

clickBtn.MouseButton1Click:Connect(function()
    local on = clickbox == nil
    setClickbox(on)
    clickBtn.Text = on and "КЛИК-ПРОДАЖА: ВКЛ" or "КЛИК-ПРОДАЖА: ВЫКЛ"
    clickBtn.BackgroundColor3 = on and Color3.fromRGB(40, 110, 90) or Color3.fromRGB(60, 62, 70)
    if on then setStatus("хитбокс включён: кликай в любом месте", Color3.fromRGB(120, 220, 160)) end
end)
local collapsed = false
minBtn.MouseButton1Click:Connect(function()
    collapsed = not collapsed
    body.Visible = not collapsed
    TS:Create(root, TweenInfo.new(0.18), { Size = collapsed and UDim2.fromOffset(330, 40) or UDim2.fromOffset(330, 540) }):Play()
    minBtn.Text = collapsed and "▢" or "—"
end)

closeBtn.MouseButton1Click:Connect(function()
    setClickbox(false)
    stop()
    pcall(maskRemove)
    if idledConn then idledConn:Disconnect() end
    if getgenv then getgenv().__W2SellAuto = nil end
    gui:Destroy()
end)

local dragging, dragStart, startPos
title.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true; dragStart = input.Position; startPos = root.Position
    end
end)
UIS.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local d = input.Position - dragStart
        root.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
    end
end)
UIS.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then dragging = false end
end)

local function typingInBox()
    local ok, tb = pcall(function() return UIS:GetFocusedTextBox() end)
    return ok and tb ~= nil
end

local function setUiHidden(v)
    uiHidden = v
    root.Visible = not v
    restoreBtn.Visible = false
    if maskPanel then maskPanel.Visible = not v end
    if clickbox then clickbox.Enabled = not v end
end

hideBtn.MouseButton1Click:Connect(function()
    setUiHidden(true)
end)

restoreBtn.MouseButton1Click:Connect(function()
    setUiHidden(false)
end)

local hkConn = UIS.InputBegan:Connect(function(input, processed)
    if hotkeySuppress or typingInBox() then return end
    local key = input.KeyCode
    if key == HIDE_KEY then
        setUiHidden(not uiHidden)
    elseif key == Enum.KeyCode.E then
        if state.enabled then stop(); setStatus("остановлено (E)") else start() end
    elseif key == Enum.KeyCode.N then
        local hrp = getHRP()
        if hrp and hrp.Anchored then
            local hum = hrp.Parent and hrp.Parent:FindFirstChildOfClass("Humanoid")
            if hum then hum.Jump = true end
            local vim = game:GetService("VirtualInputManager")
            hotkeySuppress = true
            pcall(function()
                vim:SendKeyEvent(true, Enum.KeyCode.Space, false, game)
                task.wait(0.06)
                vim:SendKeyEvent(false, Enum.KeyCode.Space, false, game)
            end)
            hotkeySuppress = false
            setStatus("воркаут: стоп (слез)", Color3.fromRGB(255, 200, 120))
        else
            startWorkoutTeleport()
        end
    elseif key == Enum.KeyCode.R then
        state.autoRebirth = not state.autoRebirth
        saveState()
        refresh()
        setStatus(state.autoRebirth and "авто-реберт включён (R)" or "авто-реберт выключен (R)",
            state.autoRebirth and Color3.fromRGB(255, 220, 150) or nil)
    end
end)
if getgenv then getgenv().__W2Sell_Hotkey = hkConn end

local vu = game:GetService("VirtualUser")
idledConn = lp.Idled:Connect(function()
    pcall(function() vu:CaptureController(); vu:ClickButton2(Vector2.new()) end)
end)

-- Гасим донат/магазин/оффер-попапы, чтобы не мешали автоматизации
local BLOCK_GUI_PATTERNS = { "Donate", "Shop", "Purchase", "Offer", "StarterPack", "Gift", "Upsell", "Bundle", "Unlock", "Robux", "Store", "Premium", "VIP", "Pass", "EventLog", "Update", "Trailer", "Wheel", "Reward", "Session", "Daily", "Quest" }
local function killShopGui(inst)
    if not (inst and inst:IsA("LayerCollector")) then return end
    for _, pat in ipairs(BLOCK_GUI_PATTERNS) do
        if string.find(inst.Name, pat, 1, true) then
            pcall(function() inst.Enabled = false end)
            return
        end
    end
end

task.spawn(function()
    while stillAlive() do
        for _, c in ipairs(lp.PlayerGui:GetDescendants()) do killShopGui(c) end
        if gethui then pcall(function() for _, c in ipairs(gethui():GetDescendants()) do killShopGui(c) end end) end
        task.wait(0.25)
    end
end)
pcall(function()
    lp.PlayerGui.ChildAdded:Connect(function(c)
        task.spawn(function()
            killShopGui(c)
            task.wait(0.05)
            killShopGui(c)
        end)
    end)
end)

-- И сами запросы покупки не показываем (Roblox-попап покупки)
pcall(function()
    if not hookfunction then return end
    local MS = game:GetService("MarketplaceService")
    for _, n in ipairs({ "PromptProductPurchase", "PromptPurchase", "PromptGamePassPurchase", "PromptBundlePurchase", "PromptPremiumPurchase" }) do
        local ok, f = pcall(function() return MS[n] end)
        if ok and type(f) == "function" then pcall(hookfunction, f, function() end) end
    end
end)

-- Блокируем покупки на уровне namecall: Roblox-попап доната не появится вообще
pcall(function()
    if not (getrawmetatable and newcclosure and getnamecallmethod and setreadonly) then return end
    local mt = getrawmetatable(game)
    local old = mt.__namecall
    if type(old) ~= "function" then return end
    local blocked = {
        PromptProductPurchase = true, PromptPurchase = true, PromptGamePassPurchase = true,
        PromptBundlePurchase = true, PromptPremiumPurchase = true, PromptRobloxPurchase = true,
    }
    setreadonly(mt, false)
    mt.__namecall = newcclosure(function(self, ...)
        local m = getnamecallmethod()
        if m and blocked[m] then return nil end
        return old(self, ...)
    end)
    setreadonly(mt, true)
end)

-- Контроллер авто-цикла: фарм энергии → x10 воркаут → реберт → снова фарм
task.spawn(function()
    local lastStrength, lastGrowAt = 0, os.clock()
    while stillAlive() do
        local _, cost, strength = rebirthReady()
        local energy = tonumber(getW2()) or 0
        local target = rebirthTargetStrength(REBIRTH_DUPE_MIN)
        strength = strength or 0
        cost = cost or 1
        if not state.enabled then
            workoutMode = false
            task.wait(0.6)
        elseif workoutMode then
            -- качаем силу: стоим на x10-коллайдере и дёргаем промпт (без мыши!)
            local part = findWorkoutCollider()
            local hrp = getHRP()
            if part and hrp then
                if (hrp.Position - part.Position).Magnitude > 20 then
                    hrp.CFrame = part.CFrame * CFrame.new(0, 6, 0)
                    task.wait(0.4)
                end
                local pr
                for _, d in ipairs(part:GetDescendants()) do
                    if d:IsA("ProximityPrompt") and d.ActionText == "Do Squats" then pr = d break end
                end
                if pr then
                    if hrp.Anchored then
                        burstPrompt(pr, 5)
                    else
                        pcall(fireproximityprompt, pr)
                        task.wait(0.8)
                    end
                end
            end
            if strength ~= lastStrength then
                lastStrength = strength
                lastGrowAt = os.clock()
            end
            if strength < 1000 and energy < cost then
                workoutMode = false
                leaveWorkout()
                setStatus("авто-цикл: реберт прошёл → фарм энергии", Color3.fromRGB(255, 220, 150))
            elseif energy < cost and strength < target then
                workoutMode = false
                leaveWorkout()
                setStatus("авто-цикл: энергия кончилась → фарм", Color3.fromRGB(255, 200, 120))
            elseif os.clock() - lastGrowAt > 30 then
                workoutMode = false
                leaveWorkout()
                setStatus("авто-цикл: сила не растёт → возврат к фарму", Color3.fromRGB(255, 140, 120))
            end
            task.wait(0.03)
        elseif energy >= energyTargetNow() and strength < target then
            workoutMode = true
            lastStrength = strength
            lastGrowAt = os.clock()
            setStatus("авто-цикл: энергия " .. fmt(energy) .. " → воркаут x10", Color3.fromRGB(160, 220, 255))
            startWorkoutTeleport()
            task.wait(0.6)
        else
            task.wait(0.6)
        end
    end
end)

task.spawn(function()
    while stillAlive() do
        task.wait(2)
        if not (getgenv and getgenv().__W2FakeGain and getgenv().__W2FakeGain.Parent) then pcall(installFakeGain) end
        refresh()
    end
end)

refresh()
if state.maskTarget ~= "" then
    task.spawn(function()
        task.wait(0.6)
        if state.maskTarget ~= "" then pcall(maskEnsureLoop) end
    end)
end
hookLightItems()
-- подчищаем осиротевшую фейк-голову от прошлой маски (если маска сейчас не выбрана)
if state.maskTarget == "" then
    local orphan = workspace:FindFirstChild("Mask_Head")
    if orphan then pcall(function() orphan:Destroy() end) end
end
pcall(installFakeGain)
local k0 = findKing()
clickBtn.Text = "КЛИК-ПРОДАЖА: ВЫКЛ"
clickBtn.BackgroundColor3 = Color3.fromRGB(60, 62, 70)
setStatus(k0 and ("готов: E=старт/стоп, N=x10 воркаут, R=реберт, " .. HIDE_KEY.Name .. "=скрыть") or ("King не найден (скрыть: " .. HIDE_KEY.Name .. ")"),
    k0 and Color3.fromRGB(120, 220, 160) or Color3.fromRGB(255, 200, 120))
log("boot: place=" .. tostring(game.PlaceId) .. " king=" .. tostring(k0 ~= nil) .. " hide=" .. HIDE_KEY.Name)
