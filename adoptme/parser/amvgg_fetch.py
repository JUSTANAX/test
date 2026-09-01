"""
Забирает цены Adopt Me с amvgg.com.

Почему без браузера. Сайт на Next.js и отдаёт данные прямо в обычном ответе
сервера - внутри кусков `self.__next_f.push([1,"..."])`. Playwright тут не
нужен: проверено, обычный GET возвращает 3.8 МБ вместе со всеми значениями.
Это важно для облака - в GitHub Actions не придётся ставить Chromium.

Почему одна страница на категорию, а не страница на предмет. Значения ВСЕХ
вариантов (обычный / неон / мега, с зельями и без) уже лежат в этой же
странице: переключение F/R/N/M на сайте не делает ни одного сетевого
запроса. Ходить на /pet/<имя> отдельно означало бы тысячи запросов вместо
десяти - и без единого нового байта данных.

Вежливость к чужому сайту: пауза между категориями, честный User-Agent,
повторы с задержкой вместо долбёжки. robots.txt разрешает обычный обход
(User-agent: * -> Allow: /) и помечает use=reference - наш случай.

Выход: adoptme/data/amvgg_values.json
"""

from __future__ import annotations

import json
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
OUT_FILE = DATA / "amvgg_values.json"

BASE = "https://amvgg.com"
CATEGORIES = [
    "pets", "eggs", "petwear", "strollers", "food",
    "vehicles", "toys", "gifts", "stickers", "houses",
]

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0 Safari/537.36")

PAUSE_BETWEEN = 2.0      # секунды между категориями
RETRIES = 3

# Как поля сайта раскладываются на «форма + зелья».
#
# Три формы питомца - обычный, неон, мега - и четыре состояния зелий:
# без зелий, только полёт, только езда, полёт и езда. Сайт хранит их
# двенадцатью отдельными полями с непоследовательными именами, поэтому
# соответствие приходится задавать руками.
#
# «np» в именах сайта значит no potion. Странность, которую легко принять
# за ошибку: у меги БЕЗ зелий цена выше, чем с зельями (npMega 39 против
# mega 36.2). Это не опечатка сайта - чистые меги реже и ценятся дороже.
VARIANT_FIELDS = {
    # (форма, зелья): (поле цены, поле спроса)
    ("regular", "fr"): ("regularValue", "regularDemand"),
    ("regular", "np"): ("npRegularValue", "npRegularDemand"),
    ("regular", "f"): ("fValue", "fDemand"),
    ("regular", "r"): ("rValue", "rDemand"),
    ("neon", "fr"): ("neonValue", "neonDemand"),
    ("neon", "np"): ("npNeonValue", "npNeonDemand"),
    ("neon", "f"): ("nfValue", "nfDemand"),
    ("neon", "r"): ("nrValue", "nrDemand"),
    ("mega", "fr"): ("megaValue", "megaDemand"),
    ("mega", "np"): ("npMegaValue", "npMegaDemand"),
    ("mega", "f"): ("mfValue", "mfDemand"),
    ("mega", "r"): ("mrValue", "mrDemand"),
}

# Для непитомцев вариантов нет - одно значение на предмет.
PLAIN_FIELDS = [("value", "demand"), ("regularValue", "regularDemand")]


# --------------------------------------------------------------------------
# Загрузка
# --------------------------------------------------------------------------

def fetch(url: str) -> str:
    """GET с повторами. Сеть иногда рвёт соединение на середине - это не повод падать."""
    last = None
    for attempt in range(1, RETRIES + 1):
        try:
            req = urllib.request.Request(url, headers={
                "User-Agent": UA,
                "Accept": "text/html,application/xhtml+xml",
                "Accept-Language": "en-US,en;q=0.9",
            })
            with urllib.request.urlopen(req, timeout=120) as r:
                return r.read().decode("utf-8", "replace")
        except (urllib.error.URLError, OSError) as e:
            last = e
            if attempt < RETRIES:
                wait = 3 * attempt
                print(f"      попытка {attempt} не удалась ({e}); жду {wait} с")
                time.sleep(wait)
    raise RuntimeError(f"не удалось загрузить {url}: {last}")


# --------------------------------------------------------------------------
# Разбор потока Next.js
# --------------------------------------------------------------------------

MARKER = "self.__next_f.push([1,"


def read_json_string(text: str, start: int) -> tuple[str | None, int]:
    """
    Читает JSON-строку начиная с кавычки в позиции start.

    Своими руками, а не регулярным выражением: внутри лежит экранированный
    JSON, и любое «до следующей кавычки» ломается на первом же \\" внутри.
    """
    if start >= len(text) or text[start] != '"':
        return None, start
    i = start + 1
    while i < len(text):
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if c == '"':
            raw = text[start:i + 1]
            try:
                return json.loads(raw), i + 1
            except json.JSONDecodeError:
                return None, i + 1
        i += 1
    return None, len(text)


def next_payload(html: str) -> str:
    """Склеивает все куски self.__next_f в один текст."""
    parts, pos = [], 0
    while True:
        idx = html.find(MARKER, pos)
        if idx < 0:
            break
        s, pos = read_json_string(html, idx + len(MARKER))
        if s:
            parts.append(s)
    return "".join(parts)


def extract_arrays(text: str) -> dict[str, list]:
    """
    Достаёт массивы предметов вида "pets":[{"id":"...

    Границу ищем по балансу скобок, а не по регулярке: внутри записей есть
    и вложенные объекты, и строки со скобками.
    """
    found: dict[str, list] = {}
    needle = '":[{"id":"'
    pos = 0
    while True:
        idx = text.find(needle, pos)
        if idx < 0:
            break
        pos = idx + 1

        # Имя ключа - назад до открывающей кавычки.
        q = text.rfind('"', 0, idx)
        if q < 0:
            continue
        key = text[q + 1:idx]
        if not key or key in found:
            continue

        start = idx + 2                      # позиция '['
        i, depth = start, 0
        while i < len(text):
            c = text[i]
            if c == '"':
                _, i = read_json_string(text, i)
                continue
            if c in "[{":
                depth += 1
            elif c in "]}":
                depth -= 1
                if depth == 0:
                    break
            i += 1

        try:
            arr = json.loads(text[start:i + 1])
        except json.JSONDecodeError:
            continue
        if isinstance(arr, list) and arr and isinstance(arr[0], dict):
            found[key] = arr
    return found


# --------------------------------------------------------------------------
# Нормализация
# --------------------------------------------------------------------------

def to_number(s) -> float | None:
    """«5.08» -> 5.08. Пустая строка, прочерк и «N/A» - это отсутствие цены, а не ноль."""
    if isinstance(s, (int, float)):
        return float(s)
    if not isinstance(s, str):
        return None
    t = s.strip().replace(",", "")
    if not t or t in {"-", "--", "N/A", "n/a", "?"}:
        return None
    try:
        return float(t)
    except ValueError:
        return None


def clean_date(v) -> str | None:
    """
    Отметка времени сайта приходит как «$D2026-08-31T13:43:33.220Z».

    Префикс $D - служебный маркер формата Next.js, к дате отношения не имеет.
    """
    if not isinstance(v, str):
        return None
    return v[2:] if v.startswith("$D") else v


def normalize(raw: dict, category: str) -> dict:
    name = raw.get("name")
    item = {
        "name": name,
        "category": category,
        "siteId": raw.get("id"),
        "origin": raw.get("origin") or "",
        "updatedAt": clean_date(raw.get("lastUpdatedAt")),
        "variants": {},
    }

    for (form, potion), (vf, df) in VARIANT_FIELDS.items():
        if vf not in raw:
            continue
        value = to_number(raw.get(vf))
        demand = raw.get(df) or ""
        if value is None and not demand:
            continue
        item["variants"][f"{form}|{potion}"] = {
            "form": form,
            "potions": potion,
            "value": value,
            "valueText": (raw.get(vf) or "") if isinstance(raw.get(vf), str) else "",
            "demand": demand,
        }

    # Предметы без вариантов - одно значение.
    if not item["variants"]:
        for vf, df in PLAIN_FIELDS:
            if vf in raw:
                item["variants"]["plain"] = {
                    "form": "plain",
                    "potions": "np",
                    "value": to_number(raw.get(vf)),
                    "valueText": raw.get(vf) if isinstance(raw.get(vf), str) else "",
                    "demand": raw.get(df) or "",
                }
                break

    return item


# --------------------------------------------------------------------------
# Главное
# --------------------------------------------------------------------------

def main() -> int:
    DATA.mkdir(parents=True, exist_ok=True)

    items: dict[str, dict] = {}
    per_category: dict[str, int] = {}
    newest: str | None = None
    failures: list[str] = []

    print("=" * 70)
    print("ЦЕНЫ ADOPT ME С AMVGG.COM")
    print("=" * 70)

    for n, cat in enumerate(CATEGORIES, 1):
        url = f"{BASE}/values/{cat}"
        print(f"[{n}/{len(CATEGORIES)}] {cat} ... ", end="", flush=True)
        try:
            html = fetch(url)
        except RuntimeError as e:
            print("НЕ ЗАГРУЗИЛОСЬ")
            print(f"      {e}")
            failures.append(cat)
            continue

        text = next_payload(html)
        arrays = extract_arrays(text)
        if not arrays:
            print("данных нет (разметка сайта изменилась?)")
            failures.append(cat)
            continue

        # Берём самый крупный массив: на странице попадаются и служебные
        # списки вроде «похожие предметы», они всегда короче основного.
        key = max(arrays, key=lambda k: len(arrays[k]))
        arr = arrays[key]

        added = 0
        for raw in arr:
            if not isinstance(raw, dict) or not raw.get("name"):
                continue
            it = normalize(raw, cat)
            # Ключ (категория, имя): одно имя может жить в разных разделах.
            items[f"{cat}|{it['name']}"] = it
            added += 1
            if it["updatedAt"] and (newest is None or it["updatedAt"] > newest):
                newest = it["updatedAt"]

        per_category[cat] = added
        print(f"{added} предметов (массив «{key}»)")

        if n < len(CATEGORIES):
            time.sleep(PAUSE_BETWEEN)

    if failures:
        print()
        print(f"Не собрано категорий: {len(failures)} ({', '.join(failures)})")

    # Неполный каталог не перезаписывает прежний: предметы пропавших
    # категорий остались бы без цены, а это хуже устаревших данных.
    if len(per_category) < len(CATEGORIES):
        print()
        print("Каталог неполон - прежний файл не тронут.")
        print("Лучше устаревшие цены, чем дырявые.")
        return 1

    priced = sum(1 for it in items.values()
                 if any(v.get("value") is not None for v in it["variants"].values()))
    variants = sum(len(it["variants"]) for it in items.values())

    payload = {
        "source": "amvgg.com",
        "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S%z"),
        "sourceUpdatedIso": newest,
        "stats": {
            "items": len(items),
            "priced": priced,
            "variants": variants,
            "perCategory": per_category,
        },
        "items": items,
    }
    OUT_FILE.write_text(json.dumps(payload, ensure_ascii=False, indent=1), encoding="utf-8")

    print()
    print("=" * 70)
    print(f"Предметов        : {len(items)}")
    print(f"  с ценой        : {priced}")
    print(f"Вариантов всего  : {variants}")
    print(f"Свежайшая правка : {newest}")
    print(f"Записано         : {OUT_FILE}")
    print("=" * 70)
    return 0


if __name__ == "__main__":
    sys.exit(main())
