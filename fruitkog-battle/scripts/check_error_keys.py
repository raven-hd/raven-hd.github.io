# Проверяет, что у каждой ошибки, которую выбрасывает сервер (raise exception '...'),
# есть русский перевод в humanError() из src/errors.js. Иначе игрок увидит английский текст.
# Запуск из корня репозитория: python3 scripts/check_error_keys.py
import glob
import re
import sys

# Ключи, которые игрок не видит, или которые остались только в старых версиях функций.
IGNORE = {
    "Invalid login attempt key",   # внутренняя ошибка Edge Function входа по нику (сайт её не вызывает)
    "Fleet already locked",        # осталась только в старых версиях ready_with_fleet
}

js = open("src/errors.js", encoding="utf-8").read()
block = js[js.index("function humanError"):]
known = re.findall(r'\["([^"]+)",\s*"', block)

missing = set()
for path in glob.glob("supabase/**/*.sql", recursive=True):
    if "/tests/" in path.replace("\\", "/"):
        continue
    text = open(path, encoding="utf-8").read()
    for key in re.findall(r"raise exception\s+'([^']+)'", text):
        if key not in IGNORE and not any(k in key for k in known):
            missing.add(key)

if missing:
    for key in sorted(missing):
        print("нет перевода в humanError():", key)
    sys.exit(1)
n = len(known)
word = "перевод" if n % 10 == 1 and n % 100 != 11 else "перевода" if 2 <= n % 10 <= 4 and not 12 <= n % 100 <= 14 else "переводов"
print(f"ок: у всех ошибок сервера есть перевод ({n} {word})")
