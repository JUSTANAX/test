"""
Собирает компактный артефакт для оверлея: игровой ключ -> цены по вариантам.

Вход:  adoptme/data/match_report.json
Выход: adoptme/data/am_values.json

ФОРМА КЛЮЧА ВАРИАНТА. Игра отдаёт про питомца четыре флага - neon,
mega_neon, rideable, flyable. Из них складывается ровно то состояние, под
которым сайт держит цену:

    форма  = mega, если mega_neon; иначе neon, если neon; иначе regular
    зелья  = fr, если летает и катает; f - только летает;
             r - только катает; np - ни то ни другое

Оверлею останется собрать «regular|fr» и взять число. Никакой логики выбора
на стороне игры - весь разбор случаев сделан здесь, потому что чинить Python
проще, чем перевыкладывать скрипт.

ПОЧЕМУ ОТДЕЛЬНЫЙ ФАЙЛ, А НЕ ОТЧЁТ. Отчёт нужен человеку и весит много:
там несопоставленные предметы, диагностика, происхождение. В игру должно
уезжать только то, что реально читается в трейде.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
IN_FILE = DATA / "match_report.json"
OUT_FILE = DATA / "am_values.json"

# Куда положить копию для чтения из исполнителя.
WORKSPACE = Path.home() / "AppData" / "Local" / "Madium" / "Workspace"

# Порядок вариантов фиксирован: так короче ключи и стабильнее дифф.
FORMS = ("regular", "neon", "mega")
POTIONS = ("np", "f", "r", "fr")


def main() -> int:
    if not IN_FILE.exists():
        print(f"ОШИБКА: нет {IN_FILE}")
        print("        сначала запусти adoptme/parser/match_report.py")
        return 1

    report = json.loads(IN_FILE.read_text(encoding="utf-8"))

    items: dict[str, dict] = {}
    stats = {"total": 0, "priced": 0, "pets": 0, "variants": 0, "computed": 0}

    for rec in report["records"]:
        variants = rec.get("variants")
        if not variants:
            continue

        values: dict[str, float] = {}
        computed_keys: list[str] = []
        for key, v in variants.items():
            if v.get("value") is None:
                continue
            values[key] = v["value"]
            if v.get("computed"):
                computed_keys.append(key)

        if not values:
            continue

        entry = {
            "n": rec["name"],
            "c": rec["gameCategory"],
            "v": values,
        }
        # Спрос берём у базового варианта - он один на форму и в трейде
        # показывается как справка, а не как число для сложения.
        base = variants.get("regular|fr") or next(iter(variants.values()))
        if base.get("demand"):
            entry["d"] = base["demand"]
        if rec.get("updatedAt"):
            entry["u"] = rec["updatedAt"][:10]
        if rec.get("method") not in ("имя+раздел",):
            # Помечаем всё, что сопоставлено не точным именем: если в трейде
            # вылезет странная цена, сразу видно, откуда она.
            entry["m"] = rec.get("method")

        items[rec["gameId"]] = entry
        stats["total"] += 1
        stats["priced"] += 1
        stats["variants"] += len(values)
        stats["computed"] += len(computed_keys)
        if rec["gameCategory"] == "pets":
            stats["pets"] += 1

    payload = {
        "source": "amvgg.com",
        "schema": 1,
        "generatedAt": report.get("generatedAt"),
        "sourceUpdatedIso": report.get("sourceUpdatedIso"),
        "forms": list(FORMS),
        "potions": list(POTIONS),
        "stats": stats,
        "items": items,
    }

    # Без отступов: файл едет по сети в игру, каждый килобайт заметен.
    text = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    OUT_FILE.write_text(text, encoding="utf-8")

    print("=" * 64)
    print("АРТЕФАКТ ДЛЯ ИГРЫ СОБРАН")
    print("=" * 64)
    print(f"Предметов с ценой : {stats['priced']}")
    print(f"  из них питомцев : {stats['pets']}")
    print(f"Значений всего    : {stats['variants']}")
    print(f"  из них счётных  : {stats['computed']}")
    print(f"Данные сайта от   : {(payload['sourceUpdatedIso'] or '?')[:10]}")
    print(f"Размер            : {len(text) / 1024:.1f} КБ")
    print(f"Записано          : {OUT_FILE}")

    if WORKSPACE.exists():
        (WORKSPACE / "am_values.json").write_text(text, encoding="utf-8")
        print(f"Копия для readfile: {WORKSPACE / 'am_values.json'}")

    print("=" * 64)
    return 0


if __name__ == "__main__":
    sys.exit(main())
