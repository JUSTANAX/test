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
local TOTAL_TEXT_SIZE = 18

local COLORS = {
    -- Оранжевый, как в MM2: цена лежит прямо на иконке, а иконки бывают и
    -- тёмными, и почти белыми, поэтому обводка чёрная и непрозрачная.
    value = Color3.fromHex("FF9D2E"),
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
local function formatValue(v)
    if type(v) ~= "number" then
        return "?"
    end
    if v == math.floor(v) and math.abs(v) < 1e9 then
        return string.format("%d", v)
    end
    local s = string.format("%.4f", v)
    s = s:gsub("0+$", "")
    s = s:gsub("%.$", "")
    return s
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
    frame.Size = UDim2.new(1, -6, 0, TAG_TEXT_SIZE + 4)
    frame.ZIndex = 60
    frame.Parent = slot

    local label = Instance.new("TextLabel")
    label.Name = "Value"
    label.BackgroundTransparency = 1
    label.Size = UDim2.new(1, 0, 1, 0)
    label.Font = FONT
    label.TextSize = TAG_TEXT_SIZE
    label.TextColor3 = COLORS.value
    label.TextStrokeColor3 = COLORS.stroke
    label.TextStrokeTransparency = 0
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextYAlignment = Enum.TextYAlignment.Center
    label.TextTruncate = Enum.TextTruncate.AtEnd
    label.ZIndex = 61
    label.Parent = frame

    table.insert(Session.created, frame)
    return frame
end

local function paintSlot(slot, item)
    if typeof(slot) ~= "Instance" then
        return nil
    end
    local tag = slot:FindFirstChild(TAG_NAME) or buildTag(slot)
    local value = lookup(item)

    if type(value) == "number" then
        tag.Value.Text = formatValue(value)
        tag.Value.TextColor3 = COLORS.value
    else
        -- Честный прочерк вместо выдуманного числа: предмета может не быть
        -- в каталоге (новый выпуск) или сайт мог не завести ему цену.
        tag.Value.Text = "?"
        tag.Value.TextColor3 = COLORS.unknown
    end
    tag.Visible = true
    return value
end

--============================================================================
-- Итог стороны
--============================================================================

--- Метка суммы рядом с именем игрока.
---
--- Кладём её СОСЕДОМ имени, а не внутрь: NameLabel игра переписывает при
--- каждом обновлении, и всё, что лежит внутри, рискует быть снесённым.
local function buildTotal(nameLabel)
    if typeof(nameLabel) ~= "Instance" or not nameLabel.Parent then
        return nil
    end
    local existing = nameLabel.Parent:FindFirstChild(TOTAL_NAME)
    if existing then
        return existing
    end

    local label = Instance.new("TextLabel")
    label.Name = TOTAL_NAME
    label.BackgroundTransparency = 1
    label.AnchorPoint = Vector2.new(1, 0)
    label.Position = UDim2.new(
        nameLabel.Position.X.Scale, nameLabel.Position.X.Offset,
        nameLabel.Position.Y.Scale, nameLabel.Position.Y.Offset + nameLabel.AbsoluteSize.Y - 4)
    label.Size = UDim2.new(0, 150, 0, TOTAL_TEXT_SIZE + 6)
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

local function repaint(pane, totalLabel)
    if type(pane) ~= "table" then
        return
    end
    local items = pane.items or {}
    local map = pane.unique_to_slot or {}

    local sum, unknown, count = 0, 0, 0
    for _, item in pairs(items) do
        count = count + 1
        local slot = map[item.unique]
        local value = paintSlot(slot, item)
        if type(value) == "number" then
            sum = sum + value
        else
            unknown = unknown + 1
        end
    end

    if totalLabel and totalLabel.Parent then
        if count == 0 then
            totalLabel.Text = ""
        else
            -- «≈» значит, что часть предметов без цены и сумма неполная.
            totalLabel.Text = (unknown > 0 and "≈" or "") .. formatValue(sum)
        end
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

    Session = { created = {}, patched = {}, stopped = false }
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

    local myTotal = buildTotal(app.negotiation_my_name_label)
    local theirTotal = buildTotal(app.negotiation_partner_name_label)

    -- Панелей четыре: две на этапе торга и две на подтверждении. Игра
    -- переключает между ними, и цены должны быть на обеих.
    patchPane(app.my_negotiation_offer_pane, myTotal, "мой оффер")
    patchPane(app.partner_negotiation_offer_pane, theirTotal, "оффер собеседника")
    patchPane(app.my_confirmation_offer_pane, nil, "мой оффер (подтверждение)")
    patchPane(app.partner_confirmation_offer_pane, nil, "оффер собеседника (подтверждение)")

    -- Если трейд уже идёт, рисуем сразу, не дожидаясь следующего изменения.
    repaint(app.my_negotiation_offer_pane, myTotal)
    repaint(app.partner_negotiation_offer_pane, theirTotal)

    Session.repaint = function()
        repaint(app.my_negotiation_offer_pane, myTotal)
        repaint(app.partner_negotiation_offer_pane, theirTotal)
    end

    local stats = Values.stats or {}
    log(string.format(
        "цены загружены из «%s»: %d предметов, %d значений, данные сайта от %s",
        tostring(Values.__source), stats.priced or 0, stats.variants or 0,
        tostring(Values.sourceUpdatedIso or ""):sub(1, 10)))
    log("жду начала трейда")
end

main()
