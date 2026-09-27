# Проверяет, что модули сайта (src/*.js) правильно связаны между собой.
# Запуск из корня репозитория: python3 scripts/check_modules.py
#
# Что проверяется:
#   1. каждый импорт указывает на существующий файл;
#   2. каждое импортированное имя действительно экспортируется из того файла;
#   3. у всех импортов и у main.js в index.html одна и та же версия ?v=N —
#      иначе браузер загрузит один модуль дважды, и у половины сайта будет своё,
#      отдельное состояние (очень странные ошибки);
#   4. каждый модуль подключён (до него можно дойти от main.js).
import glob
import os
import re
import sys

SRC = "src"
errors = []
warnings = []

IMPORT_RE = re.compile(
    r'^\s*import\s+(?:(?P<names>\{[^}]*\})|(?P<ns>\*\s+as\s+\w+)|(?P<default>\w+))?\s*(?:from\s*)?["\'](?P<spec>[^"\']+)["\']',
    re.M | re.S,
)
DYNAMIC_RE = re.compile(r'\bimport\(\s*["\'](?P<spec>[^"\']+)["\']\s*\)')
EXPORT_DECL_RE = re.compile(r'^\s*export\s+(?:async\s+)?(?:function\*?|const|let|var|class)\s+([A-Za-z_$][\w$]*)', re.M)
EXPORT_LIST_RE = re.compile(r'^\s*export\s*\{([^}]*)\}', re.M)
VERSION_RE = re.compile(r'^(?P<path>\.{1,2}/[^?]+)\?v=(?P<v>\d+)$')


def plural(n, one, few, many):
    if n % 10 == 1 and n % 100 != 11:
        return one
    if 2 <= n % 10 <= 4 and not 12 <= n % 100 <= 14:
        return few
    return many


def strip_comments(code):
    code = re.sub(r"/\*.*?\*/", "", code, flags=re.S)
    return re.sub(r"(^|[^:\\])//[^\n]*", r"\1", code)


def exports_of(path):
    code = strip_comments(open(path, encoding="utf-8").read())
    names = set(EXPORT_DECL_RE.findall(code))
    for block in EXPORT_LIST_RE.findall(code):
        for item in block.split(","):
            item = item.strip()
            if item:
                names.add(item.split(" as ")[-1].strip())
    return names


# точка входа из index.html
html = open("index.html", encoding="utf-8").read()
entry = re.search(r'<script\s+type="module"\s+src="\./src/main\.js\?v=(\d+)"', html)
if not entry:
    print('в index.html нет <script type="module" src="./src/main.js?v=N">')
    sys.exit(1)
entry_version = entry.group(1)

modules = sorted(glob.glob(os.path.join(SRC, "*.js")))
graph = {}
versions = {}
for path in modules:
    code = strip_comments(open(path, encoding="utf-8").read())
    name = os.path.basename(path)
    graph[name] = set()
    found = [(m.group("names"), m.group("spec")) for m in IMPORT_RE.finditer(code)]
    found += [(None, m.group("spec")) for m in DYNAMIC_RE.finditer(code)]
    for names, spec in found:
        m = VERSION_RE.match(spec)
        if not m:
            errors.append(f"{name}: импорт «{spec}» без версии ?v=N (или не относительный путь)")
            continue
        versions.setdefault(m.group("v"), []).append(f"{name} → {m.group('path')}")
        target = os.path.normpath(os.path.join(SRC, m.group("path")))
        if not os.path.exists(target):
            errors.append(f"{name}: файла {m.group('path')} нет")
            continue
        if os.path.dirname(target) != os.path.normpath(SRC):
            continue  # config.js и vendor/supabase.js проверяем только на существование
        graph[name].add(os.path.basename(target))
        if names:
            exported = exports_of(target)
            for item in names.strip("{} \n").split(","):
                item = item.strip()
                if not item:
                    continue
                imported = item.split(" as ")[0].strip()
                if imported not in exported:
                    errors.append(f"{name}: «{imported}» не экспортируется из {os.path.basename(target)}")

if "main.js" not in graph:
    errors.append("нет файла src/main.js")

# одна версия у всех импортов и у точки входа
all_versions = set(versions) | {entry_version}
if len(all_versions) > 1:
    errors.append(f"разные версии: в index.html main.js?v={entry_version}, в импортах — {', '.join(sorted(versions))}. "
                  "запустите python3 scripts/bump_version.py")
    for v, where in sorted(versions.items()):
        if v != entry_version:
            for w in where[:5]:
                errors.append(f"   ?v={v}: {w}")

# все модули достижимы от main.js
seen, stack = set(), ["main.js"]
while stack:
    cur = stack.pop()
    if cur in seen or cur not in graph:
        continue
    seen.add(cur)
    stack.extend(graph[cur])
for name in graph:
    if name not in seen:
        warnings.append(f"{name} нигде не импортируется — модуль не работает на сайте")

for w in warnings:
    print("предупреждение:", w)
if errors:
    for e in errors:
        print("ошибка:", e)
    sys.exit(1)
print(f"ок: {len(graph)} {plural(len(graph), 'модуль', 'модуля', 'модулей')}, все импорты на месте, версия ?v={entry_version} везде одна")
