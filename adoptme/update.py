"""
Обновление цен Adopt Me одной командой:

    python adoptme/update.py

Порядок:
    1. amvgg_fetch.py    - цены с amvgg.com (десять разделов)
    2. match_report.py   - сводит их с игровой базой
    3. build_game_map.py - собирает am_values.json для оверлея

ЧЕМ ОТЛИЧАЕТСЯ ОТ MM2. Там источник прячется за Imperva, и приходится
поднимать настоящий Chromium через Playwright. Здесь сайт отдаёт данные в
обычном ответе сервера, поэтому весь конвейер обходится стандартной
библиотекой Python - ни одной внешней зависимости, и в облаке не нужно
ставить браузер.

Игровую базу (adoptme/data/game_kinds.json) обновлять почти никогда не
нужно: она меняется, только когда в Adopt Me добавляют предметы.
Пересобрать её можно скриптом adoptme/overlay/dump_kinds.lua прямо из
исполнителя, находясь в игре.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PARSER = ROOT / "parser"

STEPS = [
    ("Цены с amvgg.com", PARSER / "amvgg_fetch.py"),
    ("Сведение с игровой базой", PARSER / "match_report.py"),
    ("Сборка артефакта для игры", PARSER / "build_game_map.py"),
]


def say(*args) -> None:
    """
    Печать с немедленным сбросом буфера.

    Обычный print буферизуется поблочно, когда вывод уходит в файл или в лог
    сборки, а дочерние процессы пишут в тот же поток сразу. Из-за этого
    заголовки шагов оказывались НИЖЕ вывода самих шагов - в логе облака
    получалась каша.
    """
    print(*args, flush=True)


def main() -> int:
    if not (ROOT / "data" / "game_kinds.json").exists():
        say("ВНИМАНИЕ: нет adoptme/data/game_kinds.json - шаг сведения упадёт.")
        say("Запусти adoptme/overlay/dump_kinds.lua из исполнителя, находясь")
        say("в Adopt Me, и положи результат в adoptme/data/game_kinds.json.")
        say()

    for i, (title, script) in enumerate(STEPS, start=1):
        say("=" * 64)
        say(f"ШАГ {i}/{len(STEPS)}: {title}")
        say("=" * 64)
        code = subprocess.run([sys.executable, str(script)], cwd=ROOT.parent).returncode
        if code != 0:
            say()
            say(f"Шаг {i} завершился с кодом {code}. Останавливаюсь.")
            # Каждый шаг сам следит, чтобы не записать неполный результат:
            # неполный каталог опаснее устаревшего, потому что предметы
            # пропавших разделов молча остались бы без цены.
            return code
        say()

    say("Готово. adoptme/data/am_values.json обновлён.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
