// Настройки баланса для игроков: числа из game_settings и склонение подсказок.
import { app } from "./state.js?v=118";
import { GAME_SETTING_DEFAULTS, configured } from "./constants.js?v=118";
import { $$ } from "./helpers.js?v=118";
import { renderCreateOptions } from "./lobby.js?v=118";

// Русское склонение по числу: ruPlural(3, ["очко", "очка", "очков"]) → "очка".
export function ruPlural(n, [one, few, many]) {
  const n10 = n % 10, n100 = n % 100;
  if (n10 === 1 && n100 !== 11) return one;
  if (n10 >= 2 && n10 <= 4 && (n100 < 12 || n100 > 14)) return few;
  return many;
}

export function pairLimitPhrase(n = app.gameSettings.pair_daily_limit) {
  return `до ${n} ${n % 10 === 1 && n % 100 !== 11 ? "рейтингового матча" : "рейтинговых матчей"}`;
}

function tournamentPointsPhrase(n = app.gameSettings.tournament_points) {
  return `${n} ${ruPlural(n, ["очко", "очка", "очков"])}`;
}

// Подставляет актуальные числа в подсказки, размеченные data-setting-text в index.html.
function applyGameSettingTexts() {
  $$("[data-setting-text]").forEach(node => {
    if (node.dataset.settingText === "pair-limit") node.textContent = pairLimitPhrase();
    if (node.dataset.settingText === "tournament-points") node.textContent = tournamentPointsPhrase();
  });
}

export async function loadPublicGameSettings() {
  if (!configured || !app.supabase) return;
  try {
    const { data, error } = await app.supabase.rpc("get_public_game_settings");
    if (error) throw error;
    for (const key of Object.keys(GAME_SETTING_DEFAULTS)) {
      const value = Number(data?.[key]);
      if (Number.isInteger(value) && value > 0) app.gameSettings[key] = value;
    }
  } catch (error) {
    console.warn("[settings] настройки баланса не загрузились, показываем значения по умолчанию", error);
  }
  applyGameSettingTexts();
  renderCreateOptions();
}
