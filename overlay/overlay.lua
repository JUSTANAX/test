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

local LocalPlayer = Players.LocalPlayer

local COLORS = {
    bg      = Color3.fromRGB(16, 16, 20),
    text    = Color3.fromRGB(255, 255, 255),
    muted   = Color3.fromRGB(150, 155, 170),
    unknown = Color3.fromRGB(120, 124, 138),
    up      = Color3.fromRGB(66, 214, 110),
    down    = Color3.fromRGB(235, 86, 62),
    good    = Color3.fromRGB(66, 214, 110),
    bad     = Color3.fromRGB(235, 86, 62),
    even    = Color3.fromRGB(180, 185, 200),
}

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
                if d.Name == "MM2ValueTag" then
                    pcall(function() d:Destroy() end)
                end
            end
        end
    end
end

teardown(rawget(_G, "MM2Value"))
_G.MM2Value = Session

--============================================================================
-- Загрузка данных
--============================================================================

local Values = nil

local function httpGet(url)
    local ok, res = pcall(function()
        return game:HttpGet(url, true)
    end)
    if ok and type(res) == "string" and #res > 0 then
        return res
    end
    -- Некоторые экзекьюторы дают только request/http_request.
    local req = rawget(getfenv(), "request") or rawget(getfenv(), "http_request") or syn and syn.request
    if req then
        local ok2, res2 = pcall(req, { Url = url, Method = "GET" })
        if ok2 and res2 and res2.Body and #res2.Body > 0 then
            return res2.Body
        end
    end
    return nil
end

local function loadValues()
    local raw, source

    if CONFIG.VALUES_URL ~= "" then
        raw = httpGet(CONFIG.VALUES_URL)
        if raw then
            source = "сеть"
        else
            warnf("не удалось скачать ценности по URL, пробую локальный файл")
        end
    end

    if not raw and isfile and isfile(CONFIG.LOCAL_FILE) then
        local ok, res = pcall(readfile, CONFIG.LOCAL_FILE)
        if ok and type(res) == "string" and #res > 0 then
            raw, source = res, "локальный файл"
        end
    end

    if not raw then
        return nil, "ценности не найдены: URL не задан или недоступен, файла "
            .. CONFIG.LOCAL_FILE .. " нет в Workspace"
    end

    local ok, decoded = pcall(function()
        return HttpService:JSONDecode(raw)
    end)
    if not ok or type(decoded) ~= "table" or type(decoded.items) ~= "table" then
        return nil, "файл ценностей повреждён или имеет неожиданный формат"
    end

    decoded.__source = source
    return decoded
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
    return string.format(
        ' <font color="#%02X%02X%02X">%s</font>',
        color.R * 255, color.G * 255, color.B * 255, arrow
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

    tag.Visible = true
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
            local label
            if not data then
                label = tostring(itemId) .. " — нет на сайте"
            elseif data.kind == "barter" then
                label = (data.name or tostring(itemId)) .. " — " .. (data.text or "бартер")
            elseif data.kind == "coming-soon" then
                label = (data.name or tostring(itemId)) .. " — ещё не оценён"
            else
                label = (data.name or tostring(itemId)) .. " — без ценности"
            end
            if amount > 1 then
                label = label .. " (x" .. amount .. ")"
            end
            table.insert(excluded, label)
        end
    end

    return total, counted, excluded
end

--============================================================================
-- Панель WindUI
--============================================================================

local UI = { totals = nil, excluded = nil, window = nil }

--- WindUI в бете, и обёртки элементов многослойные. Пробуем известные формы,
--- вместо того чтобы полагаться на одну.
local function setText(element, title, desc)
    if not element then
        return
    end
    local targets = { element, rawget(element, "ParagraphFrame") }
    for _, t in ipairs(targets) do
        if t then
            if title ~= nil then
                pcall(function() t:SetTitle(title) end)
            end
            if desc ~= nil then
                pcall(function() t:SetDesc(desc) end)
            end
        end
    end
end

local function updatePanel(mineTotal, theirTotal, mineExcluded, theirExcluded, opponent)
    local diff = mineTotal - theirTotal
    local verdict
    if math.abs(diff) < 0.0005 then
        verdict = "Равноценно"
    elseif diff > 0 then
        verdict = "Ты отдаёшь больше на " .. formatValue(diff)
    else
        verdict = "Ты получаешь больше на " .. formatValue(-diff)
    end

    setText(
        UI.totals,
        string.format("Ты: %s   •   %s: %s", formatValue(mineTotal),
            opponent or "Оппонент", formatValue(theirTotal)),
        verdict
    )

    local lines = {}
    if #mineExcluded > 0 then
        table.insert(lines, "С твоей стороны:")
        for _, l in ipairs(mineExcluded) do
            table.insert(lines, "  • " .. l)
        end
    end
    if #theirExcluded > 0 then
        table.insert(lines, "С его стороны:")
        for _, l in ipairs(theirExcluded) do
            table.insert(lines, "  • " .. l)
        end
    end

    local n = #mineExcluded + #theirExcluded
    if n == 0 then
        setText(UI.excluded, "Не учтено: ничего", "Все предметы имеют числовую ценность.")
    else
        setText(
            UI.excluded,
            "Не учтено: " .. n .. " предм.",
            "Итог считается без них.\n" .. table.concat(lines, "\n")
        )
    end
end

--============================================================================
-- Обработка трейда
--============================================================================

local TradeGui, YourContainer, TheirContainer

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
    TradeGui, YourContainer, TheirContainer = gui, yours, theirs
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

    renderSide(YourContainer, mine.Offer)
    renderSide(TheirContainer, theirs.Offer)

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

    local TradeTab = Window:Tab({
        Title = "Трейд",
        Icon = "arrow-left-right",
        Desc = "Итоги текущей сделки",
    })

    UI.totals = TradeTab:Paragraph({
        Title = "Ты: 0   •   Оппонент: 0",
        Desc = "Открой трейд, чтобы увидеть подсчёт.",
    })

    UI.excluded = TradeTab:Paragraph({
        Title = "Не учтено: ничего",
        Desc = "Сюда попадут предметы без числовой ценности.",
    })

    local SettingsTab = Window:Tab({
        Title = "Настройки",
        Icon = "settings",
    })

    SettingsTab:Toggle({
        Title = "Показывать ярлыки на иконках",
        Value = CONFIG.SHOW_TAGS,
        Callback = function(v)
            CONFIG.SHOW_TAGS = v
            if not v then
                hideTags(YourContainer)
                hideTags(TheirContainer)
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
        local okCompile, chunk = pcall(loadstring, source)
        if not okCompile or type(chunk) ~= "function" then
            warnf("WindUI: не скомпилировался — " .. tostring(chunk))
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

    table.insert(Session.connections, tradeFolder.UpdateTrade.OnClientEvent:Connect(function(state)
        local okRun, runErr = pcall(onUpdateTrade, state)
        if not okRun then
            warnf("ошибка при обработке трейда: " .. tostring(runErr))
        end
    end))

    table.insert(Session.connections, tradeFolder.DeclineTrade.OnClientEvent:Connect(function()
        hideTags(YourContainer)
        hideTags(TheirContainer)
    end))

    -- Точка входа для проверки без второго игрока: принимает ту же структуру,
    -- что приходит из Trade.UpdateTrade. Пример:
    --   _G.MM2Value.simulate({{"SeerChroma",1,"Weapons"}}, {{"Batwing",1,"Weapons"}})
    Session.simulate = function(mineOffer, theirOffer)
        onUpdateTrade({
            Player1 = { Player = LocalPlayer, Offer = mineOffer or {} },
            Player2 = { Player = { Name = "ТестОппонент" }, Offer = theirOffer or {} },
        })
    end

    log("оверлей активен, жду начала трейда")
end

main()
