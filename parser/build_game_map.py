"""
Этап 1: сборка игрового артефакта mm2_values.json.

Оверлей не занимается сопоставлением имён - всё уже решено здесь, на Python.
В событии Trade.UpdateTrade приходит ItemID, который является внутренним
ключом Sync (TradeModule делает ровно Sync[ItemType][ItemID]), поэтому карта
строится как {ItemType: {ItemID: данные}} и Lua берёт цену прямым доступом.

Предметы, которых нет на сайте, в карту НЕ попадают: их отсутствие и есть
признак "неизвестен". Предметы без числовой цены (бартер, Coming Soon,
Default Knife) попадают - оверлею нужно отличать "не знаю предмет" от
"знаю, но цены нет", чтобы честно посчитать итог.

Вход:  data/match_report.json
Выход: data/mm2_values.json  (+ копия в Workspace экзекьютора)
"""

from __future__ import annotations

import json
import shutil
import sys
import time
from collections import defaultdict
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
REPORT_FILE = DATA / "match_report.json"
SV_FILE = DATA / "sv_values.json"
OUT_FILE = DATA / "mm2_values.json"

# Локальный запасной путь доставки: Lua сможет прочитать файл через readfile,
# если сеть или GitHub-зеркало недоступны.
WORKSPACE = Path.home() / "AppData" / "Local" / "Madium" / "Workspace"


def clean(raw: Any) -> str:
    """
    Приводит поле сайта к строке, годной для показа. Пустая строка = не везём.

    Сайт помечает отсутствие данных по-разному: пустой строкой, "N/A" и
    "[N/A]" в квадратных скобках. Показать игроку "[N/A]" хуже, чем не
    показать поле вовсе. Алиасы иногда приходят списком, иногда строкой.
    """
    if raw is None:
        return ""
    if isinstance(raw, (list, tuple)):
        parts = [clean(x) for x in raw]
        return ", ".join(p for p in parts if p)
    text = str(raw).strip()
    if text.upper().strip("[]") in ("", "N/A", "NA", "NONE", "NULL"):
        return ""
    return text


def main() -> int:
    if not REPORT_FILE.exists():
        print(f"ОШИБКА: нет {REPORT_FILE} - сначала запусти match_report.py")
        return 1

    report = json.loads(REPORT_FILE.read_text(encoding="utf-8"))
    sv = json.loads(SV_FILE.read_text(encoding="utf-8")) if SV_FILE.exists() else {}

    # Возраст цены у категорий РАЗНЫЙ, и это не мелочь: снимки годли бывают
    # вчерашние, а commons - месячной давности. Одна дата на весь файл вводила
    # в заблуждение, поэтому везём дату по каждой категории и проставляем
    # предмету его собственную.
    category_dates: dict[str, str] = {}
    for name, info in (sv.get("categories") or {}).items():
        iso = (info or {}).get("sourceUpdatedIso") or ""
        if iso:
            category_dates[name] = iso[:10]

    items: dict[str, dict[str, dict]] = {"Weapons": {}, "Pets": {}}
    kinds: dict[str, int] = defaultdict(int)
    skipped_unmatched = 0

    for rec in report["records"]:
        if rec.get("method") == "нет":
            skipped_unmatched += 1
            continue

        bucket = "Pets" if rec.get("gameType") == "Pet" else "Weapons"
        kind = rec.get("valueKind") or "none"
        value = rec.get("value")

        # Совпадение из чужой категории - не доказательство цены. Показать
        # такое число как достоверное хуже, чем не показать ничего: игрок
        # примет решение о сделке по выдуманной цифре.
        if rec.get("lowConfidence"):
            kind = "uncertain"
            value = None

        kinds[kind] += 1

        entry = {
            "name": rec.get("svName") or rec.get("gameName") or "",
            "value": value,
            "kind": kind,
            "demand": rec.get("demand") or "",
            "rarity": rec.get("siteRarity") or "",
            "trend": rec.get("pctChange") or "",
            "gameRarity": rec.get("gameRarity") or "",
        }

        # Поля для панели деталей. Кладём только непустые: у трети каталога
        # их нет, и пустые строки раздули бы файл, который едет по сети
        # при каждом запуске игры.
        # Дата цены именно этого предмета.
        item_date = category_dates.get(rec.get("svCategory") or "")
        if item_date:
            entry["date"] = item_date

        for src, dst in (
            ("stability", "stability"),
            ("diff", "diff"),
            ("origin", "origin"),
            ("flippability", "flip"),
            ("riseChance", "rise"),
            ("aliases", "aliases"),
        ):
            cleaned = clean(rec.get(src))
            if cleaned:
                entry[dst] = cleaned

        # Бартерный текст нужен только там, где он есть, и только он длинный -
        # в ярлык не влезет, уедет в панель итогов.
        if kind == "barter":
            entry["text"] = rec.get("valueText") or ""

        items[bucket][rec["gameKey"]] = entry

    # Самая старая дата по категориям, а не то, что записал парсер: в старых
    # файлах там лежит дата первой попавшейся категории, и она выглядит
    # свежее, чем есть на самом деле.
    oldest = min(category_dates.values()) if category_dates else None

    payload = {
        "schema": 2,
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "sourceUpdatedIso": oldest or sv.get("sourceUpdatedIso"),
        "categoryDates": category_dates,
        "stats": {
            "weapons": len(items["Weapons"]),
            "pets": len(items["Pets"]),
            "priced": kinds.get("number", 0),
            "barter": kinds.get("barter", 0),
            "noValue": kinds.get("none", 0),
            "comingSoon": kinds.get("coming-soon", 0),
            "unmatchedSkipped": skipped_unmatched,
        },
        "items": items,
    }

    # separators без пробелов: файл едет по сети при каждом запуске игры.
    text = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    OUT_FILE.write_text(text, encoding="utf-8")

    copied = ""
    if WORKSPACE.is_dir():
        try:
            shutil.copyfile(OUT_FILE, WORKSPACE / "mm2_values.json")
            copied = f"\nКопия для readfile   : {WORKSPACE / 'mm2_values.json'}"
        except OSError as exc:
            copied = f"\nКопию в Workspace положить не удалось: {exc}"

    kb = len(text.encode("utf-8")) / 1024
    print("=" * 60)
    print("ИГРОВОЙ АРТЕФАКТ СОБРАН")
    print("=" * 60)
    print(f"Оружия               : {payload['stats']['weapons']}")
    print(f"Петов                : {payload['stats']['pets']}")
    print(f"  с числовой ценой   : {payload['stats']['priced']}")
    print(f"  бартер             : {payload['stats']['barter']}")
    print(f"  без цены           : {payload['stats']['noValue']}")
    print(f"  не оценены         : {payload['stats']['comingSoon']}")
    print(f"Пропущено неизвестных: {skipped_unmatched}")
    print(f"Данные сайта от      : {payload['sourceUpdatedIso']}")
    print(f"Размер               : {kb:.1f} КБ")
    print(f"Записано             : {OUT_FILE}{copied}")
    print("=" * 60)
    return 0


if __name__ == "__main__":
    sys.exit(main())
