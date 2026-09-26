// Админ-панель: настройки баланса (K-фактор, турнирные очки, лимит пары).
import { app } from "./state.js?v=118";
import { configured } from "./constants.js?v=118";
import { $, formatAdminDate, msg } from "./helpers.js?v=118";
import { humanError } from "./errors.js?v=118";
import { loadPublicGameSettings } from "./settings.js?v=118";

export async function loadAdminGameSettings() {
  if (!app.profile?.is_admin || !configured) return;
  try {
    const { data, error } = await app.supabase.rpc("admin_get_game_settings");
    if (error) throw error;
    app.adminGameSettingsCache = Array.isArray(data) ? data : [];
    renderAdminGameSettings();
    const message = $("adminGameSettingsMessage");
    if (message?.classList.contains("error")) msg(message, "");
  } catch (error) {
    app.adminGameSettingsCache = [];
    renderAdminGameSettings();
    msg($("adminGameSettingsMessage"), humanError(error), "error");
  }
}

function renderAdminGameSettings() {
  const wrap = $("adminGameSettings");
  if (!wrap) return;
  // если список перерисовался в фоне, не теряем число, которое админ уже начал вводить
  const typing = {};
  wrap.querySelectorAll("input[data-setting-key]").forEach(input => {
    if (input.value !== input.dataset.savedValue) {
      typing[input.dataset.settingKey] = { typed: input.value, saved: input.dataset.savedValue };
    }
  });
  wrap.innerHTML = "";
  app.adminGameSettingsCache.forEach(setting => {
    const row = document.createElement("div");
    row.className = "admin-setting";

    const info = document.createElement("div");
    info.className = "admin-setting-info";
    const title = document.createElement("strong");
    title.textContent = setting.title;
    const description = document.createElement("small");
    description.textContent = `${setting.description} допустимо от ${setting.min_value} до ${setting.max_value}.`;
    const changed = document.createElement("small");
    changed.textContent = setting.updated_at
      ? `изменено ${formatAdminDate(setting.updated_at)}${setting.updated_by_name ? ` · ${setting.updated_by_name}` : ""}`
      : "значение по умолчанию, еще не менялось";
    info.append(title, description, changed);

    const controls = document.createElement("div");
    controls.className = "admin-setting-controls";
    const input = document.createElement("input");
    input.type = "number";
    input.inputMode = "numeric";
    input.min = String(setting.min_value);
    input.max = String(setting.max_value);
    input.step = "1";
    input.value = String(setting.value);
    input.dataset.savedValue = String(setting.value);
    input.dataset.settingKey = setting.key;
    const pending = typing[setting.key];
    if (pending && pending.saved === String(setting.value)) input.value = pending.typed;
    input.setAttribute("aria-label", setting.title);
    const save = document.createElement("button");
    save.type = "button";
    save.textContent = "сохранить";
    save.addEventListener("click", () => saveAdminGameSetting(setting, input, save));
    input.addEventListener("keydown", event => { if (event.key === "Enter") save.click(); });
    controls.append(input, save);

    row.append(info, controls);
    wrap.append(row);
  });
}

async function saveAdminGameSetting(setting, input, button) {
  if (!app.profile?.is_admin || button.dataset.busy === "true") return;
  const message = $("adminGameSettingsMessage");
  const value = Number(input.value);
  if (!Number.isInteger(value) || value < setting.min_value || value > setting.max_value) {
    msg(message, `«${setting.title}»: введите целое число от ${setting.min_value} до ${setting.max_value}.`, "error");
    return;
  }
  if (value === setting.value) {
    msg(message, `«${setting.title}»: значение не изменилось.`);
    return;
  }
  if (!window.confirm(`изменить «${setting.title}» с ${setting.value} на ${value}? новое значение будет действовать для следующих результатов.`)) return;
  button.dataset.busy = "true";
  button.disabled = true;
  button.textContent = "сохраняем…";
  try {
    const { error } = await app.supabase.rpc("admin_update_game_setting", { p_key: setting.key, p_value: value });
    if (error) throw error;
    await loadAdminGameSettings();
    loadPublicGameSettings();
    msg(message, `«${setting.title}»: теперь ${value}. действует для следующих результатов.`, "success");
  } catch (error) {
    msg(message, humanError(error), "error");
  } finally {
    delete button.dataset.busy;
    button.disabled = false;
    button.textContent = "сохранить";
  }
}
