--[[
    OxyLab - цены Adopt Me прямо в окне трейда.

    Запуск:
      loadstring(game:HttpGet("https://raw.githubusercontent.com/JUSTANAX/test/main/adoptme/overlay/overlay.lua"))()

    Что делает: ставит цену слева снизу на каждой иконке в трейде и общую
    сумму рядом с именем каждой стороны. Данные - amvgg.com, обновляются
    автоматически.

    КАК ЭТО ЦЕПЛЯЕТСЯ К ИГРЕ. У игры есть штатный хук
    register_for_each_slot_callback, который отдаёт кадр слота вместе с
    предметом - казалось бы, идеально. Но на панели собеседника он УЖЕ занят
    самой игрой, а внутри стоит assert, и вторая регистрация валит скрипт.
    Поэтому цепляемся иначе: подменяем _refresh у панели. Игра зовёт его при
    любом изменении оффера, а карта «предмет -> кадр слота» лежит готовая в
    pane.unique_to_slot.

    Почему не перехват сетевых событий, как в MM2: там иначе было нельзя, а
    здесь панель сама хранит разобранные предметы. Меньше кода - меньше мест,
    где ломаться при обновлении игры.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

--============================================================================
-- Настройки
--============================================================================

local VALUES_URL =
    "https://raw.githubusercontent.com/JUSTANAX/test/main/adoptme/data/am_values.json"
local LOCAL_FILE = "am_values.json"

-- Шрифт и размеры вынесены сюда: подбираются глазами, а не расчётом.
local FONT = Enum.Font.LuckiestGuy
local TAG_TEXT_SIZE = 11
local POTION_TEXT_SIZE = 10
local TOTAL_TEXT_SIZE = 18

-- Сколько зелий езды в одной единице цены.
--
-- Не подобрано, а взято из кода сайта: у него есть режим «Ride Pot», и
-- пересчёт там ровно такой -
--     parseFloat((Math.round(154 * v * 20) / 20).toFixed(2))
-- то есть умножить на 154 и округлить до 0.05 зелья. Сходится и с ценой
-- самого зелья в каталоге: 1 / 0.0065 = 153.8.
local RIDE_POTION_FACTOR = 154

local COLORS = {
    -- Оранжевый, как в MM2: цена лежит прямо на иконке, а иконки бывают и
    -- тёмными, и почти белыми, поэтому обводка чёрная и непрозрачная.
    value = Color3.fromHex("FF9D2E"),
    -- Зелья - бледнее и того же семейства: второе число не должно спорить
    -- с первым за внимание, но должно читаться как цена, а не как подпись.
    potion = Color3.fromHex("FFD37A"),
    stroke = Color3.fromHex("000000"),
    unknown = Color3.fromHex("BFBFBF"),
}

local TAG_NAME = "OxyValueTag"
local TOTAL_NAME = "OxyOfferTotal"

--============================================================================
-- Состояние
--============================================================================

local LocalPlayer = Players.LocalPlayer
local Values                       -- каталог цен
local Session                      -- всё, что надо снять при перезапуске

local function log(msg)
    print("[OxyLab] " .. msg)
end

local function warnf(msg)
    warn("[OxyLab] " .. msg)
end

--============================================================================
-- Снятие прошлого запуска
--============================================================================

--- Убирает следы прошлого запуска.
---
--- Без этого повторный loadstring оставил бы вторую подмену _refresh поверх
--- первой, и цены рисовались бы дважды, а суммы считались бы дважды.
local function teardown()
    local old = _G.OxyLabAM
    if type(old) ~= "table" then
        return
    end

    -- Возвращаем панелям их родной _refresh.
    for _, entry in pairs(old.patched or {}) do
        if entry.pane and entry.original then
            entry.pane._refresh = entry.original
            entry.pane.__oxylab = nil
        end
    end

    -- Отписываемся до удаления меток: иначе слушатели ника продолжат
    -- дёргать расчёт для уже уничтоженных объектов.
    for _, conn in pairs(old.connections or {}) do
        pcall(function()
            conn:Disconnect()
        end)
    end

    for _, inst in pairs(old.created or {}) do
        if typeof(inst) == "Instance" and inst.Parent then
            inst:Destroy()
        end
    end

    old.stopped = true
    log("прошлый запуск снят")
end

--============================================================================
-- Загрузка цен
--============================================================================

local function loadValues()
    local sources = {}

    local okNet, netBody = pcall(function()
        return game:HttpGet(VALUES_URL)
    end)
    if okNet and type(netBody) == "string" and #netBody > 1000 then
        table.insert(sources, { name = "сеть", body = netBody })
    end

    if type(isfile) == "function" and type(readfile) == "function" then
        local okFile, fileBody = pcall(function()
            if isfile(LOCAL_FILE) then
                return readfile(LOCAL_FILE)
            end
        end)
        if okFile and type(fileBody) == "string" and #fileBody > 1000 then
            table.insert(sources, { name = "файл", body = fileBody })
        end
    end

    for _, src in ipairs(sources) do
        local okJson, parsed = pcall(function()
            return HttpService:JSONDecode(src.body)
        end)
        if okJson and type(parsed) == "table" and type(parsed.items) == "table" then
            parsed.__source = src.name
            return parsed
        end
    end
    return nil
end

--============================================================================
-- Формат чисел
--============================================================================

--- Обрезает хвостовые нули: 0.0028 -> «0.0028», 39.0 -> «39», 5.080 -> «5.08».
---
--- Цены Adopt Me лежат в диапазоне от 0.0004 до нескольких десятков, поэтому
--- фиксированной разрядности не годится: три знака превратили бы дешёвых
--- питомцев в ноль, а шесть загромоздили бы дорогих.
local function trimZeros(s)
    if s:find("%.") then
        s = s:gsub("0+$", "")
        s = s:gsub("%.$", "")
    end
    return s
end

local function formatValue(v)
    if type(v) ~= "number" then
        return "?"
    end
    if v == math.floor(v) and math.abs(v) < 1e9 then
        return string.format("%d", v)
    end
    return trimZeros(string.format("%.4f", v))
end

--- Цена в зельях езды - ровно по формуле сайта.
---
--- math.floor(x + 0.5) - это округление половины ВВЕРХ, как Math.round в
--- JavaScript. Обычное округление «к чётному» дало бы другую последнюю
--- цифру, и наши числа разошлись бы с сайтом на шаг сетки в 0.05.
local function formatPotions(v)
    if type(v) ~= "number" then
        return ""
    end
    local steps = math.floor(RIDE_POTION_FACTOR * v * 20 + 0.5)
    return trimZeros(string.format("%.2f", steps / 20))
end

--============================================================================
-- Поиск цены
--============================================================================

--- Ключ состояния питомца - ровно так, как разложены цены в каталоге.
---
--- Форма и зелья приходят от игры отдельными флагами, а на сайте это одно
--- слитное состояние. Здесь их и сводим.
local function variantKey(item)
    local p = item.properties or {}
    local form = p.mega_neon and "mega" or (p.neon and "neon" or "regular")
    local fly, ride = p.flyable, p.rideable
    local potions
    if fly and ride then
        potions = "fr"
    elseif fly then
        potions = "f"
    elseif ride then
        potions = "r"
    else
        potions = "np"
    end
    return form .. "|" .. potions
end

--- Цена предмета и почему её нет, если нет.
local function lookup(item)
    if not Values or type(item) ~= "table" then
        return nil
    end
    local entry = Values.items[tostring(item.id or item.kind or "")]
    if not entry then
        return nil
    end
    local values = entry.v or {}
    if entry.c == "pets" then
        return values[variantKey(item)], entry
    end
    -- У непитомцев вариантов нет: одно значение на предмет.
    return values.plain, entry
end

--============================================================================
-- Ярлык на иконке
--============================================================================

local function buildTag(slot)
    local frame = Instance.new("Frame")
    frame.Name = TAG_NAME
    frame.BackgroundTransparency = 1
    frame.AnchorPoint = Vector2.new(0, 1)
    frame.Position = UDim2.new(0, 3, 1, -3)
    -- Две строки: сверху цена в долях, снизу в зельях езды.
    frame.Size = UDim2.new(1, -6, 0, TAG_TEXT_SIZE + POTION_TEXT_SIZE + 4)
    frame.ZIndex = 60
    frame.Parent = slot

    local function line(name, size, color, order)
        local label = Instance.new("TextLabel")
        label.Name = name
        label.BackgroundTransparency = 1
        label.Size = UDim2.new(1, 0, 0, size + 2)
        label.Position = UDim2.new(0, 0, 0, order * (TAG_TEXT_SIZE + 2))
        label.Font = FONT
        label.TextSize = size
        label.TextColor3 = color
        label.TextStrokeColor3 = COLORS.stroke
        label.TextStrokeTransparency = 0
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.TextYAlignment = Enum.TextYAlignment.Center
        label.TextTruncate = Enum.TextTruncate.AtEnd
        label.ZIndex = 61
        label.Parent = frame
        return label
    end

    line("Value", TAG_TEXT_SIZE, COLORS.value, 0)
    line("Potions", POTION_TEXT_SIZE, COLORS.potion, 1)

    table.insert(Session.created, frame)
    return frame
end

--- Рисует уже найденную цену. Возвращать её обратно не должна.
---
--- Раньше эта функция и искала цену, и рисовала, а сумма считалась по её
--- результату. Из-за этого предмет, которому не нашлось кадра слота, выпадал
--- из суммы: итог молча занижался и помечался значком «≈», хотя цена была
--- известна. Теперь поиск цены живёт отдельно, и сумма от отрисовки не
--- зависит вовсе.
local function paintSlot(slot, value)
    if typeof(slot) ~= "Instance" then
        return
    end
    local tag = slot:FindFirstChild(TAG_NAME) or buildTag(slot)

    if type(value) == "number" then
        tag.Value.Text = formatValue(value)
        tag.Value.TextColor3 = COLORS.value
        tag.Potions.Text = formatPotions(value)
    else
        -- Честный прочерк вместо выдуманного числа: предмета может не быть
        -- в каталоге (новый выпуск) или сайт мог не завести ему цену.
        tag.Value.Text = "?"
        tag.Value.TextColor3 = COLORS.unknown
        -- Вторую строку не заполняем: пересчитывать нечего, а «?» дважды
        -- только загромождает иконку.
        tag.Potions.Text = ""
    end
    tag.Visible = true
end

--============================================================================
-- Итог стороны
--============================================================================

--- Метка суммы рядом с именем игрока.
---
--- Кладём её СОСЕДОМ имени, а не внутрь: NameLabel игра переписывает при
--- каждом обновлении, и всё, что лежит внутри, рискует быть снесённым.
-- Зазор между итогом и ником на экране подтверждения.
--
-- Пять, а не «на глаз»: ровно столько игра держит между элементами в своей
-- раскладке на экране торга. Так отступ одинаков на обоих экранах, хотя
-- считается разными способами.
local TOTAL_GAP = 5

--- Ставит итог вплотную слева от НИКА - по тексту, а не по рамке метки.
---
--- Рамка имени шире надписи и у сторон выровнена по-разному: у своей стороны
--- текст прижат влево, у собеседника вправо. Если считать от рамки, с одной
--- стороны получится отступ в пять пикселей, а с другой в семьдесят - ровно
--- это и разъехалось на скриншоте. TextBounds даёт фактическую ширину
--- отрисованного текста, и от неё отступ выходит одинаковым.
local function placeTotal(nameLabel, label)
    if typeof(nameLabel) ~= "Instance" or typeof(label) ~= "Instance" then
        return
    end
    local parent = label.Parent
    if not parent then
        return
    end
    -- Где раскладка, там наши координаты всё равно ничего не решают.
    if parent:FindFirstChildWhichIsA("UIListLayout") then
        return
    end

    local pos, size, bounds = nameLabel.AbsolutePosition, nameLabel.AbsoluteSize, nameLabel.TextBounds
    local textLeft
    if nameLabel.TextXAlignment == Enum.TextXAlignment.Right then
        textLeft = pos.X + size.X - bounds.X
    elseif nameLabel.TextXAlignment == Enum.TextXAlignment.Center then
        textLeft = pos.X + (size.X - bounds.X) / 2
    else
        textLeft = pos.X
    end

    -- Переводим в координаты родителя: Position задаётся относительно него.
    label.AnchorPoint = Vector2.new(1, 0.5)
    label.Position = UDim2.new(
        0, (textLeft - TOTAL_GAP) - parent.AbsolutePosition.X,
        0, (pos.Y + size.Y / 2) - parent.AbsolutePosition.Y)
end

--- id обязателен и должен быть разным у сторон.
---
--- На экране подтверждения обе метки имён лежат в ОДНОМ родителе
--- (ConfirmationFrame). Пока имя метки итога было общим, поиск по родителю
--- находил для второй стороны первую, и обе суммы схлопывались в одну -
--- на экране это выглядело как один итог не на своём месте.
local function buildTotal(nameLabel, id)
    if typeof(nameLabel) ~= "Instance" or not nameLabel.Parent then
        return nil
    end
    local name = TOTAL_NAME .. "_" .. id
    local existing = nameLabel.Parent:FindFirstChild(name)
    if existing then
        return existing
    end

    local label = Instance.new("TextLabel")
    label.Name = name
    label.BackgroundTransparency = 1

    -- Два разных способа встать на место, и выбор не от вкуса.
    --
    -- На экране торга рамка имени содержит UIListLayout: она сама
    -- раскладывает детей и ЛЮБУЮ заданную Position перетирает. Спорить с ней
    -- бесполезно - надо занять место в очереди. LayoutOrder на единицу
    -- меньше, чем у ника, ставит итог прямо перед ним; AutomaticSize нужен,
    -- чтобы метка занимала ширину текста, а не резервировала фиксированные
    -- 150 пикселей - именно этот резерв и отодвигал число от ника.
    --
    -- На экране подтверждения раскладки нет, и там работает обычный расчёт
    -- координат в placeTotal.
    local layout = nameLabel.Parent:FindFirstChildWhichIsA("UIListLayout")
    if layout then
        label.AutomaticSize = Enum.AutomaticSize.X
        label.Size = UDim2.new(0, 0, 0, math.max(nameLabel.AbsoluteSize.Y, TOTAL_TEXT_SIZE + 6))
        label.LayoutOrder = nameLabel.LayoutOrder - 1
    else
        label.AnchorPoint = Vector2.new(1, 0.5)
        label.Size = UDim2.new(0, 150, 0, TOTAL_TEXT_SIZE + 6)
    end
    label.Font = FONT
    label.TextSize = TOTAL_TEXT_SIZE
    label.TextColor3 = COLORS.value
    label.TextStrokeColor3 = COLORS.stroke
    label.TextStrokeTransparency = 0
    label.TextXAlignment = Enum.TextXAlignment.Right
    label.TextYAlignment = Enum.TextYAlignment.Center
    label.Text = ""
    label.ZIndex = 40
    label.Parent = nameLabel.Parent

    table.insert(Session.created, label)
    return label
end

--============================================================================
-- Перерисовка панели
--============================================================================

--- total = { label = метка итога, name = метка ника } либо nil.
local function repaint(pane, total)
    if type(pane) ~= "table" then
        return
    end
    local items = pane.items or {}
    local map = pane.unique_to_slot or {}

    local sum, unknown, count = 0, 0, 0
    for _, item in pairs(items) do
        count = count + 1
        -- Цену ищем ВСЕГДА, даже если рисовать некуда: сумма по стороне не
        -- должна зависеть от того, нашёлся ли кадр слота.
        local value = lookup(item)
        paintSlot(map[item.unique], value)
        if type(value) == "number" then
            sum = sum + value
        else
            unknown = unknown + 1
        end
    end

    local label = total and total.label
    if label and label.Parent then
        if count == 0 then
            label.Text = ""
        else
            -- «≈» значит, что часть предметов без цены и сумма неполная.
            -- Рядом с ником места хватает по ширине, но не по высоте, поэтому
            -- здесь оба числа в одну строку через точку - в отличие от иконок,
            -- где они стоят друг под другом.
            label.Text = (unknown > 0 and "≈" or "") .. formatValue(sum)
                .. " · " .. formatPotions(sum)
        end
        -- Положение считаем каждый раз: ник меняется от трейда к трейду, а
        -- вместе с ним и ширина текста, от которой мы отступаем.
        placeTotal(total.name, label)
    end
end

--- Подменяет _refresh у панели: игра зовёт его при любом изменении оффера.
---
--- Именно _refresh, а не set_items: слоты пересоздаются внутри _refresh, и
--- наши ярлыки при этом уничтожаются вместе со старыми кадрами. Рисовать
--- надо строго после него.
local function patchPane(pane, totalLabel, label)
    if type(pane) ~= "table" or pane.__oxylab then
        return
    end
    local original = pane._refresh
    if type(original) ~= "function" then
        warnf("у панели «" .. label .. "» нет _refresh - разметка игры изменилась")
        return
    end

    pane.__oxylab = true
    pane._refresh = function(self, ...)
        local results = table.pack(original(self, ...))
        -- task.defer: слоты создаются внутри original, а их размеры игра
        -- досчитывает следующим кадром.
        task.defer(function()
            if not Session.stopped then
                local ok, err = pcall(repaint, self, totalLabel)
                if not ok then
                    warnf("ошибка отрисовки (" .. label .. "): " .. tostring(err))
                end
            end
        end)
        return table.unpack(results, 1, results.n)
    end

    table.insert(Session.patched, { pane = pane, original = original })
end

--============================================================================
-- Запуск
--============================================================================

local function main()
    teardown()

    Session = { created = {}, patched = {}, connections = {}, stopped = false }
    _G.OxyLabAM = Session

    Values = loadValues()
    if not Values then
        warnf("не удалось загрузить цены — ни из сети, ни из файла")
        return
    end

    local okFsys, Fsys = pcall(function()
        return require(ReplicatedStorage:WaitForChild("Fsys", 20))
    end)
    if not okFsys then
        warnf("Fsys не найден — ты точно в Adopt Me?")
        return
    end

    local okApp, app = pcall(function()
        return Fsys.load("UIManager").apps.TradeApp
    end)
    if not okApp or type(app) ~= "table" then
        warnf("TradeApp не найден — разметка игры изменилась")
        return
    end

    Session.app = app

    local function totalFor(nameLabel, id)
        local label = buildTotal(nameLabel, id)
        if not label then
            return nil
        end

        -- Положение зависит от ШИРИНЫ ника, а игра меняет его когда захочет:
        -- при начале трейда, при смене собеседника, и до трейда там вообще
        -- висит заглушка. Разовый расчёт поэтому устаревает - привязываемся
        -- к самому тексту.
        local function reposition()
            placeTotal(nameLabel, label)
            -- TextBounds пересчитывается движком следующим кадром, поэтому
            -- повторяем: иначе первое измерение придётся на старую ширину.
            task.defer(function()
                if not Session.stopped then
                    placeTotal(nameLabel, label)
                end
            end)
        end

        for _, prop in ipairs({ "Text", "AbsoluteSize", "AbsolutePosition" }) do
            table.insert(Session.connections,
                nameLabel:GetPropertyChangedSignal(prop):Connect(reposition))
        end
        reposition()

        return { label = label, name = nameLabel }
    end

    local myTotal = totalFor(app.negotiation_my_name_label, "my")
    local theirTotal = totalFor(app.negotiation_partner_name_label, "their")

    -- У экрана подтверждения СВОИ метки имён (YouLabel / PartnerLabel), и
    -- сумма нужна там не меньше: это последний экран перед нажатием
    -- «Подтверждать», решение принимается именно на нём.
    local myConfTotal = totalFor(app.confirmation_my_name_label, "my")
    local theirConfTotal = totalFor(app.confirmation_partner_name_label, "their")

    -- Панелей четыре: две на этапе торга и две на подтверждении. Игра
    -- переключает между ними, и цены должны быть на обеих.
    patchPane(app.my_negotiation_offer_pane, myTotal, "мой оффер")
    patchPane(app.partner_negotiation_offer_pane, theirTotal, "оффер собеседника")
    patchPane(app.my_confirmation_offer_pane, myConfTotal, "мой оффер (подтверждение)")
    patchPane(app.partner_confirmation_offer_pane, theirConfTotal,
              "оффер собеседника (подтверждение)")

    -- Если трейд уже идёт, рисуем сразу, не дожидаясь следующего изменения.
    Session.repaint = function()
        repaint(app.my_negotiation_offer_pane, myTotal)
        repaint(app.partner_negotiation_offer_pane, theirTotal)
        repaint(app.my_confirmation_offer_pane, myConfTotal)
        repaint(app.partner_confirmation_offer_pane, theirConfTotal)
    end
    Session.repaint()

    local stats = Values.stats or {}
    log(string.format(
        "цены загружены из «%s»: %d предметов, %d значений, данные сайта от %s",
        tostring(Values.__source), stats.priced or 0, stats.variants or 0,
        tostring(Values.sourceUpdatedIso or ""):sub(1, 10)))
    log("жду начала трейда")
end

main()
