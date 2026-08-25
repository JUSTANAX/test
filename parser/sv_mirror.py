"""
Цены Supreme Values через публичные зеркала.

ЗАЧЕМ. Прямой доступ к supremevalues.com закрыт Imperva, а архив заходит на
страницы нерегулярно: 714 предметов из 1204 стояли на снимке месячной
давности, и Dungeon показывался за 300 вместо настоящих 175.

Зеркала - это ТЕ ЖЕ данные supremevalues, снятые Playwright'ом (настоящий
браузер защиту проходит) и выложенные статикой. Проверено сверкой: там, где
наш архивный снимок свежий, значения совпадают до последней цифры
(Evergun 3450, Constellation 2700, Evergreen 2650), и расходятся только там,
где мы отстали. Будь это чужой прайс-лист, годли бы не сошлись.

ИСТОЧНИКИ.
  hoochiem486 - основной. Чистая схема: id вида "godlies:batwing" снимает
                коллизию имён, value настоящее число, бартер разложен в
                структуру. Но uniques там всего 1 предмет и нет evos.
  Namedadude  - добивка. Шире по каталогу (uniques 128, evos 26), но value
                строкой, имена с хвостами и синтетический numericValue.

Выход - тот же sv_values.json, что делает sv_parser.py, поэтому остальной
конвейер не меняется.
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Any

import requests

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data"
OUT_FILE = DATA_DIR / "sv_values.json"

PRIMARY_URL = "https://hoochiem486.github.io/supreme-values-mm2-api/values.json"
FILLER_URL = (
    "https://raw.githubusercontent.com/Namedadude/"
    "Supreme-Values-MM2-Scraper/main/public/values.json"
)

# Третий слой - наш собственный архивный каталог. Нужен там, где зеркала
# слабее: в uniques у зеркал вместо предметов лежат ники владельцев
# (01_2027, Bmat213) и другие написания («Blue Elderwood Blade» против
# «Blue Elderwood»), а архивный разбор сетки сходился с игрой полностью.
ARCHIVE_FILE = DATA_DIR / "sv_archive.json"

MONTHS = {
    "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6,
    "july": 7, "august": 8, "september": 9, "october": 10, "november": 11,
    "december": 12,
}


def to_iso_date(raw: str) -> str:
    """
    ГГГГ-ММ-ДД из того, что отдают источники.

    Зеркала пишут по-разному: «2026-08-25T16:19:04.678Z» и
    «August 23rd, 2026 at 8:29 PM». Возраст цены показывается игроку, поэтому
    приводим к одному виду, а не тащим строки как есть.
    """
    text = clean(raw)
    if not text:
        return ""
    m = re.match(r"^(\d{4})-(\d{2})-(\d{2})", text)
    if m:
        return f"{m.group(1)}-{m.group(2)}-{m.group(3)}"
    m = re.match(r"^([A-Za-z]+)\s+(\d{1,2})[a-z]{0,2},?\s+(\d{4})", text)
    if m:
        month = MONTHS.get(m.group(1).lower())
        if month:
            return f"{m.group(3)}-{month:02d}-{int(m.group(2)):02d}"
    return ""

REQUEST_TIMEOUT = 120
RETRY_COUNT = 3
RETRY_SLEEP = 4.0

# Категории, которые нас интересуют. untradables намеренно исключены: у них
# нет цен вовсе, а в игре они всё равно не торгуются.
CATEGORIES = [
    "sets", "uniques", "ancients", "vintages", "chromas", "godlies",
    "legendaries", "rares", "uncommons", "commons", "pets", "misc", "evos",
]

# Ниже этого числа предметов считаем, что зеркало отдало обрубок.
MIN_TOTAL_ITEMS = 900

USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) OxyLab/1.0"


class MirrorFailure(Exception):
    pass


def fetch_json(url: str) -> Any:
    last = "неизвестно"
    for attempt in range(1, RETRY_COUNT + 1):
        try:
            r = requests.get(url, timeout=REQUEST_TIMEOUT,
                             headers={"User-Agent": USER_AGENT})
            if r.status_code != 200:
                last = f"HTTP {r.status_code}"
            else:
                return r.json()
        except Exception as exc:  # noqa: BLE001 - сеть, ретраим что угодно
            last = f"{type(exc).__name__}: {exc}"
        if attempt < RETRY_COUNT:
            time.sleep(RETRY_SLEEP * attempt)
    raise MirrorFailure(f"{url}: {last}")


def clean(raw: Any) -> str:
    """
    Строка, годная для показа. Пустая - значит данных нет.

    Берём только первую строку: скрапер местами прихватывает соседний текст
    со страницы, и в цене оказывается «x3 T1 Commons\\nStability». В игре
    это вылезло бы прямо в списке предметов.
    """
    if raw is None:
        return ""
    if isinstance(raw, (list, tuple)):
        parts = [clean(x) for x in raw]
        return ", ".join(p for p in parts if p)
    text = str(raw).replace("\r", "\n").split("\n", 1)[0].strip()
    if text.upper().strip("[]") in ("", "N/A", "NA", "NONE", "NULL"):
        return ""
    return text


def tiered_text(tiered: dict[str, Any] | None, fallback: str) -> str:
    """
    Человеческая запись бартерной цены: {quantity, tier, rarity} -> «x4 T1 Legendaries».

    Формат повторяет тот, что печатает сам сайт, - в игре эта строка уже
    показывается пользователю, и менять её вид не стоит.
    """
    if not isinstance(tiered, dict):
        return fallback
    qty = tiered.get("quantity")
    tier = tiered.get("tier")
    rarity = clean(tiered.get("rarity"))
    if qty is None or tier is None or not rarity:
        return fallback
    word = rarity.capitalize()
    if qty != 1 and not word.endswith("s"):
        word += "s"
    return f"x{qty} T{tier} {word}"


def from_primary(payload: dict[str, Any]) -> tuple[dict[str, dict], str]:
    """Разбирает hoochiem486. Ключ - «категория|имя», как в остальном конвейере."""
    items = payload.get("items")
    if not isinstance(items, list):
        raise MirrorFailure("в основном зеркале нет массива items")

    out: dict[str, dict] = {}
    for it in items:
        if not isinstance(it, dict):
            continue
        cat = clean(it.get("category"))
        name = clean(it.get("name"))
        if not cat or not name or cat not in CATEGORIES:
            continue

        value = it.get("value")
        vtype = clean(it.get("valueType"))
        display = clean(it.get("valueDisplay"))

        if isinstance(value, (int, float)):
            kind, text = "number", display or str(value)
        elif vtype == "tiered-items":
            kind = "barter"
            text = tiered_text(it.get("tieredValue"), display)
            value = None
        else:
            kind, text, value = "none", display, None

        pct = it.get("percentageChange")
        diff = it.get("difference")

        out[f"{cat}|{name}"] = {
            "name": name,
            "category": cat,
            "value": value,
            "valueKind": kind,
            "valueText": text,
            "demand": clean(it.get("demand")),
            "rarity": clean(it.get("rarity")),
            "stability": clean(it.get("stability")),
            # Проценту возвращаем знак и хвост: остальной конвейер ждёт вид «+4.0%».
            "pctChange": f"{pct:+.1f}%" if isinstance(pct, (int, float)) and pct else "",
            "diff": f"{diff:+d}" if isinstance(diff, int) and diff else "",
            "origin": clean(it.get("origin")),
            "flippability": clean(it.get("flippability")),
            "riseChance": clean(it.get("riseChance")),
            "aliases": clean(it.get("aliases")),
        }

    return out, clean(payload.get("fetchedAt"))


# Хвост вида « (Common)» или « (Pet)» - это класс предмета, приписанный
# скрапером. В именах самого сайта его нет, поэтому срезаем, иначе ни один
# предмет не сойдётся с игровой базой.
CLASS_SUFFIX = re.compile(
    r"\s*\((?:Common|Uncommon|Rare|Legendary|Godly|Ancient|Vintage|Unique|"
    r"Chroma|Set|Pet|Misc|Evo|Untradable)\)\s*$",
    re.IGNORECASE,
)


def from_filler(payload: dict[str, Any]) -> tuple[dict[str, dict], str]:
    """Разбирает Namedadude. Используется только для того, чего нет в основном."""
    items = payload.get("items")
    if not isinstance(items, dict):
        raise MirrorFailure("в дополняющем зеркале нет словаря items")

    out: dict[str, dict] = {}
    for it in items.values():
        if not isinstance(it, dict):
            continue
        cat = clean(it.get("category"))
        name = CLASS_SUFFIX.sub("", clean(it.get("name")))
        if not cat or not name or cat not in CATEGORIES:
            continue

        raw_value = clean(it.get("value"))
        numeric = None
        if raw_value:
            candidate = raw_value.replace(",", "")
            try:
                numeric = float(candidate)
            except ValueError:
                numeric = None

        if numeric is not None:
            kind, text = "number", raw_value
        elif raw_value:
            # numericValue тут НЕ цена: скрапер выдумывает 0.02 для
            # «x2 T1 Uncommons». Подставить это как ценность - соврать.
            kind, text, numeric = "barter", raw_value, None
        else:
            kind, text, numeric = "none", "", None

        out[f"{cat}|{name}"] = {
            "name": name,
            "category": cat,
            "value": numeric,
            "valueKind": kind,
            "valueText": text,
            "demand": clean(it.get("demand")),
            "rarity": clean(it.get("rarity")),
            "stability": clean(it.get("stability")),
            "pctChange": clean(it.get("change")),
            "diff": "",
            "origin": clean(it.get("origin")),
            "flippability": clean(it.get("flippability")),
            "riseChance": clean(it.get("chanceOfRising")),
            "aliases": clean(it.get("aliases")),
        }

    return out, clean(payload.get("lastUpdated"))


def main() -> int:
    DATA_DIR.mkdir(parents=True, exist_ok=True)

    print("=" * 62)
    print("Цены Supreme Values через зеркала")
    print("=" * 62)

    print("основное зеркало ... ", end="", flush=True)
    try:
        primary_raw = fetch_json(PRIMARY_URL)
        catalog, fetched_at = from_primary(primary_raw)
        print(f"OK  {len(catalog)} предметов, снято {fetched_at or '?'}")
    except MirrorFailure as exc:
        print(f"СБОЙ  {exc}")
        print("\nБез основного зеркала смысла продолжать нет.")
        print("Запасной путь: python parser/sv_parser.py")
        return 1

    primary_date = to_iso_date(fetched_at)
    for rec in catalog.values():
        rec["sourceDate"] = primary_date

    added = 0
    filler_updated = ""
    print("дополняющее   ... ", end="", flush=True)
    try:
        filler_raw = fetch_json(FILLER_URL)
        extra, filler_updated = from_filler(filler_raw)
        filler_date = to_iso_date(filler_updated)
        for key, rec in extra.items():
            if key not in catalog:
                rec["sourceDate"] = filler_date
                catalog[key] = rec
                added += 1
        print(f"OK  добавило {added} предметов, дата сайта {filler_updated or '?'}")
    except MirrorFailure as exc:
        # Не критично: основное зеркало уже дало каталог.
        print(f"мимо  {exc}")

    # Третий слой: наш архивный каталог закрывает то, чего у зеркал нет или
    # что у них названо иначе. Цены оттуда старее, поэтому каждой записи
    # проставляем её собственную дату - в игре возраст виден у предмета.
    from_archive = 0
    print("архивный запас ... ", end="", flush=True)
    try:
        archive = json.loads(ARCHIVE_FILE.read_text(encoding="utf-8"))
        cat_dates = {
            name: to_iso_date((info or {}).get("sourceUpdatedIso") or "")
            for name, info in (archive.get("categories") or {}).items()
        }
        for key, rec in (archive.get("items") or {}).items():
            if key in catalog or not isinstance(rec, dict):
                continue
            cat = rec.get("category")
            if cat not in CATEGORIES:
                continue
            merged = dict(rec)
            merged["sourceDate"] = cat_dates.get(cat, "")
            catalog[key] = merged
            from_archive += 1
        print(f"OK  добавило {from_archive} предметов")
    except (OSError, json.JSONDecodeError) as exc:
        print(f"мимо  {type(exc).__name__} (не критично)")

    if len(catalog) < MIN_TOTAL_ITEMS:
        print(f"\nНЕ ЗАПИСАНО: всего {len(catalog)} предметов, ожидалось "
              f"минимум {MIN_TOTAL_ITEMS}.")
        print(f"Прежний {OUT_FILE.name} оставлен нетронутым - неполный каталог")
        print("опаснее устаревшего: предметы получили бы цены однофамильцев.")
        return 1

    # Дата у категории теперь не одна на всех: часть предметов пришла из
    # зеркала (сегодняшние), часть из архива (могут быть месячной давности).
    # Берём по категории САМУЮ СТАРУЮ - иначе архивные цены выдали бы себя
    # за свежие. Возраст конкретного предмета всё равно виден по его
    # собственному sourceDate.
    by_cat: dict[str, int] = {}
    cat_oldest: dict[str, str] = {}
    for rec in catalog.values():
        cat = rec["category"]
        by_cat[cat] = by_cat.get(cat, 0) + 1
        d = rec.get("sourceDate") or ""
        if d and (cat not in cat_oldest or d < cat_oldest[cat]):
            cat_oldest[cat] = d

    site_date = min(cat_oldest.values()) if cat_oldest else to_iso_date(filler_updated)

    payload = {
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "sourceUpdatedIso": site_date,
        "sourceKind": "mirror",
        "mirrors": {"primary": PRIMARY_URL, "filler": FILLER_URL},
        "fromArchive": from_archive,
        "categories": {
            cat: {
                "count": n,
                "snapshot": fetched_at,
                "method": "зеркало",
                "sourceUpdatedIso": cat_oldest.get(cat, site_date),
            }
            for cat, n in sorted(by_cat.items())
        },
        "failedCategories": {},
        "itemCount": len(catalog),
        "items": catalog,
    }

    tmp = OUT_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(tmp, OUT_FILE)

    print()
    print("=" * 62)
    print(f"Предметов всего : {len(catalog)}")
    print(f"Категорий       : {len(by_cat)}")
    for cat in CATEGORIES:
        if cat in by_cat:
            print(f"   {cat:<14} {by_cat[cat]}")
    print(f"Цены сайта от   : {site_date or 'неизвестно'}")
    print(f"Записано        : {OUT_FILE}")
    print("=" * 62)
    return 0


if __name__ == "__main__":
    sys.exit(main())
