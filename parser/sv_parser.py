"""
Парсер ценностей Murder Mystery 2 с supremevalues.com.

Прямой доступ к сайту закрыт Imperva/Incapsula (WAF отдаёт HTTP 200 и заглушку
на 210-850 байт), поэтому страницы читаются через Wayback Machine в режиме
id_ - он отдаёт исходные байты origin-сервера без обвязки архива.

Четыре места, где наивная реализация ломается молча:
  1. Половина снимков в архиве - те же WAF-заглушки. Отсекаются по размеру.
  2. id_ отдаёт gzip без заголовка Content-Encoding: requests не разожмёт.
  3. Регулярка по _svPopup спотыкается о "};" внутри строкового значения.
  4. HTTP 200 отдают и WAF, и пустая заглушка архива. Статус не показатель.

Выход: data/sv_values.json
"""

from __future__ import annotations

import gzip
import json
import os
import re
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import requests

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data"
OUT_FILE = DATA_DIR / "sv_values.json"

CDX_URL = "http://web.archive.org/cdx/search/cdx"
WB_REPLAY = "https://web.archive.org/web/{ts}id_/https://supremevalues.com/mm2/{cat}"

# 13 категорий с ценностями. untradables и trading намеренно исключены:
# у первой нет значений, вторая - список серверов, а не предметов.
CATEGORIES = [
    "sets", "uniques", "ancients", "vintages", "chromas", "godlies",
    "legendaries", "rares", "uncommons", "commons", "pets", "misc", "evos",
]

# У этих двух категорий блока _svPopup нет вообще - только рендер-сетка.
HTML_ONLY = {"evos", "untradables"}

# WAF-заглушки в архиве весят 834-1192 байта (сжатый WARC). Живые страницы
# зависят от размера категории: godlies ~25-28 КБ, но evos/misc/vintages
# законно весят 6-10 КБ. Порог в 15 КБ (как подсказывал первый замер по
# godlies) отбрасывал целые здоровые категории, поэтому берём 3 КБ - это
# втрое выше заглушки и вдвое ниже самой мелкой живой страницы (6256 байт).
MIN_CAPTURE_BYTES = 3_000

# Меньше этого числа предметов в категории - считаем разбор провалившимся,
# а не "категория маленькая". Самая маленькая реальная категория - десятки.
MIN_ITEMS_PER_CATEGORY = 3

REQUEST_TIMEOUT = 90
RETRY_COUNT = 3
RETRY_SLEEP = 5.0
POLITE_DELAY = 1.5

# --- Свежий снимок по требованию ------------------------------------------
#
# Ключевая находка: краулер Internet Archive НЕ блокируется Imperva - он
# получает настоящую страницу, а не заглушку. И его можно позвать вручную.
#
# Без этого мы заложники расписания краулера: /mm2/commons стоял на снимке от
# 24 июля, и треть цен в нём успела устареть (Mummified 15 -> 35). После
# запроса на сохранение та же страница приехала с датой сайта 23 августа.
#
# Один запрос отрабатывает ~30 секунд, поэтому 13 категорий занимают минут
# семь. Для ежедневного прогона это приемлемо, а свежесть становится
# управляемой вместо случайной.
SAVE_URL = "https://web.archive.org/save/https://supremevalues.com/mm2/{cat}"
SAVE_TIMEOUT = 200

# Первый прогон показал, почему нельзя обновлять всё сразу: 13 запросов подряд
# дали 11 отказов HTTP 503, а следом архив зарезал и чтение - обход потерял 9
# категорий из 13. Поэтому за прогон трогаем несколько самых застоявшихся, с
# длинными паузами. При ежедневном запуске весь каталог обновляется за неделю,
# и архив не считает нас злоупотребляющими.
SAVE_BATCH = 4          # сколько категорий обновляем за один прогон
SAVE_DELAY = 45.0       # пауза между запросами на сохранение
SAVE_SETTLE = 30.0      # сколько ждать, пока CDX увидит новые снимки

# Ограничение частоты - это не отказ, а просьба подождать. Пауза здесь на
# порядок длиннее обычной: короткие повторы 5 и 10 секунд её не пересиживали.
RATE_LIMIT_CODES = {429, 503}
RATE_LIMIT_SLEEP = 60.0
RATE_LIMIT_RETRIES = 4

USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)


class ParseFailure(Exception):
    """Разбор провалился так, что молчать нельзя."""


@dataclass
class CategoryResult:
    category: str
    items: dict[str, dict[str, Any]] = field(default_factory=dict)
    snapshot_ts: str | None = None
    source_updated_iso: str | None = None
    method: str = ""
    error: str | None = None

    @property
    def ok(self) -> bool:
        return self.error is None and len(self.items) >= MIN_ITEMS_PER_CATEGORY


# --------------------------------------------------------------------------
# Сеть
# --------------------------------------------------------------------------

def make_session() -> requests.Session:
    s = requests.Session()
    s.headers.update({
        "User-Agent": USER_AGENT,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
        # Просим gzip явно, но разжимать будем сами - см. decode_body.
        "Accept-Encoding": "gzip, deflate",
    })
    return s


def fetch_raw(session: requests.Session, url: str) -> bytes:
    """GET с повторами. Возвращает сырые байты без попытки декодирования."""
    # Две разные неудачи требуют разного поведения:
    #   ограничение частоты - подождать долго, страница никуда не делась;
    #   всё остальное       - короткий повтор, дальше сдаёмся.
    last_err = "неизвестно"
    short_tries = 0
    long_tries = 0

    while True:
        try:
            r = session.get(url, timeout=REQUEST_TIMEOUT, stream=False)
        except Exception as exc:  # noqa: BLE001 - сеть, ретраим что угодно
            last_err = f"{type(exc).__name__}: {exc}"
            short_tries += 1
            if short_tries >= RETRY_COUNT:
                break
            time.sleep(RETRY_SLEEP * short_tries)
            continue

        if r.status_code == 200:
            return r.content

        if r.status_code in RATE_LIMIT_CODES:
            last_err = f"HTTP {r.status_code} (архив ограничивает частоту)"
            long_tries += 1
            if long_tries > RATE_LIMIT_RETRIES:
                break
            wait = RATE_LIMIT_SLEEP * long_tries
            print(f"\n      пауза {wait:.0f} сек по просьбе архива ... ", end="", flush=True)
            time.sleep(wait)
            continue

        # Настоящая ошибка вроде 404: повторять бессмысленно.
        last_err = f"HTTP {r.status_code}"
        break

    raise ParseFailure(f"не удалось скачать {url}: {last_err}")


def decode_body(raw: bytes) -> str:
    """
    id_-реплей отдаёт байты origin-сервера как есть, включая gzip, но без
    заголовка Content-Encoding. requests в таком случае не разжимает, и
    наивный парсер начинает читать бинарный мусор. Определяем по сигнатуре.
    """
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    return raw.decode("utf-8", errors="replace")


# --------------------------------------------------------------------------
# Выбор снимка
# --------------------------------------------------------------------------

def pick_snapshot(session: requests.Session, category: str) -> str:
    """
    Возвращает timestamp свежайшего снимка, который НЕ является WAF-заглушкой.
    Поле length в CDX - размер сжатой WARC-записи, не страницы.
    """
    params = {
        "url": f"supremevalues.com/mm2/{category}",
        "output": "json",
        "filter": "statuscode:200",
        "fl": "timestamp,length",
        "collapse": "digest",
        "limit": "-40",  # минус = с конца, то есть свежайшие
    }
    # CDX регулярно отдаёт 503/504 под нагрузкой - это временно, а не отказ.
    rows = None
    last_problem = None
    for attempt in range(1, RETRY_COUNT + 1):
        # Сам запрос тоже под try: обрыв связи или таймаут - такое же временное
        # явление, как 503. Без этого первый же ConnectionError вылетал наружу
        # мимо оставшихся попыток и терял категорию целиком.
        try:
            r = session.get(CDX_URL, params=params, timeout=REQUEST_TIMEOUT)
        except requests.RequestException as exc:
            last_problem = f"сеть: {type(exc).__name__}"
        else:
            last_problem = f"HTTP {r.status_code}"
            if r.status_code == 200:
                try:
                    rows = r.json()
                    break
                except json.JSONDecodeError as exc:
                    raise ParseFailure(f"CDX отдал не-JSON: {exc}") from exc
        if attempt < RETRY_COUNT:
            time.sleep(RETRY_SLEEP * attempt * 2)

    if rows is None:
        raise ParseFailure(f"CDX недоступен после {RETRY_COUNT} попыток ({last_problem})")

    if not rows or len(rows) < 2:
        raise ParseFailure("CDX не нашёл ни одного снимка")

    header, *data = rows
    ts_i, len_i = header.index("timestamp"), header.index("length")

    good: list[tuple[str, int]] = []
    for row in data:
        try:
            size = int(row[len_i])
        except (ValueError, IndexError):
            continue
        if size >= MIN_CAPTURE_BYTES:
            good.append((row[ts_i], size))

    if not good:
        sizes = sorted({int(r[len_i]) for r in data if str(r[len_i]).isdigit()})
        raise ParseFailure(
            f"все {len(data)} снимков меньше {MIN_CAPTURE_BYTES} байт "
            f"(размеры: {sizes[:10]}) - похоже, архив содержит только WAF-заглушки"
        )

    good.sort(key=lambda x: x[0], reverse=True)
    return good[0][0]


# --------------------------------------------------------------------------
# Извлечение данных
# --------------------------------------------------------------------------

def extract_balanced_object(text: str, start: int) -> str:
    """
    Возвращает сбалансированный {...} начиная с позиции start.

    Регулярка тут не годится: значения содержат "};" внутри строк, из-за чего
    нежадный шаблон обрывает объект на первом же таком вхождении. На
    /mm2/uniques это давало 1 предмет вместо 105.
    """
    if text[start] != "{":
        raise ParseFailure(f"ожидалась {{ на позиции {start}, найдено {text[start]!r}")

    depth = 0
    in_string = False
    escaped = False

    for i in range(start, len(text)):
        ch = text[i]
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]

    raise ParseFailure("объект не закрыт до конца документа")


def parse_sv_popup(html: str) -> dict[str, dict[str, Any]]:
    """Достаёт var _svPopup = {...} из инлайн-скрипта."""
    marker = re.search(r"var\s+_svPopup\s*=\s*", html)
    if not marker:
        raise ParseFailure("блок _svPopup не найден")

    brace = html.find("{", marker.end())
    if brace == -1:
        raise ParseFailure("после _svPopup нет открывающей скобки")

    blob = extract_balanced_object(html, brace)
    try:
        data = json.loads(blob)
    except json.JSONDecodeError as exc:
        raise ParseFailure(
            f"_svPopup извлечён ({len(blob)} байт), но это не валидный JSON: {exc}"
        ) from exc

    if not isinstance(data, dict):
        raise ParseFailure(f"_svPopup оказался {type(data).__name__}, ожидался объект")
    return data


# Атрибуты на страницах встречаются и в двойных, и в одинарных кавычках
# (data-name='Corrupt'), поэтому шаблон покрывает оба варианта.
ATTR_RE = re.compile(r"""([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')""")
COLUMN_OPEN_RE = re.compile(r'<div\b[^>]*\bclass="[^"]*\bitemcolumn\b[^"]*"[^>]*>', re.I)
ITEMHEAD_RE = re.compile(r'<div[^>]*class="[^"]*\bitemhead\b[^"]*"[^>]*>(.*?)</div>', re.I | re.S)
ITEMVALUE_RE = re.compile(r'<b[^>]*class="[^"]*\bitemvalue\b[^"]*"[^>]*>(.*?)</b>', re.I | re.S)
ITEMRANGE_RE = re.compile(r'<b[^>]*class="[^"]*\bitemrange\b[^"]*"[^>]*>(.*?)</b>', re.I | re.S)
ITEMORIGIN_RE = re.compile(r'<span[^>]*class="[^"]*\bitemorigin\b[^"]*"[^>]*>(.*?)</span>', re.I | re.S)
LABELLED_B_RE = re.compile(r'(\w[\w ]*?)\s*-\s*<b[^>]*>(.*?)</b>', re.I | re.S)
TAG_RE = re.compile(r"<[^>]+>")


def _text(fragment: str) -> str:
    """Снимает теги и html-сущности, схлопывает пробелы."""
    import html as html_mod
    return " ".join(html_mod.unescape(TAG_RE.sub(" ", fragment)).split())


def parse_html_grid(html: str) -> dict[str, dict[str, Any]]:
    """
    Разбор рендер-сетки для категорий, где _svPopup отсутствует или неполон.

    Реальная разметка (проверено на /mm2/uniques и /mm2/evos):
      <div class="itemcolumn" data-value="470" data-demand="4" data-rarity="3" ...>
        <div class="itemcell" id="Corrupt">
          <div class="itemhead">Corrupt</div>
          <div class="itembody">
            Value - <b class="itemvalue val-top">470</b>
            Range - <b class="itemrange">[N/A]</b>
            Stability - <b class="itemstability stable">Stable</b>
            Demand - <b>4</b> Rarity - <b>3</b>
            <span class="itemorigin">...</span>

    У evos денежных полей нет вовсе - там Class / Rarity / EXP Requirement,
    поэтому value остаётся None, а не подставляется нулём.
    """
    starts = [m.start() for m in COLUMN_OPEN_RE.finditer(html)]
    if not starts:
        raise ParseFailure("в разметке не найдено ни одного div.itemcolumn")

    bounds = list(zip(starts, starts[1:] + [len(html)]))
    out: dict[str, dict[str, Any]] = {}

    for start, end in bounds:
        block = html[start:end]

        head = ITEMHEAD_RE.search(block)
        name = _text(head.group(1)) if head else ""
        if not name:
            # Запасной путь: имя дублируется в data-name кнопки.
            attrs_all = {k: (v1 or v2) for k, v1, v2 in ATTR_RE.findall(block)}
            name = _text(attrs_all.get("data-name", ""))
        if not name:
            continue

        open_tag = COLUMN_OPEN_RE.match(html, start)
        attrs = {k: (v1 or v2) for k, v1, v2 in ATTR_RE.findall(open_tag.group(0))} if open_tag else {}

        value_m = ITEMVALUE_RE.search(block)
        value_text = attrs.get("data-value") or (_text(value_m.group(1)) if value_m else "")

        range_m = ITEMRANGE_RE.search(block)
        origin_m = ITEMORIGIN_RE.search(block)

        # Demand/Rarity/Class подписаны текстом перед <b>, а не атрибутами.
        labelled = {_text(k).lower(): _text(v) for k, v in LABELLED_B_RE.findall(block)}

        out[name] = {
            "value": value_text,
            "rawValue": None,
            "range": (_text(range_m.group(1)) if range_m else attrs.get("data-range", "")),
            "demand": attrs.get("data-demand") or labelled.get("demand", ""),
            "rarity": attrs.get("data-rarity") or labelled.get("rarity", ""),
            "stability": attrs.get("data-stability") or labelled.get("stability", ""),
            "origin": (_text(origin_m.group(1)) if origin_m else ""),
            "pctChange": attrs.get("data-changepct", ""),
            "class": labelled.get("class", ""),
        }

    if not out:
        raise ParseFailure("div.itemcolumn найдены, но ни у одного нет имени")
    return out


UPDATED_RE = re.compile(r'data-updated-iso\s*=\s*"([^"]+)"')


def parse_updated_iso(html: str) -> str | None:
    m = UPDATED_RE.search(html)
    return m.group(1) if m else None


# --------------------------------------------------------------------------
# Нормализация
# --------------------------------------------------------------------------

NO_VALUE_TOKENS = {"", "[n/a]", "n/a", "-", "coming soon!", "coming soon"}


def to_number(raw_value: Any, value_str: Any) -> float | None:
    """
    rawValue - целое, но есть не у всех записей. value - строка с запятыми
    ("2,600"). None означает "числа нет": такой предмет не идёт в сумму.
    """
    if isinstance(raw_value, (int, float)):
        return float(raw_value)
    if isinstance(value_str, str):
        cleaned = value_str.replace(",", "").replace(" ", "").strip()
        if cleaned.lower() not in NO_VALUE_TOKENS:
            try:
                return float(cleaned)
            except ValueError:
                pass
    return None


def classify_value(value: float | None, value_str: Any) -> str:
    """
    Почему у предмета нет числовой цены. Оверлею нужно различать эти случаи:
    бартерную цену осмысленно показать текстом, а "нет данных" - нет.

      number      - обычная числовая ценность
      barter      - цена выражена в других предметах ("x4 T1 Legendaries")
      coming-soon - сайт ещё не оценил предмет
      none        - ценности нет (Default Knife, Default Gun)
    """
    if value is not None:
        return "number"
    text = str(value_str or "").strip()
    if not text:
        return "none"
    if text.lower().startswith("coming soon"):
        return "coming-soon"
    if text.lower() in NO_VALUE_TOKENS:
        return "none"
    return "barter"


def normalize_item(name: str, src: dict[str, Any], category: str) -> dict[str, Any]:
    value = to_number(src.get("rawValue"), src.get("value"))
    return {
        "name": name,
        "category": category,
        "value": value,
        "valueKind": classify_value(value, src.get("value")),
        "valueText": src.get("value") or "",
        "range": src.get("range") or "",
        "demand": src.get("demand") or "",
        "rarity": src.get("rarity") or "",
        "stability": src.get("stability") or "",
        "diff": src.get("diff") or "",
        "pctChange": src.get("pctChange") or "",
        "origin": src.get("origin") or "",
        "aliases": [a.strip() for a in str(src.get("aliases") or "").split(",") if a.strip()],
        "flippability": src.get("flippability") or "",
        "riseChance": src.get("riseChance") or "",
        # У evos денег нет, но есть игровой класс (Ancient/Godly/...).
        "class": src.get("class") or "",
    }


# --------------------------------------------------------------------------
# Обработка категории
# --------------------------------------------------------------------------

def request_save(session: requests.Session, category: str) -> tuple[bool, str]:
    """
    Просит архив зайти на страницу прямо сейчас.

    Возвращает (получилось, пояснение). Неудача не критична: обход дальше
    возьмёт самый свежий из уже существующих снимков, просто он будет старее.
    """
    url = SAVE_URL.format(cat=category)
    try:
        r = session.get(url, timeout=SAVE_TIMEOUT, allow_redirects=True)
    except requests.RequestException as exc:
        return False, f"сеть: {type(exc).__name__}"

    if r.status_code == 429:
        return False, "архив ограничил частоту (429)"
    if r.status_code != 200:
        return False, f"HTTP {r.status_code}"

    # Метка нового снимка приезжает в адресе после переадресации.
    m = re.search(r"/web/(\d{14})/", r.url)
    if m:
        ts = m.group(1)
        return True, f"снимок {ts[:4]}-{ts[4:6]}-{ts[6:8]}"
    return True, "сохранено, метку не разобрал"


def pick_stalest(limit: int) -> list[str]:
    """
    Категории с самыми старыми ценами - их и обновляем в этот прогон.

    Возраст берём из прошлого sv_values.json. Если его нет (первый запуск),
    порядок неважен: свежих данных всё равно ни у кого нет.
    """
    ages: dict[str, str] = {}
    try:
        prev = json.loads(OUT_FILE.read_text(encoding="utf-8"))
        for name, info in (prev.get("categories") or {}).items():
            ages[name] = (info or {}).get("sourceUpdatedIso") or ""
    except (OSError, json.JSONDecodeError):
        pass

    # Категория без даты считается самой старой: про неё мы ничего не знаем.
    return sorted(CATEGORIES, key=lambda c: ages.get(c) or "")[:limit]


def refresh_snapshots(session: requests.Session, targets: list[str]) -> dict[str, str]:
    """Просит архив забрать свежие страницы по указанным категориям."""
    report: dict[str, str] = {}
    print("=" * 62)
    print(f"Прошу архив обновить {len(targets)} категории из {len(CATEGORIES)}:")
    print("  " + ", ".join(targets))
    print("Остальные подождут следующего прогона - архив не любит частых просьб.")
    print("=" * 62)

    for i, cat in enumerate(targets, 1):
        print(f"[{i}/{len(targets)}] {cat} ... ", end="", flush=True)
        ok, note = request_save(session, cat)
        report[cat] = note
        print(("OK   " if ok else "мимо ") + note)
        if i < len(targets):
            time.sleep(SAVE_DELAY)

    print()
    print(f"Жду {SAVE_SETTLE:.0f} сек, пока индекс архива увидит новые снимки...")
    time.sleep(SAVE_SETTLE)
    print()
    return report


def process_category(session: requests.Session, category: str) -> CategoryResult:
    res = CategoryResult(category=category)
    try:
        ts = pick_snapshot(session, category)
        res.snapshot_ts = ts

        html = decode_body(fetch_raw(session, WB_REPLAY.format(ts=ts, cat=category)))
        res.source_updated_iso = parse_updated_iso(html)

        # Заглушка WAF после распаковки - это сотни байт, а не десятки тысяч.
        # Основная проверка всё равно по числу разобранных предметов ниже.
        if len(html) < 5_000:
            raise ParseFailure(
                f"страница подозрительно мала ({len(html)} символов) - "
                "вероятно, это WAF-заглушка, а не контент"
            )

        # Разбираем оба источника и сливаем. Ни один по отдельности не полон:
        # на /mm2/uniques в _svPopup лежит 1 предмет, а в сетке - 105;
        # у /mm2/evos блока _svPopup нет вовсе. При этом там, где _svPopup
        # есть, он богаче полями, поэтому перекрывает сетку.
        grid: dict[str, dict[str, Any]] = {}
        popup: dict[str, dict[str, Any]] = {}
        grid_err = popup_err = None

        try:
            grid = parse_html_grid(html)
        except ParseFailure as exc:
            grid_err = str(exc)

        try:
            popup = parse_sv_popup(html)
        except ParseFailure as exc:
            popup_err = str(exc)

        if not grid and not popup:
            raise ParseFailure(f"сетка: {grid_err}; _svPopup: {popup_err}")

        raw_items = dict(grid)
        raw_items.update(popup)

        parts = []
        if popup:
            parts.append(f"svPopup:{len(popup)}")
        if grid:
            parts.append(f"сетка:{len(grid)}")
        res.method = " + ".join(parts)

        res.items = {
            name: normalize_item(name, src, category)
            for name, src in raw_items.items()
            if isinstance(src, dict)
        }

        if len(res.items) < MIN_ITEMS_PER_CATEGORY:
            raise ParseFailure(
                f"разобрано всего {len(res.items)} предметов - разбор считается неудачным"
            )

    except ParseFailure as exc:
        res.error = str(exc)
    except Exception as exc:  # noqa: BLE001
        res.error = f"{type(exc).__name__}: {exc}"

    return res


def main() -> int:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    session = make_session()

    # По умолчанию сначала просим архив обновиться. Флаг --no-save нужен для
    # быстрых повторных прогонов, когда свежесть не важна: обход без него
    # занимает на семь минут меньше.
    save_report: dict[str, str] = {}
    if "--no-save" not in sys.argv:
        batch = SAVE_BATCH
        for arg in sys.argv[1:]:
            if arg.startswith("--save="):
                batch = max(0, int(arg.split("=", 1)[1]))
        if batch > 0:
            save_report = refresh_snapshots(session, pick_stalest(batch))
    else:
        print("--no-save: беру то, что уже лежит в архиве\n")

    results: list[CategoryResult] = []
    for i, cat in enumerate(CATEGORIES, 1):
        print(f"[{i}/{len(CATEGORIES)}] {cat} ... ", end="", flush=True)
        res = process_category(session, cat)
        results.append(res)
        if res.ok:
            print(f"OK  {len(res.items):>4} предметов  "
                  f"снимок {res.snapshot_ts}  метод {res.method}")
        else:
            print(f"СБОЙ  {res.error}")
        time.sleep(POLITE_DELAY)

    ok = [r for r in results if r.ok]
    failed = [r for r in results if not r.ok]

    catalog: dict[str, dict[str, Any]] = {}
    collisions = 0
    for r in ok:
        for name, item in r.items.items():
            # Ключ - пара (имя, категория): на сайте Batwing существует
            # и как ancient за 42, и как godly за 1 000 000.
            key = f"{r.category}|{name}"
            if key in catalog:
                collisions += 1
            catalog[key] = item

    payload = {
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        # Самая СТАРАЯ дата, а не первая попавшаяся: раньше сюда попадала дата
        # категории sets просто потому, что она идёт первой в списке, и файл
        # выглядел свежим, хотя большая часть каталога ехала со снимка месячной
        # давности.
        "sourceUpdatedIso": min(
            (r.source_updated_iso for r in ok if r.source_updated_iso),
            default=None,
        ),
        "categories": {
            r.category: {
                "count": len(r.items),
                "snapshot": r.snapshot_ts,
                "method": r.method,
                "sourceUpdatedIso": r.source_updated_iso,
            }
            for r in ok
        },
        "failedCategories": {r.category: r.error for r in failed},
        "itemCount": len(catalog),
        "items": catalog,
    }

    print("\n" + "=" * 62)
    print(f"Категорий разобрано : {len(ok)}/{len(CATEGORIES)}")
    print(f"Предметов всего     : {len(catalog)}")
    if collisions:
        print(f"Коллизий ключа      : {collisions}")

    # Неполный каталог НЕЛЬЗЯ класть поверх хорошего. Пропавшая категория не
    # оставляет дырку - она отправляет предметы в фолбэк по имени, и они
    # получают цену от однофамильца из другой категории. Прошлый файл с
    # чуть устаревшими, но правильными числами полезнее свежего с чужими.
    if failed:
        print(f"Сбойные категории   : {', '.join(r.category for r in failed)}")
        print()
        print("НЕ ЗАПИСАНО: каталог неполон.")
        print(f"Прежний {OUT_FILE.name} оставлен нетронутым.")
        print("Неполный каталог опаснее устаревшего: предметы пропавших")
        print("категорий получили бы цену однофамильцев из чужих категорий.")
        print("=" * 62)
        return 1

    # Запись через временный файл: прерывание на середине не оставит
    # наполовину записанный JSON, который следующий шаг примет за годный.
    tmp = OUT_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(tmp, OUT_FILE)

    print(f"Записано            : {OUT_FILE}")
    print("=" * 62)

    # Ненулевой код возврата, если не собралось ничего осмысленного.
    return 0 if len(ok) >= len(CATEGORIES) // 2 else 1


if __name__ == "__main__":
    sys.exit(main())
