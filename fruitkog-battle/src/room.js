// Комната матча: открыть, наблюдать, выйти, сдаться, обновление состояния матча.
import { app } from "./state.js?v=118";
import { $, msg } from "./helpers.js?v=118";
import { humanError } from "./errors.js?v=118";
import { switchView } from "./navigation.js?v=118";
import { loadLobby } from "./lobby.js?v=118";
import { clearPlacementDraft, loadPlacementDraft, lockPlacement, renderPlacement, unlockPlacement } from "./placement.js?v=118";
import { refreshBattleData, refreshSpectatorData, renderBattle, renderSpectatorBattle } from "./battle.js?v=118";

export async function openGame(row) {
  app.spectatorMode = false;
  app.game = row;
  app.placement = loadPlacementDraft(app.game.id);
  app.opponentFleet = null;
  setGameUrl(app.game.id,"game");
  $("placementPanel").classList.add("hidden");
  $("battlePanel").classList.add("hidden");
  renderRoom();
  switchView("game");
  subscribeToGame();
  await refreshGame();
}

export async function observeGame(row,button=null) {
  const watchable = ["playing","paused"].includes(row.status);
  if (!watchable) return;
  if (button?.dataset.busy==="true") return;
  if (button) {
    button.dataset.busy = "true";
    button.disabled = true;
    button.textContent = "открываем…";
  }
  app.spectatorMode = true;
  app.game = row;
  app.opponentFleet = null;
  setGameUrl(app.game.id,"watch");
  $("placementPanel").classList.add("hidden");
  $("battlePanel").classList.add("hidden");
  renderRoom();
  switchView("game");
  subscribeToGame();
  await refreshGame();
}

async function cancelGame(gameId=app.game?.id) {
  if (!gameId) return;
  if (!window.confirm("закрыть эту комнату? вернуться в нее после этого будет нельзя.")) return;
  try {
    const {error} = await app.supabase.rpc("cancel_game",{p_game_id:gameId});
    if (error) throw error;

    if (app.game?.id === gameId) {
      clearPlacementDraft(gameId);
      if (app.realtimeChannel) await app.supabase.removeChannel(app.realtimeChannel);
      app.realtimeChannel = null;
      app.game = null;
      app.spectatorMode = false;
      setGameUrl(null);
      switchView("play");
    } else {
      await loadLobby();
    }
  } catch(e) {
    alert(humanError(e));
  }
}

async function leaveGame(gameId=app.game?.id) {
  if (!gameId) return;
  if (!window.confirm("выйти из этой комнаты? создатель сможет дождаться другого соперника.")) return;
  try {
    const {error} = await app.supabase.rpc("leave_game",{p_game_id:gameId});
    if (error) throw error;

    if (app.game?.id === gameId) {
      clearPlacementDraft(gameId);
      if (app.realtimeChannel) await app.supabase.removeChannel(app.realtimeChannel);
      app.realtimeChannel = null;
      app.game = null;
      app.spectatorMode = false;
      setGameUrl(null);
      switchView("play");
    } else {
      await loadLobby();
    }
  } catch(e) {
    alert(humanError(e));
  }
}

export async function surrenderGame() {
  if (!app.game?.id || app.spectatorMode || app.game.status !== "playing" || app.surrenderInProgress) return;
  if (!window.confirm("сдаться? матч завершится победой соперника. отменить это действие будет нельзя.")) return;

  app.surrenderInProgress = true;
  const button = $("surrenderGameBtn");
  button.disabled = true;
  button.textContent = "завершаем матч…";
  try {
    const {data,error} = await app.supabase.rpc("surrender_game",{p_game_id:app.game.id});
    if (error) throw error;
    app.game = data;
    await refreshGame();
    await loadLobby();
  } catch(e) {
    await refreshGame();
    if (!(app.game?.status === "finished" && app.game.surrendered_by === app.user.id)) {
      alert(humanError(e));
    }
  } finally {
    app.surrenderInProgress = false;
    button.disabled = false;
    button.textContent = "сдаться";
    if (app.game) renderRoom();
  }
}

export function exitPreGame(row=app.game) {
  if (!row) return;
  if (row.player1_id === app.user.id) return cancelGame(row.id);
  if (row.player2_id === app.user.id) return leaveGame(row.id);
}

export function statusLabel(status) {
  return ({waiting:"ждет соперника",placing:"расстановка",playing:"идет игра",paused:"приостановлена",finished:"завершена",cancelled:"отменена"})[status] || status;
}

function renderRoom() {
  $("gameView").dataset.gameStatus = app.game.status;
  $("gameTypeBadge").textContent = app.game.game_type === "rated" ? "рейтинговая игра" : app.game.game_type === "tournament" ? "турнирный матч" : "без рейтинга";
  $("player1Name").textContent = app.game.player1_name || "—";
  $("player2Name").textContent = app.game.player2_name || "ожидаем игрока";
  const player1Profile = app.profilesCache.get(app.game.player1_id);
  const player2Profile = app.profilesCache.get(app.game.player2_id);
  $("player1Avatar").textContent = player1Profile?.avatar_emoji || "";
  $("player2Avatar").textContent = player2Profile?.avatar_emoji || "";
  $("player1Avatar").classList.toggle("hidden",!player1Profile?.avatar_emoji);
  $("player2Avatar").classList.toggle("hidden",!player2Profile?.avatar_emoji);
  $("player1Ready").textContent = app.game.player1_ready ? "готов" : "не готов";
  $("player2Ready").textContent = app.game.player2_ready ? "готов" : "не готов";
  const canClose = !app.spectatorMode && app.game.game_type !== "tournament" && app.game.player1_id === app.user.id && ["waiting","placing"].includes(app.game.status);
  const canLeave = !app.spectatorMode && app.game.game_type !== "tournament" && app.game.player2_id === app.user.id && app.game.status === "placing";
  const canSurrender = !app.spectatorMode
    && [app.game.player1_id,app.game.player2_id].includes(app.user.id)
    && app.game.status === "playing";
  const backGoesBelow = !app.spectatorMode && ["waiting","placing"].includes(app.game.status);
  const backButton = $("backLobbyBtn");
  const backTarget = backGoesBelow ? $("gameRoomActions") : $("gamePrimaryButtons");
  if (backButton.parentElement !== backTarget) backTarget.prepend(backButton);
  $("closeGameBtn").classList.toggle("hidden",!(canClose || canLeave));
  $("closeGameBtn").textContent = canClose ? "закрыть комнату" : "выйти из комнаты";
  $("gameRoomActions").classList.toggle("hidden",!(canClose || canLeave || backGoesBelow));
  $("surrenderGameBtn").classList.toggle("hidden",!canSurrender);
  $("battleBadge").classList.toggle("hidden",!["playing","paused","finished"].includes(app.game.status));
  $("surrenderGameBtn").disabled = app.surrenderInProgress;

  if (app.game.status === "waiting") {
    msg($("roomMessage"),"ваша новая грядка уже готова — осталось дождаться соперника.");
  } else if (app.game.status === "placing") {
    msg($("roomMessage"),"");
  } else if (app.game.status === "playing") {
    msg($("roomMessage"),"");
  } else if (app.game.status === "paused") {
    msg($("roomMessage"),"матч приостановлен и ожидает решения администратора.");
  } else if (app.game.status === "finished") {
    msg($("roomMessage"),"");
  } else if (app.game.status === "cancelled") {
    // причины «техническая победа в турнире» и «переигровка в турнире» ставит сервер (миграция 037)
    const tournamentGame = app.game.game_type === "tournament";
    msg($("roomMessage"),tournamentGame && app.game.admin_cancel_reason === "техническая победа в турнире"
      ? "игра закрыта: администратор засчитал техническую победу. итог — на странице турнира."
      : tournamentGame && app.game.admin_cancel_reason === "переигровка в турнире"
      ? "игра закрыта: администратор назначил переигровку. новая комната — на странице турнира."
      : app.game.admin_cancelled_by
      ? "матч закрыт администратором без победителя и изменения рейтинга."
      : "комната закрыта создателем.");
  }
}

async function loadRoomProfiles() {
  const ids = [app.game?.player1_id,app.game?.player2_id].filter(Boolean);
  if (!ids.length) return;
  const {data,error} = await app.supabase.from("profiles")
    .select("user_id,account_type,avatar_emoji")
    .in("user_id",ids);
  if (error) return console.error(error);
  (data || []).forEach(player => app.profilesCache.set(player.user_id,player));
}

export function isMeReady() {
  return app.game.player1_id === app.user.id ? app.game.player1_ready : app.game.player2_ready;
}

export async function refreshGame() {
  if(app.refreshGamePromise){
    app.refreshGameQueued=true;
    return app.refreshGamePromise;
  }
  app.refreshGamePromise=(async()=>{
    do{
      app.refreshGameQueued=false;
      await refreshGameOnce();
    }while(app.refreshGameQueued);
  })();
  try{
    await app.refreshGamePromise;
  }finally{
    app.refreshGamePromise=null;
  }
}

async function refreshGameOnce() {
  if (!app.game?.id || !app.user) return;
  const requestedGameId=app.game.id;
  const {data,error} = await app.supabase.from("games").select("*").eq("id",requestedGameId).single();
  if (error) {
    console.error(error);
    // зрителя выводим, только если матча больше нет или его закрыли для просмотра (PGRST116 —
    // строка не найдена или не видна). обрыв сети и таймаут — не повод: матч догонится позже
    const gone=error.code==="PGRST116"||error.code==="42501";
    if (app.spectatorMode && gone && app.game?.id===requestedGameId) {
      alert("этот матч больше недоступен для наблюдения.");
      setGameUrl(null);
      switchView("play");
    }
    return;
  }
  if(!app.game||app.game.id!==requestedGameId)return;
  app.game = data;
  await loadRoomProfiles();
  if(!app.game||app.game.id!==requestedGameId)return;
  renderRoom();

  if (app.spectatorMode) {
    $("placementPanel").classList.add("hidden");
    if (!["playing","paused","finished"].includes(app.game.status)) {
      $("battlePanel").classList.add("hidden");
      return;
    }
    if(!await refreshSpectatorData())return;   // не загрузилось — оставляем прежнюю картину
    renderSpectatorBattle();
    $("battlePanel").classList.remove("hidden");
    app.lastGameRefreshAt=Date.now();
    return;
  }

  if (app.game.status === "waiting") {
    $("placementPanel").classList.add("hidden");
    $("battlePanel").classList.add("hidden");
    return;
  }

  if (app.game.status === "cancelled") {
    $("placementPanel").classList.add("hidden");
    $("battlePanel").classList.add("hidden");
    return;
  }

  if (app.game.status === "paused" && app.game.pause_reason === "placement_timeout") {
    $("placementPanel").classList.remove("hidden");
    $("battlePanel").classList.add("hidden");
    renderPlacement();
    lockPlacement();
    msg($("placementMessage"),"расстановка приостановлена и ожидает решения администратора.","error");
    return;
  }

  if (app.game.status === "placing") {
    $("placementPanel").classList.remove("hidden");
    $("battlePanel").classList.add("hidden");
    if (isMeReady()) {
      renderPlacement();
      lockPlacement();
      msg($("placementMessage"),"ваша расстановка зафиксирована. ждем соперника.","success");
    } else {
      unlockPlacement();
      renderPlacement();
    }
    return;
  }

  if (["playing","paused","finished"].includes(app.game.status)) {
    $("placementPanel").classList.add("hidden");
    if(!await refreshBattleData())return;   // не загрузилось — оставляем прежнюю картину
    renderBattle();
    $("battlePanel").classList.remove("hidden");
    app.lastGameRefreshAt=Date.now();
  }
}

function scheduleGameRefresh(){
  clearTimeout(app.gameRefreshTimer);
  app.gameRefreshTimer=setTimeout(()=>{
    app.gameRefreshTimer=null;
    if(Date.now()-app.lastGameRefreshAt<350)return;
    refreshGame();
  },140);
}

function subscribeToGame(){
  if(app.realtimeChannel)app.supabase.removeChannel(app.realtimeChannel);
  app.realtimeChannel=app.supabase.channel(`game-${app.game.id}`)
    .on("postgres_changes",{event:"UPDATE",schema:"public",table:"games",filter:`id=eq.${app.game.id}`},scheduleGameRefresh)
    .on("postgres_changes",{event:"INSERT",schema:"public",table:"shots",filter:`game_id=eq.${app.game.id}`},scheduleGameRefresh)
    // пока связи не было (телефон заблокирован, пропала сеть), события не приходили:
    // после каждого (пере)подключения перечитываем матч, иначе оба игрока могут ждать хода друг друга
    .subscribe(status=>{if(status==="SUBSCRIBED")scheduleGameRefresh();});
}

// вызывается при возвращении на вкладку, появлении сети и раз в 20 секунд, пока открыт
// незавершенный матч — страховка на случай, если realtime тихо потерял событие
export function resyncGame(){
  if(!app.game||app.currentView!=="game"||document.hidden)return;
  if(!["waiting","placing","playing","paused"].includes(app.game.status))return;
  scheduleGameRefresh();
}

export function setGameUrl(id,mode="game"){
  const url=new URL(location.href);
  url.searchParams.delete("game");
  url.searchParams.delete("watch");
  url.searchParams.delete("view");
  if(id)url.searchParams.set(mode,id);
  history.replaceState(null,"",url);
}

export async function restoreGame(){
  const url=new URL(location.href);
  const gameId=url.searchParams.get("game");
  const watchId=url.searchParams.get("watch");
  const id=gameId||watchId;
  if(!id||!app.user)return;
  const {data}=await app.supabase.from("games").select("*").eq("id",id).maybeSingle();
  const participant=data&&[data.player1_id,data.player2_id].includes(app.user.id);
  const canWatch=data&&(
    ["playing","paused","finished"].includes(data.status)
  );
  if(data&&((gameId&&participant)||(watchId&&canWatch))){
    app.spectatorMode=!!watchId&&!participant;
    if(participant&&watchId)setGameUrl(id,"game");
    app.game=data;
    if(participant)app.placement=loadPlacementDraft(id);
    $("placementPanel").classList.add("hidden");
    $("battlePanel").classList.add("hidden");
    renderRoom();
    switchView("game");
    subscribeToGame();
    await refreshGame();
  }else{
    setGameUrl(null);
  }
}

export async function returnToLobby(){
  const channel=app.realtimeChannel;
  app.realtimeChannel=null;
  app.game=null;
  app.spectatorMode=false;
  setGameUrl(null);
  switchView("play");
  if(channel)await app.supabase.removeChannel(channel);
}
