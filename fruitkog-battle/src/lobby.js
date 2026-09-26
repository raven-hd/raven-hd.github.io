// Игровой зал: создание и поиск матчей, активные игры, история.
import { app } from "./state.js?v=118";
import { $, $$, msg, newRequestId, safeStorage } from "./helpers.js?v=118";
import { humanError } from "./errors.js?v=118";
import { pairLimitPhrase, ruPlural } from "./settings.js?v=118";
import { exitPreGame, observeGame, openGame, statusLabel } from "./room.js?v=118";
import { tournamentStageLabel } from "./tournament.js?v=118";

const shownJoinWarnings = new Set();

function pendingCreateKey(gameType="rated") {
  return app.user?.id ? `fruitkog-create-request:${app.user.id}:${gameType}` : null;
}

function getPendingCreateRequest(gameType="rated") {
  const key = pendingCreateKey(gameType);
  if (!key) return null;
  let requestId = safeStorage.get(key);
  if (!requestId) {
    requestId = newRequestId();
    safeStorage.set(key,requestId);
  }
  return requestId;
}

function clearPendingCreateRequest(gameType="rated") {
  const key = pendingCreateKey(gameType);
  if (key) safeStorage.remove(key);
}

export function renderCreateOptions() {
  const rated = $("ratedGameMode");
  const casual = $("casualGameMode");
  const hint = $("createModeHint");
  if (!rated || !casual || !hint) return;
  const guest = app.profile?.account_type === "guest";
  const unverified = app.profile?.account_type === "registered" && !app.profile.school_verified;
  rated.disabled = guest || unverified;
  hint.classList.add("visually-hidden");
  if (guest || unverified) {
    casual.checked = true;
    hint.textContent = guest
      ? "гостевые матчи всегда проходят без рейтинга."
      : "рейтинговые матчи доступны после подтверждения школьного ника администратором.";
  } else {
    if (!rated.checked && !casual.checked) rated.checked = true;
    hint.textContent = `одна пара может провести ${pairLimitPhrase()} за 24 часа.`;
  }
}

export async function loadLobby() {
  if (!app.user) return;
  await Promise.all([loadActiveGames(),loadMatchHistory()]);
}

async function loadMatchHistory() {
  if (!app.user) return [];
  const requestedUserId = app.user.id;
  const generation = ++app.matchHistoryGeneration;
  const {data,error} = await app.supabase.rpc("list_match_history");
  if (!app.user || app.user.id!==requestedUserId || generation!==app.matchHistoryGeneration) return [];
  if (error) {
    console.error(error);
    app.matchHistoryCache = [];
  } else {
    app.matchHistoryCache = data || [];
  }
  renderMatchHistory();
  return app.matchHistoryCache;
}

function renderMatchHistory() {
  const wrap = $("matchHistory");
  const more = $("matchHistoryMore");
  const moreList = $("matchHistoryMoreList");
  wrap.innerHTML = "";
  moreList.innerHTML = "";

  const renderItem = match => {
    const item = document.createElement("div");
    item.className = "history-game";
    const names = document.createElement("strong");
    names.textContent = `${match.player1_name} — ${match.player2_name}`;
    const result = document.createElement("span");
    const winnerText = match.finish_reason === "surrender"
      ? `победитель: ${match.winner_name} (соперник сдался)`
      : `победитель: ${match.winner_name}`;
    const ratingText = match.game_type === "tournament"
      ? match.tournament_rating_applied
        ? `турнирный рейтинг: ±${match.tournament_rating_delta ?? 0}`
        : "турнирный матч · без начисления"
      : match.rating_applied
      ? `рейтинг: +${match.rating_delta ?? 0}`
      : match.rating_skip_reason === "pair_daily_limit"
        ? "без рейтинга: лимит пары"
        : "без рейтинга";
    result.textContent = `${winnerText} · ${ratingText}`;
    const date = document.createElement("time");
    date.dateTime = match.finished_at;
    date.textContent = new Intl.DateTimeFormat("ru-RU",{
      day:"2-digit",month:"2-digit",year:"numeric",hour:"2-digit",minute:"2-digit"
    }).format(new Date(match.finished_at));
    item.append(names,result,date);
    if(match.viewer_can_open&&match.game_id){
      item.classList.add("history-game-replay");
      item.tabIndex=0;
      item.setAttribute("role","button");
      item.setAttribute("aria-label",`открыть завершенный матч ${match.player1_name} и ${match.player2_name}`);
      item.title="открыть завершенный матч";
      item.addEventListener("click",()=>openCompletedMatch(match,item));
      item.addEventListener("keydown",event=>{
        if(event.key==="Enter"||event.key===" "){
          event.preventDefault();
          openCompletedMatch(match,item);
        }
      });
    }
    return item;
  };

  const historyRows = [...app.matchHistoryCache].sort((a,b) => new Date(b.finished_at) - new Date(a.finished_at));
  historyRows.slice(0,3).forEach(match => wrap.appendChild(renderItem(match)));
  historyRows.slice(3).forEach(match => moreList.appendChild(renderItem(match)));

  const hasMore = historyRows.length > 3;
  more.classList.toggle("hidden",!hasMore);
  if (!hasMore) more.open = false;
  $("matchHistoryEmpty").classList.toggle("hidden",app.matchHistoryCache.length > 0);
}

export async function openCompletedMatch(match,target=null){
  if(!match?.game_id||target?.dataset.busy==="true")return;
  if(target){target.dataset.busy="true";target.setAttribute("aria-busy","true");}
  try{
    const {data,error}=await app.supabase.from("games").select("*").eq("id",match.game_id).maybeSingle();
    if(error)throw error;
    if(!data||data.status!=="finished")throw new Error("завершенный матч не найден");
    if(![data.player1_id,data.player2_id].includes(app.user?.id)){
      throw new Error("просмотр завершенного матча доступен только его участникам");
    }
    if($("playerProfileDialog")?.open)$("playerProfileDialog").close();
    await openGame(data);
  }catch(error){
    alert(humanError(error));
  }finally{
    if(target){delete target.dataset.busy;target.removeAttribute("aria-busy");}
  }
}

async function loadActiveGames() {
  if (!app.user) return [];
  const requestedUserId = app.user.id;
  const generation = ++app.activeGamesGeneration;
  const {data,error} = await app.supabase.rpc("list_active_games");

  if (!app.user || app.user.id!==requestedUserId || generation!==app.activeGamesGeneration) return [];
  if (error) { console.error(error); return []; }
  app.activeGamesCache = data || [];
  const playerIds = [...new Set(app.activeGamesCache.flatMap(row => [row.player1_id,row.player2_id]).filter(Boolean))];
  app.profilesCache = new Map();
  if (playerIds.length) {
    const {data:players,error:playersError} = await app.supabase.from("profiles")
      .select("user_id,account_type,avatar_emoji")
      .in("user_id",playerIds);
    if (!app.user || app.user.id!==requestedUserId || generation!==app.activeGamesGeneration) return [];
    if (playersError) console.error(playersError);
    (players || []).forEach(player => app.profilesCache.set(player.user_id,player));
  }
  renderActiveGames();
  return app.activeGamesCache;
}

function playerLabel(playerId,name) {
  const avatar = app.profilesCache.get(playerId)?.avatar_emoji;
  return avatar ? `${avatar} ${name}` : name;
}

// Список игр меняется при каждом выстреле в любой игре. Обновляем его, только пока игрок
// смотрит на зал (при переходе в зал он и так загружается заново), и не чаще раза в 3 секунды —
// иначе каждый выстрел заставлял бы все открытые вкладки перезагружать зал.
function scheduleLobbyRefresh() {
  if (app.currentView !== "play" || document.hidden) return;
  if (app.lobbyRefreshTimer) return;
  const delay = Math.max(150, 3000 - (Date.now() - app.lastLobbyRefreshAt));
  app.lobbyRefreshTimer = setTimeout(() => {
    app.lobbyRefreshTimer = null;
    app.lastLobbyRefreshAt = Date.now();
    loadLobby();
  }, delay);
}

// после блокировки телефона или обрыва связи — догнать то, что пропустили
export function resyncLobby() {
  if (app.user && app.currentView === "play" && !document.hidden) scheduleLobbyRefresh();
}

export async function subscribeToLobby() {
  if (!app.supabase || !app.user) return;
  if (app.lobbyChannel) await app.supabase.removeChannel(app.lobbyChannel);
  app.lobbyChannel = app.supabase.channel(`lobby-${app.user.id}`)
    .on("postgres_changes",{event:"*",schema:"public",table:"games"},scheduleLobbyRefresh)
    .subscribe(status => { if (status === "SUBSCRIBED") resyncLobby(); });
}

function addMatchFlag(wrap,text,className="") {
  const flag = document.createElement("span");
  flag.className = `match-flag${className ? ` ${className}` : ""}`;
  flag.textContent = text;
  wrap.appendChild(flag);
}

function activePairGameWith(opponentId,excludeGameId=null) {
  return app.activeGamesCache.find(row =>
    row.id !== excludeGameId
    && row.game_type !== "tournament"
    && row.is_participant
    && ["placing","playing","paused"].includes(row.status)
    && [row.player1_id,row.player2_id].includes(opponentId)
  ) || null;
}

export function renderActiveGames() {
  let rows = app.activeGamesCache;
  if (app.activeFilter === "waiting") rows = rows.filter(r => r.status === "waiting");
  if (app.activeFilter === "playing") rows = rows.filter(r => ["placing","playing","paused"].includes(r.status));
  if (app.activeFilter === "tournament") rows = rows.filter(r => r.game_type === "tournament");
  if (app.activeFilter === "mine") rows = rows.filter(r => r.is_participant);

  const wrap = $("activeGames");
  wrap.innerHTML = "";

  rows.forEach(row => {
    const item = document.createElement("div");
    item.className = "open-game";

    const left = document.createElement("div");
    const strong = document.createElement("strong");
    const player1Label = playerLabel(row.player1_id,row.player1_name);
    const player2Label = row.player2_id ? playerLabel(row.player2_id,row.player2_name) : null;
    strong.textContent = player2Label
      ? `${player1Label} — ${player2Label}`
      : `${player1Label} ждет соперника`;
    const small = document.createElement("small");
    if (row.status === "playing") {
      const turnName = row.current_turn === row.player1_id ? row.player1_name : row.player2_name;
      small.textContent = `сейчас ходит ${turnName}`;
    } else if (row.status === "placing" && row.is_participant) {
      const myReady = row.player1_id === app.user.id ? row.player1_ready : row.player2_ready;
      small.textContent = myReady ? "ваш флот готов — ждем соперника" : "соперник в комнате — пора расставить корабли";
    } else if (row.status === "paused") {
      small.textContent = "";
    } else {
      small.textContent = "";
    }

    const existingPairGame = !row.is_participant && row.status === "waiting"
      ? activePairGameWith(row.player1_id,row.id)
      : null;
    const unverifiedRatedJoin = !row.is_participant && row.status === "waiting"
      && row.game_type === "rated" && app.profile?.account_type === "registered"
      && !app.profile.school_verified;
    small.hidden = !small.textContent;

    const flags = document.createElement("div");
    flags.className = "match-flags";
    addMatchFlag(flags,statusLabel(row.status),row.status === "paused" ? "paused" : "");
    addMatchFlag(flags,row.game_type === "rated" ? "рейтинговая" : row.game_type === "tournament" ? "турнирная" : "без рейтинга",row.game_type === "rated" ? "rated" : "");
    const stageLabel=tournamentStageLabel(row);
    if(stageLabel)addMatchFlag(flags,stageLabel,"tournament-stage");
    if (row.is_participant) addMatchFlag(flags,"ваш матч","mine");
    if (existingPairGame) addMatchFlag(flags,"уже есть совместный матч","pair-existing");
    left.append(strong,small,flags);
    let warning=null;
    if (unverifiedRatedJoin) {
      warning=document.createElement("small");
      warning.className="join-verification-warning";
      warning.hidden=!shownJoinWarnings.has(row.id);
      warning.setAttribute("role","status");
      const icon=document.createElement("i");
      icon.className="fas fa-exclamation-triangle";
      icon.setAttribute("aria-hidden","true");
      warning.append(icon,document.createTextNode(" для участия нужен подтвержденный школьный ник"));
      left.appendChild(warning);
    }

    const actions = document.createElement("div");
    actions.className = "active-game-actions";

    if (row.is_participant) {
      const resume = document.createElement("button");
      resume.type = "button";
      resume.className = "primary";
      const myReady = row.player1_id === app.user.id ? row.player1_ready : row.player2_ready;
      resume.textContent = row.status === "placing" && !myReady ? "припрятать урожай" : "вернуться";
      resume.addEventListener("click",() => openGame(row));
      actions.appendChild(resume);

      const canClose = row.game_type !== "tournament" && row.player1_id === app.user.id && ["waiting","placing"].includes(row.status);
      const canLeave = row.game_type !== "tournament" && row.player2_id === app.user.id && row.status === "placing";
      if (canClose || canLeave) {
        const close = document.createElement("button");
        close.type = "button";
        close.className = "danger-outline";
        close.textContent = canClose ? "закрыть" : "выйти";
        close.addEventListener("click",() => exitPreGame(row));
        actions.appendChild(close);
      }
    } else if (row.status === "waiting") {
      const join = document.createElement("button");
      join.type = "button";
      join.className = "primary";
      join.textContent = "присоединиться";
      if (unverifiedRatedJoin) {
        join.classList.add("join-unavailable");
        join.setAttribute("aria-disabled","true");
        join.addEventListener("click",()=>{
          shownJoinWarnings.add(row.id);
          warning.hidden=false;
        });
      } else if (existingPairGame) {
        join.disabled = true;
        join.classList.add("join-unavailable");
        join.title = "у вас уже есть незавершенный матч с этим игроком";
      } else {
        join.addEventListener("click",() => joinPublicGame(row,join));
      }
      actions.appendChild(join);
    } else if (["playing","paused"].includes(row.status)) {
      const watch = document.createElement("button");
      watch.type = "button";
      watch.className = "lobby-watch-action";
      watch.textContent = "подсматривать";
      watch.addEventListener("click",() => observeGame(row,watch));
      actions.appendChild(watch);
    }

    item.append(left,actions);
    wrap.appendChild(item);
  });

  $("activeGamesEmpty").classList.toggle("hidden",rows.length > 0);
  const activeSection = document.querySelector("#playView .lobby-active");
  if (activeSection) activeSection.classList.toggle("is-empty",rows.length === 0);
  $$('[data-game-filter]').forEach(button => {
    button.classList.toggle("active",button.dataset.gameFilter === app.activeFilter);
  });
}

export async function createGame() {
  if (app.createGameInProgress || !app.user) return;
  app.createGameInProgress = true;
  msg($("createMessage"),"");
  const button = $("createGameBtn");
  const oldText = button.textContent;
  button.disabled = true;
  button.textContent = "создаем…";
  const slowTimer = setTimeout(()=>msg($("createMessage"),"соединение медленное, продолжаем ждать. повторно нажимать не нужно."),2500);
  const requestedType = app.profile?.account_type === "guest" || !$("ratedGameMode").checked ? "casual" : "rated";
  try {
    const requestId = getPendingCreateRequest(requestedType);
    const {data,error} = await app.supabase.rpc("create_game",{p_request_id:requestId,p_game_type:requestedType});
    if (error) throw error;
    await openGame(data);
    clearPendingCreateRequest(requestedType);
  } catch(e) {
    msg($("createMessage"),humanError(e),"error");
  } finally {
    clearTimeout(slowTimer);
    app.createGameInProgress = false;
    button.disabled = false;
    button.textContent = oldText;
  }
}

async function joinPublicGame(row,button=null) {
  if (button?.dataset.busy==="true") return;
  msg($("joinMessage"));
  const gameId = typeof row === "string" ? row : row.id;
  const requestedType = typeof row === "string" ? null : row.game_type;
  const oldText = button?.textContent;
  if (button) {
    button.dataset.busy = "true";
    button.disabled = true;
    button.textContent = "подключаем…";
  }
  try {
    const {data,error} = await app.supabase.rpc("join_public_game",{p_game_id:gameId});
    if (error) throw error;
    if (requestedType === "rated" && data.game_type !== "rated") {
      const reason = data.rating_skip_reason === "pair_daily_limit"
        ? `вы уже сыграли ${app.gameSettings.pair_daily_limit} ${ruPlural(app.gameSettings.pair_daily_limit, ["рейтинговый матч", "рейтинговых матча", "рейтинговых матчей"])} с этим соперником за последние 24 часа. этот матч пройдет без рейтинга.`
        : "в матче участвует гость, поэтому он пройдет без рейтинга.";
      alert(reason);
    }
    await openGame(data);
  } catch(e) {
    msg($("joinMessage"),humanError(e),"error");
    if (button) {
      button.disabled = false;
      button.textContent = oldText;
      delete button.dataset.busy;
    }
  }
}
