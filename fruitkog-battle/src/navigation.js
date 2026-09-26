// Переключение разделов сайта и адрес страницы (?view=…).
import { app } from "./state.js?v=118";
import { TOURNAMENT_DEMO_ENABLED } from "./constants.js?v=118";
import { $, $$ } from "./helpers.js?v=118";
import { loadLobby } from "./lobby.js?v=118";
import { loadTournaments } from "./tournament.js?v=118";
import { loadRating } from "./rating.js?v=118";
import { loadAdmin } from "./admin.js?v=118";

export function switchView(name) {
  const changed = app.currentView !== name;
  if (name !== "game") setViewUrl(name);
  ["home","play","rating","tournament","admin","game"].forEach(v => {
    $(`${v}View`).classList.toggle("hidden", v !== name);
  });
  document.documentElement.removeAttribute("data-initial-view");
  app.currentView = name;
  document.body.dataset.view = name;
  $$(".main-nav [data-view]").forEach(button => {
    const active = button.dataset.view === name;
    button.classList.toggle("active", active);
    if (active) button.setAttribute("aria-current", "page");
    else button.removeAttribute("aria-current");
  });
  if (name === "play" && app.user) loadLobby();
  if (name === "rating") loadRating();
  if (name === "tournament") loadTournaments();
  if (name === "admin") loadAdmin();
  if (changed) window.scrollTo({top:0,behavior:"auto"});
}

function setViewUrl(name){
  const url=new URL(location.href);
  url.searchParams.delete("game");
  url.searchParams.delete("watch");
  if(name&&name!=="home")url.searchParams.set("view",name);
  else url.searchParams.delete("view");
  history.replaceState(null,"",url);
}

export function restoreSavedView(){
  if(app.currentView==="game")return;
  const requested=new URL(location.href).searchParams.get("view")||(TOURNAMENT_DEMO_ENABLED?"tournament":null);
  const allowed=new Set(["home","play","rating","tournament","admin"]);
  if(!requested||!allowed.has(requested))return;
  if(requested==="admin"&&!app.profile?.is_admin){
    switchView("home");
    return;
  }
  switchView(requested);
}
