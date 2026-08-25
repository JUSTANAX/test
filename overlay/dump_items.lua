--[[
    MM2Value - выгрузка игровой базы предметов.

    Читает ReplicatedStorage.Database.Sync и сохраняет оружие и петов в
    mm2_game_items.json в папке Workspace экзекьютора.

    Запускать в Murder Mystery 2 (placeId 142823291), находясь в игре.
    Результат подхватывает parser/match_report.py на стороне ПК.
]]

local HttpService = game:GetService("HttpService")

local OUT_NAME = "mm2_game_items.json"

local function fail(msg)
    warn("[MM2Value] " .. msg)
    return false
end

local okSync, Sync = pcall(function()
    return require(game:GetService("ReplicatedStorage"):WaitForChild("Database", 10)
        :WaitForChild("Sync", 10))
end)

if not okSync or type(Sync) ~= "table" then
    return fail("не удалось загрузить Database.Sync - ты точно в MM2 и игра прогрузилась?")
end

if type(Sync.Weapons) ~= "table" then
    return fail("Sync.Weapons отсутствует или не таблица")
end

local out = { weapons = {}, pets = {} }
local weaponCount, petCount = 0, 0

for key, d in pairs(Sync.Weapons) do
    if type(d) == "table" then
        out.weapons[tostring(key)] = {
            name   = tostring(d.ItemName or ""),
            type   = tostring(d.ItemType or ""),
            rarity = tostring(d.Rarity or ""),
            event  = d.Event and tostring(d.Event) or nil,
            year   = d.Year and tostring(d.Year) or nil,
        }
        weaponCount = weaponCount + 1
    end
end

if type(Sync.Pets) == "table" then
    for key, d in pairs(Sync.Pets) do
        if type(d) == "table" then
            out.pets[tostring(key)] = {
                name   = tostring(d.Name or ""),
                rarity = tostring(d.Rarity or ""),
                type   = tostring(d.Type or ""),
            }
            petCount = petCount + 1
        end
    end
end

local okEncode, json = pcall(function()
    return HttpService:JSONEncode(out)
end)

if not okEncode then
    return fail("JSONEncode упал: " .. tostring(json))
end

local okWrite, writeErr = pcall(function()
    writefile(OUT_NAME, json)
end)

if not okWrite then
    return fail("writefile упал: " .. tostring(writeErr))
end

print(string.format(
    "[MM2Value] Готово: %d оружий, %d петов, %d байт -> %s",
    weaponCount, petCount, #json, OUT_NAME
))

return true
