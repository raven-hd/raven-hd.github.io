# Поднимает номера версий ?v=N у файлов сайта, чтобы браузеры игроков загрузили свежие файлы,
# а не взяли старые из кэша. Запускать после правок в src/, styles.css или boot.js, перед отправкой на GitHub.
#
#   python3 scripts/bump_version.py            # поднять всё: модули (src/*.js), styles.css и boot.js
#   python3 scripts/bump_version.py modules    # только модули
#   python3 scripts/bump_version.py css        # только styles.css
#   python3 scripts/bump_version.py boot       # только boot.js
#
# Версия модулей одна на все: и в index.html (main.js?v=N), и в каждом import внутри src/.
# Если хоть один импорт останется со старым номером, браузер загрузит модуль дважды —
# поэтому эту версию меняем только скриптом. Картинки (?v= в адресах .png) скрипт не трогает.
import glob
import re
import sys

parts = set(sys.argv[1:]) or {"modules", "css", "boot"}
unknown = parts - {"modules", "css", "boot"}
if unknown:
    print("неизвестный параметр:", ", ".join(sorted(unknown)), "— можно: modules, css, boot")
    sys.exit(2)

INDEX = "index.html"
html = open(INDEX, encoding="utf-8").read()
changed_files = set()


def bump_html(pattern, label):
    """Поднимает версию у одного файла, подключённого в index.html."""
    global html
    m = re.search(pattern, html)
    if not m:
        print(f"в {INDEX} не найден {label}")
        sys.exit(1)
    old = int(m.group("v"))
    html = html[:m.start("v")] + str(old + 1) + html[m.end("v"):]
    changed_files.add(INDEX)
    print(f"{label}: {old} → {old + 1}")


if "css" in parts:
    bump_html(r'href="\./styles\.css\?v=(?P<v>\d+)"', "styles.css")
if "boot" in parts:
    bump_html(r'src="\./boot\.js\?v=(?P<v>\d+)"', "boot.js")

if "modules" in parts:
    entry = re.search(r'src="\./src/main\.js\?v=(?P<v>\d+)"', html)
    if not entry:
        print(f"в {INDEX} не найден ./src/main.js?v=N")
        sys.exit(1)
    # новая версия — больше любой, что сейчас встречается (на случай, если где-то уже разъехались)
    import_re = re.compile(r'(?P<pre>(?:\bfrom\s*|\bimport\s*\(?\s*)["\']\.{1,2}/[^"\'?]+\?v=)(?P<v>\d+)(?P<post>["\'])')
    sources = {path: open(path, encoding="utf-8").read() for path in sorted(glob.glob("src/*.js"))}
    seen = [int(entry.group("v"))] + [int(m.group("v")) for code in sources.values() for m in import_re.finditer(code)]
    new = max(seen) + 1
    html = html[:entry.start("v")] + str(new) + html[entry.end("v"):]
    changed_files.add(INDEX)
    total = 0
    for path, code in sources.items():
        updated, n = import_re.subn(lambda m: f"{m.group('pre')}{new}{m.group('post')}", code)
        if n:
            open(path, "w", encoding="utf-8").write(updated)
            changed_files.add(path)
            total += n
    print(f"модули: {min(seen)}{'' if min(seen) == max(seen) else '…' + str(max(seen))} → {new} (index.html и {total} импортов)")

open(INDEX, "w", encoding="utf-8").write(html)
print(f"изменено файлов: {len(changed_files)}. проверка: python3 scripts/check_modules.py")
