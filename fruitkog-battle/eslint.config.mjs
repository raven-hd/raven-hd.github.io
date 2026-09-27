// Настройки линтера ESLint: он читает код сайта и находит ошибки до того, как их увидят игроки.
// Запуск из корня репозитория (нужен Node.js 20.19+ или 22.13+, ставить ничего не надо):
//   npx --yes eslint@10.11.0 .
// Этот же запуск делает GitHub при каждом изменении (.github/workflows/checks.yml).
// Правила перечислены явно, без внешних пакетов, чтобы не заводить package.json и node_modules.

// API браузера, которыми пользуется сайт. Если понадобится новое (например, fetch) — допишите сюда.
const browserGlobals = Object.fromEntries([
  "window", "document", "location", "history", "navigator", "console",
  "localStorage", "sessionStorage", "crypto", "performance",
  "setTimeout", "clearTimeout", "setInterval", "clearInterval",
  "requestAnimationFrame", "cancelAnimationFrame", "queueMicrotask", "structuredClone",
  "alert", "confirm", "prompt", "getComputedStyle", "matchMedia", "scrollTo",
  "URL", "URLSearchParams", "Intl", "fetch", "AbortController", "AbortSignal", "FormData", "Blob", "File", "FileReader",
  "TextEncoder", "TextDecoder", "Image", "Event", "CustomEvent", "KeyboardEvent", "MouseEvent", "PointerEvent",
  "Node", "Element", "HTMLElement", "HTMLInputElement", "HTMLButtonElement", "HTMLDialogElement",
  "ResizeObserver", "MutationObserver", "IntersectionObserver",
].map(name => [name, "readonly"]));

// Ошибки, которые ломают сайт или делают его уязвимым. Любая из них останавливает проверку.
const errors = {
  "no-undef": "error",              // имя не объявлено и не импортировано — в браузере будет ReferenceError
  "no-import-assign": "error",      // присваивание импортированному имени (в модулях так нельзя — общее состояние хранится в app)
  "no-const-assign": "error",
  "no-func-assign": "error",
  "no-redeclare": "error",
  "no-dupe-keys": "error",
  "no-duplicate-case": "error",
  "no-dupe-else-if": "error",
  "no-duplicate-imports": "error",
  "no-self-assign": "error",
  "no-unreachable": "error",
  "no-unsafe-finally": "error",
  "no-unsafe-negation": "error",
  "no-unsafe-optional-chaining": "error",
  "no-cond-assign": ["error", "except-parens"],
  "no-compare-neg-zero": "error",
  "no-ex-assign": "error",
  "no-invalid-regexp": "error",
  "no-loss-of-precision": "error",
  "no-obj-calls": "error",
  "no-setter-return": "error",
  "no-sparse-arrays": "error",
  "no-unexpected-multiline": "error",
  "getter-return": "error",
  "use-isnan": "error",
  "valid-typeof": "error",
  "no-global-assign": "error",
  "no-shadow-restricted-names": "error",
  // защита от XSS: текст игроков вставляется только через textContent и DOM-методы
  "no-eval": "error",
  "no-implied-eval": "error",
  "no-new-func": "error",
  "no-restricted-syntax": ["error",
    { selector: "AssignmentExpression[left.property.name='innerHTML'][right.value!='']",
      message: "innerHTML можно только очищать (= \"\"). Текст — через textContent, разметку — через createElement." },
    { selector: "AssignmentExpression[left.property.name='outerHTML']",
      message: "outerHTML опасен для текста игроков: используйте createElement и textContent." },
    { selector: "CallExpression[callee.property.name='insertAdjacentHTML']",
      message: "insertAdjacentHTML опасен для текста игроков: используйте createElement и textContent." },
    { selector: "CallExpression[callee.object.name='document'][callee.property.name=/^write(ln)?$/]",
      message: "document.write не используйте." },
  ],
};

// Не ломает сайт, но стоит убрать: лишний импорт или неиспользуемая переменная.
const warnings = {
  "no-unused-vars": ["warn", { args: "none", caughtErrors: "none" }],
};

export default [
  { ignores: ["vendor/**", "assets/**", "supabase/**", "node_modules/**", "dist/**"] },
  {
    files: ["src/**/*.js", "config.js"],
    languageOptions: { ecmaVersion: "latest", sourceType: "module", globals: browserGlobals },
    rules: { ...errors, ...warnings },
  },
  {
    files: ["boot.js"],   // обычный скрипт (не модуль): грузится раньше всего, чтобы не мигал раздел
    languageOptions: { ecmaVersion: "latest", sourceType: "script", globals: browserGlobals },
    rules: { ...errors, ...warnings },
  },
  {
    files: ["eslint.config.mjs"],
    languageOptions: { ecmaVersion: "latest", sourceType: "module" },
  },
];
