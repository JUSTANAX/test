"""
Гейт Этапа 0: сводит игровую базу MM2 со списком Supreme Values и честно
показывает, какой процент предметов вообще удаётся оценить.

Если процент низкий - переделывать надо здесь, а не после написания оверлея.

Вход:
    data/game_items.json  - дамп ReplicatedStorage.Database.Sync из живого клиента
    data/sv_values.json   - результат sv_parser.py
Выход:
    data/match_report.json - машиночитаемый результат
    отчёт в консоль
"""

from __future__ import annotations

import json
import re
import sys
import unicodedata
from collections import defaultdict
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
GAME_FILE = DATA / "game_items.json"
SV_FILE = DATA / "sv_values.json"
OUT_FILE = DATA / "match_report.json"

# Редкость в игре -> категория на сайте.
# Vintage в игровой базе отсутствует как редкость, но на сайте категория есть;
# по количеству (10 против 10 Classic) это почти наверняка одно и то же.
RARITY_TO_CATEGORY = {
    "Godly": "godlies",
    "Ancient": "ancients",
    "Legendary": "legendaries",
    "Rare": "rares",
    "Uncommon": "uncommons",
    "Common": "commons",
    "Unique": "uniques",
    "Classic": "vintages",
    "Vintage": "vintages",
}

# Редкости, для которых прямого соответствия нет - ищем по всем категориям.
RARITY_NO_DIRECT_CATEGORY = {"Christmas", "Halloween"}


def canon(s: str) -> str:
    """
    Каноническая форма имени для сравнения.

    Апострофы на сайте - ASCII U+0027, но в игре может встретиться типографский
    U+2019, поэтому приводим оба к одному виду до удаления символов.
    """
    s = unicodedata.normalize("NFKD", s or "")
    s = s.replace("’", "'").replace("‘", "'")
    return re.sub(r"[^a-z0-9]+", "", s.lower())


def load(path: Path, what: str) -> Any:
    if not path.exists():
        print(f"ОШИБКА: нет файла {path}")
        print(f"        ({what})")
        sys.exit(1)
    return json.loads(path.read_text(encoding="utf-8"))


def sv_display_name(game_key: str, item_name: str) -> tuple[str, bool]:
    """
    Имя, под которым предмет ожидается на сайте, и флаг "это хрома".

    В игре хрома-версия имеет то же ItemName, что и обычная (SeerChroma ->
    "Seer"), а на сайте это отдельный предмет "Chroma Seer" с другой ценой.
    Матчить по ItemName нельзя - обычный Seer стоит копейки, хрома дорого.

    Игра использует ОБА написания ключа, и это легко упустить:
        SeerChroma        - суффикс, таких большинство
        ChromaDarkbringer - префикс, таких мало, но они дорогие

    Пока учитывался только суффикс, ChromaDarkbringer сопоставлялся с обычным
    Darkbringer за 33 вместо Chroma Darkbringer за 65 - занижение вдвое, и
    молча: в сводке он просто не попадал в число хром.

    Chromatic_G_2023 отсекается отдельно: это самостоятельный предмет, а не
    хрома-версия, и наивная проверка префикса его бы сломала.
    """
    if game_key.endswith("Chroma"):
        return f"Chroma {item_name}", True
    if game_key.startswith("Chroma") and not re.match(r"^Chromatic($|_)", game_key):
        return f"Chroma {item_name}", True
    return item_name, False


def name_candidates(base: str, item_type: str, year: str, event: str) -> list[str]:
    """
    Варианты написания имени на сайте, от точного к общему.

    Игра хранит тип и год отдельными полями, а Supreme Values зашивает их
    прямо в имя, причём двумя несовместимыми стилями сразу:
        Frozen (Gun) / Frozen (Knife)   - разделение по типу оружия
        Pumpkin (2017)                  - год в круглых скобках
        Blue Pumpkin [HALLOWS2018]      - событие и год в квадратных
    Без этих вариантов промахивались целые пласты сезонных предметов.
    """
    out = [base]

    # Обратный случай: год уже вшит в игровое имя, а на сайте его нет.
    # "Skeleton Key 2018" -> "Skeleton Key".
    stripped = re.sub(r"\s+(19|20)\d{2}$", "", base).strip()
    if stripped and stripped != base:
        out.append(stripped)

    for stem in list(out):
        if item_type in ("Knife", "Gun"):
            out.append(f"{stem} ({item_type})")
        if year:
            out.append(f"{stem} ({year})")
            if event:
                out.append(f"{stem} [{event.upper()}{year}]")
                out.append(f"{stem} {event} {year}")
        # Единственное/множественное: "Checker" <-> "Checkers".
        if stem.endswith("s"):
            out.append(stem[:-1])
        else:
            out.append(stem + "s")

    seen_v: set[str] = set()
    uniq = []
    for v in out:
        if v and v not in seen_v:
            seen_v.add(v)
            uniq.append(v)
    return uniq


def sv_payload(hit: dict) -> dict:
    """Поля с сайта, которые дальше уезжают в игру. Один источник правды."""
    return {
        "svName": hit["name"],
        "svCategory": hit["category"],
        "value": hit["value"],
        "valueKind": hit["valueKind"],
        "valueText": hit.get("valueText", ""),
        "demand": hit.get("demand", ""),
        "siteRarity": hit.get("rarity", ""),
        "stability": hit.get("stability", ""),
        "pctChange": hit.get("pctChange", ""),
        "diff": hit.get("diff", ""),
    }


def build_sv_index(sv: dict) -> tuple[dict, dict, dict]:
    """Три индекса: (категория, имя) -> предмет; имя -> [предметы]; алиас -> [предметы]."""
    by_cat_name: dict[tuple[str, str], dict] = {}
    by_name: dict[str, list[dict]] = defaultdict(list)
    by_alias: dict[str, list[dict]] = defaultdict(list)

    for item in sv["items"].values():
        c = canon(item["name"])
        by_cat_name[(item["category"], c)] = item
        by_name[c].append(item)
        for alias in item.get("aliases") or []:
            by_alias[canon(alias)].append(item)

    return by_cat_name, by_name, by_alias


def main() -> int:
    game = load(GAME_FILE, "дамп игровой базы; выгружается из живого клиента Roblox")
    sv = load(SV_FILE, "результат sv_parser.py; запусти сначала его")

    by_cat_name, by_name, by_alias = build_sv_index(sv)

    records: list[dict] = []

    # --- Оружие -----------------------------------------------------------
    skipped_placeholders: list[str] = []

    for key, g in game.get("weapons", {}).items():
        # Записи без имени - это не предметы, а служебные заглушки лутбоксов
        # (RandomLegendaryWeapon, RandomRareWeapon). В трейде не появляются,
        # в знаменателе им делать нечего.
        if not (g.get("name") or "").strip():
            skipped_placeholders.append(key)
            continue

        name, is_chroma = sv_display_name(key, g.get("name", ""))
        rarity = g.get("rarity", "")
        expected_cat = "chromas" if is_chroma else RARITY_TO_CATEGORY.get(rarity)
        c = canon(name)

        rec = {
            "gameKey": key,
            "gameName": g.get("name", ""),
            "expectedName": name,
            "gameType": g.get("type", ""),
            "gameRarity": rarity,
            "expectedCategory": expected_cat,
            "isChroma": is_chroma,
            "method": None,
            "svName": None,
            "svCategory": None,
            "value": None,
            "valueKind": None,
            "ambiguous": False,
        }

        variants = name_candidates(name, g.get("type", ""), g.get("year", ""), g.get("event", ""))

        hit = None
        # Сначала пробуем все варианты имени в ожидаемой категории - это самый
        # надёжный ключ. Только если ни один не подошёл, расширяем поиск на все
        # категории, потом на алиасы.
        if expected_cat:
            for v in variants:
                key = (expected_cat, canon(v))
                if key in by_cat_name:
                    hit = by_cat_name[key]
                    rec["method"] = "имя+категория" if v == name else "имя+тип/год+категория"
                    rec["matchedVariant"] = v
                    break

        if hit is None:
            for v in variants:
                cv = canon(v)
                if cv in by_name:
                    candidates = by_name[cv]
                    hit = candidates[0]
                    rec["method"] = "только имя" if v == name else "имя+тип/год"
                    rec["matchedVariant"] = v
                    rec["ambiguous"] = len(candidates) > 1
                    if rec["ambiguous"]:
                        rec["candidates"] = [
                            {"category": x["category"], "value": x["value"]} for x in candidates
                        ]
                    # Совпадение из ЧУЖОЙ категории - не доказательство.
                    # Silver Vampire's Axe в игре Unique, на сайте у него цены
                    # нет, и фолбэк подставлял ему 1450 от древнего Vampire's
                    # Axe. Один кандидат вместо нескольких не делает такую
                    # подстановку достовернее, поэтому ambiguous тут не спасал.
                    if expected_cat and hit["category"] != expected_cat:
                        rec["lowConfidence"] = True
                        rec["wrongCategory"] = hit["category"]
                    break

        if hit is None and c in by_alias:
            candidates = by_alias[c]
            hit = candidates[0]
            rec["method"] = "алиас"
            rec["ambiguous"] = len(candidates) > 1

        if hit:
            rec.update(sv_payload(hit))
        else:
            rec["method"] = "нет"

        records.append(rec)

    # --- Петы -------------------------------------------------------------
    for key, g in game.get("pets", {}).items():
        # Хрома-петы (BatChroma, FoxChroma и ещё пятеро) устроены так же, как
        # хрома-оружие, и раньше флаг им не проставлялся вовсе.
        name, is_chroma = sv_display_name(key, g.get("name", ""))
        c = canon(name)
        rec = {
            "gameKey": key,
            "gameName": g.get("name", ""),
            "expectedName": name,
            "gameType": "Pet",
            "gameRarity": g.get("rarity", ""),
            "expectedCategory": "chromas" if is_chroma else "pets",
            "isChroma": is_chroma,
            "method": None,
            "svName": None,
            "svCategory": None,
            "value": None,
            "valueKind": None,
            "ambiguous": False,
        }

        # Пет ищется только среди петов (или хром, если это хрома-пет).
        # Прежний фолбэк по всем категориям уводил пета в оружие: пет Santa
        # получал данные ножа Santa вместе с бартерным текстом «x3 T1 Commons».
        target_cat = "chromas" if is_chroma else "pets"
        hit = by_cat_name.get((target_cat, c))
        if hit:
            rec["method"] = "имя+категория"
        else:
            for v in name_candidates(name, "", g.get("year", ""), g.get("event", "")):
                probe = by_cat_name.get((target_cat, canon(v)))
                if probe:
                    hit = probe
                    rec["method"] = "имя+год"
                    rec["matchedVariant"] = v
                    break
        if hit:
            rec.update(sv_payload(hit))
        else:
            rec["method"] = "нет"
        records.append(rec)

    # --- Сводка -----------------------------------------------------------
    total = len(records)
    matched = [r for r in records if r["method"] != "нет"]
    priced = [r for r in matched if r["value"] is not None]
    ambiguous = [r for r in matched if r["ambiguous"]]
    unmatched = [r for r in records if r["method"] == "нет"]

    by_method: dict[str, int] = defaultdict(int)
    for r in records:
        by_method[r["method"]] += 1

    def pct(n: int) -> str:
        return f"{100.0 * n / total:.1f}%" if total else "-"

    print("=" * 68)
    print("ГЕЙТ ЭТАПА 0 - СВЕДЕНИЕ ИГРОВОЙ БАЗЫ С SUPREME VALUES")
    print("=" * 68)
    print(f"Предметов в игре        : {total}")
    print(f"Найдено на сайте        : {len(matched)}  ({pct(len(matched))})")
    print(f"  из них с числовой ценой: {len(priced)}  ({pct(len(priced))})")
    print(f"Неоднозначных            : {len(ambiguous)}")
    print(f"Не найдено               : {len(unmatched)}  ({pct(len(unmatched))})")
    if skipped_placeholders:
        print(f"Исключено заглушек       : {len(skipped_placeholders)} "
              f"({', '.join(skipped_placeholders[:3])}...)")
    print()
    print("По способу сопоставления:")
    for m, n in sorted(by_method.items(), key=lambda x: -x[1]):
        print(f"   {m:24} {n:>5}")

    # Общий процент обманчив: в трейде носят годли и хромы, а не Default Knife.
    # Смотреть надо на дорогие редкости отдельно.
    print()
    print("По редкости (что реально важно в трейде):")
    print(f"   {'редкость':14} {'всего':>6} {'найдено':>9} {'с ценой':>9}")
    by_rarity: dict[str, list[dict]] = defaultdict(list)
    for r in records:
        by_rarity[r["gameRarity"] or "?"].append(r)
    order = ["Godly", "Ancient", "Unique", "Legendary", "Rare", "Uncommon",
             "Common", "Classic", "Christmas", "Halloween"]
    for rar in order + [k for k in sorted(by_rarity) if k not in order]:
        group = by_rarity.get(rar)
        if not group:
            continue
        n = len(group)
        m = sum(1 for r in group if r["method"] != "нет")
        p = sum(1 for r in group if r["value"] is not None)
        print(f"   {rar:14} {n:>6} {m:>6} {100.0*m/n:>5.0f}% {p:>6} {100.0*p/n:>5.0f}%")

    # Хромы - отдельно, это самое опасное место
    chromas = [r for r in records if r["isChroma"]]
    chroma_ok = [r for r in chromas if r["method"] != "нет"]
    print()
    print(f"Хрома-предметы           : {len(chromas)}, сопоставлено {len(chroma_ok)}")
    for r in chromas[:5]:
        status = f"-> {r['svName']} ({r['svCategory']}, {r['value']})" if r["svName"] else "-> НЕ НАЙДЕН"
        print(f"   {r['gameKey']:24} {status}")

    if unmatched:
        # Для каждого промаха ищем ближайшие имена на сайте. Это отделяет
        # "предмета на сайте нет" от "мы не угадали написание" - второе
        # лечится правилом, первое нет.
        from difflib import get_close_matches

        all_sv_names = sorted({item["name"] for item in sv["items"].values()})
        canon_to_names: dict[str, list[str]] = defaultdict(list)
        for n in all_sv_names:
            canon_to_names[canon(n)].append(n)
        canon_keys = list(canon_to_names)

        for r in unmatched:
            near = get_close_matches(canon(r["expectedName"]), canon_keys, n=2, cutoff=0.82)
            r["nearest"] = [canon_to_names[k][0] for k in near]

        print()
        print(f"--- НЕ НАЙДЕНО, первые 30 из {len(unmatched)} ---")
        for r in unmatched[:30]:
            near = ", ".join(r["nearest"]) if r["nearest"] else "-"
            print(f"   {r['gameKey']:24} {r['expectedName']!r:22} "
                  f"{r['gameRarity']:11} похоже на: {near}")

        with_near = [r for r in unmatched if r["nearest"]]
        print()
        print(f"   Из них похожи на существующее имя: {len(with_near)} "
              f"(вероятно, чиним правилом)")
        print(f"   Ни на что не похожи: {len(unmatched) - len(with_near)} "
              f"(вероятно, на сайте их нет)")

        miss_by_rarity: dict[str, int] = defaultdict(int)
        for r in unmatched:
            miss_by_rarity[r["gameRarity"] or "?"] += 1
        print()
        print("   Не найдено по редкости:",
              dict(sorted(miss_by_rarity.items(), key=lambda x: -x[1])))

    if ambiguous:
        print()
        print(f"--- НЕОДНОЗНАЧНЫЕ, первые 15 из {len(ambiguous)} ---")
        for r in ambiguous[:15]:
            cands = r.get("candidates") or []
            desc = ", ".join(f"{c['category']}={c['value']}" for c in cands) or "?"
            print(f"   {r['expectedName']!r:26} взято {r['svCategory']}={r['value']}  из [{desc}]")

    OUT_FILE.write_text(
        json.dumps(
            {
                "total": total,
                "matched": len(matched),
                "priced": len(priced),
                "ambiguous": len(ambiguous),
                "unmatched": len(unmatched),
                "records": records,
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
    print()
    print(f"Подробности записаны в {OUT_FILE}")
    print("=" * 68)
    return 0


if __name__ == "__main__":
    sys.exit(main())
