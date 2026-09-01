"""
Как часто Supreme Values на самом деле публикует новые цены.

    python parser/cadence.py

ПОЧЕМУ НЕ ПО АРХИВУ. Первым делом я полез в Wayback - и зря. Imperva
блокирует краулер архива ровно так же, как блокировала нас: из 81 снимка
страницы godlies 72 оказались заглушками по 212 байт, а девять, которые
индекс считает крупными, при выдаче отдают ту же заглушку. Метки
data-updated-iso в архиве нет вообще, мерить там нечего.

ЧЕМ МЕРИМ ВМЕСТО ЭТОГО. Своей историей. Бот кладёт в каждый коммит поле
sourceUpdatedIso - дату публикации, которую сайт показал в тот момент.
Каждая её смена и есть новая публикация цен. Данные накапливаются сами,
и чем дольше работает автообновление, тем точнее ответ.

ЧТО СЧИТАТЬ ШУМОМ. Пока конвейер настраивался, цены брались то с зеркал,
то из архива, и «дата сайта» прыгала назад (например с 2026-08-20 на
2026-07-21 - это архив отдал месячной давности снимок, а не сайт откатил
цены). Прыжки назад отбрасываем: публикация не может быть старше
предыдущей.
"""

from __future__ import annotations

import json
import subprocess
import sys
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TRACKED = "data/mm2_values.json"


def sh(*args: str) -> str:
    return subprocess.run(args, cwd=ROOT, capture_output=True,
                          text=True, encoding="utf-8").stdout


def main() -> int:
    lines = sh("git", "log", "--format=%H %cI", "--", TRACKED).splitlines()
    if not lines:
        print(f"нет истории по {TRACKED}")
        return 1

    seen: list[str] = []
    for line in lines:
        if not line.strip():
            continue
        sha = line.split()[0]
        blob = sh("git", "show", f"{sha}:{TRACKED}")
        if not blob.strip():
            continue
        try:
            iso = (json.loads(blob).get("sourceUpdatedIso") or "")[:10]
        except json.JSONDecodeError:
            continue
        if iso and iso not in seen:
            seen.append(iso)

    seen.reverse()

    # Отбрасываем прыжки назад: это следы зеркал и архива, а не публикации.
    clean: list[str] = []
    for d in seen:
        if not clean or d > clean[-1]:
            clean.append(d)
        else:
            print(f"   пропускаю {d}: старше предыдущей ({clean[-1]}) - "
                  f"это зеркало или архив, а не публикация сайта")

    print()
    print("=" * 56)
    print("ПУБЛИКАЦИИ ЦЕН, ЗАФИКСИРОВАННЫЕ НАМИ")
    print("=" * 56)

    gaps: list[int] = []
    prev: date | None = None
    for d in clean:
        cur = date.fromisoformat(d)
        tail = ""
        if prev:
            g = (cur - prev).days
            gaps.append(g)
            tail = f"   +{g} дн."
        print(f"   {d}{tail}")
        prev = cur

    print()
    if not gaps:
        print("Промежутков пока нет - слишком короткая история наблюдений.")
        return 0

    gaps_sorted = sorted(gaps)
    n = len(gaps_sorted)
    mid = gaps_sorted[n // 2] if n % 2 else (gaps_sorted[n // 2 - 1] + gaps_sorted[n // 2]) / 2
    print(f"промежутков : {n}  {gaps}")
    print(f"медиана     : {mid} дн.")
    print(f"среднее     : {sum(gaps) / n:.1f} дн.")
    print(f"размах      : {gaps_sorted[0]}..{gaps_sorted[-1]} дн.")
    print()
    print(f"Наблюдение длится {(date.fromisoformat(clean[-1]) - date.fromisoformat(clean[0])).days} "
          f"дн. Чем дольше работает автообновление, тем надёжнее число:")
    print("на трёх-четырёх промежутках говорить о точной частоте рано.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
