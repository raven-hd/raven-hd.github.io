// Константы и флаги: правила поля и флота, скины, режим демо-турнира.
import { SUPABASE_PUBLISHABLE_KEY, SUPABASE_URL } from "../config.js?v=118";

export const configured =
  SUPABASE_URL &&
  SUPABASE_PUBLISHABLE_KEY &&
  !SUPABASE_URL.includes("PASTE_") &&
  !SUPABASE_PUBLISHABLE_KEY.includes("PASTE_");

export const TOURNAMENT_DEMO_ENABLED = new URLSearchParams(location.search).get("tournament-demo") === "1";

export const TOURNAMENT_DEMO_STATES = new Set(["none","registration","active","large","mixed","finished"]);

// Настройки баланса (миграция 035). Значения по умолчанию = прежние правила игры:
// если настройки не загрузились, подсказки покажут именно их.
export const GAME_SETTING_DEFAULTS = { elo_k: 16, tournament_points: 12, pair_daily_limit: 3 };

export const COLS = "ABCDEFGHIJ".split("");

export const FLEET = [
  {length:4,label:"линкор"},
  {length:3,label:"крейсер"},
  {length:3,label:"крейсер"},
  {length:2,label:"эсминец"},
  {length:2,label:"эсминец"},
  {length:2,label:"эсминец"},
  {length:1,label:"катер"},
  {length:1,label:"катер"},
  {length:1,label:"катер"},
  {length:1,label:"катер"},
];

export const SHIP_SKINS = {1:"mushroom",2:"eggplant",3:"carrot",4:"celery"};

export const PRODUCE_BY_SHIP_LENGTH={1:"шампиньон",2:"баклажан",3:"морковь",4:"сельдерей"};
