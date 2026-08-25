--[[
    MM2Value - оверлей ценностей Murder Mystery 2.

    Показывает ценность каждого предмета в левом нижнем углу его иконки внутри
    игрового окна трейда и считает итог обеих сторон в отдельной панели WindUI.

    Как это работает:
      * Слоты трейда (NewItem1..4 в YourOffer и TheirOffer) существуют заранее и
        только переключают Visible - клонировать ничего не нужно, ярлыки вешаются
        один раз при старте.
      * Trade.UpdateTrade приходит с массивом {ItemID, Amount, ItemType}, где
        ItemID - внутренний ключ базы игры. Сопоставление с сайтом уже сделано
        на стороне ПК, поэтому здесь просто прямой доступ по ключу.

    Данные: mm2_values.json, собирается parser/build_game_map.py
]]

--============================================================================
-- Настройки
--============================================================================

local CONFIG = {
    -- Зеркало на GitHub. Если недоступно, оверлей молча падает на локальный
    -- файл - трейд не должен ломаться из-за сети.
    VALUES_URL = "https://raw.githubusercontent.com/JUSTANAX/test/main/data/mm2_values.json",

    -- Запасной путь: файл в Workspace экзекьютора.
    LOCAL_FILE = "mm2_values.json",

    WINDUI_URL = "https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua",

    SHOW_TAGS = true,
    TAG_HEIGHT = 30,
}

--============================================================================
-- Сервисы и базовые ссылки
--============================================================================

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Фолбэк нужен для ранней инъекции (autoexec, сразу после телепорта): там
-- LocalPlayer может быть ещё nil, и захват без ожидания ронял бы весь скрипт.
local LocalPlayer = Players.LocalPlayer or Players.PlayerAdded:Wait()

-- Палитра: чистый чёрный, голубой, синий, белый.
--
-- Каждая пара «текст на фоне» посчитана по WCAG 2.1 и проходит AA. Числа в
-- комментариях - реальные коэффициенты контраста, а не оценка на глаз.
--
-- Главное, что стоит знать при правках: карточка отделяется от панели НЕ
-- заливкой. cardBg к чёрному даёт всего 1.34 - на почти-чёрном фоне залить
-- карточку так, чтобы её было видно, физически невозможно без ухода в серый.
-- Границу держит обводка: 4.90 к карточке и 6.23 к панели. Поэтому нельзя
-- поднимать strokeTransparency - панель мгновенно развалится в пятно.
local COLORS = {
    bg       = Color3.fromHex("000000"),  -- панель, тот самый супер-чёрный
    surface  = Color3.fromHex("16233A"),  -- карточка
    stroke   = Color3.fromHex("6E9FD6"),  -- кант, держит границу карточки
    text     = Color3.fromHex("FFFFFF"),  -- 15.72 на карточке, 21.0 на панели
    muted    = Color3.fromHex("A9C8EA"),  -- 9.09 на карточке (запас вдвое)
    unknown  = Color3.fromHex("A9C8EA"),
    accent   = Color3.fromHex("66B8F5"),  -- 7.29 на карточке
    primary  = Color3.fromHex("48CCF2"),  -- голубой, точка в шапке
    listName = Color3.fromHex("FFFFFF"),
    up       = Color3.fromHex("96F4FF"),  -- рост, 12.49 на карточке
    down     = Color3.fromHex("6690FF"),  -- падение, 5.24
    good     = Color3.fromHex("96F4FF"),
    bad      = Color3.fromHex("6690FF"),
    even     = Color3.fromHex("A9C8EA"),
}

-- 0 = непрозрачно. Значение подобрано так, чтобы кант давал 4.90 к карточке.
local STROKE_TRANSPARENCY = 0.10

local RADIUS_WINDOW = 16
local RADIUS_ELEMENT = 8

-- Цветная метка стороны читается быстрее, чем префикс «ты:» в тексте.
-- Пара разведена и по тону, и по яркости: 3.12 друг к другу, обе проходят
-- порог 3.0 для графики на обоих фонах.
local SIDE_COLOR = {
    mine   = Color3.fromHex("74DDFF"),
    theirs = Color3.fromHex("4169E1"),
}

-- Объявляем заранее: эти ссылки заполняются в resolveTradeGui, но нужны
-- функциям, которые определены выше по файлу. Без forward declaration они
-- увидели бы глобальную nil вместо локальной переменной.
local TradeFrame, YourContainer, TheirContainer

local function log(...)
    print("[MM2Value]", ...)
end

local function warnf(...)
    warn("[MM2Value]", ...)
end

--============================================================================
-- Демонтаж предыдущего запуска
--
-- Скрипт запускают руками и нередко несколько раз подряд. Без этого блока
-- каждый запуск добавлял бы ещё одно окно WindUI и ещё один обработчик
-- UpdateTrade - итог считался бы дважды.
--============================================================================

local Session = { connections = {}, window = nil }

local function teardown(previous)
    if type(previous) ~= "table" then
        return
    end
    for _, conn in ipairs(previous.connections or {}) do
        pcall(function() conn:Disconnect() end)
    end
    if previous.window then
        pcall(function() previous.window:Destroy() end)
    end
    -- Ярлыки принадлежат игровому GUI и переживают перезапуск скрипта,
    -- поэтому их надо снять явно.
    local ok, pg = pcall(function() return LocalPlayer:FindFirstChild("PlayerGui") end)
    if ok and pg then
        local gui = pg:FindFirstChild("TradeGUI")
        if gui then
            for _, d in ipairs(gui:GetDescendants()) do
                if d.Name == "MM2ValueTag" or d.Name == "MM2ValuePanel" then
                    pcall(function() d:Destroy() end)
                end
            end
        end
    end
end

-- Внимание: teardown НЕ вызывается здесь. Он срабатывает в main() только
-- после того, как ценности загрузились и окно трейда найдено. Иначе неудачный
-- перезапуск (нет сети, не та игра) сносил бы рабочий оверлей и не ставил
-- ничего взамен — прямо посреди открытого трейда.

--============================================================================
-- Загрузка данных
--============================================================================

local Values = nil

--- Похоже ли тело на JSON. Нужно потому, что и GitHub, и провайдеры отдают
--- текстовые заглушки («404: Not Found», HTML-страницу) с непустым телом,
--- а иногда и с кодом 200. Без этой проверки такая заглушка уезжает в
--- JSONDecode и выглядит как «файл повреждён», хотя проблема в сети.
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
    -- Некоторые экзекьюторы дают только request/http_request.
    --
    -- Обращаемся обычным способом, а НЕ через rawget(getfenv(), ...): rawget
    -- обходит метатаблицы, а многие экзекьюторы отдают свои глобалы через
    -- прокси с __index. Там rawget вернул бы nil при живой функции, и запасной
    -- путь молча не сработал бы.
    local req = request or http_request or (syn and syn.request)
    if type(req) == "function" then
        local ok2, res2 = pcall(req, { Url = url, Method = "GET" })
        if ok2 and type(res2) == "table" and type(res2.Body) == "string" and #res2.Body > 0 then
            -- Здесь статус доступен, в отличие от game:HttpGet - и его надо
            -- проверять: 404 приходит с осмысленным телом, которое иначе
            -- уедет дальше как данные.
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

--- Разбирает тело в таблицу ценностей. nil и причина, если не вышло.
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

--- Перебирает источники по очереди. Откат срабатывает не по «не скачалось», а
--- по «не разобралось»: иначе заглушка вместо данных считалась бы успехом и
--- локальный файл не пробовался бы никогда.
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

    return nil, "ценности не загрузились — " .. table.concat(problems, "; ")
end

--- Данные по предмету из карты. nil - предмет неизвестен.
local function lookup(itemType, itemId)
    if not Values then
        return nil
    end
    local bucket = Values.items[itemType]
    if not bucket then
        -- В событии тип приходит как ключ базы: Weapons / Pets.
        return nil
    end
    return bucket[tostring(itemId)]
end

--============================================================================
-- Форматирование
--============================================================================

local function trimZeros(s)
    s = s:gsub("%.?0+$", "")
    return s
end

--- 1500000 -> "1.5m", 27000 -> "27k", 0.002 -> "0.002"
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

--- Стрелка тренда с цветом. Пустая строка, если тренда нет.
local function formatTrend(trend)
    if type(trend) ~= "string" or trend == "" then
        return ""
    end
    local num = tonumber((trend:gsub("[%%+]", "")))
    if not num or num == 0 then
        return ""
    end
    local color = num > 0 and COLORS.up or COLORS.down
    local arrow = num > 0 and "▲" or "▼"
    -- math.floor обязателен: компоненты Color3 - дробные 0..1, а спецификатор
    -- %X ждёт целое. Без округления это зависит от реализации string.format
    -- и может упасть на другом рантайме.
    return string.format(
        ' <font color="#%02X%02X%02X">%s</font>',
        math.floor(color.R * 255 + 0.5),
        math.floor(color.G * 255 + 0.5),
        math.floor(color.B * 255 + 0.5),
        arrow
    )
end

--============================================================================
-- Ярлыки на иконках
--============================================================================

local TAG_NAME = "MM2ValueTag"

local function buildTag(parent)
    local frame = Instance.new("Frame")
    frame.Name = TAG_NAME
    frame.AnchorPoint = Vector2.new(0, 1)
    frame.Position = UDim2.new(0, 2, 1, -2)
    frame.Size = UDim2.new(1, -4, 0, CONFIG.TAG_HEIGHT)
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
    pad.PaddingLeft = UDim.new(0, 4)
    pad.PaddingRight = UDim.new(0, 4)
    pad.Parent = frame

    -- Ценность. TextScaled выключен намеренно: иначе на длинном числе шрифт
    -- схлопнется в нечитаемый, а нам важнее обрезать хвост.
    local value = Instance.new("TextLabel")
    value.Name = "Value"
    value.BackgroundTransparency = 1
    value.Position = UDim2.new(0, 0, 0, 1)
    value.Size = UDim2.new(1, 0, 0, 16)
    value.Font = Enum.Font.GothamBold
    value.TextSize = 14
    value.TextColor3 = COLORS.text
    value.TextXAlignment = Enum.TextXAlignment.Left
    value.TextYAlignment = Enum.TextYAlignment.Center
    value.TextTruncate = Enum.TextTruncate.AtEnd
    value.ZIndex = 51
    value.Parent = frame

    -- Спрос, редкость, тренд. RichText нужен, чтобы покрасить только стрелку.
    local meta = Instance.new("TextLabel")
    meta.Name = "Meta"
    meta.BackgroundTransparency = 1
    meta.Position = UDim2.new(0, 0, 0, 16)
    meta.Size = UDim2.new(1, 0, 0, 12)
    meta.Font = Enum.Font.Gotham
    meta.TextSize = 10
    meta.TextColor3 = COLORS.muted
    meta.TextXAlignment = Enum.TextXAlignment.Left
    meta.TextYAlignment = Enum.TextYAlignment.Center
    meta.TextTruncate = Enum.TextTruncate.AtEnd
    meta.RichText = true
    meta.ZIndex = 51
    meta.Parent = frame

    return frame
end

local function getTag(slot)
    local container = slot:FindFirstChild("Container")
    if not container then
        return nil
    end
    return container:FindFirstChild(TAG_NAME) or buildTag(container)
end

--- Суммарная высота видимых игровых бейджей (Chroma, FX, Halloween и прочих).
---
--- Они лежат в NewItem.Tags - это СОСЕД Container, а не потомок. При
--- ZIndexBehavior = Sibling порядок отрисовки задаёт очередь детей
--- (Container, ItemName, Tags), поэтому бейджи всегда поверх нашего ярлыка
--- независимо от ZIndex. Перебить это нельзя, можно только не пересекаться.
---
--- Высоты разные: Chroma и FX по 16px, Halloween и Christmas по 37px,
--- Unique 18px - фиксированный отступ не подошёл бы.
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

-- Зазор между ярлыком и бейджем. Высота бейджа дробная (16.875), поэтому
-- без явного отступа они сходятся впритык и визуально слипаются.
local BADGE_GAP = 4

--- Ставит ярлык в левый нижний угол иконки, но выше игровых бейджей.
local function placeTag(slot, tag)
    local lift = badgeStackHeight(slot)
    if lift > 0 then
        lift = lift + BADGE_GAP
    end
    tag.Position = UDim2.new(0, 2, 1, -2 - lift)
end

--- Заполняет ярлык данными предмета. data = nil означает "предмет неизвестен".
local function paintTag(slot, data)
    local tag = getTag(slot)
    if not tag then
        return
    end
    if not CONFIG.SHOW_TAGS then
        tag.Visible = false
        return
    end

    local valueLabel = tag.Value
    local metaLabel = tag.Meta

    -- Неизвестен, бартер, Coming Soon и предметы без ценности выглядят
    -- одинаково - серый "?". Подробности уходят в панель итогов.
    if not data or data.kind ~= "number" or type(data.value) ~= "number" then
        valueLabel.Text = "?"
        valueLabel.TextColor3 = COLORS.unknown
        metaLabel.Text = data and (data.gameRarity or "") or ""
    else
        valueLabel.Text = formatValue(data.value)
        valueLabel.TextColor3 = COLORS.text

        local parts = {}
        if data.demand and data.demand ~= "" then
            table.insert(parts, "D" .. data.demand)
        end
        if data.rarity and data.rarity ~= "" then
            table.insert(parts, "R" .. data.rarity)
        end
        metaLabel.Text = table.concat(parts, " ") .. formatTrend(data.trend)
    end

    placeTag(slot, tag)
    tag.Visible = true

    -- Игра могла показать бейджи в том же кадре, и их AbsoluteSize ещё не
    -- пересчитан. Повторяем замер следующим кадром - иначе на первом
    -- обновлении ярлык изредка садится на бейдж.
    task.defer(function()
        if tag.Parent then
            placeTag(slot, tag)
        end
    end)
end

local function hideTags(container)
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
-- Подсчёт итогов
--============================================================================

--- Возвращает сумму по стороне и список того, что в неё не попало.
local function summarise(offer)
    local total, counted = 0, 0
    local excluded = {}

    for _, entry in pairs(offer or {}) do
        local itemId = entry[1] or entry.ItemID
        local amount = entry[2] or entry.Amount or 1
        local itemType = entry[3] or entry.ItemType
        local data = lookup(itemType, itemId)

        if data and data.kind == "number" and type(data.value) == "number" then
            total = total + data.value * amount
            counted = counted + 1
        else
            -- Отдаём разобранным на части: название и причину рисуем разными
            -- строками, иначе они склеиваются в сплошной текст и рвутся
            -- переносом посреди фразы.
            local name, reason
            if not data then
                name, reason = tostring(itemId), "нет на сайте"
            elseif data.kind == "barter" then
                name = data.name or tostring(itemId)
                reason = data.text or "цена бартером"
            elseif data.kind == "coming-soon" then
                name, reason = data.name or tostring(itemId), "ещё не оценён"
            else
                name, reason = data.name or tostring(itemId), "без ценности"
            end
            if amount > 1 then
                name = name .. "  ×" .. amount
            end
            table.insert(excluded, { name = name, reason = reason })
        end
    end

    return total, counted, excluded
end

--============================================================================
-- Панель WindUI
--============================================================================

local UI = { panel = nil, window = nil, rows = {} }

local PANEL_NAME = "MM2ValuePanel"
local PANEL_WIDTH = 248

--- Строка «подпись — значение». Подпись слева, значение справа, каждое в своей
--- половине: длинное число не наезжает на подпись, длинная подпись обрезается.
--- Обе половины выровнены по центру строки, поэтому разный кегль не ломает
--- базовую линию.
local function buildRow(parent, order, caption, valueSize)
    local row = Instance.new("Frame")
    row.Name = "Row_" .. caption
    row.BackgroundTransparency = 1
    row.Size = UDim2.new(1, 0, 0, 27)
    row.LayoutOrder = order
    row.Parent = parent

    local label = Instance.new("TextLabel")
    label.Name = "Caption"
    label.BackgroundTransparency = 1
    label.AnchorPoint = Vector2.new(0, 0.5)
    label.Position = UDim2.new(0, 0, 0.5, 0)
    label.Size = UDim2.new(0.54, 0, 1, 0)
    label.Font = Enum.Font.GothamMedium
    label.TextSize = 15
    label.TextColor3 = COLORS.muted
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextYAlignment = Enum.TextYAlignment.Center
    label.TextTruncate = Enum.TextTruncate.AtEnd
    label.Text = caption
    label.Parent = row

    local value = Instance.new("TextLabel")
    value.Name = "Value"
    value.BackgroundTransparency = 1
    value.AnchorPoint = Vector2.new(1, 0.5)
    value.Position = UDim2.new(1, 0, 0.5, 0)
    value.Size = UDim2.new(0.46, 0, 1, 0)
    value.Font = Enum.Font.GothamBold
    value.TextSize = valueSize or 18
    value.TextColor3 = COLORS.text
    value.TextXAlignment = Enum.TextXAlignment.Right
    value.TextYAlignment = Enum.TextYAlignment.Center
    value.TextTruncate = Enum.TextTruncate.AtEnd
    value.Text = "—"
    value.Parent = row

    return value
end

--- Карточка в духе WindUI: скруглённый блок ElementBackground с отступами.
local function buildCard(parent, order, heightScale, heightOffset)
    local card = Instance.new("Frame")
    card.Name = "Card"
    card.BackgroundColor3 = COLORS.surface
    card.BorderSizePixel = 0
    card.Size = UDim2.new(1, 0, heightScale or 0, heightOffset or 0)
    card.AutomaticSize = (heightScale == nil and heightOffset == nil)
        and Enum.AutomaticSize.Y or Enum.AutomaticSize.None
    card.LayoutOrder = order
    card.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, RADIUS_ELEMENT)
    corner.Parent = card

    -- Именно кант отделяет карточку от чёрной панели: заливка даёт всего 1.34,
    -- обводка - 4.90. Без неё карточка сливается с фоном.
    local cardStroke = Instance.new("UIStroke")
    cardStroke.Color = COLORS.stroke
    cardStroke.Transparency = STROKE_TRANSPARENCY
    cardStroke.Thickness = 1
    cardStroke.Parent = card

    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0, 8)
    pad.PaddingBottom = UDim.new(0, 8)
    pad.PaddingLeft = UDim.new(0, 12)
    pad.PaddingRight = UDim.new(0, 12)
    pad.Parent = card

    local list = Instance.new("UIListLayout")
    list.FillDirection = Enum.FillDirection.Vertical
    list.SortOrder = Enum.SortOrder.LayoutOrder
    list.Padding = UDim.new(0, 2)
    list.Parent = card

    return card
end

--- Панель живёт внутри TradeGUI, поэтому появляется и исчезает вместе с окном
--- трейда и не может уехать в угол экрана, как отдельное окно.
local function buildTradePanel()
    if not TradeFrame then
        return nil
    end
    local old = TradeFrame:FindFirstChild(PANEL_NAME)
    if old then
        old:Destroy()
    end

    local panel = Instance.new("Frame")
    panel.Name = PANEL_NAME
    panel.AnchorPoint = Vector2.new(0, 0)
    panel.Position = UDim2.new(1, 10, 0, 0)
    panel.Size = UDim2.new(0, PANEL_WIDTH, 1, 0)
    panel.BackgroundColor3 = COLORS.bg
    panel.BorderSizePixel = 0
    panel.ZIndex = 5
    panel.Parent = TradeFrame

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, RADIUS_WINDOW)
    corner.Parent = panel

    local stroke = Instance.new("UIStroke")
    stroke.Color = COLORS.stroke
    stroke.Transparency = STROKE_TRANSPARENCY
    stroke.Thickness = 1
    stroke.Parent = panel

    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0, 12)
    pad.PaddingBottom = UDim.new(0, 12)
    pad.PaddingLeft = UDim.new(0, 12)
    pad.PaddingRight = UDim.new(0, 12)
    pad.Parent = panel

    local list = Instance.new("UIListLayout")
    list.FillDirection = Enum.FillDirection.Vertical
    list.SortOrder = Enum.SortOrder.LayoutOrder
    list.Padding = UDim.new(0, 8)
    list.Parent = panel

    -- Шапка. Иконка и текст в одной строке, обе выровнены по центру.
    local header = Instance.new("Frame")
    header.Name = "Header"
    header.BackgroundTransparency = 1
    header.Size = UDim2.new(1, 0, 0, 24)
    header.LayoutOrder = 1
    header.Parent = panel

    local dot = Instance.new("Frame")
    dot.Name = "Dot"
    dot.AnchorPoint = Vector2.new(0, 0.5)
    dot.Position = UDim2.new(0, 0, 0.5, 0)
    dot.Size = UDim2.new(0, 8, 0, 8)
    dot.BackgroundColor3 = COLORS.primary
    dot.BorderSizePixel = 0
    dot.Parent = header
    local dotCorner = Instance.new("UICorner")
    dotCorner.CornerRadius = UDim.new(1, 0)
    dotCorner.Parent = dot

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.BackgroundTransparency = 1
    title.AnchorPoint = Vector2.new(0, 0.5)
    title.Position = UDim2.new(0, 16, 0.5, 0)
    title.Size = UDim2.new(1, -16, 1, 0)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 16
    title.TextColor3 = COLORS.text
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextYAlignment = Enum.TextYAlignment.Center
    title.Text = "MM2Value"
    title.Parent = header

    -- Карточка с итогами
    local totalsCard = buildCard(panel, 2, 0, 104)
    UI.rows.mine = buildRow(totalsCard, 1, "Ты", 18)
    UI.rows.theirs = buildRow(totalsCard, 2, "Оппонент", 18)

    local divider = Instance.new("Frame")
    divider.Name = "Divider"
    divider.Size = UDim2.new(1, 0, 0, 1)
    divider.BackgroundColor3 = COLORS.stroke
    divider.BackgroundTransparency = 0.6
    divider.BorderSizePixel = 0
    divider.LayoutOrder = 3
    divider.Parent = totalsCard

    UI.rows.diff = buildRow(totalsCard, 4, "Разница", 21)

    local verdict = Instance.new("TextLabel")
    verdict.Name = "Verdict"
    verdict.BackgroundTransparency = 1
    verdict.Size = UDim2.new(1, 0, 0, 34)
    verdict.LayoutOrder = 3
    verdict.Font = Enum.Font.Gotham
    verdict.TextSize = 14
    verdict.TextColor3 = COLORS.muted
    verdict.TextXAlignment = Enum.TextXAlignment.Left
    verdict.TextYAlignment = Enum.TextYAlignment.Top
    verdict.TextWrapped = true
    verdict.Text = "Открой трейд."
    verdict.Parent = panel
    UI.rows.verdict = verdict

    -- Карточка с неучтённым. Растягивается на остаток высоты панели.
    local exCard = buildCard(panel, 4, 1, -190)

    local exHeader = Instance.new("Frame")
    exHeader.Name = "ExcludedHeader"
    exHeader.BackgroundTransparency = 1
    exHeader.Size = UDim2.new(1, 0, 0, 20)
    exHeader.LayoutOrder = 1
    exHeader.Parent = exCard

    local exTitle = Instance.new("TextLabel")
    exTitle.Name = "ExcludedTitle"
    exTitle.BackgroundTransparency = 1
    exTitle.AnchorPoint = Vector2.new(0, 0.5)
    exTitle.Position = UDim2.new(0, 0, 0.5, 0)
    exTitle.Size = UDim2.new(0.55, 0, 1, 0)
    exTitle.Font = Enum.Font.GothamBold
    exTitle.TextSize = 14
    exTitle.TextColor3 = COLORS.text
    exTitle.TextXAlignment = Enum.TextXAlignment.Left
    exTitle.TextYAlignment = Enum.TextYAlignment.Center
    exTitle.TextTruncate = Enum.TextTruncate.AtEnd
    exTitle.Text = "Не учтено"
    exTitle.Parent = exHeader
    UI.rows.excludedTitle = exTitle

    -- Легенда к цветным полоскам. RichText, чтобы покрасить только квадратики
    -- и не плодить ради этого отдельные фреймы.
    local legend = Instance.new("TextLabel")
    legend.Name = "Legend"
    legend.BackgroundTransparency = 1
    legend.AnchorPoint = Vector2.new(1, 0.5)
    legend.Position = UDim2.new(1, 0, 0.5, 0)
    legend.Size = UDim2.new(0.45, 0, 1, 0)
    legend.Font = Enum.Font.Gotham
    legend.TextSize = 12
    legend.TextColor3 = COLORS.muted
    legend.RichText = true
    legend.TextXAlignment = Enum.TextXAlignment.Right
    legend.TextYAlignment = Enum.TextYAlignment.Center
    legend.Text = string.format(
        '<font color="#%s">▍</font>ты  <font color="#%s">▍</font>он',
        SIDE_COLOR.mine:ToHex(), SIDE_COLOR.theirs:ToHex()
    )
    legend.Parent = exHeader

    -- Бартерные названия длинные, поэтому список прокручивается внутри себя
    -- и не растягивает панель за пределы окна трейда.
    local scroll = Instance.new("ScrollingFrame")
    scroll.Name = "Excluded"
    scroll.BackgroundTransparency = 1
    scroll.BorderSizePixel = 0
    scroll.Size = UDim2.new(1, 0, 1, -24)
    scroll.LayoutOrder = 2
    scroll.ScrollBarThickness = 3
    scroll.ScrollBarImageColor3 = COLORS.muted
    scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    scroll.Parent = exCard

    local scrollList = Instance.new("UIListLayout")
    scrollList.SortOrder = Enum.SortOrder.LayoutOrder
    scrollList.Padding = UDim.new(0, 5)
    scrollList.Parent = scroll

    UI.rows.excluded = scroll
    UI.panel = panel
    return panel
end

--- Держит панель в пределах экрана. Справа места обычно хватает, но на узком
--- окне панель уехала бы за край - тогда перекидываем её влево от трейда.
local function positionPanel()
    local panel = UI.panel
    local camera = workspace.CurrentCamera
    if not panel or not TradeFrame or not camera then
        return
    end
    local viewport = camera.ViewportSize
    local tradeRight = TradeFrame.AbsolutePosition.X + TradeFrame.AbsoluteSize.X
    local tradeLeft = TradeFrame.AbsolutePosition.X

    if tradeRight + 10 + PANEL_WIDTH <= viewport.X then
        panel.Position = UDim2.new(1, 10, 0, 0)
    elseif tradeLeft - 10 - PANEL_WIDTH >= 0 then
        panel.Position = UDim2.new(0, -PANEL_WIDTH - 10, 0, 0)
    else
        -- Совсем узкий экран: кладём панель поверх правого края трейда.
        panel.Position = UDim2.new(1, -PANEL_WIDTH, 0, 0)
    end
end

local function setExcludedList(entries)
    local scroll = UI.rows.excluded
    if not scroll then
        return
    end
    for _, child in ipairs(scroll:GetChildren()) do
        if not child:IsA("UIListLayout") then
            child:Destroy()
        end
    end

    for i, entry in ipairs(entries) do
        local block = Instance.new("Frame")
        block.Name = "Entry" .. i
        block.BackgroundTransparency = 1
        block.Size = UDim2.new(1, -6, 0, 0)
        block.AutomaticSize = Enum.AutomaticSize.Y
        block.LayoutOrder = i
        block.Parent = scroll

        -- Вертикальная полоска слева: цвет говорит, чья это сторона.
        local bar = Instance.new("Frame")
        bar.Name = "Bar"
        bar.Position = UDim2.new(0, 0, 0, 2)
        bar.Size = UDim2.new(0, 3, 1, -4)
        bar.BackgroundColor3 = SIDE_COLOR[entry.side] or COLORS.muted
        bar.BorderSizePixel = 0
        bar.Parent = block
        local barCorner = Instance.new("UICorner")
        barCorner.CornerRadius = UDim.new(1, 0)
        barCorner.Parent = bar

        local textWrap = Instance.new("Frame")
        textWrap.Name = "Text"
        textWrap.BackgroundTransparency = 1
        textWrap.Position = UDim2.new(0, 10, 0, 0)
        textWrap.Size = UDim2.new(1, -10, 0, 0)
        textWrap.AutomaticSize = Enum.AutomaticSize.Y
        textWrap.Parent = block

        local wrapList = Instance.new("UIListLayout")
        wrapList.SortOrder = Enum.SortOrder.LayoutOrder
        wrapList.Padding = UDim.new(0, 1)
        wrapList.Parent = textWrap

        local name = Instance.new("TextLabel")
        name.Name = "Name"
        name.BackgroundTransparency = 1
        name.Size = UDim2.new(1, 0, 0, 0)
        name.AutomaticSize = Enum.AutomaticSize.Y
        name.LayoutOrder = 1
        name.Font = Enum.Font.GothamMedium
        name.TextSize = 14
        name.TextColor3 = COLORS.listName
        name.TextXAlignment = Enum.TextXAlignment.Left
        name.TextYAlignment = Enum.TextYAlignment.Top
        name.TextWrapped = true
        name.Text = entry.name
        name.Parent = textWrap

        local reason = Instance.new("TextLabel")
        reason.Name = "Reason"
        reason.BackgroundTransparency = 1
        reason.Size = UDim2.new(1, 0, 0, 0)
        reason.AutomaticSize = Enum.AutomaticSize.Y
        reason.LayoutOrder = 2
        reason.Font = Enum.Font.Gotham
        reason.TextSize = 13
        reason.TextColor3 = COLORS.muted
        reason.TextXAlignment = Enum.TextXAlignment.Left
        reason.TextYAlignment = Enum.TextYAlignment.Top
        reason.TextWrapped = true
        reason.Text = entry.reason
        reason.Parent = textWrap
    end
end

local function updatePanel(mineTotal, theirTotal, mineExcluded, theirExcluded, opponent)
    if not UI.panel then
        return
    end

    -- Числовая цена есть меньше чем у половины каталога: 470 предметов против
    -- 571 бартерных и неоценённых. Предмет без цены даёт в сумму ноль, поэтому
    -- уверенный вердикт по такой сумме - враньё. Пока хоть один предмет не
    -- учтён, показываем приблизительность и не красим разницу в вердикт.
    local incomplete = (#mineExcluded + #theirExcluded) > 0
    local approx = incomplete and "≈" or ""

    local diff = mineTotal - theirTotal
    local verdict, diffColor, diffText
    if math.abs(diff) < 0.0005 then
        verdict = incomplete and "Учтённые части равны." or "Стороны равноценны."
        diffColor = COLORS.even
        diffText = approx .. "0"
    elseif diff > 0 then
        verdict = "Ты отдаёшь больше на " .. formatValue(diff) .. "."
        diffColor = incomplete and COLORS.even or COLORS.bad
        diffText = approx .. "-" .. formatValue(diff)
    else
        verdict = "Ты получаешь больше на " .. formatValue(-diff) .. "."
        diffColor = incomplete and COLORS.even or COLORS.good
        diffText = approx .. "+" .. formatValue(-diff)
    end

    if incomplete then
        verdict = verdict .. " Но "
            .. (#mineExcluded + #theirExcluded)
            .. " предм. без цены — сравнение неполное."
    end

    UI.rows.mine.Text = approx .. formatValue(mineTotal)
    UI.rows.theirs.Text = approx .. formatValue(theirTotal)
    UI.rows.theirs.Parent.Caption.Text = opponent or "Оппонент"
    UI.rows.diff.Text = diffText
    UI.rows.diff.TextColor3 = diffColor
    UI.rows.verdict.Text = verdict

    local entries = {}
    for _, e in ipairs(mineExcluded) do
        table.insert(entries, { side = "mine", name = e.name, reason = e.reason })
    end
    for _, e in ipairs(theirExcluded) do
        table.insert(entries, { side = "theirs", name = e.name, reason = e.reason })
    end

    local n = #entries
    if n == 0 then
        UI.rows.excludedTitle.Text = "Не учтено: ничего"
    else
        UI.rows.excludedTitle.Text = "Не учтено: " .. n
    end
    setExcludedList(entries)
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
        return false, "TradeGUI не найден - ты точно в MM2?"
    end
    local trade = gui:FindFirstChild("Container") and gui.Container:FindFirstChild("Trade")
    if not trade then
        return false, "TradeGUI.Container.Trade отсутствует - разметка игры изменилась"
    end
    local yours = trade:FindFirstChild("YourOffer") and trade.YourOffer:FindFirstChild("Container")
    local theirs = trade:FindFirstChild("TheirOffer") and trade.TheirOffer:FindFirstChild("Container")
    if not yours or not theirs then
        return false, "не найдены контейнеры YourOffer/TheirOffer"
    end
    TradeFrame, YourContainer, TheirContainer = trade, yours, theirs
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

    -- Запоминаем состояние: по нему тумблер ярлыков сможет перерисовать их
    -- обратно, не дожидаясь следующего изменения трейда.
    Session.lastState = state

    renderSide(YourContainer, mine.Offer)
    renderSide(TheirContainer, theirs.Offer)

    -- Позицию считаем здесь, а не при создании панели: на момент создания окно
    -- трейда ещё скрыто и его AbsoluteSize равен нулю.
    positionPanel()

    local mineTotal, _, mineExcluded = summarise(mine.Offer)
    local theirTotal, _, theirExcluded = summarise(theirs.Offer)
    local opponent = theirs.Player and theirs.Player.Name or "Оппонент"

    updatePanel(mineTotal, theirTotal, mineExcluded, theirExcluded, opponent)
end

--============================================================================
-- Запуск
--============================================================================

local function buildWindow(WindUI)
    local stats = Values.stats or {}

    local Window = WindUI:CreateWindow({
        Title = "MM2Value",
        Icon = "gem",
        Folder = "MM2Value",
        Author = "ценности Supreme Values",
        Topbar = { Height = 40, ButtonsType = "Mac" },
        OpenButton = { Title = "MM2Value", Enabled = true, Draggable = true },
    })
    UI.window = Window
    Session.window = Window

    -- Итоги теперь живут в самом окне трейда, здесь только настройки.
    local SettingsTab = Window:Tab({
        Title = "Настройки",
        Icon = "settings",
    })

    SettingsTab:Toggle({
        Title = "Показывать ярлыки на иконках",
        Value = CONFIG.SHOW_TAGS,
        Callback = function(v)
            CONFIG.SHOW_TAGS = v
            if v then
                -- Ярлыки рисуются только по событию UpdateTrade, поэтому без
                -- перерисовки по сохранённому состоянию они не вернулись бы,
                -- пока в трейде что-нибудь не поменяется.
                if Session.lastState then
                    pcall(onUpdateTrade, Session.lastState)
                end
            else
                hideTags(YourContainer)
                hideTags(TheirContainer)
            end
        end,
    })

    SettingsTab:Toggle({
        Title = "Показывать панель итогов в трейде",
        Value = true,
        Callback = function(v)
            if UI.panel then
                UI.panel.Visible = v
            end
        end,
    })

    SettingsTab:Paragraph({
        Title = "Источник данных",
        Desc = string.format(
            "Ценности от: %s\nЗагружено из: %s\nОружия: %d, петов: %d\nС числовой ценой: %d, бартер: %d, без цены: %d",
            tostring(Values.sourceUpdatedIso or "неизвестно"),
            tostring(Values.__source or "?"),
            stats.weapons or 0, stats.pets or 0,
            stats.priced or 0, stats.barter or 0, stats.noValue or 0
        ),
    })

    SettingsTab:Button({
        Title = "Перезагрузить ценности",
        Icon = "refresh-cw",
        Callback = function()
            local fresh, err = loadValues()
            if fresh then
                Values = fresh
                WindUI:Notify({
                    Title = "MM2Value",
                    Content = "Ценности перезагружены (" .. tostring(fresh.__source) .. ")",
                })
            else
                WindUI:Notify({ Title = "MM2Value", Content = "Не вышло: " .. tostring(err) })
            end
        end,
    })

    return Window
end

local function main()
    local err
    Values, err = loadValues()
    if not Values then
        warnf(err)
        return
    end
    log(string.format(
        "ценности загружены из «%s»: %d оружий, %d петов, данные сайта от %s",
        tostring(Values.__source),
        (Values.stats and Values.stats.weapons) or 0,
        (Values.stats and Values.stats.pets) or 0,
        tostring(Values.sourceUpdatedIso)
    ))

    local ok, why = resolveTradeGui()
    if not ok then
        warnf(why)
        return
    end

    -- Ярлыки создаём заранее для всех восьми слотов: они статичны, игра их
    -- только показывает и прячет.
    -- Точка невозврата: всё, что могло помешать старту, уже проверено.
    -- Только теперь сносим предыдущий экземпляр.
    teardown(rawget(_G, "MM2Value"))
    _G.MM2Value = Session

    buildTradePanel()

    for _, container in ipairs({ YourContainer, TheirContainer }) do
        for i = 1, 4 do
            local slot = container:FindFirstChild("NewItem" .. i)
            if slot then
                getTag(slot)
            end
        end
    end

    -- Три шага раздельно: иначе непонятно, что именно упало - сеть,
    -- компиляция или сама библиотека.
    local WindUI
    local okFetch, source = pcall(function()
        return game:HttpGet(CONFIG.WINDUI_URL, true)
    end)
    if not okFetch or type(source) ~= "string" or #source == 0 then
        warnf("WindUI: не скачался — " .. tostring(source))
    else
        -- Третье значение обязательно: loadstring при ошибке возвращает
        -- (nil, текст), значит pcall отдаёт (true, nil, текст). Без него в
        -- консоль уходило «не скомпилировался — nil», то есть ровно та потеря
        -- диагностики, ради устранения которой шаги и разделены.
        local okCompile, chunk, compileErr = pcall(loadstring, source)
        if not okCompile or type(chunk) ~= "function" then
            warnf("WindUI: не скомпилировался — " .. tostring(compileErr or chunk))
        else
            local okRun, lib = pcall(chunk)
            if not okRun or type(lib) ~= "table" then
                warnf("WindUI: не запустился — " .. tostring(lib))
            else
                WindUI = lib
                local okWin, winErr = pcall(buildWindow, WindUI)
                if not okWin then
                    warnf("WindUI: панель не собралась — " .. tostring(winErr))
                end
            end
        end
    end

    if not WindUI then
        warnf("работаю без панели итогов, ярлыки на иконках при этом активны")
    end

    local tradeFolder = ReplicatedStorage:WaitForChild("Trade", 20)
    if not tradeFolder then
        warnf("ReplicatedStorage.Trade не найден")
        return
    end

    -- Через FindFirstChild, а не прямым индексом: если игру пропатчат и ремоут
    -- переименуют, прямой индекс бросит ошибку и уронит весь main вместе с
    -- уже созданной панелью, вместо понятного сообщения.
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

    -- Не обязателен: без него ярлыки просто останутся до следующего трейда.
    local declineRemote = tradeFolder:FindFirstChild("DeclineTrade")
    if declineRemote then
        table.insert(Session.connections, declineRemote.OnClientEvent:Connect(function()
            hideTags(YourContainer)
            hideTags(TheirContainer)
        end))
    end

    -- Точка входа для проверки без второго игрока: принимает ту же структуру,
    -- что приходит из Trade.UpdateTrade. Пример:
    --   _G.MM2Value.simulate({{"SeerChroma",1,"Weapons"}}, {{"Batwing",1,"Weapons"}})
    Session.simulate = function(mineOffer, theirOffer, drawCards)
        -- drawCards ~= false: заодно рисуем сами карточки так же, как это
        -- делает игра. Без этого проверка обходит ItemModule.DisplayItem -
        -- ровно тот код, который теоретически мог бы снести наши ярлыки.
        if drawCards ~= false then
            local okDraw, drawErr = pcall(function()
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
                            local data = { DataType = itemType, Amount = amount }
                            for k, v in pairs(record) do
                                data[k] = v
                            end
                            ItemModule.DisplayItem(slot, data, amount)
                            slot.Visible = true
                        end
                    end
                end

                draw(YourContainer, mineOffer)
                draw(TheirContainer, theirOffer)
            end)
            if not okDraw then
                warnf("имитация карточек не удалась: " .. tostring(drawErr))
            end
        end

        onUpdateTrade({
            Player1 = { Player = LocalPlayer, Offer = mineOffer or {} },
            Player2 = { Player = { Name = "ТестОппонент" }, Offer = theirOffer or {} },
        })
    end

    -- Смена разрешения или переход в полноэкранный режим не поднимает
    -- UpdateTrade, поэтому позицию панели пересчитываем отдельно.
    local camera = workspace.CurrentCamera
    if camera then
        table.insert(Session.connections,
            camera:GetPropertyChangedSignal("ViewportSize"):Connect(positionPanel))
    end

    log("оверлей активен, жду начала трейда")
end

main()
