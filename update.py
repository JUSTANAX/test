"""
Обновление цен одной командой:

    python update.py

Порядок такой:
    1. цены Supreme Values, три источника по убыванию свежести:
         sv_direct.py  - напрямую с сайта через Playwright
         sv_mirror.py  - через публичные зеркала
         sv_parser.py  - через архив Wayback
       Следующий пробуется, только если предыдущий не отдал полный каталог.
    2. match_report.py   - сводит их с игровой базой
    3. build_game_map.py - собирает mm2_values.json для оверлея

ПОЧЕМУ ПРЯМОЙ ДОСТУП ОСНОВНОЙ. Imperva отсеивает не «ботов вообще», а
клиентов без настоящего браузерного отпечатка. Playwright запускает
настоящий Chrome, и сайт отдаёт ему полную страницу: обычный запрос получает
заглушку в 878 байт, Playwright - 608 002 символа. Все 13 категорий приходят
одной датой, тогда как архив держал три из них на снимке месячной давности.

ПОЧЕМУ ОСТАЛЬНЫЕ ОСТАЛИСЬ. Зеркала - на случай, если Playwright не поставлен
или сайт сменит защиту. Архив - последний рубеж, он не зависит ни от чего
чужого. Ни один из трёх не перезаписывает каталог, если тот вышел неполным:
предметы пропавших категорий получили бы цены однофамильцев.

Игровую базу (data/game_items.json) обновлять почти никогда не нужно - она
меняется только когда в MM2 добавляют предметы. Пересобрать её можно
скриптом overlay/dump_items.lua прямо из Madium.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PARSER = ROOT / "parser"


def run(script: Path, args: list[str] | None = None) -> int:
    cmd = [sys.executable, str(script)] + (args or [])
    return subprocess.run(cmd, cwd=ROOT).returncode


def say(*args) -> None:
    """
    Печать с немедленным сбросом буфера.

    Обычный print буферизуется поблочно, когда вывод уходит в файл или в лог
    сборки, а дочерние процессы пишут в тот же поток сразу. Из-за этого
    заголовки шагов оказывались НИЖЕ вывода самих шагов, и лог прогона
    читался задом наперёд.
    """
    print(*args, flush=True)


def main() -> int:
    if not (ROOT / "data" / "game_items.json").exists():
        say("ВНИМАНИЕ: нет data/game_items.json - шаг сведения упадёт.")
        say("Запусти overlay/dump_items.lua из Madium, находясь в MM2,")
        say("затем скопируй результат из Workspace в data/game_items.json.")
        say()

    say("=" * 64)
    say("ШАГ 1/3: цены Supreme Values")
    say("=" * 64)

    # Три источника по убыванию свежести. Каждый следующий пробуется, только
    # если предыдущий не отдал полный каталог; неполный никто не записывает.
    sources = [
        (PARSER / "sv_direct.py", "напрямую с сайта через Playwright"),
        (PARSER / "sv_mirror.py", "через публичные зеркала"),
        (PARSER / "sv_parser.py", "через архив Wayback"),
    ]

    code = 1
    for i, (script, label) in enumerate(sources):
        if i > 0:
            say()
            say(f"Предыдущий источник не сработал. Пробую {label}.")
            say()
        code = run(script)
        if code == 0:
            break

    if code != 0:
        say("\nНи один источник не отдал полный каталог.")
        say("Прежние цены не тронуты - лучше устаревшие, чем неполные.")
        return code

    for i, (title, script) in enumerate(
        [("Сведение с игровой базой", PARSER / "match_report.py"),
         ("Сборка артефакта для игры", PARSER / "build_game_map.py")], start=2):
        say()
        say("=" * 64)
        say(f"ШАГ {i}/3: {title}")
        say("=" * 64)
        code = run(script)
        if code != 0:
            say(f"\nШаг {i} завершился с кодом {code}. Останавливаюсь.")
            return code

    say("\nГотово. mm2_values.json обновлён.")
    say("Если настроено GitHub-зеркало - не забудь запушить data/mm2_values.json.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
