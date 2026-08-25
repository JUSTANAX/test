"""
Обновление ценностей одной командой:

    python update.py

Гонит три шага подряд и останавливается на первом же сбое:
    1. sv_parser.py      - забирает свежие ценности с Supreme Values
    2. match_report.py   - сводит их с игровой базой
    3. build_game_map.py - собирает mm2_values.json для оверлея

Игровую базу (data/game_items.json) обновлять почти никогда не нужно - она
меняется только когда в MM2 добавляют предметы. Пересобрать её можно скриптом
overlay/dump_items.lua прямо из Madium.

Ценности на сайте двигаются пачками раз в 2-5 дней, так что гонять это чаще
раза в сутки бессмысленно - в архиве просто не будет нового снимка.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PARSER = ROOT / "parser"

STEPS = [
    ("Сбор ценностей с сайта", PARSER / "sv_parser.py"),
    ("Сведение с игровой базой", PARSER / "match_report.py"),
    ("Сборка артефакта для игры", PARSER / "build_game_map.py"),
]


def main() -> int:
    if not (ROOT / "data" / "game_items.json").exists():
        print("ВНИМАНИЕ: нет data/game_items.json - шаг сведения упадёт.")
        print("Запусти overlay/dump_items.lua из Madium, находясь в MM2,")
        print("затем скопируй результат из Workspace в data/game_items.json.")
        print()

    for i, (title, script) in enumerate(STEPS, 1):
        print(f"\n{'=' * 64}")
        print(f"ШАГ {i}/{len(STEPS)}: {title}")
        print("=" * 64)
        result = subprocess.run([sys.executable, str(script)], cwd=ROOT)
        if result.returncode != 0:
            print(f"\nШаг {i} завершился с кодом {result.returncode}. Останавливаюсь.")
            return result.returncode

    print("\nГотово. mm2_values.json обновлён и скопирован в Workspace Madium.")
    print("Если настроено GitHub-зеркало - не забудь запушить data/mm2_values.json.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
