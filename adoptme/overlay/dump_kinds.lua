--[[
    Выгружает базу предметов Adopt Me (KindDB) в JSON для сопоставления с amvgg.

    Запускать из исполнителя, находясь в игре. Результат ляжет в папку
    Workspace исполнителя, оттуда его надо скопировать в
    adoptme/data/game_kinds.json.

    Что берём и почему именно это:

      id / kind   - внутренний ключ игры. Именно он приходит в предмете
                    инвентаря, по нему и придётся искать цену.
      name        - отображаемое имя. Совпадает с именем на amvgg
                    («Shadow Dragon»), это основной ключ сопоставления.
      origin      - событие и ГОД появления. Самое ценное поле: игровые
                    ключи носят год в себе (halloween_2023_dire_stag), и
                    одно и то же имя встречается у разных выпусков. В MM2
                    ровно на этом мы теряли цены - пять разных «зомби»
                    садились на одну запись сайта. Год разводит их надёжно.
      rarity      - для проверки, что сопоставили не абы что.
      category    - pets / toys / food и так далее.

    Остальные полторы сотни полей KindDB - про анимации, модели и смещения
    при переноске. Для цен они бесполезны, и таскать их незачем.
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local OUT_NAME = "adoptme_kinds.json"

local function log(msg)
    print("[OxyLab AM] " .. msg)
end

local okFsys, Fsys = pcall(function()
    return require(ReplicatedStorage:WaitForChild("Fsys", 15))
end)
if not okFsys then
    log("не удалось загрузить Fsys — ты точно в Adopt Me?")
    return
end

local okDB, KindDB = pcall(function()
    return Fsys.load("KindDB")
end)
if not okDB or type(KindDB) ~= "table" then
    log("KindDB не читается: " .. tostring(KindDB))
    return
end

local items = {}
local byCategory = {}
local total, withYear = 0, 0

for key, v in pairs(KindDB) do
    if type(v) == "table" and v.name then
        total = total + 1
        local cat = tostring(v.category or "?")
        byCategory[cat] = (byCategory[cat] or 0) + 1

        local rec = {
            id = tostring(v.id or key),
            kind = tostring(v.kind or key),
            name = tostring(v.name),
            category = cat,
            rarity = tostring(v.rarity or ""),
            contentpack = tostring(v.contentpack or ""),
        }

        -- Флаги, по которым отличаются сами предметы, а не их варианты.
        if v.is_egg ~= nil then rec.isEgg = v.is_egg and true or false end
        if v.temporary ~= nil then rec.temporary = v.temporary and true or false end
        if v.donatable ~= nil then rec.donatable = v.donatable and true or false end

        local oe = v.origin_entry
        if type(oe) == "table" then
            rec.origin = tostring(oe.origin or "")
            rec.fullOrigin = tostring(oe.full_origin or "")
            if oe.year then
                rec.year = tostring(oe.year)
                withYear = withYear + 1
            end
        end

        items[rec.id] = rec
    end
end

local payload = {
    source = "Adopt Me KindDB",
    placeId = game.PlaceId,
    generatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    stats = { total = total, withYear = withYear, byCategory = byCategory },
    items = items,
}

local okJson, encoded = pcall(function()
    return HttpService:JSONEncode(payload)
end)
if not okJson then
    log("JSON не собрался: " .. tostring(encoded))
    return
end

log(string.format("предметов: %d, из них с годом: %d", total, withYear))
for cat, n in pairs(byCategory) do
    log(string.format("   %s: %d", cat, n))
end

if type(writefile) == "function" then
    local okWrite, err = pcall(writefile, OUT_NAME, encoded)
    if okWrite then
        log("записано в Workspace/" .. OUT_NAME .. " (" .. #encoded .. " байт)")
    else
        log("записать не вышло: " .. tostring(err))
    end
else
    log("writefile недоступен — забирай из _G.OxyLabKinds")
end

-- Дублируем в глобальную переменную: так результат можно снять,
-- даже если запись файлов исполнителю запрещена.
_G.OxyLabKinds = payload
