--[[
    OxyLab - цены предметов Murder Mystery 2 прямо в окне трейда.

    Показывает две вещи и ничего больше:
      * цену каждого предмета в левом нижнем углу его иконки;
      * сумму по каждой стороне справа от надписей YOUR OFFER / THEIR OFFER.

    Ни панелей, ни окон, ни кнопок. Данные готовятся заранее на ПК, поэтому
    в игре цена берётся прямым доступом по ключу и ничего не разбирается на
    лету.

    Данные: mm2_values.json, собирается parser/build_game_map.py
]]

--============================================================================
-- Настройки
--============================================================================

local CONFIG = {
    -- Зеркало с ценами. Если недоступно - берём локальный файл.
    VALUES_URL = "https://raw.githubusercontent.com/JUSTANAX/test/main/data/mm2_values.json",
    LOCAL_FILE = "mm2_values.json",
}

--============================================================================
-- Сервисы и палитра
--============================================================================

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Фолбэк нужен при ранней инъекции: LocalPlayer может быть ещё nil.
local LocalPlayer = Players.LocalPlayer or Players.PlayerAdded:Wait()

local COLORS = {
    bg      = Color3.fromHex("000000"),
    text    = Color3.fromHex("FFFFFF"),
    unknown = Color3.fromHex("A1A1A1"),
}

-- Объявляем заранее: заполняются в resolveTradeGui, но нужны функциям выше.
local YourOffer, TheirOffer, YourContainer, TheirContainer

local function log(...)
    print("[OxyLab]", ...)
end

local function warnf(...)
    warn("[OxyLab]", ...)
end

--============================================================================
-- Демонтаж предыдущего запуска
--============================================================================

local Session = {
    connections = {},
    yourTotal = nil,    -- надпись с суммой рядом с YOUR OFFER
    theirTotal = nil,   -- то же для THEIR OFFER
    lastState = nil,    -- последнее состояние трейда, для перерисовки
    simulate = nil,     -- точка входа для проверки без второго игрока
}

local function teardown(previous)
    if type(previous) ~= "table" then
        return
    end
    for _, conn in ipairs(previous.connections or {}) do
        pcall(function() conn:Disconnect() end)
    end
    local ok, pg = pcall(function() return LocalPlayer:FindFirstChild("PlayerGui") end)
    if ok and pg then
        local gui = pg:FindFirstChild("TradeGUI")
        if gui then
            for _, d in ipairs(gui:GetDescendants()) do
                if d.Name == "OxyValueTag" or d.Name == "OxyOfferTotal" then
                    pcall(function() d:Destroy() end)
                end
            end
        end
        -- Остатки прежних версий, у которых были панели и своя кнопка.
        for _, name in ipairs({ "OxyLabToast", "OxyLabButton" }) do
            local leftover = pg:FindFirstChild(name)
            if leftover then
                pcall(function() leftover:Destroy() end)
            end
        end
    end
end

--============================================================================
-- Загрузка цен
--============================================================================

local Values = nil

--- Похоже ли тело на JSON. И GitHub, и провайдеры отдают текстовые заглушки
--- («404: Not Found», HTML-страницу) с непустым телом и кодом 200. Без этой
--- проверки заглушка уезжала в JSONDecode и выглядела как «файл повреждён».
local function looksLikeJson(s)
    if type(s) ~= "string" then
        return false
    end
    local first = s:match("^%s*(.)")
    return first == "{" or first == "["
end

local function httpGet(url)
    local ok, res = pcall(function()
        return game:HttpGet(url, true)
    end)
    if ok and type(res) == "string" and #res > 0 then
        return res
    end

    -- Обращаемся к глобалам экзекьютора обычным способом, а НЕ через
    -- rawget(getfenv(), ...): rawget обходит метатаблицы, а многие
    -- экзекьюторы отдают свои глобалы через прокси с __index.
    local req = request or http_request or (syn and syn.request)
    if type(req) == "function" then
        local ok2, res2 = pcall(req, { Url = url, Method = "GET" })
        if ok2 and type(res2) == "table" and type(res2.Body) == "string" and #res2.Body > 0 then
            local code = tonumber(res2.StatusCode)
            local okStatus = res2.Success == true
                or (code ~= nil and code >= 200 and code < 300)
                or (res2.Success == nil and code == nil)
            if okStatus then
                return res2.Body
            end
        end
    end
    return nil
end

local function decodeValues(raw)
    if type(raw) ~= "string" or #raw == 0 then
        return nil, "пусто"
    end
    if not looksLikeJson(raw) then
        return nil, "это не JSON, а " .. string.format("%q", raw:sub(1, 60))
    end
    local ok, decoded = pcall(function()
        return HttpService:JSONDecode(raw)
    end)
    if not ok then
        return nil, "JSON не разобрался"
    end
    if type(decoded) ~= "table" or type(decoded.items) ~= "table" then
        return nil, "в JSON нет поля items"
    end
    return decoded
end

--- Перебирает источники. Откат срабатывает по «не разобралось», а не по «не
--- скачалось»: иначе заглушка вместо данных считалась бы успехом.
local function loadValues()
    local attempts = {}

    if CONFIG.VALUES_URL ~= "" then
        table.insert(attempts, {
            name = "сеть",
            fetch = function() return httpGet(CONFIG.VALUES_URL) end,
        })
    end
    table.insert(attempts, {
        name = "локальный файл",
        fetch = function()
            if not (isfile and readfile) or not isfile(CONFIG.LOCAL_FILE) then
                return nil
            end
            local ok, res = pcall(readfile, CONFIG.LOCAL_FILE)
            return ok and res or nil
        end,
    })

    local problems = {}
    for _, attempt in ipairs(attempts) do
        local raw = attempt.fetch()
        if raw then
            local decoded, why = decodeValues(raw)
            if decoded then
                decoded.__source = attempt.name
                return decoded
            end
            table.insert(problems, attempt.name .. ": " .. tostring(why))
        else
            table.insert(problems, attempt.name .. ": недоступно")
        end
    end
    return nil, "цены не загрузились — " .. table.concat(problems, "; ")
end

--- Данные по предмету. nil - предмет неизвестен.
local function lookup(itemType, itemId)
    if not Values then
        return nil
    end
    local bucket = Values.items[itemType]
    return bucket and bucket[tostring(itemId)] or nil
end

--============================================================================
-- Формат чисел
--============================================================================

local function trimZeros(s)
    return (s:gsub("%.?0+$", ""))
end

--- 1500000 -> «1.5m», 27000 -> «27k», 0.002 -> «0.002»
local function formatValue(v)
    if type(v) ~= "number" then
        return "?"
    end
    local abs = math.abs(v)
    if abs >= 1e6 then
        return trimZeros(string.format("%.2f", v / 1e6)) .. "m"
    elseif abs >= 1e3 then
        return trimZeros(string.format("%.1f", v / 1e3)) .. "k"
    elseif abs >= 1 then
        return trimZeros(string.format("%.1f", v))
    elseif abs > 0 then
        return trimZeros(string.format("%.3f", v))
    end
    return "0"
end

--============================================================================
-- Ярлык с ценой на иконке
--============================================================================

local TAG_NAME = "OxyValueTag"

local function buildTag(parent)
    local frame = Instance.new("Frame")
    frame.Name = TAG_NAME
    frame.AnchorPoint = Vector2.new(0, 1)
    frame.Size = UDim2.new(1, -4, 0, 24)
    frame.BackgroundColor3 = COLORS.bg
    frame.BackgroundTransparency = 0.2
    frame.BorderSizePixel = 0
    frame.ZIndex = 50
    frame.Visible = false
    frame.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 4)
    corner.Parent = frame

    local pad = Instance.new("UIPadding")
    pad.PaddingLeft = UDim.new(0, 5)
    pad.PaddingRight = UDim.new(0, 5)
    pad.Parent = frame

    -- TextScaled выключен намеренно: иначе на длинном числе шрифт схлопнется
    -- в нечитаемый, а нам важнее обрезать хвост.
    local value = Instance.new("TextLabel")
    value.Name = "Value"
    value.BackgroundTransparency = 1
    value.Size = UDim2.new(1, 0, 1, 0)
    value.Font = Enum.Font.GothamBold
    value.TextSize = 17
    value.TextColor3 = COLORS.text
    value.TextXAlignment = Enum.TextXAlignment.Left
    value.TextYAlignment = Enum.TextYAlignment.Center
    value.TextTruncate = Enum.TextTruncate.AtEnd
    value.ZIndex = 51
    value.Parent = frame

    return frame
end

local function getTag(slot)
    local container = slot:FindFirstChild("Container")
    if not container then
        return nil
    end
    return container:FindFirstChild(TAG_NAME) or buildTag(container)
end

--- Суммарная высота видимых игровых бейджей (Chroma, FX и прочих).
---
--- Они лежат в NewItem.Tags - это СОСЕД Container, а не потомок. При
--- ZIndexBehavior = Sibling порядок отрисовки задаёт очередь детей
--- (Container, ItemName, Tags), поэтому бейджи всегда поверх нашего ярлыка
--- независимо от ZIndex. Перебить это нельзя, можно только не пересекаться.
--- Высоты разные (Chroma и FX по 16.875, Unique 18), поэтому считаем на лету.
local function badgeStackHeight(slot)
    local tags = slot:FindFirstChild("Tags")
    if not tags then
        return 0
    end
    local height = 0
    for _, badge in ipairs(tags:GetChildren()) do
        if badge:IsA("Frame") and badge.Visible then
            height = height + badge.AbsoluteSize.Y
        end
    end
    return height
end

-- Высота бейджа дробная, поэтому без явного зазора они слипаются.
local BADGE_GAP = 4

local function placeTag(slot, tag)
    local lift = badgeStackHeight(slot)
    if lift > 0 then
        lift = lift + BADGE_GAP
    end
    tag.Position = UDim2.new(0, 2, 1, -2 - lift)
end

--- Рисует цену предмета. data = nil - предмет неизвестен.
local function paintTag(slot, data)
    local tag = getTag(slot)
    if not tag then
        return
    end

    -- Бартер, неоценённые и неподтверждённые выглядят одинаково: серый «?».
    -- Показать выдуманное число хуже, чем честно признать, что его нет.
    if not data or data.kind ~= "number" or type(data.value) ~= "number" then
        tag.Value.Text = "?"
        tag.Value.TextColor3 = COLORS.unknown
    else
        tag.Value.Text = formatValue(data.value)
        tag.Value.TextColor3 = COLORS.text
    end

    placeTag(slot, tag)
    tag.Visible = true

    -- Игра могла показать бейджи в том же кадре, и их AbsoluteSize ещё не
    -- пересчитан. Повторяем замер следующим кадром.
    task.defer(function()
        if tag.Parent then
            placeTag(slot, tag)
        end
    end)
end

local function hideTags(container)
    if not container then
        return
    end
    for _, child in ipairs(container:GetChildren()) do
        if child:IsA("Frame") then
            local inner = child:FindFirstChild("Container")
            local tag = inner and inner:FindFirstChild(TAG_NAME)
            if tag then
                tag.Visible = false
            end
        end
    end
end

--============================================================================
-- Итог стороны рядом с YOUR OFFER / THEIR OFFER
--============================================================================

local TOTAL_NAME = "OxyOfferTotal"
local TOTAL_WIDTH = 150

local function buildOfferTotal(offer)
    if not offer then
        return nil
    end
    local old = offer:FindFirstChild(TOTAL_NAME)
    if old then
        old:Destroy()
    end

    local label = Instance.new("TextLabel")
    label.Name = TOTAL_NAME
    label.AnchorPoint = Vector2.new(1, 0.5)
    label.Size = UDim2.new(0, TOTAL_WIDTH, 0, 26)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamBold
    label.TextSize = 22
    label.TextColor3 = COLORS.text
    label.TextXAlignment = Enum.TextXAlignment.Right
    label.TextYAlignment = Enum.TextYAlignment.Center
    label.TextTruncate = Enum.TextTruncate.AtEnd
    label.TextStrokeColor3 = COLORS.bg
    label.TextStrokeTransparency = 0.35
    label.ZIndex = 30
    label.Text = ""
    label.Parent = offer
    return label
end

--- Ставит итог справа, на одной высоте с заголовком оффера.
---
--- У THEIR OFFER справа уже стоит имя игрока, поэтому сдвигаемся левее него.
--- Координаты не зашиваем: считаем от реальных размеров, чтобы вёрстка не
--- поехала на другом разрешении.
local function placeOfferTotal(offer, label)
    if not offer or not label then
        return
    end
    local title = offer:FindFirstChild("Title")
    local yOffset = 14
    if title and title.AbsoluteSize.Y > 0 then
        yOffset = (title.AbsolutePosition.Y - offer.AbsolutePosition.Y)
            + title.AbsoluteSize.Y / 2
    end

    local rightGap = 6
    local username = offer:FindFirstChild("Username")
    if username and username.Visible and username.AbsoluteSize.X > 0 then
        -- Имя оппонента прижато вправо: встаём слева от него.
        local usernameLeft = username.AbsolutePosition.X - offer.AbsolutePosition.X
        rightGap = math.max(6, offer.AbsoluteSize.X - usernameLeft + 10)
    end

    label.Position = UDim2.new(1, -rightGap, 0, yOffset)
end

--============================================================================
-- Подсчёт
--============================================================================

--- Сумма по стороне и сколько предметов в неё не попало.
local function summarise(offer)
    local total, skipped = 0, 0
    for _, entry in pairs(offer or {}) do
        local itemId = entry[1] or entry.ItemID
        local amount = entry[2] or entry.Amount or 1
        local itemType = entry[3] or entry.ItemType
        local data = lookup(itemType, itemId)

        if data and data.kind == "number" and type(data.value) == "number" then
            total = total + data.value * amount
        else
            skipped = skipped + 1
        end
    end
    return total, skipped
end

--============================================================================
-- Обработка трейда
--============================================================================

local function resolveTradeGui()
    local pg = LocalPlayer:WaitForChild("PlayerGui", 20)
    if not pg then
        return false, "PlayerGui не появился"
    end
    local gui = pg:WaitForChild("TradeGUI", 20)
    if not gui then
        return false, "TradeGUI не найден — ты точно в MM2?"
    end
    local trade = gui:FindFirstChild("Container") and gui.Container:FindFirstChild("Trade")
    if not trade then
        return false, "TradeGUI.Container.Trade отсутствует — разметка игры изменилась"
    end
    local yours = trade:FindFirstChild("YourOffer")
    local theirs = trade:FindFirstChild("TheirOffer")
    if not yours or not theirs then
        return false, "не найдены YourOffer/TheirOffer"
    end
    if not yours:FindFirstChild("Container") or not theirs:FindFirstChild("Container") then
        return false, "не найдены контейнеры предметов"
    end

    YourOffer, TheirOffer = yours, theirs
    YourContainer, TheirContainer = yours.Container, theirs.Container
    return true
end

local function renderSide(container, offer)
    hideTags(container)
    for index, entry in pairs(offer or {}) do
        local slot = container:FindFirstChild("NewItem" .. index)
        if slot then
            local itemId = entry[1] or entry.ItemID
            local itemType = entry[3] or entry.ItemType
            paintTag(slot, lookup(itemType, itemId))
        end
    end
end

local function onUpdateTrade(state)
    if type(state) ~= "table" or not state.Player1 or not state.Player2 then
        return
    end

    local mine, theirs
    if state.Player1.Player == LocalPlayer then
        mine, theirs = state.Player1, state.Player2
    elseif state.Player2.Player == LocalPlayer then
        mine, theirs = state.Player2, state.Player1
    else
        return
    end

    Session.lastState = state

    renderSide(YourContainer, mine.Offer)
    renderSide(TheirContainer, theirs.Offer)

    local mineTotal, mineSkipped = summarise(mine.Offer)
    local theirTotal, theirSkipped = summarise(theirs.Offer)

    -- Числовая цена есть меньше чем у половины каталога, поэтому сумма с
    -- пропущенными предметами - приблизительная, и это надо показать.
    for _, side in ipairs({
        { offer = YourOffer, label = Session.yourTotal, sum = mineTotal, skipped = mineSkipped },
        { offer = TheirOffer, label = Session.theirTotal, sum = theirTotal, skipped = theirSkipped },
    }) do
        if side.label then
            side.label.Text = (side.skipped > 0 and "≈" or "") .. formatValue(side.sum)
            placeOfferTotal(side.offer, side.label)
        end
    end
end

local function clearTotals()
    for _, label in ipairs({ Session.yourTotal, Session.theirTotal }) do
        if label then
            label.Text = ""
        end
    end
end

--============================================================================
-- Запуск
--============================================================================

local function main()
    local err
    Values, err = loadValues()
    if not Values then
        warnf(err)
        return
    end

    local ok, why = resolveTradeGui()
    if not ok then
        warnf(why)
        return
    end

    -- Точка невозврата: всё, что могло помешать старту, уже проверено.
    teardown(rawget(_G, "OxyLab") or rawget(_G, "MM2Value"))
    _G.OxyLab = Session
    _G.MM2Value = Session

    -- Ярлыки создаём заранее для всех восьми слотов: они статичны, игра их
    -- только показывает и прячет.
    for _, container in ipairs({ YourContainer, TheirContainer }) do
        for i = 1, 4 do
            local slot = container:FindFirstChild("NewItem" .. i)
            if slot then
                getTag(slot)
            end
        end
    end

    Session.yourTotal = buildOfferTotal(YourOffer)
    Session.theirTotal = buildOfferTotal(TheirOffer)

    local tradeFolder = ReplicatedStorage:WaitForChild("Trade", 20)
    if not tradeFolder then
        warnf("ReplicatedStorage.Trade не найден")
        return
    end

    -- Через FindFirstChild, а не прямым индексом: если игру пропатчат и
    -- ремоут переименуют, прямой индекс уронил бы весь запуск вместо
    -- понятного сообщения.
    local updateRemote = tradeFolder:FindFirstChild("UpdateTrade")
    if not updateRemote then
        warnf("Trade.UpdateTrade не найден — разметка игры изменилась")
        return
    end

    table.insert(Session.connections, updateRemote.OnClientEvent:Connect(function(state)
        local okRun, runErr = pcall(onUpdateTrade, state)
        if not okRun then
            warnf("ошибка при обработке трейда: " .. tostring(runErr))
        end
    end))

    local declineRemote = tradeFolder:FindFirstChild("DeclineTrade")
    if declineRemote then
        table.insert(Session.connections, declineRemote.OnClientEvent:Connect(function()
            hideTags(YourContainer)
            hideTags(TheirContainer)
            clearTotals()
        end))
    end

    -- Проверка без второго игрока:
    --   _G.OxyLab.simulate({{"SeerChroma",1,"Weapons"}}, {{"Batwing",1,"Weapons"}})
    Session.simulate = function(mineOffer, theirOffer, drawCards)
        -- drawCards ~= false: рисуем и сами карточки так же, как это делает
        -- игра, иначе проверка обходит ItemModule.DisplayItem - ровно тот код,
        -- который теоретически мог бы снести наши ярлыки.
        if drawCards ~= false then
            pcall(function()
                local Sync = require(ReplicatedStorage.Database.Sync)
                local ItemModule = require(ReplicatedStorage.Modules.ItemModule)
                local function draw(container, offer)
                    for i = 1, 4 do
                        local slot = container:FindFirstChild("NewItem" .. i)
                        if slot then
                            slot.Visible = false
                        end
                    end
                    for index, entry in pairs(offer or {}) do
                        local itemId = entry[1] or entry.ItemID
                        local amount = entry[2] or entry.Amount or 1
                        local itemType = entry[3] or entry.ItemType
                        local slot = container:FindFirstChild("NewItem" .. index)
                        local record = Sync[itemType] and Sync[itemType][itemId]
                        if slot and record then
                            local payload = { DataType = itemType, Amount = amount }
                            for k, v in pairs(record) do
                                payload[k] = v
                            end
                            ItemModule.DisplayItem(slot, payload, amount)
                            slot.Visible = true
                        end
                    end
                end
                draw(YourContainer, mineOffer)
                draw(TheirContainer, theirOffer)
            end)
        end

        onUpdateTrade({
            Player1 = { Player = LocalPlayer, Offer = mineOffer or {} },
            Player2 = { Player = { Name = "ТестОппонент" }, Offer = theirOffer or {} },
        })
    end

    local stats = Values.stats or {}
    log(string.format(
        "цены загружены из «%s»: %d предметов, %d с ценой, данные сайта от %s",
        tostring(Values.__source),
        (stats.weapons or 0) + (stats.pets or 0),
        stats.priced or 0,
        tostring(Values.sourceUpdatedIso)))
    log("жду начала трейда")
end

main()
