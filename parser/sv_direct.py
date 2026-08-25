"""
Цены Supreme Values напрямую с сайта через Playwright.

ПОЧЕМУ ЭТО РАБОТАЕТ. Imperva отсеивает не «ботов вообще», а клиентов без
настоящего браузерного отпечатка: без JS-движка, без TLS-подписи Chrome, без
его API. Playwright запускает НАСТОЯЩИЙ Chrome, поэтому для сайта он
неотличим от обычного посетителя. Проверено: обычный запрос получает заглушку
в 878 байт, Playwright - 608 002 символа с полным каталогом, причём headless
и с первой попытки.

ЧЕМ ЭТО ЛУЧШЕ ПРЕЖНИХ ПУТЕЙ.
  Wayback - заходит на страницы нерегулярно, половина каталога месячной
            давности.
  Зеркала - те же данные, но чужими руками: два сторонних репозитория,
            которые автор может забросить.
  Здесь   - свои данные, свежесть минутная, зависимостей нет.

ПРОСТОТА РАЗБОРА. На странице цены лежат в глобальной переменной _svPopup.
Это живой объект JavaScript, поэтому читаем его как есть - без gzip, без
регулярок и без счётчика скобок, которые нужны были при работе с архивом.

Выход - тот же sv_values.json, что делают sv_parser.py и sv_mirror.py,
поэтому остальной конвейер не меняется.
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data"
OUT_FILE = DATA_DIR / "sv_values.json"

BASE = "https://supremevalues.com/mm2/{cat}"

CATEGORIES = [
    "sets", "uniques", "ancients", "vintages", "chromas", "godlies",
    "legendaries", "rares", "uncommons", "commons", "pets", "misc", "evos",
]

# Меньше этого числа предметов в категории - считаем разбор провалившимся.
MIN_ITEMS_PER_CATEGORY = 3
# Меньше этого суммарно - не перезаписываем каталог вовсе.
MIN_TOTAL_ITEMS = 900

NAV_TIMEOUT = 60_000
SETTLE_MS = 2_500          # сколько ждать после загрузки
POLITE_DELAY = 1.0         # пауза между категориями

# Читаем и _svPopup, и отрисованную сетку. Ни один источник не полон сам по
# себе: на /mm2/uniques в _svPopup лежит один предмет, а в сетке - сотня;
# у /mm2/evos блока _svPopup нет вовсе. Там, где _svPopup есть, он богаче
# полями, поэтому при слиянии перекрывает сетку.
EXTRACT = """() => {
  const out = { popup: {}, grid: {}, updated: null, len: document.documentElement.outerHTML.length };

  const upd = document.querySelector('[data-updated-iso]');
  if (upd) out.updated = upd.getAttribute('data-updated-iso');

  if (typeof window._svPopup === 'object' && window._svPopup) {
    for (const [name, it] of Object.entries(window._svPopup)) {
      out.popup[name] = {
        value: it.rawValue,
        valueText: it.value,
        demand: it.demand,
        rarity: it.rarity,
        stability: it.stability,
        pctChange: it.pctChange,
        diff: it.diff,
        origin: it.origin,
        flippability: it.flippability,
        riseChance: it.riseChance,
        aliases: it.aliases,
        range: it.range,
        cls: it.class,
      };
    }
  }

  // Сначала собираем всё списком: на странице бывают РАЗНЫЕ предметы с
  // одинаковым именем, различающиеся только годом. Blue Pumpkin существует
  // как версия 2018 за 220, 2020 за 7 и 2019 за 1. При записи сразу в
  // словарь по имени побеждала последняя, и дорогая версия получала цену
  // дешёвой - ошибка в 220 раз.
  const rows = [];
  for (const cell of document.querySelectorAll('div.itemcolumn, div.itemcell')) {
    const rawName = cell.getAttribute('data-name')
      || (cell.querySelector('div.itemhead') || {}).textContent;
    if (!rawName) continue;
    const name = rawName.trim();
    if (!name) continue;
    rows.push({
      name,
      year: (cell.getAttribute('data-year') || '').trim(),
      data: {
        valueText: ((cell.querySelector('b.itemvalue') || {}).textContent
          || cell.getAttribute('data-value') || '').trim(),
        demand: cell.getAttribute('data-demand'),
        rarity: cell.getAttribute('data-rarity'),
        stability: cell.getAttribute('data-stability'),
        pctChange: cell.getAttribute('data-changepct'),
      },
    });
  }

  // _svPopup - главный и уже разведён самим сайтом: его ключи уникальны.
  // Сетка добавляет только то, чего в нём нет, иначе один предмет попадёт в
  // каталог дважды - под голым именем из popup и под именем с годом из сетки.
  const known = new Set(Object.keys(out.popup));
  const rest = rows.filter(r => !known.has(r.name));

  // В остатке имя дополняем годом там, где оно повторяется: одиночные вещи
  // должны сохранить обычное имя, иначе перестанут совпадать с игровой базой.
  const seen = {};
  for (const r of rest) seen[r.name] = (seen[r.name] || 0) + 1;
  for (const r of rest) {
    const key = (seen[r.name] > 1 && r.year) ? `${r.name} (${r.year})` : r.name;
    out.grid[key] = r.data;
  }
  out.gridDisambiguated = Object.keys(seen).filter(n => seen[n] > 1).length;
  return out;
}"""


def clean(raw: Any) -> str:
    """Строка для показа. Пустая - данных нет."""
    if raw is None:
        return ""
    if isinstance(raw, (list, tuple)):
        parts = [clean(x) for x in raw]
        return ", ".join(p for p in parts if p)
    text = str(raw).replace("\r", "\n").split("\n", 1)[0].strip()
    if text.upper().strip("[]") in ("", "N/A", "NA", "NONE", "NULL"):
        return ""
    return text


def to_number(raw: Any) -> float | None:
    """Число из того, что дал сайт. None - значит цена не числовая."""
    if isinstance(raw, (int, float)):
        return float(raw)
    text = clean(raw).replace(",", "")
    if not text:
        return None
    try:
        return float(text)
    except ValueError:
        return None


def build_record(name: str, category: str, src: dict[str, Any]) -> dict[str, Any]:
    value = to_number(src.get("value"))
    text = clean(src.get("valueText"))

    # Числовое поле есть только у записей из _svPopup. Те, что пришли из
    # отрисованной сетки, несут цену строкой - и «220,000» это ровно такое же
    # число, как 220000. Без этого разбора хрома-предметы уезжали в бартер.
    if value is None and text:
        value = to_number(text)

    if value is not None:
        kind = "number"
    elif text:
        # «x4 T1 Legendaries» и подобное - бартер, а не цена. Превращать это
        # в число нельзя: получится выдуманная ценность.
        kind = "barter"
    else:
        kind = "none"

    if clean(src.get("valueText")).lower().startswith("coming soon"):
        kind = "coming-soon"

    return {
        "name": name,
        "category": category,
        "value": value,
        "valueKind": kind,
        "valueText": text,
        "demand": clean(src.get("demand")),
        "rarity": clean(src.get("rarity")),
        "stability": clean(src.get("stability")),
        "pctChange": clean(src.get("pctChange")),
        "diff": clean(src.get("diff")),
        "origin": clean(src.get("origin")),
        "flippability": clean(src.get("flippability")),
        "riseChance": clean(src.get("riseChance")),
        "aliases": clean(src.get("aliases")),
    }


def launch_browser(pw):
    """
    Настоящий Chrome, если он есть; иначе встроенный Chromium.

    Локально системный Chrome предпочтительнее - именно на нём проверено, что
    Imperva пропускает. На сервере GitHub Actions его нет, поэтому падаем на
    встроенный: пройдёт ли он - как раз то, что мы и выясняем.
    """
    for channel in ("chrome", None):
        try:
            kwargs: dict[str, Any] = {"headless": True}
            if channel:
                kwargs["channel"] = channel
            browser = pw.chromium.launch(**kwargs)
            print(f"браузер: {channel or 'встроенный chromium'}")
            return browser
        except Exception as exc:  # noqa: BLE001
            print(f"   {channel or 'chromium'} не запустился: {type(exc).__name__}")
    raise RuntimeError("не удалось запустить ни один браузер")


def main() -> int:
    DATA_DIR.mkdir(parents=True, exist_ok=True)

    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print("playwright не установлен: pip install playwright && playwright install chromium")
        return 1

    print("=" * 62)
    print("Цены Supreme Values напрямую с сайта")
    print("=" * 62)

    catalog: dict[str, dict] = {}
    cat_info: dict[str, dict] = {}
    failed: dict[str, str] = {}

    with sync_playwright() as pw:
        browser = launch_browser(pw)
        ctx = browser.new_context(
            viewport={"width": 1440, "height": 900},
            locale="en-US",
        )
        page = ctx.new_page()

        for i, cat in enumerate(CATEGORIES, 1):
            print(f"[{i}/{len(CATEGORIES)}] {cat} ... ", end="", flush=True)
            try:
                page.goto(BASE.format(cat=cat), wait_until="domcontentloaded",
                          timeout=NAV_TIMEOUT)
                page.wait_for_timeout(SETTLE_MS)
                res = page.evaluate(EXTRACT)

                merged: dict[str, dict] = {}
                for name, src in (res.get("grid") or {}).items():
                    merged[name] = src
                for name, src in (res.get("popup") or {}).items():
                    merged[name] = src

                if len(merged) < MIN_ITEMS_PER_CATEGORY:
                    # Страница в 878 байт - это заглушка Imperva, а не пустая
                    # категория. Отличаем по объёму, а не по коду ответа.
                    hint = ("похоже на заглушку защиты"
                            if res.get("len", 0) < 5000 else "страница есть, но пуста")
                    raise RuntimeError(f"{len(merged)} предметов, {hint} "
                                       f"({res.get('len')} символов)")

                for name, src in merged.items():
                    catalog[f"{cat}|{name}"] = build_record(name, cat, src)

                iso = clean(res.get("updated"))
                cat_info[cat] = {
                    "count": len(merged),
                    "snapshot": time.strftime("%Y%m%d%H%M%S"),
                    "method": f"напрямую (popup:{len(res.get('popup') or {})} "
                              f"+ сетка:{len(res.get('grid') or {})})",
                    "sourceUpdatedIso": iso,
                }
                print(f"OK  {len(merged):>4} предметов  обновлено {iso[:10] or '?'}")
            except Exception as exc:  # noqa: BLE001
                failed[cat] = f"{type(exc).__name__}: {exc}"
                print(f"СБОЙ  {exc}")
            time.sleep(POLITE_DELAY)

        browser.close()

    print()
    print("=" * 62)
    print(f"Категорий разобрано : {len(cat_info)}/{len(CATEGORIES)}")
    print(f"Предметов всего     : {len(catalog)}")

    if failed:
        print(f"Сбойные категории   : {', '.join(failed)}")

    # Неполный каталог не кладём поверх хорошего: предметы пропавших
    # категорий получили бы цену однофамильцев из чужих категорий.
    if failed or len(catalog) < MIN_TOTAL_ITEMS:
        print()
        print("НЕ ЗАПИСАНО: каталог неполон.")
        print(f"Прежний {OUT_FILE.name} оставлен нетронутым.")
        for cat, why in failed.items():
            print(f"   {cat}: {why}")
        print("=" * 62)
        return 1

    dates = [c["sourceUpdatedIso"][:10] for c in cat_info.values() if c["sourceUpdatedIso"]]
    oldest = min(dates) if dates else ""

    payload = {
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "sourceUpdatedIso": oldest,
        "sourceKind": "direct",
        "categories": cat_info,
        "failedCategories": {},
        "itemCount": len(catalog),
        "items": catalog,
    }

    tmp = OUT_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(tmp, OUT_FILE)

    print(f"Цены сайта от       : {oldest or 'неизвестно'}")
    print(f"Записано            : {OUT_FILE}")
    print("=" * 62)
    return 0


if __name__ == "__main__":
    sys.exit(main())
