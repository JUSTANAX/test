"""
Обновление цен одной командой:

    python update.py

Порядок такой:
    1. sv_mirror.py      - цены Supreme Values через зеркала (быстро, свежо)
       при неудаче
       sv_parser.py      - тот же Supreme Values, но через Wayback (медленно)
    2. match_report.py   - сводит их с игровой базой
    3. build_game_map.py - собирает mm2_values.json для оверлея

ПОЧЕМУ ЗЕРКАЛА ОСНОВНЫЕ. Прямой доступ к сайту закрыт Imperva, а архив
заходит на страницы нерегулярно: 714 предметов из 1204 стояли на снимке
месячной давности, и Dungeon показывался за 300 вместо настоящих 175.
Зеркала - те же данные того же сайта, снятые настоящим браузером; проверено
сверкой: где наш архивный снимок свежий, значения совпадают до последней
цифры, и расходятся только там, где мы отстали.

ПОЧЕМУ АРХИВ ОСТАЛСЯ. Зеркала - чужие репозитории. Если автор их забросит,
мы это увидим по дате, и Wayback подхватит работу. Плюс архив закрывает
uniques, где у зеркал вместо предметов лежат ники владельцев.

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


def main() -> int:
    if not (ROOT / "data" / "game_items.json").exists():
        print("ВНИМАНИЕ: нет data/game_items.json - шаг сведения упадёт.")
        print("Запусти overlay/dump_items.lua из Madium, находясь в MM2,")
        print("затем скопируй результат из Workspace в data/game_items.json.")
        print()

    print("=" * 64)
    print("ШАГ 1/3: цены Supreme Values")
    print("=" * 64)
    code = run(PARSER / "sv_mirror.py")
    if code != 0:
        print()
        print("Зеркала не отдали данные. Пробую через архив - это дольше,")
        print("и цены будут менее свежими, но лучше, чем ничего.")
        print()
        code = run(PARSER / "sv_parser.py")
        if code != 0:
            print("\nОба источника недоступны. Прежний каталог не тронут.")
            return code

    for i, (title, script) in enumerate(
        [("Сведение с игровой базой", PARSER / "match_report.py"),
         ("Сборка артефакта для игры", PARSER / "build_game_map.py")], start=2):
        print()
        print("=" * 64)
        print(f"ШАГ {i}/3: {title}")
        print("=" * 64)
        code = run(script)
        if code != 0:
            print(f"\nШаг {i} завершился с кодом {code}. Останавливаюсь.")
            return code

    print("\nГотово. mm2_values.json обновлён.")
    print("Если настроено GitHub-зеркало - не забудь запушить data/mm2_values.json.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
