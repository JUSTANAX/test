"""Ищет фантомные дубликаты, возникшие при слиянии попапа и сетки."""
import json
import re
import sys
import unicodedata
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
data = json.loads((ROOT / "data" / "sv_values.json").read_text(encoding="utf-8"))

by_cat = defaultdict(list)
for key, item in data["items"].items():
    by_cat[item["category"]].append(item)


def canon(s: str) -> str:
    """Агрессивная нормализация: только буквы и цифры, нижний регистр."""
    s = unicodedata.normalize("NFKD", s)
    s = s.replace("’", "'").replace("‘", "'")
    return re.sub(r"[^a-z0-9]", "", s.lower())


total_phantom = 0
for cat in sorted(by_cat):
    groups = defaultdict(list)
    for item in by_cat[cat]:
        groups[canon(item["name"])].append(item)
    dupes = {k: v for k, v in groups.items() if len(v) > 1}
    if dupes:
        print(f"--- {cat}: {len(dupes)} групп-дубликатов ---")
        for k, v in list(dupes.items())[:8]:
            names = [f"{i['name']!r}(value={i['value']})" for i in v]
            print("   " + " <=> ".join(names))
        total_phantom += sum(len(v) - 1 for v in dupes.values())

print()
print(f"Всего лишних записей из-за расхождения написания: {total_phantom}")
print(f"Предметов в каталоге: {data['itemCount']}")
print()

# Сколько предметов вообще без цены
no_value = [i for i in data["items"].values() if i["value"] is None]
print(f"Без цены (value=None): {len(no_value)}")
cnt = defaultdict(int)
for i in no_value:
    cnt[i["category"]] += 1
print("   по категориям:", dict(sorted(cnt.items(), key=lambda x: -x[1])))
