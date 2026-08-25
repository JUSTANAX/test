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

local SCRIPT_VERSION = "1.0"

local CONFIG = {
    -- Ссылка на сам скрипт, для кнопки «скопировать запуск».
    SCRIPT_URL = "https://raw.githubusercontent.com/JUSTANAX/test/main/overlay/overlay.lua",

    SHOW_DETAILS = true,

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
    -- Фон чисто чёрный. Отделять от него карточку заливкой бесполезно, поэтому
    -- карточка - не цвет, а лёгкая белая подсветка поверх (см. CARD_*): тот же
    -- приём, которым пользуется сам WindUI.
    bg       = Color3.fromHex("000000"),
    surface  = Color3.fromHex("FFFFFF"),  -- подсветка карточки, не заливка
    stroke   = Color3.fromHex("FFFFFF"),  -- кант белый и тихий, как у WindUI
    text     = Color3.fromHex("FFFFFF"),  -- 21.0 на чёрном
    muted    = Color3.fromHex("A1A1A1"),  -- Placeholder из темы WindUI
    unknown  = Color3.fromHex("A1A1A1"),
    listName = Color3.fromHex("FFFFFF"),

    -- Голубой и синий остаются, но только как акценты: тренд, выгода,
    -- полоски сторон, точка в шапке. Ими не красится ни один фон.
    accent   = Color3.fromHex("66B8F5"),
    primary  = Color3.fromHex("48CCF2"),
    up       = Color3.fromHex("96F4FF"),
    down     = Color3.fromHex("6690FF"),
    good     = Color3.fromHex("96F4FF"),
    bad      = Color3.fromHex("6690FF"),
    even     = Color3.fromHex("A1A1A1"),
}

-- Подсветка карточки: белый при 0.94 даёт на чёрном примерно #0F0F0F.
-- Ровно так WindUI отделяет свои элементы, не уходя от чёрного фона.
local CARD_TRANSPARENCY = 0.94
-- Обводки больше нет: границу держат спрайт со скруглением и тень под ним,
-- как в самом WindUI. Яркий кант был вынужденной мерой при плоской заливке.

local RADIUS_WINDOW = 16
local RADIUS_ELEMENT = 8

--============================================================================
-- Поверхности в стиле WindUI
--
-- WindUI не красит фон заливкой - он рисует девятислайсовый спрайт и тонирует
-- его через ImageColor3. Отсюда мягкие края и «материальность» окна, которой
-- плоский BackgroundColor3 не даёт. Берём те же спрайты, чтобы наша панель и
-- его окно настроек не выглядели как два разных приложения.
--
-- SliceCenter у исходника 460, поэтому скругление задаётся не UICorner, а
-- SliceScale = нужный радиус / 460.
--============================================================================

local SPRITE_SURFACE = "rbxassetid://89641024074289"
local SPRITE_SHADOW = "rbxassetid://8992230677"
local SPRITE_SLICE = 460
local SHADOW_SLICE = 99

--- Фон-спрайт на всю площадь родителя.
local function paintSurface(parent, color, transparency, radius)
    local img = Instance.new("ImageLabel")
    img.Name = "Surface"
    img.BackgroundTransparency = 1
    img.Size = UDim2.new(1, 0, 1, 0)
    img.Image = SPRITE_SURFACE
    img.ImageColor3 = color
    img.ImageTransparency = transparency or 0
    img.ScaleType = Enum.ScaleType.Slice
    img.SliceCenter = Rect.new(SPRITE_SLICE, SPRITE_SLICE, SPRITE_SLICE, SPRITE_SLICE)
    img.SliceScale = (radius or RADIUS_WINDOW) / SPRITE_SLICE
    img.Parent = parent
    return img
end

--- Мягкая тень под окном. Именно она сажает панель на экран, вместо того
--- чтобы она выглядела наклеенной.
local function paintShadow(parent)
    local img = Instance.new("ImageLabel")
    img.Name = "Shadow"
    img.BackgroundTransparency = 1
    img.Size = UDim2.new(1, 100, 1, 100)
    img.Position = UDim2.new(0, -50, 0, -50)
    img.Image = SPRITE_SHADOW
    img.ImageColor3 = Color3.new(0, 0, 0)
    img.ImageTransparency = 0.6
    img.ScaleType = Enum.ScaleType.Slice
    img.SliceCenter = Rect.new(SHADOW_SLICE, SHADOW_SLICE, SHADOW_SLICE, SHADOW_SLICE)
    img.Parent = parent
    return img
end

--- Каркас окна: прозрачный фрейм, тень, поверхность и отдельный слой контента.
--- Контент вынесен в свой фрейм намеренно - иначе спрайты попали бы в
--- UIListLayout и встали бы в поток как обычные элементы.
local function buildSurfaceWindow(parent, name, width, color, transparency)
    local root = Instance.new("Frame")
    root.Name = name
    root.BackgroundTransparency = 1
    root.Size = UDim2.new(0, width, 1, 0)
    root.Parent = parent

    paintShadow(root)
    paintSurface(root, color, transparency, RADIUS_WINDOW)

    local content = Instance.new("Frame")
    content.Name = "Content"
    content.BackgroundTransparency = 1
    content.Size = UDim2.new(1, 0, 1, 0)
    content.Parent = root

    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0, 12)
    pad.PaddingBottom = UDim.new(0, 12)
    pad.PaddingLeft = UDim.new(0, 12)
    pad.PaddingRight = UDim.new(0, 12)
    pad.Parent = content

    local list = Instance.new("UIListLayout")
    list.SortOrder = Enum.SortOrder.LayoutOrder
    list.Padding = UDim.new(0, 8)
    list.Parent = content

    return root, content
end

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

-- showDetails определена ниже, но нужна уже в paintTag: ярлык вешает на себя
-- обработчик нажатия. Без этой строки внутри paintTag она была бы глобальной
-- nil - ровно та ошибка, на которой этот файл уже спотыкался дважды.
local showDetails

local function log(...)
    print("[OxyLab]", ...)
end

local function warnf(...)
    warn("[OxyLab]", ...)
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
    -- Window:Destroy() разбирает содержимое окна, но ScreenGui-контейнеры
    -- WindUI после него остаются, и каждый перезапуск оставлял на экране ещё
    -- одно окно. Сносим ровно те контейнеры, которые появились при создании
    -- НАШЕГО окна: чистить все подряд нельзя - у другого скрипта может быть
    -- свой WindUI, и мы бы снесли его.
    for _, gui in ipairs(previous.windUiGuis or {}) do
        pcall(function() gui:Destroy() end)
    end
    -- Ярлыки принадлежат игровому GUI и переживают перезапуск скрипта,
    -- поэтому их надо снять явно.
    local ok, pg = pcall(function() return LocalPlayer:FindFirstChild("PlayerGui") end)
    if ok and pg then
        local gui = pg:FindFirstChild("TradeGUI")
        if gui then
            for _, d in ipairs(gui:GetDescendants()) do
                if d.Name == "MM2ValueTag" or d.Name == "MM2ValuePanel"
                    or d.Name == "MM2ValueDetails" then
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

--- Короткая причина отсутствия цены - для ярлыка на иконке.
---
--- Раньше здесь показывалась игровая редкость («Unique»), но это сбивало:
--- у предметов С ценой на том же месте стоят D/R с сайта, и одна строка
--- означала разное в зависимости от предмета.
local function shortReason(data)
    if not data then
        return "нет на сайте"
    elseif data.kind == "barter" then
        return "бартер"
    elseif data.kind == "coming-soon" then
        return "не оценён"
    elseif data.kind == "uncertain" then
        return "не подтверждена"
    end
    return "без цены"
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

-- Соединения ярлыков держим здесь, а не полем на самом объекте: Instance в
-- Roblox не принимает произвольные свойства, попытка записать tag.__conn
-- падает с «is not a valid member of TextButton».
-- Слабые ключи, чтобы уничтоженный ярлык не держал запись вечно.
local tagClicks = setmetatable({}, { __mode = "k" })

local function buildTag(parent)
    -- TextButton, а не Frame: по нажатию открывается панель деталей.
    -- Занимает левый нижний угол иконки; остальная площадь по-прежнему
    -- принадлежит игровой кнопке, которая убирает предмет из оффера.
    local frame = Instance.new("TextButton")
    frame.Text = ""
    frame.AutoButtonColor = false
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
        metaLabel.Text = shortReason(data)
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

    -- Пересоздаём обработчик: предмет в слоте меняется, а ярлык переиспользуется.
    if tagClicks[tag] then
        tagClicks[tag]:Disconnect()
    end
    local slotName = slot:FindFirstChild("ItemName")
    local fallbackName = slotName and slotName.Label.Text or nil
    tagClicks[tag] = tag.MouseButton1Click:Connect(function()
        showDetails(data, fallbackName)
    end)

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
            elseif data.kind == "uncertain" then
                name, reason = data.name or tostring(itemId), "цена не подтверждена"
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

local UI = {
    panel = nil,          -- панель итогов справа
    window = nil,         -- окно настроек WindUI
    rows = {},            -- строки итогов
    details = nil,        -- панель деталей слева
    detail_rows = {},     -- её строки «подпись - значение»
    detail_title = nil,
    detail_price = nil,
    detail_trend = nil,
    detail_origin = nil,
    detail_aliases = nil,
    status = nil,         -- абзац состояния в окне настроек
    source = nil,         -- абзац источника данных
}

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

--- Карточка тем же спрайтом, что и окно, только подсветкой вместо заливки.
--- Возвращает слой контента: спрайт лежит отдельно и не участвует в раскладке.
local function buildCard(parent, order, heightScale, heightOffset)
    local card = Instance.new("Frame")
    card.Name = "Card"
    card.BackgroundTransparency = 1
    card.Size = UDim2.new(1, 0, heightScale or 0, heightOffset or 0)
    card.AutomaticSize = (heightScale == nil and heightOffset == nil)
        and Enum.AutomaticSize.Y or Enum.AutomaticSize.None
    card.LayoutOrder = order
    card.Parent = parent

    paintSurface(card, COLORS.surface, CARD_TRANSPARENCY, RADIUS_ELEMENT)

    local content = Instance.new("Frame")
    content.Name = "CardContent"
    content.BackgroundTransparency = 1
    content.Size = UDim2.new(1, 0, 1, 0)
    content.AutomaticSize = card.AutomaticSize
    content.Parent = card

    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0, 8)
    pad.PaddingBottom = UDim.new(0, 8)
    pad.PaddingLeft = UDim.new(0, 12)
    pad.PaddingRight = UDim.new(0, 12)
    pad.Parent = content

    local list = Instance.new("UIListLayout")
    list.FillDirection = Enum.FillDirection.Vertical
    list.SortOrder = Enum.SortOrder.LayoutOrder
    list.Padding = UDim.new(0, 2)
    list.Parent = content

    return content
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

    local panel, body = buildSurfaceWindow(TradeFrame, PANEL_NAME, PANEL_WIDTH, COLORS.bg, 0)
    panel.Position = UDim2.new(1, 10, 0, 0)

    -- Шапка. Иконка и текст в одной строке, обе выровнены по центру.
    local header = Instance.new("Frame")
    header.Name = "Header"
    header.BackgroundTransparency = 1
    header.Size = UDim2.new(1, 0, 0, 24)
    header.LayoutOrder = 1
    header.Parent = body

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
    title.Text = "OxyLab"
    title.Parent = header

    -- Карточка с итогами
    local totalsCard = buildCard(body, 2, 0, 104)
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
    -- 52, а не 34: приписка про неполноту сравнения занимает третью строку и
    -- при прежней высоте обрывалась на полуслове.
    verdict.Size = UDim2.new(1, 0, 0, 52)
    verdict.LayoutOrder = 3
    verdict.Font = Enum.Font.Gotham
    verdict.TextSize = 14
    verdict.TextColor3 = COLORS.muted
    verdict.TextXAlignment = Enum.TextXAlignment.Left
    verdict.TextYAlignment = Enum.TextYAlignment.Top
    verdict.TextWrapped = true
    verdict.Text = "Открой трейд."
    verdict.Parent = body
    UI.rows.verdict = verdict

    -- Карточка с неучтённым. Растягивается на остаток высоты панели.
    -- -208 = -190 минус 18px, на которые подрос блок вердикта.
    local exCard = buildCard(body, 4, 1, -208)

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

--============================================================================
-- Панель деталей предмета (слева, по нажатию на ярлык)
--============================================================================

local DETAILS_NAME = "MM2ValueDetails"
local DETAILS_WIDTH = 264

--- Ставит панель слева от всего окна трейда, включая инвентарь.
--- Инвентарь шире и левее самого фрейма трейда, поэтому опираться только на
--- TradeFrame нельзя - панель легла бы поверх списка предметов.
local function positionDetails()
    local panel = UI.details
    local camera = workspace.CurrentCamera
    if not panel or not TradeFrame or not camera then
        return
    end

    local tradeLeft = TradeFrame.AbsolutePosition.X
    local leftMost = tradeLeft
    local container = TradeFrame.Parent
    if container then
        for _, sibling in ipairs(container:GetChildren()) do
            if sibling:IsA("GuiObject") and sibling.Visible and sibling.AbsoluteSize.X > 0 then
                leftMost = math.min(leftMost, sibling.AbsolutePosition.X)
            end
        end
    end

    local offset = (leftMost - tradeLeft) - 10 - DETAILS_WIDTH
    -- Не даём уехать за левый край экрана.
    if tradeLeft + offset < 0 then
        offset = -tradeLeft
    end
    panel.Position = UDim2.new(0, offset, 0, 0)
end

--- Строка «подпись — значение» для панели деталей.
local function detailRow(parent, order, caption)
    local value = buildRow(parent, order, caption, 15)
    value.Font = Enum.Font.GothamMedium
    return value
end

local function buildDetailsPanel()
    if not TradeFrame then
        return nil
    end
    local old = TradeFrame:FindFirstChild(DETAILS_NAME)
    if old then
        old:Destroy()
    end

    local panel, body = buildSurfaceWindow(TradeFrame, DETAILS_NAME, DETAILS_WIDTH, COLORS.bg, 0)
    panel.Position = UDim2.new(0, -DETAILS_WIDTH - 10, 0, 0)
    panel.Visible = false

    -- Шапка: имя предмета и крестик. Крестик фиксированной ширины и не
    -- сжимается, длинное имя обрезается вместо того, чтобы его выдавить.
    local header = Instance.new("Frame")
    header.Name = "Header"
    header.BackgroundTransparency = 1
    header.Size = UDim2.new(1, 0, 0, 24)
    header.LayoutOrder = 1
    header.Parent = body

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.BackgroundTransparency = 1
    title.AnchorPoint = Vector2.new(0, 0.5)
    title.Position = UDim2.new(0, 0, 0.5, 0)
    title.Size = UDim2.new(1, -28, 1, 0)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 16
    title.TextColor3 = COLORS.text
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextYAlignment = Enum.TextYAlignment.Center
    title.TextTruncate = Enum.TextTruncate.AtEnd
    title.Text = "—"
    title.Parent = header
    UI.detail_title = title

    local close = Instance.new("TextButton")
    close.Name = "Close"
    close.AnchorPoint = Vector2.new(1, 0.5)
    close.Position = UDim2.new(1, 0, 0.5, 0)
    close.Size = UDim2.new(0, 22, 0, 22)
    close.BackgroundTransparency = 1
    close.Font = Enum.Font.GothamBold
    close.TextSize = 18
    close.TextColor3 = COLORS.muted
    close.Text = "×"
    close.AutoButtonColor = false
    close.Parent = header
    close.MouseButton1Click:Connect(function()
        panel.Visible = false
    end)

    -- Цена и тренд крупно: ради тренда всё и затевалось.
    local priceCard = buildCard(body, 2, 0, 96)

    local price = Instance.new("TextLabel")
    price.Name = "Price"
    price.BackgroundTransparency = 1
    price.Size = UDim2.new(1, 0, 0, 40)
    price.LayoutOrder = 1
    price.Font = Enum.Font.GothamBold
    price.TextSize = 34
    price.TextColor3 = COLORS.text
    price.TextXAlignment = Enum.TextXAlignment.Left
    price.TextYAlignment = Enum.TextYAlignment.Center
    price.TextTruncate = Enum.TextTruncate.AtEnd
    price.Text = "—"
    price.Parent = priceCard
    UI.detail_price = price

    local trend = Instance.new("TextLabel")
    trend.Name = "Trend"
    trend.BackgroundTransparency = 1
    trend.Size = UDim2.new(1, 0, 0, 24)
    trend.LayoutOrder = 2
    trend.Font = Enum.Font.GothamBold
    trend.TextSize = 20
    trend.TextColor3 = COLORS.muted
    trend.TextXAlignment = Enum.TextXAlignment.Left
    trend.TextYAlignment = Enum.TextYAlignment.Center
    trend.RichText = true
    trend.Text = "—"
    trend.Parent = priceCard
    UI.detail_trend = trend

    -- Остальные поля
    local infoCard = buildCard(body, 3, 0, 190)
    UI.detail_rows = {
        demand = detailRow(infoCard, 1, "Спрос"),
        rarity = detailRow(infoCard, 2, "Редкость сайта"),
        stability = detailRow(infoCard, 3, "Стабильность"),
        flip = detailRow(infoCard, 4, "Перепродажа"),
        rise = detailRow(infoCard, 5, "Шанс роста"),
        gameRarity = detailRow(infoCard, 6, "Класс в игре"),
    }

    local originCard = buildCard(body, 4)

    local originTitle = Instance.new("TextLabel")
    originTitle.Name = "OriginTitle"
    originTitle.BackgroundTransparency = 1
    originTitle.Size = UDim2.new(1, 0, 0, 18)
    originTitle.LayoutOrder = 1
    originTitle.Font = Enum.Font.GothamBold
    originTitle.TextSize = 13
    originTitle.TextColor3 = COLORS.muted
    originTitle.TextXAlignment = Enum.TextXAlignment.Left
    originTitle.Text = "Откуда"
    originTitle.Parent = originCard

    local origin = Instance.new("TextLabel")
    origin.Name = "Origin"
    origin.BackgroundTransparency = 1
    origin.Size = UDim2.new(1, 0, 0, 0)
    origin.AutomaticSize = Enum.AutomaticSize.Y
    origin.LayoutOrder = 2
    origin.Font = Enum.Font.Gotham
    origin.TextSize = 14
    origin.TextColor3 = COLORS.text
    origin.TextXAlignment = Enum.TextXAlignment.Left
    origin.TextYAlignment = Enum.TextYAlignment.Top
    origin.TextWrapped = true
    origin.Text = "—"
    origin.Parent = originCard
    UI.detail_origin = origin

    local aliases = Instance.new("TextLabel")
    aliases.Name = "Aliases"
    aliases.BackgroundTransparency = 1
    aliases.Size = UDim2.new(1, 0, 0, 0)
    aliases.AutomaticSize = Enum.AutomaticSize.Y
    aliases.LayoutOrder = 3
    aliases.Font = Enum.Font.Gotham
    aliases.TextSize = 13
    aliases.TextColor3 = COLORS.muted
    aliases.TextXAlignment = Enum.TextXAlignment.Left
    aliases.TextYAlignment = Enum.TextYAlignment.Top
    aliases.TextWrapped = true
    aliases.Text = ""
    aliases.Parent = originCard
    UI.detail_aliases = aliases

    UI.details = panel
    return panel
end

--- Наполняет и показывает панель. data = nil - предмет неизвестен.
--- Переменная объявлена выше по файлу, здесь только присваивание.
function showDetails(data, fallbackName)
    if not UI.details or not CONFIG.SHOW_DETAILS then
        return
    end

    UI.detail_title.Text = (data and data.name) or fallbackName or "Неизвестный предмет"

    if data and data.kind == "number" and type(data.value) == "number" then
        UI.detail_price.Text = formatValue(data.value)
        UI.detail_price.TextColor3 = COLORS.text
    else
        UI.detail_price.Text = "?"
        UI.detail_price.TextColor3 = COLORS.unknown
    end

    -- Тренд крупно: процент, абсолютное изменение и стрелка одним блоком.
    local trendText = "нет данных"
    local trendColor = COLORS.muted
    if data and data.trend and data.trend ~= "" then
        local num = tonumber((data.trend:gsub("[%%+]", "")))
        if num and num ~= 0 then
            trendColor = num > 0 and COLORS.up or COLORS.down
            local arrow = num > 0 and "▲" or "▼"
            trendText = arrow .. " " .. data.trend
            if data.diff and data.diff ~= "" then
                trendText = trendText .. "   (" .. data.diff .. ")"
            end
        else
            trendText = "без изменений"
        end
    elseif data and data.kind == "barter" then
        trendText = data.text or "цена бартером"
        trendColor = COLORS.unknown
    elseif data then
        trendText = shortReason(data)
        trendColor = COLORS.unknown
    end
    UI.detail_trend.Text = trendText
    UI.detail_trend.TextColor3 = trendColor

    local function put(key, raw, suffix)
        local label = UI.detail_rows[key]
        if not label then
            return
        end
        local text = raw
        if text == nil or text == "" then
            text = "—"
        elseif suffix then
            text = text .. suffix
        end
        label.Text = tostring(text)
    end

    put("demand", data and data.demand, " / 10")
    put("rarity", data and data.rarity, " / 10")
    put("stability", data and data.stability)
    put("flip", data and data.flip)
    put("rise", data and data.rise, "%")
    put("gameRarity", data and data.gameRarity)

    UI.detail_origin.Text = (data and data.origin) or "неизвестно"
    UI.detail_aliases.Text = (data and data.aliases) and ("Также зовут: " .. data.aliases) or ""

    UI.details.Visible = true
    positionDetails()
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

    -- Знак приблизительности - на ту сторону, где действительно есть
    -- неучтённое. Общий флаг ставил «≈» и на точно посчитанную сторону.
    UI.rows.mine.Text = (#mineExcluded > 0 and "≈" or "") .. formatValue(mineTotal)
    UI.rows.theirs.Text = (#theirExcluded > 0 and "≈" or "") .. formatValue(theirTotal)
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
    positionDetails()

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

    -- Запоминаем, что лежало в контейнере интерфейсов ДО создания окна, чтобы
    -- потом точно знать, какие ScreenGui породили именно мы.
    local hostGui = (gethui and gethui()) or game:GetService("CoreGui")
    local before = {}
    if hostGui then
        for _, g in ipairs(hostGui:GetChildren()) do
            before[g] = true
        end
    end

    local Window = WindUI:CreateWindow({
        Title = "OxyLab",
        Icon = "gem",
        Folder = "OxyLab",
        Author = "ценности Supreme Values",
        Topbar = { Height = 40, ButtonsType = "Mac" },
        OpenButton = { Title = "OxyLab", Enabled = true, Draggable = true },
    })
    UI.window = Window
    Session.window = Window

    -- Всё, что появилось в контейнере после CreateWindow, принадлежит нам.
    --
    -- Снимок отложенный: WindUI создаёт свои ScreenGui не в самом вызове
    -- CreateWindow, и мгновенная проверка не видела ничего. Обычно список
    -- остаётся пустым - при повторном запуске библиотека переиспользует уже
    -- созданные контейнеры, и убирать нечего.
    Session.windUiGuis = {}
    if hostGui then
        task.defer(function()
            for _, g in ipairs(hostGui:GetChildren()) do
                if not before[g] then
                    table.insert(Session.windUiGuis, g)
                end
            end
        end)
    end

    Window:Tag({ Title = "v" .. SCRIPT_VERSION, Color = COLORS.primary, Border = true })

    -- Итоги живут в самом окне трейда, здесь только управление и данные.
    -- Разделы и квадратные иконки - как в примере самой WindUI, чтобы окно
    -- выглядело её родным, а не самоделкой.
    local OverlaySection = Window:Section({ Title = "Оверлей" })
    local DataSection = Window:Section({ Title = "Данные" })

    --------------------------------------------------------------------
    -- Обзор
    --------------------------------------------------------------------
    local OverviewTab = OverlaySection:Tab({
        Title = "Обзор",
        Desc = "Что сейчас загружено",
        Icon = "solar:home-2-bold",
        IconColor = COLORS.primary,
        IconShape = "Square",
        Border = true,
    })

    OverviewTab:Section({ Title = "Состояние" })

    UI.status = OverviewTab:Paragraph({
        Title = "Ценности загружены",
        Desc = string.format(
            "Источник: %s\nОружия: %d   Петов: %d\nС числовой ценой: %d из %d",
            tostring(Values.__source or "?"),
            stats.weapons or 0, stats.pets or 0,
            stats.priced or 0,
            (stats.weapons or 0) + (stats.pets or 0)
        ),
    })

    OverviewTab:Section({ Title = "Как пользоваться" })

    OverviewTab:Paragraph({
        Title = "Ярлык на иконке",
        Desc = "Цена предмета в левом нижнем углу. Ниже — спрос, редкость "
            .. "сайта и стрелка тренда. Нажми на ярлык, чтобы открыть подробности слева.",
    })

    OverviewTab:Paragraph({
        Title = "Знак «?» и «≈»",
        Desc = "«?» значит, что числовой цены нет: бартер, предмет не оценён "
            .. "или совпадение ненадёжное. Такие предметы не идут в сумму, "
            .. "поэтому итог помечается знаком «≈».",
    })

    --------------------------------------------------------------------
    -- Отображение
    --------------------------------------------------------------------
    local ViewTab = OverlaySection:Tab({
        Title = "Отображение",
        Desc = "Что показывать в трейде",
        Icon = "solar:square-transfer-horizontal-bold",
        IconColor = COLORS.accent,
        IconShape = "Square",
        Border = true,
    })

    ViewTab:Section({ Title = "Элементы" })

    ViewTab:Toggle({
        Title = "Ярлыки на иконках",
        Desc = "Цена и тренд поверх каждого предмета",
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

    ViewTab:Toggle({
        Title = "Панель итогов справа",
        Desc = "Суммы сторон, разница и список неучтённого",
        Value = true,
        Callback = function(v)
            if UI.panel then
                UI.panel.Visible = v
            end
        end,
    })

    ViewTab:Toggle({
        Title = "Панель деталей слева",
        Desc = "Открывается нажатием на ярлык предмета",
        Value = true,
        Callback = function(v)
            CONFIG.SHOW_DETAILS = v
            if not v and UI.details then
                UI.details.Visible = false
            end
        end,
    })

    --------------------------------------------------------------------
    -- Источник
    --------------------------------------------------------------------
    local SourceTab = DataSection:Tab({
        Title = "Источник",
        Desc = "Откуда берутся цены",
        Icon = "solar:folder-with-files-bold",
        IconColor = COLORS.accent,
        IconShape = "Square",
        Border = true,
    })

    SourceTab:Section({ Title = "Данные" })

    UI.source = SourceTab:Paragraph({
        Title = "Supreme Values",
        Desc = string.format(
            "Цены от: %s\nЗагружено из: %s\nС ценой: %d   Бартер: %d   Без цены: %d",
            tostring(Values.sourceUpdatedIso or "неизвестно"),
            tostring(Values.__source or "?"),
            stats.priced or 0, stats.barter or 0, stats.noValue or 0
        ),
    })

    SourceTab:Button({
        Title = "Перезагрузить цены",
        Icon = "refresh-cw",
        Callback = function()
            local fresh, err = loadValues()
            if fresh then
                Values = fresh
                local s = fresh.stats or {}
                pcall(function()
                    UI.source:SetDesc(string.format(
                        "Цены от: %s\nЗагружено из: %s\nС ценой: %d   Бартер: %d   Без цены: %d",
                        tostring(fresh.sourceUpdatedIso or "неизвестно"),
                        tostring(fresh.__source or "?"),
                        s.priced or 0, s.barter or 0, s.noValue or 0))
                end)
                WindUI:Notify({
                    Title = "OxyLab",
                    Content = "Цены обновлены (" .. tostring(fresh.__source) .. ")",
                    Icon = "check",
                })
            else
                WindUI:Notify({
                    Title = "OxyLab",
                    Content = "Не вышло: " .. tostring(err),
                    Icon = "trash",
                })
            end
        end,
    })

    SourceTab:Section({ Title = "Что важно знать" })

    SourceTab:Paragraph({
        Title = "Цена есть не у всех",
        Desc = "Около 44% каталога сайт оценивает бартером вроде «x4 T1 Legendaries». "
            .. "Такие предметы честно показываются как «?» и не идут в сумму.",
    })

    --------------------------------------------------------------------
    -- О скрипте
    --------------------------------------------------------------------
    local AboutTab = DataSection:Tab({
        Title = "О скрипте",
        Icon = "solar:info-square-bold",
        IconColor = COLORS.muted,
        IconShape = "Square",
        Border = true,
    })

    AboutTab:Paragraph({
        Title = "OxyLab   v" .. SCRIPT_VERSION,
        Desc = "Оверлей ценностей Murder Mystery 2.\n\n"
            .. "Сопоставление предметов сделано заранее на стороне ПК, "
            .. "поэтому в игре цена берётся прямым доступом по ключу и "
            .. "ничего не разбирается на лету.",
    })

    AboutTab:Button({
        Title = "Скопировать ссылку на запуск",
        Icon = "copy",
        Callback = function()
            local link = 'loadstring(game:HttpGet("' .. CONFIG.SCRIPT_URL .. '"))()'
            local ok = pcall(function()
                (setclipboard or toclipboard or set_clipboard)(link)
            end)
            WindUI:Notify({
                Title = "OxyLab",
                Content = ok and "Ссылка скопирована" or "Буфер обмена недоступен",
                Icon = ok and "check" or "trash",
            })
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
    teardown(rawget(_G, "OxyLab") or rawget(_G, "MM2Value"))
    _G.OxyLab = Session
    -- Прежнее имя оставлено намеренно: на него ссылаются README и уже
    -- записанные команды проверки.
    _G.MM2Value = Session

    buildTradePanel()
    buildDetailsPanel()

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
        -- Панели живут в окне трейда и от WindUI не зависят: без него
        -- пропадает только окно настроек.
        warnf("окна настроек не будет; ярлыки, итоги и детали работают")
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

    -- Открыть панель деталей без нажатия, для проверки:
    --   _G.MM2Value.details("TravelerGunChroma", "Weapons")
    Session.details = function(itemId, itemType)
        showDetails(lookup(itemType or "Weapons", itemId), tostring(itemId))
    end

    log("оверлей активен, жду начала трейда")
end

main()
