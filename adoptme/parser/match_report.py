"""
Сводит игровую базу Adopt Me с ценами amvgg и честно показывает, сколько
предметов удалось оценить.

Вход:
    adoptme/data/game_kinds.json   - выгрузка KindDB из живого клиента
    adoptme/data/amvgg_values.json - результат amvgg_fetch.py
Выход:
    adoptme/data/match_report.json - машиночитаемый результат
    отчёт в консоль

ПОЧЕМУ ЭТО ОТДЕЛЬНЫЙ ШАГ. Здесь ломается больше всего: имена на сайте и в
игре расходятся, категории нарезаны по-разному, а одно имя может
принадлежать нескольким предметам. В MM2 ровно на этом мы теряли цены -
пять разных «зомби» садились на одну запись сайта, и предмет молча получал
чужое число. Проще увидеть это в отчёте, чем в трейде.
"""

from __future__ import annotations

import json
import re
import sys
import unicodedata
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
GAME_FILE = DATA / "game_kinds.json"
SITE_FILE = DATA / "amvgg_values.json"
OUT_FILE = DATA / "match_report.json"

# Категория в игре -> разделы сайта, где искать.
#
# Нарезка разная: в игре яйца лежат внутри pets (флагом is_egg), на сайте у
# них свой раздел. Дома на сайте есть, а в KindDB их нет вовсе - жильё в
# Adopt Me живёт отдельной подсистемой, в инвентарь не попадает и в трейде
# не участвует, поэтому раздел houses мы просто не используем.
CATEGORY_MAP = {
    "pets": ["pets", "eggs"],
    "pet_accessories": ["petwear"],
    "transport": ["vehicles"],
    "toys": ["toys"],
    "stickers": ["stickers"],
    "food": ["food"],
    "gifts": ["gifts"],
    "strollers": ["strollers"],
}

# Категории игры, которых на сайте нет совсем. Не ошибка - эти предметы
# просто не торгуются и цены не имеют.
CATEGORIES_WITHOUT_PRICES = {"roleplay"}


def canon(s: str) -> str:
    """
    Каноническая форма имени.

    Приводим типографские апострофы к ASCII до вычистки символов: в игре
    встречается U+2019, на сайте обычный U+0027, и «Bee's» с разными
    апострофами иначе не совпали бы.
    """
    s = unicodedata.normalize("NFKD", s or "")
    s = s.replace("’", "'").replace("‘", "'")
    return re.sub(r"[^a-z0-9]+", "", s.lower())


def canon_loose(s: str) -> str:
    """
    Форма для запасного прохода: снимаем артикль в начале.

    «The Black Dog» в игре и «Black Dog» на сайте - один и тот же пёс.
    Отдельная функция, а не общий canon: артикль иногда значим, и мешать
    точное сравнение с приблизительным нельзя.
    """
    return canon(re.sub(r"^\s*the\s+", "", (s or ""), flags=re.I))


# Расхождения в написании между игрой и сайтом. Список ЯВНЫЙ и короткий -
# и это осознанный отказ от автоматики.
#
# Сначала здесь стоял подбор по похожести с высоким порогом. Он нашёл эти
# три пары - и заодно решил, что «Ram Sticker» это «Rat Sticker», «Cat
# Sticker» тоже «Rat Sticker», а «Banana Rattle» - «Anna Rattle». У коротких
# имён одна буква разницы проходит любой порог, и предмет молча получает
# чужую цену. Три ручные строки надёжнее любого порога, а новые расхождения
# всё равно всплывут в обратной проверке внизу отчёта.
#
# Слева - как называет игра, справа - как называет сайт.
ALIASES = {
    "Malayan Tapir": "Malaysian Tapir",
    "Woolly Rhino": "Wooly Rhino",
}


def spelling_candidates(name: str, pool: dict[str, list]) -> list[str]:
    """
    Похожие имена - ТОЛЬКО чтобы показать человеку, никогда не для подстановки.

    Нужно, чтобы новое расхождение в написании не потерялось: оно всплывёт
    в отчёте как подсказка, а решение добавить его в ALIASES принимает
    человек.
    """
    import difflib

    c = canon(name)
    if not c:
        return []
    return difflib.get_close_matches(c, list(pool.keys()), n=3, cutoff=0.88)


def load(path: Path, what: str):
    if not path.exists():
        print(f"ОШИБКА: нет файла {path}")
        print(f"        ({what})")
        sys.exit(1)
    return json.loads(path.read_text(encoding="utf-8"))


def build_index(site: dict) -> dict[str, dict[str, list]]:
    """Индекс: раздел сайта -> каноническое имя -> список записей."""
    idx: dict[str, dict[str, list]] = defaultdict(lambda: defaultdict(list))
    for item in site["items"].values():
        idx[item["category"]][canon(item["name"])].append(item)
    return idx


def pick(candidates: list, game_item: dict) -> tuple[dict | None, bool]:
    """
    Выбор из нескольких записей сайта с одинаковым именем.

    Возвращает (запись, неоднозначно ли). Если кандидат один - берём его.
    Если больше, пробуем развести по году: у игрового предмета год лежит в
    origin_entry, у сайта - в тексте origin («Halloween Event (2019)»).
    """
    if not candidates:
        return None, False
    if len(candidates) == 1:
        return candidates[0], False

    year = game_item.get("year")
    if year:
        same_year = [c for c in candidates if year in (c.get("origin") or "")]
        if len(same_year) == 1:
            return same_year[0], False

    # Развести не вышло - берём первого, но честно помечаем.
    return candidates[0], True


def main() -> int:
    game = load(GAME_FILE, "выгрузка KindDB; запусти adoptme/overlay/dump_kinds.lua")
    site = load(SITE_FILE, "цены amvgg; запусти adoptme/parser/amvgg_fetch.py")
    idx = build_index(site)

    records: list[dict] = []

    for gid, g in game["items"].items():
        gcat = g.get("category", "")
        rec = {
            "gameId": gid,
            "gameKind": g.get("kind", gid),
            "name": g.get("name", ""),
            "gameCategory": gcat,
            "rarity": g.get("rarity", ""),
            "year": g.get("year"),
            "origin": g.get("fullOrigin", ""),
            "method": "нет",
            "siteName": None,
            "siteCategory": None,
            "ambiguous": False,
            "variants": None,
        }

        if gcat in CATEGORIES_WITHOUT_PRICES:
            rec["method"] = "категория без цен"
            records.append(rec)
            continue

        sections = CATEGORY_MAP.get(gcat)
        if not sections:
            rec["method"] = "нет раздела на сайте"
            records.append(rec)
            continue

        # Яйцу ищем пару сначала среди яиц: в игре они лежат внутри pets,
        # на сайте вынесены отдельно, и имена могут пересекаться.
        if g.get("isEgg"):
            sections = ["eggs"] + [s for s in sections if s != "eggs"]

        name = g.get("name", "")
        c = canon(name)
        hit, ambiguous = None, False

        # 1. Точное совпадение имени.
        for section in sections:
            found = idx.get(section, {}).get(c, [])
            hit, ambiguous = pick(found, g)
            if hit:
                rec["method"] = "имя+раздел"
                break

        # 2. Без артикля: «The Black Dog» -> «Black Dog».
        if not hit:
            cl = canon_loose(name)
            if cl != c:
                for section in sections:
                    found = idx.get(section, {}).get(cl, [])
                    hit, ambiguous = pick(found, g)
                    if hit:
                        rec["method"] = "имя без артикля"
                        break

        # 3. Явный список расхождений в написании.
        if not hit and name in ALIASES:
            ca = canon(ALIASES[name])
            for section in sections:
                found = idx.get(section, {}).get(ca, [])
                hit, ambiguous = pick(found, g)
                if hit:
                    rec["method"] = "по списку написаний"
                    break

        if hit:
            rec["siteName"] = hit["name"]
            rec["siteCategory"] = hit["category"]
            rec["ambiguous"] = ambiguous
            rec["variants"] = hit["variants"]
            rec["updatedAt"] = hit.get("updatedAt")

        records.append(rec)

    # --- Сводка ----------------------------------------------------------
    total = len(records)
    matched = [r for r in records if r["variants"]]
    no_section = [r for r in records if r["method"] == "нет раздела на сайте"]
    no_price_cat = [r for r in records if r["method"] == "категория без цен"]
    missed = [r for r in records
              if r["method"] == "нет" and r not in no_section and r not in no_price_cat]
    ambiguous = [r for r in matched if r["ambiguous"]]

    print("=" * 72)
    print("СВЕДЕНИЕ ИГРОВОЙ БАЗЫ ADOPT ME С ЦЕНАМИ AMVGG")
    print("=" * 72)
    print(f"Предметов в игре      : {total}")
    print(f"Нашли цену            : {len(matched)}")
    print(f"Не нашли              : {len(missed)}")
    print(f"Категорий без цен     : {len(no_price_cat) + len(no_section)}")
    print(f"Неоднозначных         : {len(ambiguous)}")

    print()
    print("ПО КАТЕГОРИЯМ (важно только то, что носят в трейде)")
    print(f"   {'категория':<18} {'в игре':>7} {'с ценой':>9} {'доля':>7}")
    by_cat: dict[str, list] = defaultdict(list)
    for r in records:
        by_cat[r["gameCategory"]].append(r)
    for cat in sorted(by_cat, key=lambda c: -len(by_cat[c])):
        group = by_cat[cat]
        hit = sum(1 for r in group if r["variants"])
        share = f"{hit / len(group) * 100:.0f}%" if group else "-"
        print(f"   {cat:<18} {len(group):>7} {hit:>9} {share:>7}")

    # Питомцы - главное. По ним и судим о готовности.
    pets = by_cat.get("pets", [])
    pets_hit = [r for r in pets if r["variants"]]
    print()
    print(f"ПИТОМЦЫ: {len(pets_hit)} из {len(pets)} с ценой "
          f"({len(pets_hit) / len(pets) * 100:.1f}%)" if pets else "ПИТОМЦЕВ НЕТ")

    if missed:
        print()
        print(f"--- НЕ НАШЛИ ЦЕНУ, первые 15 из {len(missed)} ---")
        for r in missed[:15]:
            print(f"   {r['name']:<30} {r['gameCategory']:<16} {r['rarity']}")

    if ambiguous:
        print()
        print(f"--- НЕОДНОЗНАЧНЫЕ, все {len(ambiguous)} ---")
        for r in ambiguous:
            print(f"   {r['name']:<30} год={r['year']}  -> «{r['siteName']}»")

    # Совпадения не по точному имени показываем ВСЕ и всегда: это место, где
    # предмет мог бы получить чужую цену.
    loose = [r for r in matched
             if r["method"] in ("имя без артикля", "по списку написаний")]
    if loose:
        print()
        print(f"--- СОПОСТАВЛЕНО НЕ ПО ТОЧНОМУ ИМЕНИ, все {len(loose)} ---")
        for r in loose:
            print(f"   {r['name']:<28} -> «{r['siteName']}»  [{r['method']}]")

    # Обратная проверка: цены сайта, которым не нашлось предмета в игре.
    # Именно здесь всплывают новые расхождения в написании - раньше, чем
    # кто-то заметит отсутствие цены в трейде.
    used = {(r["siteCategory"], r["siteName"]) for r in matched}
    leftovers = [(v["category"], v["name"]) for v in site["items"].values()
                 if (v["category"], v["name"]) not in used]
    interesting = [(c, n) for c, n in leftovers if c in ("pets", "eggs")]
    if interesting:
        print()
        print(f"--- ЦЕНЫ САЙТА БЕЗ ПАРЫ В ИГРЕ (питомцы и яйца): {len(interesting)} ---")
        print("    возможные расхождения в написании - проверь и допиши в ALIASES:")
        for c, n in sorted(interesting):
            hints = spelling_candidates(n, {canon(r["name"]): r for r in records
                                            if r["gameCategory"] == "pets"})
            hint = ""
            if hints:
                names = {canon(r["name"]): r["name"] for r in records}
                hint = "  похоже на: " + ", ".join(names.get(h, h) for h in hints)
            print(f"   [{c}] {n}{hint}")

    print()
    print(f"Цен сайта пристроено  : {len(used)} из {len(site['items'])}"
          f"  ({len(used) / len(site['items']) * 100:.1f}%)")

    OUT_FILE.write_text(
        json.dumps({
            "generatedAt": site.get("generatedAt"),
            "sourceUpdatedIso": site.get("sourceUpdatedIso"),
            "stats": {
                "total": total,
                "matched": len(matched),
                "missed": len(missed),
                "ambiguous": len(ambiguous),
            },
            "records": records,
        }, ensure_ascii=False, indent=1),
        encoding="utf-8")

    print()
    print(f"Отчёт записан: {OUT_FILE}")

    # Питомцы - это то, ради чего всё затевалось. Если их покрытие
    # обвалилось, дальше идти нельзя: оверлей будет молчать в трейдах.
    if pets and len(pets_hit) / len(pets) < 0.90:
        print()
        print("ПОКРЫТИЕ ПИТОМЦЕВ НИЖЕ 90% - что-то сломалось в сопоставлении.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
