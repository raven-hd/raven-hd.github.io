// Мелкие общие помощники: поиск элементов, привязка событий, сообщения, форматирование дат.

export const $ = id => document.getElementById(id);

export const $$ = selector => [...document.querySelectorAll(selector)];

// Привязка обработчика по id. Если элемента нет (кнопку удалили или переименовали в index.html),
// пишет предупреждение в консоль вместо того, чтобы уронить запуск всего приложения.
export function bind(id, event, handler) {
  const node = document.getElementById(id);
  if (!node) {
    console.warn(`[wire] нет элемента #${id} — обработчик ${event} не привязан`);
    return;
  }
  node.addEventListener(event, handler);
}

export function msg(el, text="", type="") {
  el.textContent = text;
  el.classList.add("message");
  el.classList.remove("error","success");
  if (type) el.classList.add(type);
}

export function wait(ms) {
  return new Promise(resolve => setTimeout(resolve,ms));
}

// Пробелы любого вида и переносы строк — один обычный пробел (как и раньше).
const SPACES = /[\s\u0085]+/g;
// Управляющие символы (кроме пробелов и переносов, их уже заменили) — убираем из любого текста.
const CONTROL_CHARS = /[\u0000-\u001F\u007F-\u009F]/g;
// Невидимые и служебные символы (нулевой ширины, смена направления текста, «пустой» символ
// Брайля, теги и т.п.): с ними можно сделать ник, неотличимый от чужого. Сервер такие ники
// отклоняет (миграция 038), сайт вычищает их из ника заранее. Сюда входят и соединитель
// эмодзи с селекторами вариантов, поэтому составные эмодзи в нике распадаются на простые.
const HIDDEN_CHARS = /[\u0000-\u001F\u007F-\u009F\u00AD\u034F\u061C\u115F\u1160\u17B4\u17B5\u180B-\u180F\u200B-\u200F\u2028-\u202E\u2060-\u206F\u2800\u3164\uFE00-\uFE0F\uFEFF\uFFA0\uFFF9-\uFFFB\u{1BCA0}-\u{1BCA3}\u{1D173}-\u{1D17A}\u{E0000}-\u{E007F}\u{E0100}-\u{E01EF}]/gu;

function tidy(value, max) {
  return value.replace(/ {2,}/g, " ").trim().slice(0, max).trim();
}

// Текст из поля ввода (объявление, название турнира): пробелы и переносы — один пробел,
// управляющие символы убраны, эмодзи остаются как есть.
export function cleanText(value, max) {
  return tidy(value.replace(SPACES, " ").replace(CONTROL_CHARS, ""), max);
}

// Ник: то же самое плюс без невидимых и служебных символов.
export function cleanName(value, max=48) {
  return tidy(value.replace(SPACES, " ").replace(HIDDEN_CHARS, ""), max);
}

// localStorage бывает недоступен (запрет cookie и данных сайтов, некоторые встроенные
// браузеры соцсетей) или переполнен. Тогда черновики и ключи запросов живут в памяти
// до перезагрузки страницы, а игра продолжает работать.
const memoryStorage = new Map();
export const safeStorage = {
  get(key) {
    // копия в памяти есть, только если сохранить в localStorage не удалось, — она свежее
    if (memoryStorage.has(key)) return memoryStorage.get(key);
    try { return localStorage.getItem(key); } catch { return null; }
  },
  set(key, value) {
    try { localStorage.setItem(key, value); memoryStorage.delete(key); }
    catch { memoryStorage.set(key, String(value)); }   // запрещено или переполнено
  },
  remove(key) {
    try { localStorage.removeItem(key); } catch { /* недоступно — чистим только память */ }
    memoryStorage.delete(key);
  },
};

// id для защиты от двойной отправки. crypto.randomUUID нет в старых браузерах (iOS до 15.4).
export function newRequestId() {
  if (typeof crypto.randomUUID === "function") return crypto.randomUUID();
  const b = crypto.getRandomValues(new Uint8Array(16));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = [...b].map(x => x.toString(16).padStart(2, "0")).join("");
  return `${h.slice(0,8)}-${h.slice(8,12)}-${h.slice(12,16)}-${h.slice(16,20)}-${h.slice(20)}`;
}

export function formatAdminDate(value){
  if(!value)return "—";
  return new Intl.DateTimeFormat("ru-RU",{
    day:"2-digit",month:"2-digit",year:"numeric",hour:"2-digit",minute:"2-digit"
  }).format(new Date(value));
}
