import { createClient } from "./vendor/supabase.js";
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from "./config.js";

const $ = id => document.getElementById(id);
const $$ = selector => [...document.querySelectorAll(selector)];

const configured =
  SUPABASE_URL &&
  SUPABASE_PUBLISHABLE_KEY &&
  !SUPABASE_URL.includes("PASTE_") &&
  !SUPABASE_PUBLISHABLE_KEY.includes("PASTE_");
const TOURNAMENT_DEMO_ENABLED = new URLSearchParams(location.search).get("tournament-demo") === "1";
const TOURNAMENT_DEMO_STATES = new Set(["none","registration","active","large","mixed","finished"]);

let supabase = null;
let user = null;
let profile = null;
let game = null;
let myFleet = null;
let shots = [];
let realtimeChannel = null;
let lobbyChannel = null;
let lobbyRefreshTimer = null;
let guestSetupInProgress = false;
let spectatorMode = false;
let spectatorFleets = [];
let opponentFleet = null;
let activeGamesCache = [];
let matchHistoryCache = [];
let profilesCache = new Map();
let activeFilter = "all";
let currentView = "home";
let authReady = false;
let sessionGeneration = 0;
let activeGamesGeneration = 0;
let matchHistoryGeneration = 0;
let createGameInProgress = false;
let readyInProgress = false;
let shotInProgress = false;
let surrenderInProgress = false;
let placementDrag = null;
let suppressPlacementClick = false;
let gameRefreshTimer = null;
let lastGameRefreshAt = 0;
let refreshGamePromise = null;
let refreshGameQueued = false;
let adminPlayersCache = [];
let adminGamesCache = [];
let adminPlayerFilter = "all";
let adminGameFilter = "active";
let adminCurrentGameId = null;
let adminLoading = false;
let tournamentsCache = [];
let currentTournamentId = null;
let openedArchivedTournamentId = null;
let currentTournamentBoard = null;
let adminCurrentTournamentId = null;
let adminCurrentTournamentBoard = null;
let tournamentLoading = false;
let tournamentApplicationBusy = false;
let tournamentBracketResizeObserver = null;
let tournamentBracketDrawVersion = 0;
let tournamentDemoState = TOURNAMENT_DEMO_STATES.has(new URLSearchParams(location.search).get("tournament-state"))
  ? new URLSearchParams(location.search).get("tournament-state")
  : "none";
let adminTournamentBusy = false;
let adminNotificationsCache = [];
let adminNotificationsLoading = false;
let adminNotificationsTimer = null;

const COLS = "ABCDEFGHIJ".split("");
const FLEET = [
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

let placement = { ships: [], orientation: "h", selectedShipIndex: 0, selectedPlacedIndex: null };

function emptyPlacement() {
  return { ships: [], orientation: "h", selectedShipIndex: 0, selectedPlacedIndex: null };
}

function placementDraftKey(gameId=game?.id) {
  return gameId && user?.id ? `fruitkog-placement:${user.id}:${gameId}` : null;
}

function loadPlacementDraft(gameId=game?.id) {
  const key = placementDraftKey(gameId);
  if (!key) return emptyPlacement();
  try {
    const saved = JSON.parse(localStorage.getItem(key));
    if (!saved || !Array.isArray(saved.ships) || !["h","v"].includes(saved.orientation)) return emptyPlacement();
    return {
      ships: saved.ships,
      orientation: saved.orientation,
      selectedShipIndex: saved.selectedShipIndex ?? null,
      selectedPlacedIndex: null,
    };
  } catch {
    return emptyPlacement();
  }
}

function savePlacementDraft() {
  const key = placementDraftKey();
  if (key) localStorage.setItem(key,JSON.stringify(placement));
}

function clearPlacementDraft(gameId) {
  const key = placementDraftKey(gameId);
  if (key) localStorage.removeItem(key);
}

function msg(el, text="", type="") {
  el.textContent = text;
  el.classList.add("message");
  el.classList.remove("error","success");
  if (type) el.classList.add(type);
}

function wait(ms) {
  return new Promise(resolve => setTimeout(resolve,ms));
}

function pendingCreateKey(gameType="rated") {
  return user?.id ? `fruitkog-create-request:${user.id}:${gameType}` : null;
}

function getPendingCreateRequest(gameType="rated") {
  const key = pendingCreateKey(gameType);
  if (!key) return null;
  let requestId = localStorage.getItem(key);
  if (!requestId) {
    requestId = crypto.randomUUID();
    localStorage.setItem(key,requestId);
  }
  return requestId;
}

function clearPendingCreateRequest(gameType="rated") {
  const key = pendingCreateKey(gameType);
  if (key) localStorage.removeItem(key);
}

function cleanName(value, max=48) {
  return value.trim().replace(/\s+/g, " ").slice(0, max);
}

function humanError(error) {
  const raw = error?.message || String(error || "неизвестная ошибка");
  const map = [
    ["Invalid login credentials","неверный email или пароль."],
    ["Email not confirmed","сначала подтвердите email по ссылке из письма."],
    ["User already registered","аккаунт с таким email уже существует."],
    ["School nick already registered","такой школьный ник уже зарегистрирован."],
    ["Guest name conflicts with registered player","это имя уже принадлежит зарегистрированному игроку."],
    ["Game not found","игра не найдена."],
    ["Game is full","в этой игре уже два игрока."],
    ["Cannot join your own game","нельзя присоединиться к собственной игре."],
    ["Only the room creator can close it","закрыть комнату может только ее создатель."],
    ["Game can no longer be closed","после начала боя комнату уже нельзя закрыть."],
    ["Only the second player can leave","выйти из этой комнаты сейчас нельзя."],
    ["Game can no longer be left","после начала боя выйти из комнаты уже нельзя."],
    ["Game is paused","матч приостановлен и ожидает решения администратора."],
    ["Pair already has active game","у вас уже идет незавершенный матч с этим игроком."],
    ["Game cannot be surrendered","сдаться можно только после начала боя."],
    ["Invalid game type","неизвестный режим матча."],
    ["Not a participant","вы не участвуете в этом матче."],
    ["Not your turn","сейчас ход соперника."],
    ["Cell already fired","в эту клетку уже стреляли."],
    ["Invalid fleet","сервер отклонил расстановку."],
    ["Admin required","этот раздел доступен только администратору."],
    ["Registered profile not found","зарегистрированный профиль не найден."],
    ["Game cannot be cancelled","этот матч уже завершен или закрыт."],
    ["Invalid admin game filter","неизвестный фильтр матчей."],
    ["Tournament not found","турнир не найден."],
    ["Tournament name required","введите название турнира."],
    ["Invalid tournament size","неверное количество участников."],
    ["Invalid tournament format","неверный формат турнира."],
    ["Tournament format required","сначала выберите формат турнира."],
    ["Tournament format locked","формат можно менять только до окончания приема заявок."],
    ["Invalid registration deadline","укажите будущую дату окончания регистрации."],
    ["Invalid qualifying match count","укажите от 1 до 10 квалификационных матчей."],
    ["Invalid playoff size","выберите размер плей-офф: 4, 8 или 16 участников."],
    ["Playoff size exceeds tournament limit","размер плей-офф превышает лимит участников турнира."],
    ["Playoff size exceeds participants","для выбранного плей-офф пока недостаточно участников."],
    ["Qualifying settings unavailable","для этого турнира нельзя настроить квалификацию."],
    ["Qualifying stage setup required","для этого турнира сначала нужно настроить отборочные матчи."],
    ["Qualifying settings required","сначала сохраните настройки квалификации."],
    ["Qualifying match count exceeds opponents","у каждого игрока меньше возможных соперников, чем назначенных матчей."],
    ["Qualifying schedule requires even total","с таким числом игроков нельзя назначить всем одинаковое число матчей. измените состав или количество матчей."],
    ["Qualifying stage not started","квалификация еще не запущена."],
    ["Qualifying matches not found","квалификационные матчи не найдены."],
    ["Qualifying matches incomplete","сначала завершите все квалификационные матчи."],
    ["Qualifying tiebreak required","на границе выхода в плей-офф осталось равенство. сначала проведите дополнительный матч."],
    ["Tournament has pending applications","сначала рассмотрите все ожидающие заявки."],
    ["Tournament already has matches","турнирные матчи уже созданы."],
    ["Tournament pair has active game","у одной из назначенных пар уже есть незавершенный матч. сначала завершите или закройте его."],
    ["Tournament match cannot be left","назначенный турнирный матч нельзя покинуть или закрыть."],
    ["Tournament registration closed","регистрация в этот турнир уже закрыта."],
    ["Registered profile required","в турнир можно добавить только зарегистрированного игрока."],
    ["Tournament is full","в турнире уже нет свободных мест."],
    ["Tournament already started","турнир уже начался."],
    ["Tournament already finished","завершенный турнир можно сохранить в истории или удалить навсегда."],
    ["Only finished tournament can be archived","в архив можно отправить только завершенный турнир."],
    ["Tournament already has games","нельзя перестроить сетку после создания турнирных игр."],
    ["Tournament can no longer be deleted","удалить можно только турнир, в котором еще не проводилась жеребьевка."],
    ["Tournament needs two players","для жеребьевки нужны хотя бы два участника."],
    ["Tournament needs even player count","для жеребьевки нужно четное число участников. добавьте еще одного игрока или уберите одного из списка."],
    ["Tournament application not found","заявка на этот турнир не найдена."],
    ["Tournament application not pending","эта заявка уже рассмотрена или отозвана."],
    ["Tournament application required","сначала игрок должен подать заявку на турнир."],
    ["Invalid application decision","неверное решение по заявке."],
    ["Announcement title required","введите заголовок объявления."],
    ["Announcement body required","введите текст объявления."],
    ["Invalid notification","уведомление не найдено."],
    ["Invalid school nick length","ник должен содержать от 1 до 48 символов."],
    ["Verified school nick required","для рейтинговой игры и участия в турнире сначала подтвердите школьный ник."],
    ["Authentication required","сначала нужно войти."],
  ];
  for (const [needle, text] of map) if (raw.includes(needle)) return text;
  return raw;
}

function switchView(name) {
  const changed = currentView !== name;
  if (name !== "game") setViewUrl(name);
  ["home","play","rating","tournament","admin","game"].forEach(v => {
    $(`${v}View`).classList.toggle("hidden", v !== name);
  });
  document.documentElement.removeAttribute("data-initial-view");
  currentView = name;
  document.body.dataset.view = name;
  $$(".main-nav [data-view]").forEach(button => {
    const active = button.dataset.view === name;
    button.classList.toggle("active", active);
    if (active) button.setAttribute("aria-current", "page");
    else button.removeAttribute("aria-current");
  });
  if (name === "play" && user) loadLobby();
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

function restoreSavedView(){
  if(currentView==="game")return;
  const requested=new URL(location.href).searchParams.get("view")||(TOURNAMENT_DEMO_ENABLED?"tournament":null);
  const allowed=new Set(["home","play","rating","tournament","admin"]);
  if(!requested||!allowed.has(requested))return;
  if(requested==="admin"&&!profile?.is_admin){
    switchView("home");
    return;
  }
  switchView(requested);
}

function setAuthTab(name) {
  const names = ["login","register","guest"];
  names.forEach(n => {
    if (n === name && !$(`${n}Tab`).classList.contains("active")) {
      const message = $(`${n}Message`);
      if (message) msg(message);
    }
    $(`${n}Tab`).classList.toggle("active", n === name);
    $(`${n}Pane`).classList.toggle("hidden", n !== name);
  });
}

function openAuth(tab="login") {
  for (const name of ["login", "register", "guest"]) {
    const message = $(`${name}Message`);
    if (message) msg(message, "");
  }
  for (const id of ["registerNick", "registerEmail", "registerPassword", "registerPassword2", "loginPassword"]) {
    const input = $(id);
    if (input) input.value = "";
  }
  setAuthTab(tab);
  $("authDialog").showModal();
}

function renderCreateOptions() {
  const rated = $("ratedGameMode");
  const casual = $("casualGameMode");
  const hint = $("createModeHint");
  if (!rated || !casual || !hint) return;
  const guest = profile?.account_type === "guest";
  const unverified = profile?.account_type === "registered" && !profile.school_verified;
  rated.disabled = guest || unverified;
  hint.classList.add("visually-hidden");
  if (guest || unverified) {
    casual.checked = true;
    hint.textContent = guest
      ? "гостевые матчи всегда проходят без рейтинга."
      : "рейтинговые матчи доступны после подтверждения школьного ника администратором.";
  } else {
    if (!rated.checked && !casual.checked) rated.checked = true;
    hint.textContent = "одна пара может провести до трех рейтинговых матчей за 24 часа.";
  }
}

function renderAccount() {
  $("authLoadingBox").classList.toggle("hidden",authReady);
  $("needAuthBox").classList.toggle("hidden",!authReady || !!user);
  $("lobby").classList.toggle("hidden",!authReady || !user);
  renderCreateOptions();
  $("adminNavBtn").classList.toggle("hidden",!profile?.is_admin);
  $("adminNotificationShell").classList.toggle("hidden",profile?.account_type!=="registered");

  const slot = $("accountSlot");
  slot.innerHTML = "";

  if (!authReady) {
    const loading = document.createElement("button");
    loading.type = "button";
    loading.disabled = true;
    loading.textContent = "восстанавливаем вход…";
    slot.appendChild(loading);
    return;
  }

  if (!user) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.textContent = "войти";
    btn.addEventListener("click", () => openAuth("login"));
    slot.appendChild(btn);
    return;
  }

  if (!profile) {
    const loading = document.createElement("button");
    loading.type = "button";
    loading.disabled = true;
    loading.textContent = "загружаем профиль…";
    slot.appendChild(loading);
    return;
  }

  const btn = document.createElement("button");
  btn.type = "button";
  if (profile.avatar_emoji) {
    const avatar = document.createElement("span");
    avatar.className = "account-avatar";
    avatar.textContent = profile.avatar_emoji;
    btn.appendChild(avatar);
  }
  const accountName = document.createElement("span");
  accountName.className = "account-name";
  accountName.textContent = profile.display_name;
  btn.appendChild(accountName);
  if(profile.account_type === "registered" && !profile.school_verified){
    const warning = document.createElement("span");
    warning.className = "account-warning-badge";
    warning.textContent = "!";
    warning.setAttribute("aria-label","ник ожидает проверки");
    warning.title = "ник ожидает проверки";
    btn.appendChild(warning);
  }
  btn.addEventListener("click", () => {
    $("profileAvatar").textContent = profile.avatar_emoji || "🍏";
    $("profileAvatar").classList.remove("hidden");
    $("profileName").textContent = profile.display_name;
    $("profileEmail").textContent = profile.account_type === "guest"
      ? "гостевой аккаунт без email"
      : (user.email || "");
    $("profileStatus").textContent = profile.account_type === "guest"
      ? "гость: доступны игры без рейтинга; рейтинг и турниры недоступны"
      : profile.school_verified
        ? ""
        : "школьный ник ожидает подтверждения администратора";
    $("profileStatus").classList.toggle("hidden",profile.account_type === "registered" && profile.school_verified);
    $("openPlayerProfileBtn").classList.toggle("hidden",profile.account_type!=="registered");
    $("profileDialog").showModal();
  });
  slot.appendChild(btn);
}

async function fetchProfile(userId) {
  let lastError = null;
  for (let attempt=0;attempt<3;attempt++) {
    const {data,error} = await supabase.from("profiles")
      .select("user_id,display_name,account_type,school_verified,is_admin,avatar_emoji,rating,rated_games,rated_wins,rated_losses,created_at")
      .eq("user_id",userId).maybeSingle();
    if (!error && data) return data;
    lastError = error;
    if (attempt<2) await wait(350*(attempt+1));
  }
  if (lastError) console.error(lastError);
  return null;
}

async function register() {
  const nick = cleanName($("registerNick").value);
  const email = $("registerEmail").value.trim();
  const pass = $("registerPassword").value;
  const pass2 = $("registerPassword2").value;

  if (!nick || !email || !pass) return msg($("registerMessage"),"заполните все поля.","error");
  if (pass.length < 8) return msg($("registerMessage"),"пароль должен содержать минимум 8 символов.","error");
  if (pass !== pass2) return msg($("registerMessage"),"пароли не совпадают.","error");

  $("registerBtn").disabled = true;
  try {
    const {data:available,error:checkError} = await supabase.rpc("is_school_nick_available",{p_nick:nick});
    if (checkError) throw checkError;
    if (!available) throw new Error("School nick already registered");

    const {data,error} = await supabase.auth.signUp({
      email,
      password: pass,
      options: { data: { school_nick: nick } }
    });
    if (error) throw error;

    if (data.session) {
      msg($("registerMessage"),"аккаунт создан.","success");
      $("authDialog").close();
    } else {
      msg($("registerMessage"),"аккаунт создан. подтвердите email по письму, затем войдите.","success");
    }
  } catch (e) {
    msg($("registerMessage"),humanError(e),"error");
  } finally {
    $("registerBtn").disabled = false;
  }
}

async function login() {
  const email = $("loginEmail").value.trim();
  const password = $("loginPassword").value;
  if (!email || !password) return msg($("loginMessage"),"введите email и пароль.","error");

  $("loginBtn").disabled = true;
  try {
    const {error} = await supabase.auth.signInWithPassword({email,password});
    if(error)throw error;
    $("authDialog").close();
  } catch(e) {
    msg($("loginMessage"),humanError(e),"error");
  } finally {
    $("loginBtn").disabled = false;
  }
}

function showPasswordDialog(update=false){
  $("passwordRequestPane").classList.toggle("hidden",update);
  $("passwordUpdatePane").classList.toggle("hidden",!update);
  if($("authDialog").open)$("authDialog").close();
  if(!$("passwordDialog").open)$("passwordDialog").showModal();
}

async function sendPasswordLink(){
  const email=$("passwordEmail").value.trim();
  if(!$("passwordEmail").checkValidity()||!email)
    return msg($("passwordRequestMessage"),"укажите корректный email.","error");
  const button=$("sendPasswordLinkBtn");button.disabled=true;
  try{
    const redirectTo=location.origin+location.pathname;
    const {error}=await supabase.auth.resetPasswordForEmail(email,{redirectTo});
    if(error)throw error;
    msg($("passwordRequestMessage"),"если аккаунт с таким email существует, письмо со ссылкой придет на почту.","success");
  }catch(e){msg($("passwordRequestMessage"),humanError(e),"error");}
  finally{button.disabled=false;}
}

async function updatePassword(){
  const password=$("newPassword").value;
  if(password.length<8)return msg($("passwordUpdateMessage"),"пароль должен содержать минимум 8 символов.","error");
  if(password!==$("newPassword2").value)return msg($("passwordUpdateMessage"),"пароли не совпадают.","error");
  const button=$("updatePasswordBtn");button.disabled=true;
  try{
    const {error}=await supabase.auth.updateUser({password});
    if(error)throw error;
    $("newPassword").value="";$("newPassword2").value="";
    msg($("passwordUpdateMessage"),"пароль изменен. теперь можно войти с новым паролем.","success");
    history.replaceState(null,"",location.pathname);
  }catch(e){msg($("passwordUpdateMessage"),humanError(e),"error");}
  finally{button.disabled=false;}
}

async function guestLogin() {
  $("guestBtn").disabled = true;
  guestSetupInProgress = true;
  try {
    const {data,error} = await supabase.auth.signInAnonymously();
    if (error) throw error;
    const {error:claimError} = await supabase.rpc("claim_random_guest");
    if (claimError) {
      await supabase.auth.signOut();
      throw claimError;
    }
    await handleSession(data.session);
    $("authDialog").close();
  } catch(e) {
    msg($("guestMessage"),humanError(e),"error");
  } finally {
    guestSetupInProgress = false;
    $("guestBtn").disabled = false;
  }
}

async function logout() {
  if (profile?.account_type === "guest") {
    const confirmed = window.confirm("выйти из гостевого профиля? восстановить его не получится. комнаты, в которых бой еще не начался, будут освобождены.");
    if (!confirmed) return;
    try {
      const {data:rowsData,error:rowsError}=await supabase.rpc("list_active_games");
      if(rowsError)throw rowsError;
      const rows=rowsData||[];
      for (const row of rows.filter(item => item.is_participant)) {
        if (row.player1_id === user.id && ["waiting","placing"].includes(row.status)) {
          const {error} = await supabase.rpc("cancel_game",{p_game_id:row.id});
          if (error) throw error;
        } else if (row.player2_id === user.id && row.status === "placing") {
          const {error} = await supabase.rpc("leave_game",{p_game_id:row.id});
          if (error) throw error;
        }
      }
    } catch (error) {
      alert(`не удалось освободить гостевые комнаты: ${humanError(error)}`);
      return;
    }
  }
  if (realtimeChannel) await supabase.removeChannel(realtimeChannel);
  if (lobbyChannel) await supabase.removeChannel(lobbyChannel);
  realtimeChannel = null;
  lobbyChannel = null;
  game = null;
  spectatorMode = false;
  setGameUrl(null);
  await supabase.auth.signOut();
  $("profileDialog").close();
  switchView("home");
}

async function loadLobby() {
  if (!user) return;
  await Promise.all([loadActiveGames(),loadMatchHistory()]);
}

async function loadMatchHistory() {
  if (!user) return [];
  const requestedUserId = user.id;
  const generation = ++matchHistoryGeneration;
  const {data,error} = await supabase.rpc("list_match_history");
  if (!user || user.id!==requestedUserId || generation!==matchHistoryGeneration) return [];
  if (error) {
    console.error(error);
    matchHistoryCache = [];
  } else {
    matchHistoryCache = data || [];
  }
  renderMatchHistory();
  return matchHistoryCache;
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

  const historyRows = [...matchHistoryCache].sort((a,b) => new Date(b.finished_at) - new Date(a.finished_at));
  historyRows.slice(0,3).forEach(match => wrap.appendChild(renderItem(match)));
  historyRows.slice(3).forEach(match => moreList.appendChild(renderItem(match)));

  const hasMore = historyRows.length > 3;
  more.classList.toggle("hidden",!hasMore);
  if (!hasMore) more.open = false;
  $("matchHistoryEmpty").classList.toggle("hidden",matchHistoryCache.length > 0);
}

async function openCompletedMatch(match,target=null){
  if(!match?.game_id||target?.dataset.busy==="true")return;
  if(target){target.dataset.busy="true";target.setAttribute("aria-busy","true");}
  try{
    const {data,error}=await supabase.from("games").select("*").eq("id",match.game_id).maybeSingle();
    if(error)throw error;
    if(!data||data.status!=="finished")throw new Error("завершенный матч не найден");
    if(![data.player1_id,data.player2_id].includes(user?.id)){
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
  if (!user) return [];
  const requestedUserId = user.id;
  const generation = ++activeGamesGeneration;
  const {data,error} = await supabase.rpc("list_active_games");

  if (!user || user.id!==requestedUserId || generation!==activeGamesGeneration) return [];
  if (error) { console.error(error); return []; }
  activeGamesCache = data || [];
  const playerIds = [...new Set(activeGamesCache.flatMap(row => [row.player1_id,row.player2_id]).filter(Boolean))];
  profilesCache = new Map();
  if (playerIds.length) {
    const {data:players,error:playersError} = await supabase.from("profiles")
      .select("user_id,account_type,avatar_emoji")
      .in("user_id",playerIds);
    if (!user || user.id!==requestedUserId || generation!==activeGamesGeneration) return [];
    if (playersError) console.error(playersError);
    (players || []).forEach(player => profilesCache.set(player.user_id,player));
  }
  renderActiveGames();
  return activeGamesCache;
}

function playerLabel(playerId,name) {
  const avatar = profilesCache.get(playerId)?.avatar_emoji;
  return avatar ? `${avatar} ${name}` : name;
}

function scheduleLobbyRefresh() {
  clearTimeout(lobbyRefreshTimer);
  lobbyRefreshTimer = setTimeout(() => loadLobby(),150);
}

async function subscribeToLobby() {
  if (!supabase || !user) return;
  if (lobbyChannel) await supabase.removeChannel(lobbyChannel);
  lobbyChannel = supabase.channel(`lobby-${user.id}`)
    .on("postgres_changes",{event:"*",schema:"public",table:"games"},scheduleLobbyRefresh)
    .subscribe();
}

function addMatchFlag(wrap,text,className="") {
  const flag = document.createElement("span");
  flag.className = `match-flag${className ? ` ${className}` : ""}`;
  flag.textContent = text;
  wrap.appendChild(flag);
}

function activePairGameWith(opponentId,excludeGameId=null) {
  return activeGamesCache.find(row =>
    row.id !== excludeGameId
    && row.game_type !== "tournament"
    && row.is_participant
    && ["placing","playing","paused"].includes(row.status)
    && [row.player1_id,row.player2_id].includes(opponentId)
  ) || null;
}

function renderActiveGames() {
  let rows = activeGamesCache;
  if (activeFilter === "waiting") rows = rows.filter(r => r.status === "waiting");
  if (activeFilter === "playing") rows = rows.filter(r => ["placing","playing","paused"].includes(r.status));
  if (activeFilter === "tournament") rows = rows.filter(r => r.game_type === "tournament");
  if (activeFilter === "mine") rows = rows.filter(r => r.is_participant);

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
      const myReady = row.player1_id === user.id ? row.player1_ready : row.player2_ready;
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
      && row.game_type === "rated" && profile?.account_type === "registered"
      && !profile.school_verified;
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

    const actions = document.createElement("div");
    actions.className = "active-game-actions";

    if (row.is_participant) {
      const resume = document.createElement("button");
      resume.type = "button";
      resume.className = "primary";
      const myReady = row.player1_id === user.id ? row.player1_ready : row.player2_ready;
      resume.textContent = row.status === "placing" && !myReady ? "припрятать урожай" : "вернуться";
      resume.addEventListener("click",() => openGame(row));
      actions.appendChild(resume);

      const canClose = row.game_type !== "tournament" && row.player1_id === user.id && ["waiting","placing"].includes(row.status);
      const canLeave = row.game_type !== "tournament" && row.player2_id === user.id && row.status === "placing";
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
        const warning=document.createElement("small");
        warning.className="join-verification-warning hidden";
        warning.setAttribute("role","status");
        const icon=document.createElement("i");
        icon.className="fas fa-exclamation-triangle";
        icon.setAttribute("aria-hidden","true");
        warning.append(icon,document.createTextNode(" для участия нужен подтвержденный школьный ник"));
        join.addEventListener("click",()=>warning.classList.remove("hidden"));
        const stack=document.createElement("div");
        stack.className="join-action-stack";
        stack.append(join,warning);
        actions.appendChild(stack);
      } else if (existingPairGame) {
        join.disabled = true;
        join.classList.add("join-unavailable");
        join.title = "у вас уже есть незавершенный матч с этим игроком";
      } else {
        join.addEventListener("click",() => joinPublicGame(row,join));
      }
      if (!unverifiedRatedJoin) actions.appendChild(join);
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
    button.classList.toggle("active",button.dataset.gameFilter === activeFilter);
  });
}

async function createGame() {
  if (createGameInProgress || !user) return;
  createGameInProgress = true;
  msg($("createMessage"),"");
  const button = $("createGameBtn");
  const oldText = button.textContent;
  button.disabled = true;
  button.textContent = "создаем…";
  const slowTimer = setTimeout(()=>msg($("createMessage"),"соединение медленное, продолжаем ждать. повторно нажимать не нужно."),2500);
  const requestedType = profile?.account_type === "guest" || !$("ratedGameMode").checked ? "casual" : "rated";
  try {
    const requestId = getPendingCreateRequest(requestedType);
    const {data,error} = await supabase.rpc("create_game",{p_request_id:requestId,p_game_type:requestedType});
    if (error) throw error;
    await openGame(data);
    clearPendingCreateRequest(requestedType);
  } catch(e) {
    msg($("createMessage"),humanError(e),"error");
  } finally {
    clearTimeout(slowTimer);
    createGameInProgress = false;
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
    const {data,error} = await supabase.rpc("join_public_game",{p_game_id:gameId});
    if (error) throw error;
    if (requestedType === "rated" && data.game_type !== "rated") {
      const reason = data.rating_skip_reason === "pair_daily_limit"
        ? "вы уже сыграли три рейтинговых матча с этим соперником за последние 24 часа. этот матч пройдет без рейтинга."
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

async function openGame(row) {
  spectatorMode = false;
  game = row;
  placement = loadPlacementDraft(game.id);
  opponentFleet = null;
  setGameUrl(game.id,"game");
  $("placementPanel").classList.add("hidden");
  $("battlePanel").classList.add("hidden");
  renderRoom();
  switchView("game");
  subscribeToGame();
  await refreshGame();
}

async function observeGame(row,button=null) {
  const watchable = ["playing","paused"].includes(row.status);
  if (!watchable) return;
  if (button?.dataset.busy==="true") return;
  const oldText = button?.textContent;
  if (button) {
    button.dataset.busy = "true";
    button.disabled = true;
    button.textContent = "открываем…";
  }
  spectatorMode = true;
  game = row;
  opponentFleet = null;
  setGameUrl(game.id,"watch");
  $("placementPanel").classList.add("hidden");
  $("battlePanel").classList.add("hidden");
  renderRoom();
  switchView("game");
  subscribeToGame();
  await refreshGame();
}

async function cancelGame(gameId=game?.id) {
  if (!gameId) return;
  if (!window.confirm("закрыть эту комнату? вернуться в нее после этого будет нельзя.")) return;
  try {
    const {error} = await supabase.rpc("cancel_game",{p_game_id:gameId});
    if (error) throw error;

    if (game?.id === gameId) {
      clearPlacementDraft(gameId);
      if (realtimeChannel) await supabase.removeChannel(realtimeChannel);
      realtimeChannel = null;
      game = null;
      spectatorMode = false;
      setGameUrl(null);
      switchView("play");
    } else {
      await loadLobby();
    }
  } catch(e) {
    alert(humanError(e));
  }
}

async function leaveGame(gameId=game?.id) {
  if (!gameId) return;
  if (!window.confirm("выйти из этой комнаты? создатель сможет дождаться другого соперника.")) return;
  try {
    const {error} = await supabase.rpc("leave_game",{p_game_id:gameId});
    if (error) throw error;

    if (game?.id === gameId) {
      clearPlacementDraft(gameId);
      if (realtimeChannel) await supabase.removeChannel(realtimeChannel);
      realtimeChannel = null;
      game = null;
      spectatorMode = false;
      setGameUrl(null);
      switchView("play");
    } else {
      await loadLobby();
    }
  } catch(e) {
    alert(humanError(e));
  }
}

async function surrenderGame() {
  if (!game?.id || spectatorMode || game.status !== "playing" || surrenderInProgress) return;
  if (!window.confirm("сдаться? матч завершится победой соперника. отменить это действие будет нельзя.")) return;

  surrenderInProgress = true;
  const button = $("surrenderGameBtn");
  button.disabled = true;
  button.textContent = "завершаем матч…";
  try {
    const {data,error} = await supabase.rpc("surrender_game",{p_game_id:game.id});
    if (error) throw error;
    game = data;
    await refreshGame();
    await loadLobby();
  } catch(e) {
    await refreshGame();
    if (!(game?.status === "finished" && game.surrendered_by === user.id)) {
      alert(humanError(e));
    }
  } finally {
    surrenderInProgress = false;
    button.disabled = false;
    button.textContent = "сдаться";
    if (game) renderRoom();
  }
}

function exitPreGame(row=game) {
  if (!row) return;
  if (row.player1_id === user.id) return cancelGame(row.id);
  if (row.player2_id === user.id) return leaveGame(row.id);
}

function statusLabel(status) {
  return ({waiting:"ждет соперника",placing:"расстановка",playing:"идет игра",paused:"приостановлена",finished:"завершена",cancelled:"отменена"})[status] || status;
}

function renderRoom() {
  $("gameView").dataset.gameStatus = game.status;
  $("gameTypeBadge").textContent = game.game_type === "rated" ? "рейтинговая игра" : game.game_type === "tournament" ? "турнирный матч" : "без рейтинга";
  $("player1Name").textContent = game.player1_name || "—";
  $("player2Name").textContent = game.player2_name || "ожидаем игрока";
  const player1Profile = profilesCache.get(game.player1_id);
  const player2Profile = profilesCache.get(game.player2_id);
  $("player1Avatar").textContent = player1Profile?.avatar_emoji || "";
  $("player2Avatar").textContent = player2Profile?.avatar_emoji || "";
  $("player1Avatar").classList.toggle("hidden",!player1Profile?.avatar_emoji);
  $("player2Avatar").classList.toggle("hidden",!player2Profile?.avatar_emoji);
  $("player1Ready").textContent = game.player1_ready ? "готов" : "не готов";
  $("player2Ready").textContent = game.player2_ready ? "готов" : "не готов";
  const canClose = !spectatorMode && game.game_type !== "tournament" && game.player1_id === user.id && ["waiting","placing"].includes(game.status);
  const canLeave = !spectatorMode && game.game_type !== "tournament" && game.player2_id === user.id && game.status === "placing";
  const canSurrender = !spectatorMode
    && [game.player1_id,game.player2_id].includes(user.id)
    && game.status === "playing";
  const backGoesBelow = !spectatorMode && ["waiting","placing"].includes(game.status);
  const backButton = $("backLobbyBtn");
  const backTarget = backGoesBelow ? $("gameRoomActions") : $("gamePrimaryButtons");
  if (backButton.parentElement !== backTarget) backTarget.prepend(backButton);
  $("closeGameBtn").classList.toggle("hidden",!(canClose || canLeave));
  $("closeGameBtn").textContent = canClose ? "закрыть комнату" : "выйти из комнаты";
  $("gameRoomActions").classList.toggle("hidden",!(canClose || canLeave || backGoesBelow));
  $("surrenderGameBtn").classList.toggle("hidden",!canSurrender);
  $("battleBadge").classList.toggle("hidden",!["playing","paused","finished"].includes(game.status));
  $("surrenderGameBtn").disabled = surrenderInProgress;

  if (game.status === "waiting") {
    msg($("roomMessage"),"ваша новая грядка уже готова — осталось дождаться соперника.");
  } else if (game.status === "placing") {
    msg($("roomMessage"),"");
  } else if (game.status === "playing") {
    msg($("roomMessage"),"");
  } else if (game.status === "paused") {
    msg($("roomMessage"),"матч приостановлен и ожидает решения администратора.");
  } else if (game.status === "finished") {
    msg($("roomMessage"),"");
  } else if (game.status === "cancelled") {
    msg($("roomMessage"),game.admin_cancelled_by
      ? "матч закрыт администратором без победителя и изменения рейтинга."
      : "комната закрыта создателем.");
  }
}

async function loadRoomProfiles() {
  const ids = [game?.player1_id,game?.player2_id].filter(Boolean);
  if (!ids.length) return;
  const {data,error} = await supabase.from("profiles")
    .select("user_id,account_type,avatar_emoji")
    .in("user_id",ids);
  if (error) return console.error(error);
  (data || []).forEach(player => profilesCache.set(player.user_id,player));
}

function isMeReady() {
  return game.player1_id === user.id ? game.player1_ready : game.player2_ready;
}

async function refreshGame() {
  if(refreshGamePromise){
    refreshGameQueued=true;
    return refreshGamePromise;
  }
  refreshGamePromise=(async()=>{
    do{
      refreshGameQueued=false;
      await refreshGameOnce();
    }while(refreshGameQueued);
  })();
  try{
    await refreshGamePromise;
  }finally{
    refreshGamePromise=null;
  }
}

async function refreshGameOnce() {
  if (!game?.id || !user) return;
  const requestedGameId=game.id;
  const {data,error} = await supabase.from("games").select("*").eq("id",requestedGameId).single();
  if (error) {
    console.error(error);
    if (spectatorMode) {
      alert("этот матч больше недоступен для наблюдения.");
      setGameUrl(null);
      switchView("play");
    }
    return;
  }
  if(!game||game.id!==requestedGameId)return;
  game = data;
  await loadRoomProfiles();
  if(!game||game.id!==requestedGameId)return;
  renderRoom();

  if (spectatorMode) {
    $("placementPanel").classList.add("hidden");
    if (!["playing","paused","finished"].includes(game.status)) {
      $("battlePanel").classList.add("hidden");
      return;
    }
    await refreshSpectatorData();
    renderSpectatorBattle();
    $("battlePanel").classList.remove("hidden");
    lastGameRefreshAt=Date.now();
    return;
  }

  if (game.status === "waiting") {
    $("placementPanel").classList.add("hidden");
    $("battlePanel").classList.add("hidden");
    return;
  }

  if (game.status === "cancelled") {
    $("placementPanel").classList.add("hidden");
    $("battlePanel").classList.add("hidden");
    return;
  }

  if (game.status === "paused" && game.pause_reason === "placement_timeout") {
    $("placementPanel").classList.remove("hidden");
    $("battlePanel").classList.add("hidden");
    renderPlacement();
    lockPlacement();
    msg($("placementMessage"),"расстановка приостановлена и ожидает решения администратора.","error");
    return;
  }

  if (game.status === "placing") {
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

  if (["playing","paused","finished"].includes(game.status)) {
    $("placementPanel").classList.add("hidden");
    await refreshBattleData();
    renderBattle();
    $("battlePanel").classList.remove("hidden");
    lastGameRefreshAt=Date.now();
  }
}

function coordsToCell(col,row){ return `${COLS[col]}${row+1}`; }
function cellToCoords(cell){ return {col:COLS.indexOf(cell[0]),row:Number(cell.slice(1))-1}; }

const SHIP_SKINS = {1:"mushroom",2:"eggplant",3:"carrot",4:"celery"};
let vegetablesEnabled = true;
try { vegetablesEnabled = localStorage.getItem("fruitkog-vegetables") !== "off"; } catch {}
function syncVegetableMode(){
  document.body.classList.toggle("vegetables-on",vegetablesEnabled);
  document.querySelectorAll("[data-vegetable-toggle]").forEach(button=>{
    const label=vegetablesEnabled?"отключить овощизм":"включить овощизм";
    button.setAttribute("aria-label",label);button.title=label;
    button.setAttribute("aria-pressed",String(vegetablesEnabled));
  });
}
// Whole-ship artwork uses the same responsive cell size as the board.
// Call only with fleets already visible to this player.
function addShipSkin(board,ship,preview=false,valid=true){
  if(!ship.cells?.length||!SHIP_SKINS[ship.length])return;
  const points=ship.cells.map(cellToCoords);
  const col=Math.min(...points.map(p=>p.col)),row=Math.min(...points.map(p=>p.row));
  const horizontal=ship.length>1&&points.every(p=>p.row===row);
  const sprite=document.createElement("span");
  sprite.className="vegetable-ship"+(preview?" vegetable-preview":"")+(!valid?" invalid":"");
  sprite.setAttribute("aria-hidden","true");
  sprite.setAttribute("data-length",String(ship.length));
  sprite.style.setProperty("--ship-col",col);
  sprite.style.setProperty("--ship-row",row);
  sprite.style.setProperty("--ship-length",ship.length);
  sprite.style.setProperty("--ship-width",horizontal?ship.length:1);
  sprite.style.setProperty("--ship-height",horizontal?1:ship.length);
  if(horizontal)sprite.classList.add("horizontal");
  if(ship.sunk&&!preview)sprite.classList.add("vegetable-sunk");
  const img=document.createElement("img");
  img.src=`./assets/ships/${SHIP_SKINS[ship.length]}.png?v=108`;
  img.alt="";img.draggable=false;
  sprite.append(img);board.append(sprite);
}
function renderFleetSkins(board,ships,boardShots=[]){
  board.querySelectorAll(".vegetable-ship").forEach(el=>el.remove());
  const hits=new Set(boardShots.filter(s=>["hit","sunk","win"].includes(s.result)).map(s=>s.cell));
  (ships||[]).forEach(ship=>{
    const sunk=ship.cells.length>0&&ship.cells.every(cell=>hits.has(cell));
    addShipSkin(board,{...ship,sunk});
    if(sunk)ship.cells.forEach(cell=>board.querySelector(`[data-cell="${cell}"]`)?.classList.add("sunk-ship"));
  });
}
// Reconstruct only fully sunk ships from public shot results, never hidden fleets.
function sunkShipsFromShots(boardShots){
  const hits=new Set(boardShots.filter(s=>["hit","sunk","win"].includes(s.result)).map(s=>s.cell));
  const seen=new Set(),ships=[];
  boardShots.filter(s=>["sunk","win"].includes(s.result)).forEach(shot=>{
    if(seen.has(shot.cell))return;
    const cells=[],queue=[shot.cell];seen.add(shot.cell);
    while(queue.length){
      const cell=queue.shift();cells.push(cell);
      const {col,row}=cellToCoords(cell);
      [[col-1,row],[col+1,row],[col,row-1],[col,row+1]].forEach(([c,r])=>{
        if(c<0||c>9||r<0||r>9)return;
        const next=coordsToCell(c,r);
        if(hits.has(next)&&!seen.has(next)){seen.add(next);queue.push(next);}
      });
    }
    if(SHIP_SKINS[cells.length])ships.push({length:cells.length,cells});
  });
  return ships;
}
function flashInvalidPlacement(cells){
  clearPlacementPreview();
  const board=$("placementBoard");
  (cells||[]).forEach(cell=>board.querySelector(`[data-cell="${cell}"]`)?.classList.add("candidate-invalid"));
}

function buildBoard(container,onClick) {
  container._onCellClick = onClick;
  if (container.querySelectorAll(".board-cell").length === 100) return;
  container.innerHTML = "";
  const corner = document.createElement("div"); corner.className = "board-corner"; container.appendChild(corner);
  if(["placementBoard","ownBoard","enemyBoard"].includes(container.id)){
    const toggle=document.createElement("button");toggle.type="button";
    toggle.className="vegetable-toggle";toggle.dataset.vegetableToggle="";
    const leaf=document.createElement("i");leaf.className="fa-solid fa-leaf";leaf.setAttribute("aria-hidden","true");
    toggle.append(leaf);corner.append(toggle);
    toggle.addEventListener("click",()=>{
      vegetablesEnabled=!vegetablesEnabled;
      try {localStorage.setItem("fruitkog-vegetables",vegetablesEnabled?"on":"off");} catch {}
      syncVegetableMode();
    });
    syncVegetableMode();
  }
  COLS.forEach(c => { const l=document.createElement("div");l.className="board-label board-label-column";l.textContent=c;container.appendChild(l); });
  for(let r=0;r<10;r++){
    const rl=document.createElement("div");rl.className="board-label board-label-row";rl.textContent=String(r+1);container.appendChild(rl);
    for(let c=0;c<10;c++){
      const cell=coordsToCell(c,r);
      const b=document.createElement("button");b.type="button";b.className="board-cell";b.dataset.cell=cell;b.dataset.row=String(r);b.dataset.col=String(c);b.setAttribute("aria-label",cell);
      b.addEventListener("click",event=>container._onCellClick?.(cell,event));
      container.appendChild(b);
    }
  }
}

function resetBoard(container) {
  container.querySelectorAll(".vegetable-ship").forEach(el=>el.remove());
  container.querySelectorAll(".board-cell").forEach(cell=>{
    cell.className="board-cell";
    cell.disabled=false;
    cell.replaceChildren();
    cell.removeAttribute("aria-busy");
    delete cell.dataset.fleetIndex;
  });
}

function fleetCells(){ return new Set(placement.ships.flatMap(s=>s.cells)); }

function candidateCells(start,length,orientation=placement.orientation){
  const {col,row}=cellToCoords(start), out=[];
  for(let i=0;i<length;i++){
    const c=orientation==="h"?col+i:col;
    const r=orientation==="v"?row+i:row;
    if(c>=10||r>=10)return null;
    out.push(coordsToCell(c,r));
  }
  return out;
}

function canPlace(cells,ignoreFleetIndex=null){
  if(!cells)return false;
  const occupied=new Set(
    placement.ships
      .filter(ship=>ship.fleetIndex!==ignoreFleetIndex)
      .flatMap(ship=>ship.cells)
  );
  for(const cell of cells){
    if(occupied.has(cell))return false;
    const {col,row}=cellToCoords(cell);
    for(let dr=-1;dr<=1;dr++)for(let dc=-1;dc<=1;dc++){
      const c=col+dc,r=row+dr;
      if(c<0||c>=10||r<0||r>=10)continue;
      if(occupied.has(coordsToCell(c,r)))return false;
    }
  }
  return true;
}

function nextUnused(preferredLength=null){
  const used=new Set(placement.ships.map(s=>s.fleetIndex));
  if(preferredLength!==null){
    const same=FLEET.findIndex((ship,index)=>ship.length===preferredLength&&!used.has(index));
    if(same!==-1)return same;
  }
  for(let i=0;i<FLEET.length;i++)if(!used.has(i))return i;
  return null;
}

function shipAtCell(cell){
  return placement.ships.find(ship=>ship.cells.includes(cell)) || null;
}

function shipOrientation(ship){
  if(!ship || ship.length===1)return placement.orientation;
  return ship.cells[0][0]===ship.cells[1][0]?"v":"h";
}

function clearPlacementPreview(){
  $("placementBoard").querySelectorAll(".vegetable-preview").forEach(el=>el.remove());
  $("placementBoard").querySelectorAll(".candidate-valid,.candidate-invalid")
    .forEach(cell=>cell.classList.remove("candidate-valid","candidate-invalid"));
}

function cellsThrough(anchor,length,orientation,preferredOffset=0){
  const {col,row}=cellToCoords(anchor);
  const offsets=Array.from({length},(_,index)=>index)
    .sort((a,b)=>Math.abs(a-preferredOffset)-Math.abs(b-preferredOffset));
  return offsets.map(offset=>{
    const startCol=orientation==="h"?col-offset:col;
    const startRow=orientation==="v"?row-offset:row;
    if(startCol<0||startRow<0)return null;
    return candidateCells(coordsToCell(startCol,startRow),length,orientation);
  }).filter(Boolean);
}

function previewPlacement(start){
  clearPlacementPreview();
  if(game?.status!=="placing"||isMeReady()||placementDrag)return;
  const idx=placement.selectedShipIndex;
  if(idx===null||placement.ships.some(ship=>ship.fleetIndex===idx)||shipAtCell(start))return;
  const cells=candidateCells(start,FLEET[idx].length);
  const valid=canPlace(cells);
  if(cells)addShipSkin($("placementBoard"),{length:FLEET[idx].length,cells},true,valid);
  const previewCells=cells||[start];
  previewCells.forEach(cell=>{
    const button=$("placementBoard").querySelector(`[data-cell="${cell}"]`);
    if(button)button.classList.add(valid?"candidate-valid":"candidate-invalid");
  });
}

function rotatePlacedShip(fleetIndex,anchorCell=null){
  if(!game||game.status!=="placing"||isMeReady())return;
  const ship=placement.ships.find(item=>item.fleetIndex===fleetIndex);
  if(!ship)return;
  if(ship.length===1)return;
  const orientation=shipOrientation(ship)==="h"?"v":"h";
  const anchor=anchorCell||ship.cells[0];
  const preferred=Math.max(0,ship.cells.indexOf(anchor));
  const cells=cellsThrough(anchor,ship.length,orientation,preferred)
    .find(candidate=>canPlace(candidate,ship.fleetIndex));
  if(!cells)return flashInvalidPlacement(ship.cells);
  ship.cells=cells;
  placement.orientation=orientation;
  placement.selectedPlacedIndex=null;
  savePlacementDraft();
  msg($("placementMessage"),"");
  renderPlacement();
}

function cellFromPointer(event){
  const element=document.elementFromPoint(event.clientX,event.clientY);
  const cell=element?.closest?.("#placementBoard .board-cell");
  return cell?.dataset.cell||null;
}

function dragCandidate(ship,cell){
  if(!cell)return null;
  const orientation=shipOrientation(ship);
  const offset=Math.max(0,placementDrag?.grabOffset||0);
  const {col,row}=cellToCoords(cell);
  const startCol=orientation==="h"?col-offset:col;
  const startRow=orientation==="v"?row-offset:row;
  if(startCol<0||startRow<0)return null;
  return candidateCells(coordsToCell(startCol,startRow),ship.length,orientation);
}

function beginPlacementDrag(event,ship,cell){
  if(event.button!==0||isMeReady()||game?.status!=="placing")return;
  placementDrag={
    pointerId:event.pointerId,
    fleetIndex:ship.fleetIndex,
    grabOffset:Math.max(0,ship.cells.indexOf(cell)),
    startX:event.clientX,
    startY:event.clientY,
    moved:false,
    cells:null,
    valid:false,
  };
  event.currentTarget.setPointerCapture?.(event.pointerId);
}

function movePlacementDrag(event){
  if(!placementDrag||event.pointerId!==placementDrag.pointerId)return;
  if(!placementDrag.moved&&Math.hypot(event.clientX-placementDrag.startX,event.clientY-placementDrag.startY)<7)return;
  placementDrag.moved=true;
  event.preventDefault();
  clearPlacementPreview();
  const ship=placement.ships.find(item=>item.fleetIndex===placementDrag.fleetIndex);
  if(!ship)return;
  const cells=dragCandidate(ship,cellFromPointer(event));
  const valid=canPlace(cells,ship.fleetIndex);
  placementDrag.cells=cells;
  placementDrag.valid=valid;
  if(cells)addShipSkin($("placementBoard"),{length:ship.length,cells},true,valid);
  (cells||[]).forEach(cell=>{
    $("placementBoard").querySelector(`[data-cell="${cell}"]`)
      ?.classList.add(valid?"candidate-valid":"candidate-invalid");
  });
}

function endPlacementDrag(event){
  if(!placementDrag||event.pointerId!==placementDrag.pointerId)return;
  const drag=placementDrag;
  placementDrag=null;
  clearPlacementPreview();
  if(!drag.moved)return;
  suppressPlacementClick=true;
  setTimeout(()=>{suppressPlacementClick=false;},0);
  if(!drag.valid||!drag.cells)return;
  const ship=placement.ships.find(item=>item.fleetIndex===drag.fleetIndex);
  if(!ship)return;
  ship.cells=drag.cells;
  placement.selectedPlacedIndex=null;
  savePlacementDraft();
  msg($("placementMessage"),"");
  renderPlacement();
}

function cancelPlacementDrag(event){
  if(!placementDrag||event.pointerId!==placementDrag.pointerId)return;
  placementDrag=null;
  clearPlacementPreview();
}

function hoverPlacedShip(fleetIndex,active,relatedTarget=null){
  if(!active&&relatedTarget?.closest?.(`[data-fleet-index="${fleetIndex}"]`))return;
  $("placementBoard").querySelectorAll(`[data-fleet-index="${fleetIndex}"]`)
    .forEach(cell=>cell.classList.toggle("ship-hover",active));
}

function renderPalette(){
  const wrap=$("shipPalette");wrap.innerHTML="";
  const used=new Set(placement.ships.map(s=>s.fleetIndex));
  const names={4:"сельдерей",3:"морковь",2:"баклажан",1:"гриб"};
  [4,3,2,1].forEach(length=>{
    const available=FLEET.map((ship,index)=>({ship,index}))
      .filter(item=>item.ship.length===length&&!used.has(item.index));
    const selected=available.some(item=>item.index===placement.selectedShipIndex);
    const b=document.createElement("button");
    b.type="button";b.className="ship-choice";b.disabled=available.length===0;
    b.dataset.length=String(length);
    b.setAttribute("aria-label",`${names[length]}, осталось ${available.length}, ${length} клеток`);
    b.setAttribute("aria-pressed",String(selected));
    b.title=`${names[length]} · ${length} клеток`;
    if(!available.length)b.classList.add("used");
    if(selected)b.classList.add("active");
    const visual=document.createElement("span");visual.className="palette-visual";
    const art=document.createElement("img");
    art.className="palette-vegetable";art.src=`./assets/ships/${SHIP_SKINS[length]}.png?v=108`;
    art.alt="";art.draggable=false;visual.append(art);
    const preview=document.createElement("span");preview.className="ship-preview";
    for(let i=0;i<length;i++)preview.appendChild(document.createElement("i"));
    visual.append(preview);b.append(visual);
    const name=document.createElement("span");name.className="palette-name";name.textContent=names[length];b.append(name);
    const count=document.createElement("span");count.className="palette-count";count.textContent=`×${available.length}`;b.append(count);
    b.addEventListener("click",()=>{
      if(!available.length)return;
      if(selected)placement.orientation=placement.orientation==="h"?"v":"h";
      else placement.selectedShipIndex=available[0].index;
      placement.selectedPlacedIndex=null;
      savePlacementDraft();renderPlacement();
    });
    wrap.appendChild(b);
  });
}

function renderPlacement(){
  const savedScroll=window.scrollY;
  if(document.activeElement instanceof HTMLElement)document.activeElement.blur();
  $("placementBoard").innerHTML="";
  buildBoard($("placementBoard"),(cell,event)=>{
    const existing=shipAtCell(cell);
    if(existing){
      if(suppressPlacementClick)return;
      rotatePlacedShip(existing.fleetIndex,cell);
      return;
    }
    const idx=placement.selectedShipIndex;
    if(idx===null||placement.ships.some(s=>s.fleetIndex===idx))return;
    const cells=candidateCells(cell,FLEET[idx].length);
    if(!canPlace(cells))return previewPlacement(cell);
    placement.ships.push({fleetIndex:idx,length:FLEET[idx].length,cells});
    placement.selectedShipIndex=nextUnused(FLEET[idx].length);
    savePlacementDraft();
    msg($("placementMessage"),"");
    renderPlacement();
  });
  resetBoard($("placementBoard"));

  placement.ships.forEach(ship=>{
    ship.cells.forEach(cell=>{
      const button=$("placementBoard").querySelector(`[data-cell="${cell}"]`);
      if(!button)return;
      button.classList.add("ship");
      button.dataset.fleetIndex=String(ship.fleetIndex);
      button.addEventListener("pointerdown",event=>beginPlacementDrag(event,ship,cell));
      button.addEventListener("mouseenter",()=>hoverPlacedShip(ship.fleetIndex,true));
      button.addEventListener("mouseleave",event=>hoverPlacedShip(ship.fleetIndex,false,event.relatedTarget));
    });
  });
  $("placementBoard").querySelectorAll(".board-cell").forEach(button=>{
    button.addEventListener("mouseenter",()=>previewPlacement(button.dataset.cell));
  });
  $("placementBoard").onmouseleave=clearPlacementPreview;
  renderFleetSkins($("placementBoard"),placement.ships);
  renderPalette();
  $("placementCounter").textContent=`высажено ${placement.ships.length} из ${FLEET.length}`;
  $("readyBtn").disabled=placement.ships.length!==FLEET.length;
  if(window.scrollY!==savedScroll)window.scrollTo({top:savedScroll,behavior:"auto"});
}

function lockPlacement(){
  ["resetFleetBtn","readyBtn"].forEach(id=>$(id).disabled=true);
  $("placementBoard").querySelectorAll(".board-cell").forEach(b=>b.disabled=true);
  $("shipPalette").querySelectorAll("button").forEach(b=>b.disabled=true);
}
function unlockPlacement(){
  ["resetFleetBtn"].forEach(id=>$(id).disabled=false);
}

async function ready(){
  if(placement.ships.length!==FLEET.length||readyInProgress)return;
  readyInProgress=true;
  const payload=placement.ships.map(s=>({length:s.length,cells:s.cells})).sort((a,b)=>b.length-a.length);
  const button=$("readyBtn");
  button.textContent="сохраняем флот…";
  lockPlacement();
  const slowTimer=setTimeout(()=>msg($("placementMessage"),"соединение медленное, но флот сохранен в браузере. продолжаем ждать."),2500);
  try{
    const {data,error}=await supabase.rpc("ready_with_fleet",{p_game_id:game.id,p_ships:payload});
    if(error)throw error;
    game=data;
    await refreshGame();
  }catch(e){
    await refreshGame();
    if(game&&isMeReady())msg($("placementMessage"),"ваша расстановка зафиксирована. ждем соперника.","success");
    else msg($("placementMessage"),humanError(e),"error");
  }finally{
    clearTimeout(slowTimer);
    readyInProgress=false;
    button.textContent="грядка готова";
    if(game?.status==="placing"&&!isMeReady()){
      unlockPlacement();
      renderPlacement();
    }
  }
}

async function refreshBattleData(){
  let fleetQuery = supabase.from("fleets").select("owner_id,ships").eq("game_id",game.id);
  if (game.status !== "finished") fleetQuery = fleetQuery.eq("owner_id",user.id);
  const [fleetRes,shotsRes]=await Promise.all([
    fleetQuery,
    supabase.from("shots").select("*").eq("game_id",game.id).order("id",{ascending:true}),
  ]);
  const fleets = fleetRes.data || [];
  myFleet = fleets.find(fleet => fleet.owner_id === user.id) || null;
  opponentFleet = game.status === "finished"
    ? fleets.find(fleet => fleet.owner_id !== user.id) || null
    : null;
  shots=shotsRes.data||[];
}

async function refreshSpectatorData(){
  const requests = [
    supabase.from("shots").select("*").eq("game_id",game.id).order("id",{ascending:true}),
  ];
  if (game.status === "finished") {
    requests.push(supabase.from("fleets").select("owner_id,ships").eq("game_id",game.id));
  }
  const [shotsRes,fleetsRes] = await Promise.all(requests);
  shots = shotsRes.data || [];
  spectatorFleets = fleetsRes?.data || [];
}

function opponentName(){ return game.player1_id===user.id?game.player2_name:game.player1_name; }
const PRODUCE_BY_SHIP_LENGTH={1:"шампиньон",2:"баклажан",3:"морковь",4:"сельдерей"};

function foundProduceName(shot,allShots=shots){
  if(!shot?.cell)return "плод";
  const hitCells=new Set(allShots
    .filter(item=>item.shooter_id===shot.shooter_id
      && item.target_id===shot.target_id
      && ["hit","sunk","win"].includes(item.result))
    .map(item=>item.cell));
  if(!hitCells.has(shot.cell))return "плод";
  const found=new Set([shot.cell]);
  const queue=[shot.cell];
  while(queue.length){
    const current=queue.shift();
    const {col,row}=cellToCoords(current);
    [[col-1,row],[col+1,row],[col,row-1],[col,row+1]].forEach(([nextCol,nextRow])=>{
      if(nextCol<0||nextCol>9||nextRow<0||nextRow>9)return;
      const next=coordsToCell(nextCol,nextRow);
      if(hitCells.has(next)&&!found.has(next)){found.add(next);queue.push(next);}
    });
  }
  return PRODUCE_BY_SHIP_LENGTH[found.size]||"плод";
}

function resultLabel(shot,allShots=shots){
  if(!shot)return "ход";
  if(shot.result==="miss")return "мимо";
  if(shot.result==="hit")return "заметил плод";
  if(["sunk","win"].includes(shot.result))return `нашел «${foundProduceName(shot,allShots)}»`;
  return shot.result;
}

function finishedGameSummary(){
  if(game?.status!=="finished")return "";
  const winner=game.winner_id===game.player1_id?game.player1_name:game.player2_name;
  if(game.finish_reason==="surrender"){
    const surrendered=game.surrendered_by===game.player1_id?game.player1_name:game.player2_name;
    return `${surrendered} сдался. победитель: ${winner}.`;
  }
  return `победитель: ${winner}.`;
}

function renderShotHistory(shooterLabel){
  const result=$("battleHistoryResult");
  const summary=finishedGameSummary();
  result.textContent=summary;
  result.classList.toggle("hidden",!summary);
  $("shotLog").innerHTML="";
  $("shotLog").start=Math.max(shots.length,1);
  [...shots].reverse().forEach((shot,index)=>{
    const li=document.createElement("li");
    li.value=shots.length-index;
    li.textContent=`${shooterLabel(shot)}: ${shot.cell} — ${resultLabel(shot)}`;
    $("shotLog").appendChild(li);
  });
}

function appendHitMarker(cell){
  const marker=document.createElement("span");marker.className="hit-marker";marker.setAttribute("aria-hidden","true");
  const icon=document.createElement("i");icon.className="fa-solid fa-xmark";marker.append(icon);cell.append(marker);
}

function renderBattle(){
  $("shotBar").classList.remove("hidden");
  $("ownBoardTitle").textContent="ваша грядка";
  $("enemyBoardTitle").textContent="грядка соперника";
  buildBoard($("ownBoard"),null);
  buildBoard($("enemyBoard"),cell=>fire(cell));
  resetBoard($("ownBoard"));
  resetBoard($("enemyBoard"));

  const ownShots=shots.filter(s=>s.target_id===user.id);
  const enemyShots=shots.filter(s=>s.shooter_id===user.id);
  renderFleetSkins($("ownBoard"),myFleet?.ships,ownShots);
  renderFleetSkins($("enemyBoard"),game.status==="finished"?opponentFleet?.ships:sunkShipsFromShots(enemyShots),enemyShots);
  const own=new Set((myFleet?.ships||[]).flatMap(s=>s.cells));
  $("ownBoard").querySelectorAll(".board-cell").forEach(b=>{if(own.has(b.dataset.cell))b.classList.add("ship");});
  if (game.status === "finished") {
    const opponent = new Set((opponentFleet?.ships || []).flatMap(ship => ship.cells));
    $("enemyBoard").querySelectorAll(".board-cell").forEach(cell => {
      if (opponent.has(cell.dataset.cell)) cell.classList.add("ship");
    });
  }

  shots.forEach(s=>{
    const board=s.shooter_id===user.id?$("enemyBoard"):$("ownBoard");
    const b=board.querySelector(`[data-cell="${s.cell}"]`);
    if(!b)return;
    b.classList.remove("ship");
    b.classList.add(s.result==="miss"?"miss":"hit");b.disabled=true;
    if(s.result!=="miss")appendHitMarker(b);
  });

  const myTurn=game.status==="playing"&&game.current_turn===user.id;
  $("enemyBoard").querySelectorAll(".board-cell").forEach(b=>{
    if(!myTurn||shotInProgress||b.classList.contains("hit")||b.classList.contains("miss"))b.disabled=true;
  });
  $("shotHint").textContent=shotInProgress?"выстрел отправлен…":myTurn?"нажмите на клетку соперника":"ожидаем ход соперника";

  if(game.status==="finished"){
    $("turnTitle").textContent=game.winner_id===user.id?"вы победили":`${opponentName()} победил`;
    $("battleBadge").textContent=game.finish_reason==="surrender"
      ? (game.surrendered_by===user.id?"вы сдались":"соперник сдался")
      : "матч завершен";
  }else if(game.status==="paused"){
    $("turnTitle").textContent="матч приостановлен";$("battleBadge").textContent="ожидает администратора";
  }else if(myTurn){
    $("turnTitle").textContent="ваш ход";$("battleBadge").textContent="ваш ход";
  }else{
    $("turnTitle").textContent=`ходит ${opponentName()}`;$("battleBadge").textContent="ход соперника";
  }

  renderShotHistory(shot=>shot.shooter_id===user.id?"вы":opponentName());
}

function renderSpectatorBattle(){
  $("shotBar").classList.add("hidden");
  $("ownBoardTitle").textContent=`грядка: ${game.player1_name}`;
  $("enemyBoardTitle").textContent=`грядка: ${game.player2_name}`;
  buildBoard($("ownBoard"),null);
  buildBoard($("enemyBoard"),null);
  resetBoard($("ownBoard"));
  resetBoard($("enemyBoard"));

  if (game.status === "finished") {
    spectatorFleets.forEach(fleet => {
      const board = fleet.owner_id === game.player1_id ? $("ownBoard") : $("enemyBoard");
      renderFleetSkins(board,fleet.ships,shots.filter(s=>s.target_id===fleet.owner_id));
      const cells = new Set((fleet.ships || []).flatMap(ship => ship.cells));
      board.querySelectorAll(".board-cell").forEach(cell => {
        if (cells.has(cell.dataset.cell)) cell.classList.add("ship");
      });
    });
  }

  if(game.status!=="finished"){
    [game.player1_id,game.player2_id].forEach((owner,index)=>{
      const boardShots=shots.filter(s=>s.target_id===owner);
      renderFleetSkins($(index===0?"ownBoard":"enemyBoard"),sunkShipsFromShots(boardShots),boardShots);
    });
  }

  shots.forEach(shot => {
    const board = shot.target_id === game.player1_id ? $("ownBoard") : $("enemyBoard");
    const cell = board.querySelector(`[data-cell="${shot.cell}"]`);
    if (!cell) return;
    cell.classList.remove("ship");
    cell.classList.add(shot.result === "miss" ? "miss" : "hit");
    if(shot.result!=="miss")appendHitMarker(cell);
    cell.disabled = true;
  });

  $("ownBoard").querySelectorAll(".board-cell").forEach(cell => cell.disabled=true);
  $("enemyBoard").querySelectorAll(".board-cell").forEach(cell => cell.disabled=true);

  if (game.status === "finished") {
    const winner = game.winner_id === game.player1_id ? game.player1_name : game.player2_name;
    $("turnTitle").textContent=`победил ${winner}`;
    $("battleBadge").textContent=game.finish_reason==="surrender"?"завершен сдачей":"матч завершен";
  } else if (game.status === "paused") {
    $("turnTitle").textContent="матч приостановлен";
    $("battleBadge").textContent="ожидает администратора";
  } else {
    const turnName = game.current_turn === game.player1_id ? game.player1_name : game.player2_name;
    $("turnTitle").textContent=`ходит ${turnName}`;
    $("battleBadge").textContent="наблюдение";
  }

  renderShotHistory(shot=>shot.shooter_id===game.player1_id?game.player1_name:game.player2_name);
  msg($("battleMessage"),"");
}

async function fire(cell){
  if(shotInProgress||game?.status!=="playing"||game.current_turn!==user.id)return;
  if(shots.some(shot=>shot.shooter_id===user.id&&shot.cell===cell))return;
  shotInProgress=true;
  const pending=$("enemyBoard").querySelector(`[data-cell="${cell}"]`);
  pending?.classList.add("shot-pending");
  pending?.setAttribute("aria-busy","true");
  $("enemyBoard").querySelectorAll(".board-cell").forEach(item=>item.disabled=true);
  $("shotHint").textContent="выстрел отправлен…";
  msg($("battleMessage"),"");
  try{
    const {data,error}=await supabase.rpc("shoot",{p_game_id:game.id,p_cell:cell});
    if(error)throw error;
    await refreshGame();
  }catch(e){
    msg($("battleMessage"),humanError(e),"error");
  }finally{
    shotInProgress=false;
    if(game&&["playing","paused","finished"].includes(game.status))renderBattle();
  }
}

function scheduleGameRefresh(){
  clearTimeout(gameRefreshTimer);
  gameRefreshTimer=setTimeout(()=>{
    gameRefreshTimer=null;
    if(Date.now()-lastGameRefreshAt<350)return;
    refreshGame();
  },140);
}

function subscribeToGame(){
  if(realtimeChannel)supabase.removeChannel(realtimeChannel);
  realtimeChannel=supabase.channel(`game-${game.id}`)
    .on("postgres_changes",{event:"UPDATE",schema:"public",table:"games",filter:`id=eq.${game.id}`},scheduleGameRefresh)
    .on("postgres_changes",{event:"INSERT",schema:"public",table:"shots",filter:`game_id=eq.${game.id}`},scheduleGameRefresh)
    .subscribe();
}

function setGameUrl(id,mode="game"){
  const url=new URL(location.href);
  url.searchParams.delete("game");
  url.searchParams.delete("watch");
  url.searchParams.delete("view");
  if(id)url.searchParams.set(mode,id);
  history.replaceState(null,"",url);
}

async function restoreGame(){
  const url=new URL(location.href);
  const gameId=url.searchParams.get("game");
  const watchId=url.searchParams.get("watch");
  const id=gameId||watchId;
  if(!id||!user)return;
  const {data}=await supabase.from("games").select("*").eq("id",id).maybeSingle();
  const participant=data&&[data.player1_id,data.player2_id].includes(user.id);
  const canWatch=data&&(
    ["playing","paused","finished"].includes(data.status)
  );
  if(data&&((gameId&&participant)||(watchId&&canWatch))){
    spectatorMode=!!watchId&&!participant;
    if(participant&&watchId)setGameUrl(id,"game");
    game=data;
    if(participant)placement=loadPlacementDraft(id);
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

async function returnToLobby(){
  const channel=realtimeChannel;
  realtimeChannel=null;
  game=null;
  spectatorMode=false;
  setGameUrl(null);
  switchView("play");
  if(channel)await supabase.removeChannel(channel);
}

function tournamentStatusLabel(status){
  return ({
    draft:"черновик",
    registration:"регистрация",
    active:"идет турнир",
    finished:"завершен",
    cancelled:"отменен",
  })[status]||status;
}

function tournamentFormatLabel(format){
  return ({
    knockout:"плей-офф",
    qualifiers_playoff:"квалификация + плей-офф",
  })[format]||"формат еще не выбран";
}

function qualifierSummary(tournament){
  if(tournament?.tournament_format!=="qualifiers_playoff")return "";
  const matches=Number(tournament.qualifying_matches_per_player)||0;
  const playoff=Number(tournament.playoff_size)||0;
  if(!matches||!playoff)return "квалификация еще не настроена";
  const matchesWord=matches===1?"матч":matches>=2&&matches<=4?"матча":"матчей";
  return `${matches} ${matchesWord} у каждого · плей-офф на ${playoff}`;
}

function isTournamentRegistrationOpen(tournament){
  if(tournament?.status!=="registration")return false;
  return !tournament.registration_deadline||new Date(tournament.registration_deadline).getTime()>Date.now();
}

function registrationDeadlineLabel(tournament){
  if(!tournament?.registration_deadline)return "срок записи не указан";
  const prefix=isTournamentRegistrationOpen(tournament)?"запись до":"запись завершена";
  return `${prefix}: ${formatAdminDate(tournament.registration_deadline)}`;
}

function dateTimeLocalValue(value){
  const date=value?new Date(value):new Date(Date.now()+7*24*60*60*1000);
  if(Number.isNaN(date.getTime()))return "";
  const shifted=new Date(date.getTime()-date.getTimezoneOffset()*60000);
  return shifted.toISOString().slice(0,16);
}

function resetTournamentDeadlineInput(){
  $("adminTournamentDeadline").value=dateTimeLocalValue();
}

function tournamentRoundLabel(roundNo,totalRounds,status){
  if(roundNo===totalRounds)return "финал";
  if(roundNo===totalRounds-1)return "полуфинал";
  if(roundNo===totalRounds-2)return "четвертьфинал";
  return `раунд ${roundNo}`;
}

function tournamentStageLabel(match){
  if(match?.game_type!=="tournament")return "";
  if(match.tournament_stage==="qualifying")return "квалификация";
  if(match.tournament_stage==="playoff"){
    return tournamentRoundLabel(Number(match.tournament_round_no)||1,Number(match.tournament_total_rounds)||1);
  }
  return "турнирный матч";
}

function tournamentMatchNote(match){
  if(match.game_status==="placing")return "расстановка кораблей";
  if(match.game_status==="paused")return "матч приостановлен";
  if(match.status==="ready")return "пара сформирована";
  if(match.status==="playing")return "идет игра";
  if(match.status==="awaiting_confirmation")return "результат проверяется";
  if(match.status==="finished")return match.winner_id
    ? `победитель: ${match.winner_id===match.player1_id?match.player1_name:match.player2_name}`
    : "матч завершен";
  if(match.status==="technical")return match.winner_id
    ? `техническая победа: ${match.winner_id===match.player1_id?match.player1_name:match.player2_name}`
    : "технический результат";
  if(match.status==="cancelled")return "пара отменена";
  return "ожидаем участников";
}

function calculateQualifierStandings(players,matches,playoffSize){
  const activePlayers=(players||[]).filter(player=>player.status==="active");
  const rows=activePlayers.map(player=>({
    user_id:player.user_id,
    display_name:player.display_name,
    avatar_emoji:player.avatar_emoji,
    games:0,wins:0,losses:0,points:0,direct_points:0,opponent_strength:0,
  }));
  const byId=new Map(rows.map(row=>[row.user_id,row]));
  const settled=(matches||[]).filter(match=>
    ["finished","technical"].includes(match.status)&&match.winner_id&&
    byId.has(match.player1_id)&&byId.has(match.player2_id)
  );

  settled.forEach(match=>{
    const first=byId.get(match.player1_id);
    const second=byId.get(match.player2_id);
    first.games+=1;second.games+=1;
    if(match.winner_id===first.user_id){first.wins+=1;first.points+=3;second.losses+=1;}
    else if(match.winner_id===second.user_id){second.wins+=1;second.points+=3;first.losses+=1;}
  });

  const pointGroups=new Map();
  rows.forEach(row=>{
    if(!pointGroups.has(row.points))pointGroups.set(row.points,[]);
    pointGroups.get(row.points).push(row.user_id);
  });
  pointGroups.forEach(ids=>{
    const tied=new Set(ids);
    settled.forEach(match=>{
      if(tied.has(match.player1_id)&&tied.has(match.player2_id)){
        const winner=byId.get(match.winner_id);
        if(winner)winner.direct_points+=3;
      }
    });
  });

  settled.forEach(match=>{
    const first=byId.get(match.player1_id);
    const second=byId.get(match.player2_id);
    first.opponent_strength+=second.points;
    second.opponent_strength+=first.points;
  });

  rows.sort((a,b)=>
    b.points-a.points||
    b.direct_points-a.direct_points||
    b.opponent_strength-a.opponent_strength||
    a.display_name.localeCompare(b.display_name,"ru")
  );
  const sameResult=(a,b)=>!!a&&!!b&&
    a.points===b.points&&
    a.direct_points===b.direct_points&&
    a.opponent_strength===b.opponent_strength;
  rows.forEach((row,index)=>{
    row.position=index>0&&sameResult(row,rows[index-1])?rows[index-1].position:index+1;
  });

  const completed=matches.length>0&&matches.every(match=>["finished","technical"].includes(match.status));
  const cutoff=Math.min(Number(playoffSize)||0,rows.length);
  let boundaryTie=false;
  let boundaryIds=new Set();
  if(completed&&cutoff>0&&cutoff<rows.length&&sameResult(rows[cutoff-1],rows[cutoff])){
    boundaryTie=true;
    const anchor=rows[cutoff-1];
    boundaryIds=new Set(rows.filter(row=>sameResult(row,anchor)).map(row=>row.user_id));
  }
  rows.forEach((row,index)=>{
    row.boundary_tie=boundaryIds.has(row.user_id);
    row.qualifies=!row.boundary_tie&&index<cutoff;
  });
  return {rows,completed,cutoff,boundaryTie};
}

function createTournamentKbHelp(){
  const details=document.createElement("details");
  details.className="tournament-results-help tournament-stage-help tournament-kb-help";
  const summary=document.createElement("summary");
  summary.setAttribute("aria-label","что такое КБ");
  summary.title="что такое КБ";
  summary.textContent="?";
  const note=document.createElement("div");
  const title=document.createElement("strong");
  title.textContent="КБ — коэффициент Бухгольца.";
  note.append(title," он равен сумме очков всех соперников игрока. если основные очки и результат личной встречи совпали, выше располагается участник с большим КБ.");
  details.append(summary,note);
  return details;
}

function renderTournamentParticipants(tournament,players,matches){
  const wrap=$("tournamentPlayers");
  const empty=$("tournamentPlayersEmpty");
  const tiebreak=$("tournamentQualifierTiebreak");
  const activePlayers=(players||[]).filter(player=>player.status==="active");
  const qualifyingMatches=(matches||[]).filter(match=>match.stage==="qualifying");
  const settledMatches=(matches||[]).filter(match=>["finished","technical"].includes(match.status)&&match.winner_id);

  wrap.innerHTML="";
  tiebreak.classList.add("hidden");
  tiebreak.textContent="";
  empty.classList.toggle("hidden",activePlayers.length>0);
  const hasStarted=tournament.status==="active"||tournament.status==="finished"||settledMatches.length>0;
  $("tournamentParticipantsEyebrow").textContent=!hasStarted
    ? "предварительный"
    : tournament.status==="finished"
    ? "результаты"
    : "текущий рейтинг";
  $("tournamentParticipantsTitle").textContent=hasStarted?"таблица результатов":"список участников";
  $("tournamentParticipantsNavBtn").textContent=hasStarted?"результаты":"участники";

  const appendRow=(className,values)=>{
    const row=document.createElement("div");
    row.className=className;
    values.forEach((value,index)=>{
      if(value instanceof Node)row.appendChild(value);
      else{
        const cell=document.createElement(index===1?"strong":"span");
        cell.textContent=String(value);
        row.appendChild(cell);
      }
    });
    wrap.appendChild(row);
    return row;
  };

  if(!hasStarted){
    wrap.className="tournament-participants-table roster-table";
    appendRow("tournament-participant-row tournament-participant-head",["#","игрок","статус"]);
    [...activePlayers]
      .sort((a,b)=>(Number(a.seed)||9999)-(Number(b.seed)||9999)||a.display_name.localeCompare(b.display_name,"ru"))
      .forEach((player,index)=>appendRow("tournament-participant-row",[
        player.seed||index+1,
        `${player.avatar_emoji?`${player.avatar_emoji} `:""}${player.display_name}`,
        "участник",
      ]));
    return;
  }

  if(tournament.tournament_format==="qualifiers_playoff"){
    wrap.className="tournament-participants-table qualifier-table";
    const hasResults=qualifyingMatches.some(match=>["finished","technical"].includes(match.status)&&match.winner_id);
    const result=calculateQualifierStandings(activePlayers,qualifyingMatches,tournament.playoff_size);
    const kbHeading=document.createElement("span");
    kbHeading.className="qualifier-kb-heading";
    const kbLabel=document.createElement("span");
    kbLabel.textContent="КБ";
    kbHeading.append(kbLabel,createTournamentKbHelp());
    appendRow("qualifier-standing-row qualifier-standing-head",["#","игрок","игры","победы","поражения","очки",kbHeading,"статус"]);
    const rows=hasResults
      ? result.rows
      : [...activePlayers]
        .sort((a,b)=>(Number(a.seed)||9999)-(Number(b.seed)||9999)||a.display_name.localeCompare(b.display_name,"ru"))
        .map((player,index)=>({...player,position:player.seed||index+1,games:0,wins:0,losses:0,points:0,opponent_strength:0,qualifies:false,boundary_tie:false}));
    rows.forEach((row,index)=>{
      const line=appendRow("qualifier-standing-row",[
        row.position,
        `${row.avatar_emoji?`${row.avatar_emoji} `:""}${row.display_name}`,
        row.games,
        row.wins,
        row.losses,
        row.points,
        hasResults?row.opponent_strength:"—",
        !hasResults
          ? "участник"
          : !result.completed
          ? index<result.cutoff?"зона плей-офф":"квалификация"
          : row.boundary_tie?"доп. матч":row.qualifies?"плей-офф":"не прошел",
      ]);
      if(row.qualifies)line.classList.add("qualifies");
      if(row.boundary_tie)line.classList.add("needs-tiebreak");
      line.lastElementChild?.classList.add("qualifier-standing-result");
    });
    if(result.boundaryTie){
      tiebreak.textContent="на границе выхода в плей-офф осталось полное равенство. этим игрокам нужен дополнительный матч.";
      tiebreak.classList.remove("hidden");
    }
    return;
  }

  wrap.className="tournament-participants-table results-table";
  appendRow("tournament-result-row tournament-participant-head",["#","игрок","игры","победы","поражения","статус"]);
  const stats=activePlayers.map(player=>({
    ...player,
    games:0,
    wins:0,
    losses:0,
  }));
  const byId=new Map(stats.map(row=>[row.user_id,row]));
  settledMatches.forEach(match=>{
    const first=byId.get(match.player1_id);
    const second=byId.get(match.player2_id);
    if(!first||!second)return;
    first.games+=1;second.games+=1;
    if(match.winner_id===first.user_id){first.wins+=1;second.losses+=1;}
    if(match.winner_id===second.user_id){second.wins+=1;first.losses+=1;}
  });
  stats.sort((a,b)=>b.wins-a.wins||a.losses-b.losses||(Number(a.seed)||9999)-(Number(b.seed)||9999)||a.display_name.localeCompare(b.display_name,"ru"));
  stats.forEach((row,index)=>{
    const status=tournament.status==="registration"
      ? "участник"
      : row.user_id===tournament.winner_id
      ? "победитель"
      : row.losses>0
      ? "выбыл"
      : row.games>0
      ? "в игре"
      : "ожидает матча";
    const line=appendRow("tournament-result-row",[
      index+1,
      `${row.avatar_emoji?`${row.avatar_emoji} `:""}${row.display_name}`,
      row.games,
      row.wins,
      row.losses,
      status,
    ]);
    if(status==="победитель")line.classList.add("winner");
  });
}

function activateTournamentSection(targetId){
  const target=$(targetId);
  if(!target||target.classList.contains("hidden"))return;
  $$('[data-tournament-section]').forEach(button=>button.classList.toggle("active",button.dataset.tournamentSection===targetId));
  target.scrollIntoView({behavior:"smooth",block:"start"});
}

function updateTournamentSectionNav(tournament){
  $("tournamentOverviewNavBtn").textContent=tournament.status==="finished"?"итоги":"о турнире";
  $$('[data-tournament-section]').forEach(button=>{
    const target=$(button.dataset.tournamentSection);
    const hidden=!target||target.classList.contains("hidden");
    button.classList.toggle("hidden",hidden);
  });
  $("tournamentSectionNav").classList.add("hidden");
}

async function openTournamentMatch(match,button){
  if(!match?.game_id||button?.dataset.busy==="true")return;
  if(TOURNAMENT_DEMO_ENABLED){
    msg($("tournamentMessage"),"это предпросмотр: демонстрационный матч не открывается.","success");
    return;
  }
  const oldText=button?.textContent;
  if(button){button.dataset.busy="true";button.disabled=true;button.textContent="открываем…";}
  try{
    const {data,error}=await supabase.from("games").select("*").eq("id",match.game_id).maybeSingle();
    if(error)throw error;
    if(!data)throw new Error("Game not found");
    const participant=[data.player1_id,data.player2_id].includes(user?.id);
    if(data.status==="finished"&&!participant){
      throw new Error("просмотр завершенного матча доступен только его участникам");
    }
    if(participant)await openGame(data);
    else await observeGame(data);
  }catch(error){
    alert(humanError(error));
    if(button){button.disabled=false;button.textContent=oldText;delete button.dataset.busy;}
  }
}

function tournamentApplicationStatusLabel(status){
  return ({
    pending:"заявка ожидает решения администратора",
    approved:"заявка одобрена: вы участвуете в турнире",
    rejected:"заявка отклонена",
    withdrawn:"заявка отозвана",
  })[status]||"заявка не подана";
}

function renderTournamentApplication(tournament,application){
  const panel=$("tournamentApplicationPanel");
  const button=$("tournamentApplicationBtn");
  const status=application?.status||null;
  const registrationOpen=isTournamentRegistrationOpen(tournament);
  if(!registrationOpen){
    panel.classList.add("hidden");
    button.classList.add("hidden");
    button.dataset.action="none";
    return;
  }
  panel.classList.remove("hidden");
  button.classList.remove("hidden");
  button.disabled=tournamentApplicationBusy;
  button.className="primary";
  $("tournamentApplicationTitle").textContent="подача заявки";
  const applicationDeadline=tournament.registration_deadline
    ? `подать заявку можно до ${formatTournamentDate(tournament.registration_deadline)}.`
    : "подать заявку можно до начала турнира.";

  if(TOURNAMENT_DEMO_ENABLED){
    $("tournamentApplicationText").textContent=applicationDeadline;
    button.textContent="подать заявку";
    button.dataset.action="demo";
    return;
  }

  if(!user){
    $("tournamentApplicationText").textContent=registrationOpen
      ? "войдите или зарегистрируйтесь, чтобы подать заявку."
      : "регистрация в этот турнир закрыта.";
    button.textContent="войти / зарегистрироваться";
    button.dataset.action="auth";
    button.classList.toggle("hidden",!registrationOpen);
    return;
  }

  if(profile?.account_type!=="registered"){
    $("tournamentApplicationText").textContent="заявки доступны только зарегистрированным игрокам.";
    button.textContent="нужна регистрация";
    button.dataset.action="none";
    button.disabled=true;
    button.classList.toggle("hidden",!registrationOpen);
    return;
  }

  $("tournamentApplicationText").textContent=status
    ? tournamentApplicationStatusLabel(status)
    : registrationOpen?applicationDeadline:"регистрация в этот турнир закрыта.";

  if(!registrationOpen){
    button.classList.add("hidden");
    button.dataset.action="none";
  }else if(status==="pending"){
    button.textContent=tournamentApplicationBusy?"отзываем…":"отозвать заявку";
    button.className="danger-outline";
    button.dataset.action="withdraw";
  }else if(status==="approved"){
    button.textContent=tournamentApplicationBusy?"отказываемся…":"отказаться от участия";
    button.className="danger-outline";
    button.dataset.action="withdraw";
  }else{
    button.textContent=tournamentApplicationBusy?"отправляем…":status==="rejected"?"подать повторно":"подать заявку";
    button.dataset.action="apply";
  }
}

async function changeTournamentApplication(){
  if(!currentTournamentBoard||tournamentApplicationBusy)return;
  if(TOURNAMENT_DEMO_ENABLED){
    msg($("tournamentApplicationMessage"),"это предпросмотр: заявка не отправляется.","success");
    return;
  }
  const button=$("tournamentApplicationBtn");
  const action=button.dataset.action;
  if(action==="auth"){openAuth("register");return;}
  if(!["apply","withdraw"].includes(action))return;
  if(action==="withdraw"&&!window.confirm("отозвать заявку? если она уже одобрена, вы будете исключены из состава турнира."))return;

  tournamentApplicationBusy=true;
  renderTournamentApplication(currentTournamentBoard.tournament,currentTournamentBoard.my_application);
  msg($("tournamentApplicationMessage"),action==="apply"?"отправляем заявку…":"отзываем заявку…");
  try{
    const rpc=action==="apply"?"apply_to_tournament":"withdraw_tournament_application";
    const {data,error}=await supabase.rpc(rpc,{p_tournament_id:currentTournamentBoard.tournament.id});
    if(error)throw error;
    currentTournamentBoard=data;
    tournamentApplicationBusy=false;
    syncTournamentBoard(data);
    renderTournamentBoard(data);
    msg($("tournamentApplicationMessage"),action==="apply"?"заявка отправлена.":"заявка отозвана.","success");
  }catch(error){
    tournamentApplicationBusy=false;
    renderTournamentApplication(currentTournamentBoard.tournament,currentTournamentBoard.my_application);
    msg($("tournamentApplicationMessage"),humanError(error),"error");
  }
}

function tournamentDemoIso(daysFromNow,hour=12){
  const date=new Date();
  date.setDate(date.getDate()+daysFromNow);
  date.setHours(hour,0,0,0);
  return date.toISOString();
}

function tournamentDemoPlayers(){
  const names=["Алыча","Брусника","Груша","Дыня","Киви","Малина","Персик","Слива"];
  const avatars=["🍒","🫐","🍐","🍈","🥝","🍓","🍑","🍎"];
  return names.map((display_name,index)=>({
    user_id:`demo-player-${index+1}`,
    display_name,
    avatar_emoji:avatars[index],
    seed:index+1,
    status:"active",
  }));
}

function tournamentDemoLargePlayers(){
  const names=[
    "Абрикос","Авокадо","Айва","Алыча","Апельсин","Арбуз","Банан","Брусника",
    "Вишня","Гранат","Груша","Дыня","Ежевика","Инжир","Киви","Клубника",
    "Клюква","Крыжовник","Лайм","Лимон","Малина","Манго","Мандарин","Маракуйя",
    "Нектарин","Облепиха","Персик","Помело","Слива","Смородина","Фейхоа","Хурма",
  ];
  const avatars=["🍑","🥑","🍏","🍒","🍊","🍉","🍌","🫐","🍒","🍎","🍐","🍈","🫐","🍐","🥝","🍓","🍒","🍇","🍋","🍋","🍓","🥭","🍊","🍈","🍑","🍊","🍑","🍊","🍎","🍇","🍐","🍅"];
  return names.map((display_name,index)=>({
    user_id:`demo-large-player-${index+1}`,
    display_name,
    avatar_emoji:avatars[index],
    seed:index+1,
    status:"active",
  }));
}

function tournamentDemoMatch({id,stage="playoff",round=1,position=1,first,second,winner=null,status="pending"}){
  const hasPair=!!first&&!!second;
  const gameStatus=status==="finished"?"finished":status==="playing"?"playing":hasPair?"placing":null;
  return {
    id,
    stage,
    round_no:round,
    position,
    player1_id:first?.user_id||null,
    player1_name:first?.display_name||null,
    player1_avatar:first?.avatar_emoji||null,
    player2_id:second?.user_id||null,
    player2_name:second?.display_name||null,
    player2_avatar:second?.avatar_emoji||null,
    winner_id:winner?.user_id||null,
    game_id:hasPair?`demo-game-${id}`:null,
    game_status:gameStatus,
    status,
    result_reason:null,
    next_match_id:null,
    next_slot:null,
    resolved_at:status==="finished"?tournamentDemoIso(-1):null,
  };
}

function tournamentDemoPlayoff(players,finished=false){
  const firstRound=[
    [players[0],players[1],players[0]],
    [players[2],players[3],players[3]],
    [players[4],players[5],players[4]],
    [players[6],players[7],players[7]],
  ].map(([first,second,winner],index)=>tournamentDemoMatch({
    id:`playoff-1-${index+1}`,round:1,position:index+1,first,second,winner,status:"finished",
  }));
  const secondRound=[
    tournamentDemoMatch({id:"playoff-2-1",round:2,position:1,first:players[0],second:players[3],winner:players[0],status:"finished"}),
    tournamentDemoMatch({id:"playoff-2-2",round:2,position:2,first:players[4],second:players[7],winner:finished?players[4]:null,status:finished?"finished":"playing"}),
  ];
  const final=tournamentDemoMatch({
    id:"playoff-3-1",round:3,position:1,first:players[0],second:finished?players[4]:null,
    winner:finished?players[0]:null,status:finished?"finished":"pending",
  });
  return [...firstRound,...secondRound,final];
}

function tournamentDemoLargePlayoff(players){
  const matches=[];
  let entrants=[...players];
  const totalRounds=5;
  for(let round=1;round<=totalRounds;round++){
    const next=[];
    const pairCount=Math.max(1,entrants.length/2);
    for(let position=1;position<=pairCount;position++){
      const first=entrants[(position-1)*2]||null;
      const second=entrants[(position-1)*2+1]||null;
      const finished=round===1&&first&&second;
      const playing=round===2&&first&&second;
      const winner=finished?first:null;
      matches.push(tournamentDemoMatch({
        id:`large-playoff-${round}-${position}`,
        round,
        position,
        first,
        second,
        winner,
        status:finished?"finished":playing?"playing":"pending",
      }));
      next.push(winner);
    }
    entrants=next;
  }
  return matches;
}

function tournamentDemoQualifiers(players){
  const pairs=[
    [0,1,0],[2,3,3],[4,5,4],[6,7,7],
    [0,2,0],[1,3,3],[4,6,4],[5,7,7],
  ];
  return pairs.map(([first,second,winner],index)=>tournamentDemoMatch({
    id:`qualifying-${index+1}`,
    stage:"qualifying",
    round:1,
    position:index+1,
    first:players[first],
    second:players[second],
    winner:players[winner],
    status:"finished",
  }));
}

function buildTournamentDemoBoard(state){
  const players=state==="large"?tournamentDemoLargePlayers():tournamentDemoPlayers();
  const base={
    id:`demo-${state}`,
    slug:`demo-${state}`,
    description:"демонстрационный турнир",
    max_players:16,
    qualifying_matches_per_player:2,
    playoff_size:8,
    rating_applied:false,
    rating_applied_at:null,
    created_at:tournamentDemoIso(-14),
    updated_at:tournamentDemoIso(-1),
    registration_deadline:tournamentDemoIso(-8),
    qualifying_started_at:null,
    started_at:null,
    finished_at:null,
    archived_at:null,
    winner_id:null,
    winner_name:null,
  };
  if(state==="registration"){
    return {tournament:{...base,name:"Кубок спелой груши",status:"registration",tournament_format:"qualifiers_playoff",registration_deadline:tournamentDemoIso(5)},players:players.slice(0,5),matches:[],my_application:null};
  }
  if(state==="active"){
    return {tournament:{...base,name:"Осенний плей-офф",status:"active",tournament_format:"knockout",started_at:tournamentDemoIso(-6)},players,matches:tournamentDemoPlayoff(players,false),my_application:null};
  }
  if(state==="large"){
    return {tournament:{...base,name:"Большой фруктовый кубок",status:"active",tournament_format:"knockout",max_players:32,playoff_size:32,started_at:tournamentDemoIso(-3)},players,matches:tournamentDemoLargePlayoff(players),my_application:null};
  }
  if(state==="mixed"){
    return {tournament:{...base,name:"Большой урожай",status:"active",tournament_format:"qualifiers_playoff",qualifying_started_at:tournamentDemoIso(-9),started_at:tournamentDemoIso(-9)},players,matches:[...tournamentDemoQualifiers(players),...tournamentDemoPlayoff(players,false)],my_application:null};
  }
  const archived=state==="archived";
  return {
    tournament:{...base,id:archived?"demo-archive":"demo-finished",slug:archived?"demo-archive":"demo-finished",name:archived?"Первый фруктовый кубок":"Фруктовый финал",status:"finished",tournament_format:"qualifiers_playoff",created_at:archived?tournamentDemoIso(-60):base.created_at,registration_deadline:archived?tournamentDemoIso(-56):base.registration_deadline,qualifying_started_at:archived?tournamentDemoIso(-55):tournamentDemoIso(-12),started_at:archived?tournamentDemoIso(-55):tournamentDemoIso(-12),finished_at:archived?tournamentDemoIso(-50):tournamentDemoIso(-1),archived_at:archived?tournamentDemoIso(-49):null,winner_id:players[0].user_id,winner_name:players[0].display_name,rating_applied:true,rating_applied_at:archived?tournamentDemoIso(-50):tournamentDemoIso(-1)},
    players,
    matches:[...tournamentDemoQualifiers(players),...tournamentDemoPlayoff(players,true)],
    my_application:null,
  };
}

function tournamentDemoSummary(board){
  const tournament=board.tournament;
  return {
    ...tournament,
    participant_count:(board.players||[]).length,
    round_count:Math.max(0,...(board.matches||[]).filter(match=>match.stage==="playoff").map(match=>Number(match.round_no)||0)),
  };
}

function updateTournamentDemoControls(){
  $("tournamentDemoPanel").classList.toggle("hidden",!TOURNAMENT_DEMO_ENABLED);
  $$('[data-tournament-demo]').forEach(button=>button.classList.toggle("active",button.dataset.tournamentDemo===tournamentDemoState));
}

function renderTournamentDemoState(state=tournamentDemoState){
  tournamentDemoState=TOURNAMENT_DEMO_STATES.has(state)?state:"none";
  const url=new URL(location.href);
  url.searchParams.set("tournament-demo","1");
  url.searchParams.set("tournament-state",tournamentDemoState);
  history.replaceState(null,"",url);
  updateTournamentDemoControls();
  msg($("tournamentMessage"),"");
  msg($("tournamentApplicationMessage"),"");

  const archivedBoard=buildTournamentDemoBoard("archived");
  if(tournamentDemoState==="none"){
    tournamentsCache=[tournamentDemoSummary(archivedBoard)];
    currentTournamentId=null;
    openedArchivedTournamentId=null;
    currentTournamentBoard=null;
    $("tournamentView").classList.add("no-current-tournament");
    $("tournamentPageHeadingContent").classList.add("hidden");
    $("tournamentPageEyebrow").classList.add("hidden");
    $("tournamentPageIntro").classList.add("hidden");
    $("tournamentStatusBadge").classList.add("hidden");
    $("tournamentFormatBadge").classList.add("hidden");
    $("tournamentEmpty").classList.remove("hidden");
    $("tournamentContent").classList.add("hidden");
    $("tournamentSectionNav").classList.add("hidden");
    $("tournamentArchiveBackBtn").classList.add("hidden");
    $("tournamentRulesSection").classList.remove("hidden");
    renderTournamentDirectory();
    return;
  }

  const board=buildTournamentDemoBoard(tournamentDemoState);
  const summary=tournamentDemoSummary(board);
  tournamentsCache=[summary,tournamentDemoSummary(archivedBoard)];
  currentTournamentId=board.tournament.id;
  openedArchivedTournamentId=null;
  renderTournamentBoard(board);
  renderTournamentDirectory();
}

async function loadTournaments(){
  if(TOURNAMENT_DEMO_ENABLED){renderTournamentDemoState();return;}
  if(!configured||tournamentLoading)return;
  tournamentLoading=true;
  $("refreshTournamentBtn").disabled=true;
  msg($("tournamentMessage"),"загружаем турнир…");
  msg($("tournamentApplicationMessage"),"");
  try{
    const {data,error}=await supabase.rpc("list_public_tournaments");
    if(error)throw error;
    tournamentsCache=data||[];
    const selected=tournamentsCache.find(row=>
      row.id===currentTournamentId&&(!row.archived_at||row.id===openedArchivedTournamentId)
    );
    const visibleCurrent=tournamentsCache.filter(row=>!row.archived_at&&!["draft","cancelled"].includes(row.status));
    const current=selected
      ||visibleCurrent.find(row=>row.status==="active")
      ||visibleCurrent.find(isTournamentRegistrationOpen)
      ||visibleCurrent.find(row=>row.status==="registration")
      ||visibleCurrent.find(row=>row.status==="finished")
      ||null;
    const nextTournamentId=current?.id||null;
    if(current&&!current.archived_at)openedArchivedTournamentId=null;
    currentTournamentId=nextTournamentId;

    $("tournamentEmpty").classList.toggle("hidden",!!current);
    $("tournamentContent").classList.toggle("hidden",!current);
    $("tournamentSectionNav").classList.add("hidden");
    $("tournamentPageIntro").classList.add("hidden");
    $("tournamentArchiveBackBtn").classList.toggle("hidden",!openedArchivedTournamentId);
    if(!currentTournamentId){
      currentTournamentBoard=null;
      $("tournamentView").classList.add("no-current-tournament");
      $("tournamentPageHeadingContent").classList.add("hidden");
      $("tournamentPageEyebrow").classList.add("hidden");
      $("tournamentStatusBadge").classList.add("hidden");
      $("tournamentFormatBadge").classList.add("hidden");
      $("tournamentRulesSection").classList.remove("hidden");
      renderTournamentDirectory();
      msg($("tournamentMessage"),"");
      return;
    }

    const boardResult=await supabase.rpc("get_tournament_board",{p_tournament_id:currentTournamentId});
    if(boardResult.error)throw boardResult.error;
    renderTournamentBoard(boardResult.data);
    msg($("tournamentMessage"),"");
  }catch(error){
    msg($("tournamentMessage"),humanError(error),"error");
  }finally{
    tournamentLoading=false;
    $("refreshTournamentBtn").disabled=false;
  }
}

async function openPublicTournament(tournamentId,button){
  if(!tournamentId||tournamentLoading)return;
  if(TOURNAMENT_DEMO_ENABLED){
    renderTournamentDemoState("finished");
    const archivedBoard=buildTournamentDemoBoard("archived");
    tournamentsCache=[tournamentDemoSummary(archivedBoard)];
    openedArchivedTournamentId=archivedBoard.tournament.id;
    renderTournamentBoard(archivedBoard);
    $("tournamentView").scrollIntoView({behavior:"smooth",block:"start"});
    return;
  }
  const oldText=button?.textContent;
  if(button){button.disabled=true;button.textContent="открываем…";}
  tournamentLoading=true;
  try{
    const {data,error}=await supabase.rpc("get_tournament_board",{p_tournament_id:tournamentId});
    if(error)throw error;
    openedArchivedTournamentId=tournamentsCache.find(item=>item.id===tournamentId)?.archived_at?tournamentId:null;
    currentTournamentId=tournamentId;
    $("tournamentEmpty").classList.add("hidden");
    $("tournamentContent").classList.remove("hidden");
    $("tournamentPageIntro").classList.add("hidden");
    renderTournamentBoard(data);
    renderTournamentDirectory();
    $("tournamentView").scrollIntoView({behavior:"smooth",block:"start"});
    msg($("tournamentMessage"),"");
  }catch(error){
    msg($("tournamentMessage"),humanError(error),"error");
  }finally{
    tournamentLoading=false;
    if(button){button.disabled=false;button.textContent=oldText;}
  }
}

function renderTournamentDirectory(){
  const panel=$("tournamentOtherPanel");
  const wrap=$("tournamentOtherList");
  if(!panel||!wrap)return;
  const others=tournamentsCache.filter(tournament=>tournament.archived_at&&tournament.id!==currentTournamentId);
  panel.classList.toggle("hidden",currentTournamentId!==null||others.length===0);
  wrap.innerHTML="";
  others.forEach(tournament=>{
    const card=document.createElement("article");
    card.className=`tournament-other-card${tournament.status==="finished"?" completed":""}`;
    const main=document.createElement("div");
    const name=document.createElement("strong");name.textContent=tournament.name;
    const details=document.createElement("span");
    details.textContent=`${formatTournamentDate(tournament.created_at)} — ${formatTournamentDate(tournament.finished_at)} · победитель: ${tournament.winner_name||"не определен"}`;
    main.append(name,details);
    const action=document.createElement("button");action.type="button";
    action.textContent="открыть архив";
    action.addEventListener("click",()=>openPublicTournament(tournament.id,action));
    card.append(main,action);wrap.appendChild(card);
  });
}

function formatTournamentDate(value){
  if(!value)return "—";
  const date=new Date(value);
  if(Number.isNaN(date.getTime()))return "—";
  return new Intl.DateTimeFormat("ru-RU",{day:"2-digit",month:"2-digit",year:"numeric"}).format(date);
}

function tournamentDisplayNumber(tournamentId){
  const chronological=[...tournamentsCache]
    .filter(item=>item.status!=="draft")
    .sort((a,b)=>new Date(a.created_at||0)-new Date(b.created_at||0));
  const index=chronological.findIndex(item=>item.id===tournamentId);
  return index>=0?index+1:1;
}

function createTournamentMatchAction(match){
  const completed=["finished","technical"].includes(match.status);
  const participant=[match.player1_id,match.player2_id].includes(user?.id)
    ||(TOURNAMENT_DEMO_ENABLED&&!!match.player1_id&&!!match.player2_id);
  const watchable=["playing","paused"].includes(match.game_status);
  if(!match.game_id||(!participant&&!watchable))return null;
  const action=document.createElement("button");
  action.type="button";
  action.className=participant?"primary tournament-match-action":"tournament-match-action";
  action.textContent=participant?(completed?"посмотреть итог":"войти в матч"):"наблюдать";
  action.addEventListener("click",()=>openTournamentMatch(match,action));
  return action;
}

function isTournamentMatchAvailableToCurrentPlayer(match){
  if(!match?.game_id)return false;
  const participant=[match.player1_id,match.player2_id].includes(user?.id);
  const watchable=["playing","paused"].includes(match.game_status);
  const demoParticipant=TOURNAMENT_DEMO_ENABLED&&[match.player1_id,match.player2_id].includes("demo-player-1");
  const completed=["finished","technical"].includes(match.status)||match.game_status==="finished";
  return completed?(participant||demoParticipant):(participant||watchable||demoParticipant);
}

function createBracketMatch(match){
  const card=document.createElement("article");
  card.className="tournament-match";
  if(isTournamentMatchAvailableToCurrentPlayer(match)){
    card.classList.add("available-to-player");
    card.title="матч доступен для просмотра";
    card.tabIndex=0;
    card.setAttribute("role","button");
    card.setAttribute("aria-label",`открыть матч ${match.player1_name||"первого игрока"} и ${match.player2_name||"второго игрока"}`);
    card.addEventListener("click",()=>openTournamentMatch(match));
    card.addEventListener("keydown",event=>{
      if(event.key==="Enter"||event.key===" "){
        event.preventDefault();
        openTournamentMatch(match);
      }
    });
  }
  [
    {id:match.player1_id,name:match.player1_name,avatar:match.player1_avatar},
    {id:match.player2_id,name:match.player2_name,avatar:match.player2_avatar},
  ].forEach(player=>{
    const line=document.createElement("div");
    line.className="tournament-match-player";
    if(player.id===match.winner_id)line.classList.add("winner");
    if(!player.id)line.classList.add("empty");
    line.textContent=player.id?`${player.avatar?`${player.avatar} `:""}${player.name}`:"место пока свободно";
    card.appendChild(line);
  });
  return card;
}

function renderTournamentQualifyingBracket(qualifyingMatches){
  const panel=$("tournamentQualifyingBracketPanel");
  const wrap=$("tournamentQualifyingBracket");
  panel.classList.toggle("hidden",!qualifyingMatches.length);
  wrap.innerHTML="";
  qualifyingMatches
    .slice()
    .sort((a,b)=>(Number(a.position)||0)-(Number(b.position)||0))
    .forEach((match,index)=>{
      const item=document.createElement("article");
      item.className="tournament-qualifying-pair";
      const number=document.createElement("span");
      number.textContent=`матч ${index+1}`;
      item.append(number,createBracketMatch(match));
      wrap.appendChild(item);
  });
}

function tournamentBracketMatchKey(match){
  return match?.id?String(match.id):`${Number(match?.round_no)||0}:${Number(match?.position)||0}`;
}

function drawTournamentBracketConnections(bracket,playoffMatches,totalRounds,drawVersion){
  if(drawVersion!==tournamentBracketDrawVersion||!bracket?.isConnected)return;
  let svg=bracket.querySelector(".tournament-bracket-lines");
  if(!svg){
    svg=document.createElementNS("http://www.w3.org/2000/svg","svg");
    svg.classList.add("tournament-bracket-lines");
    svg.setAttribute("aria-hidden","true");
    bracket.appendChild(svg);
  }
  svg.replaceChildren();
  const width=bracket.scrollWidth;
  const height=bracket.scrollHeight;
  if(!width||!height)return;
  svg.setAttribute("viewBox",`0 0 ${width} ${height}`);
  svg.setAttribute("width",String(width));
  svg.setAttribute("height",String(height));
  const bracketRect=bracket.getBoundingClientRect();
  const slots=new Map($$("#tournamentBracket .tournament-bracket-slot").map(slot=>[slot.dataset.matchKey,slot]));
  const matchesById=new Map(playoffMatches.filter(match=>match.id).map(match=>[String(match.id),match]));
  const matchesByPlace=new Map(playoffMatches.map(match=>[`${Number(match.round_no)||0}:${Number(match.position)||0}`,match]));
  const coordinate=value=>Math.round(value*2)/2;

  playoffMatches.forEach(match=>{
    const roundNo=Number(match.round_no)||0;
    if(roundNo<=0||roundNo>=totalRounds)return;
    const target=match.next_match_id
      ? matchesById.get(String(match.next_match_id))
      : matchesByPlace.get(`${roundNo+1}:${Math.ceil((Number(match.position)||1)/2)}`);
    const sourceSlot=slots.get(tournamentBracketMatchKey(match));
    const targetSlot=target?slots.get(tournamentBracketMatchKey(target)):null;
    const sourceCard=sourceSlot?.querySelector(".tournament-match");
    const targetCard=targetSlot?.querySelector(".tournament-match");
    if(!sourceCard||!targetCard)return;
    const sourceRect=sourceCard.getBoundingClientRect();
    const targetRect=targetCard.getBoundingClientRect();
    const x1=coordinate(sourceRect.right-bracketRect.left+bracket.scrollLeft);
    const y1=coordinate(sourceRect.top+sourceRect.height/2-bracketRect.top+bracket.scrollTop);
    const x2=coordinate(targetRect.left-bracketRect.left+bracket.scrollLeft);
    const y2=coordinate(targetRect.top+targetRect.height/2-bracketRect.top+bracket.scrollTop);
    const middle=coordinate((x1+x2)/2);
    const path=document.createElementNS("http://www.w3.org/2000/svg","path");
    path.setAttribute("d",`M ${x1} ${y1} H ${middle} V ${y2} H ${x2}`);
    path.setAttribute("vector-effect","non-scaling-stroke");
    svg.appendChild(path);
  });
}

function scheduleTournamentBracketConnections(bracket,playoffMatches,totalRounds){
  tournamentBracketResizeObserver?.disconnect();
  tournamentBracketResizeObserver=null;
  const drawVersion=++tournamentBracketDrawVersion;
  const draw=()=>drawTournamentBracketConnections(bracket,playoffMatches,totalRounds,drawVersion);
  requestAnimationFrame(()=>requestAnimationFrame(draw));
  if("ResizeObserver" in window){
    tournamentBracketResizeObserver=new ResizeObserver(()=>requestAnimationFrame(draw));
    tournamentBracketResizeObserver.observe(bracket);
  }
  document.fonts?.ready.then(draw);
}

function renderTournamentBracket(playoffMatches,totalRounds){
  const panel=$("tournamentBracketPanel");
  panel.classList.toggle("hidden",!playoffMatches.length);
  const bracket=$("tournamentBracket");
  bracket.innerHTML="";
  bracket.classList.remove("is-large");
  if(!playoffMatches.length){
    tournamentBracketResizeObserver?.disconnect();
    tournamentBracketResizeObserver=null;
    tournamentBracketDrawVersion+=1;
    return;
  }

  const firstRoundCount=Math.max(1,playoffMatches.filter(match=>match.round_no===1).length);
  const largeBracket=firstRoundCount>=16;
  bracket.classList.toggle("is-large",largeBracket);
  bracket.style.setProperty("--bracket-height",`${Math.max(180,firstRoundCount*(largeBracket?64:92))}px`);
  for(let roundNo=1;roundNo<=totalRounds;roundNo++){
    const matches=playoffMatches
      .filter(match=>match.round_no===roundNo)
      .sort((a,b)=>(Number(a.position)||0)-(Number(b.position)||0));
    if(!matches.length)continue;
    const round=document.createElement("section");
    round.className=`tournament-round${roundNo===totalRounds?" is-final":""}`;
    const track=document.createElement("div");
    track.className="tournament-round-track";
    matches.forEach(match=>{
      const slot=document.createElement("div");
      slot.className="tournament-bracket-slot";
      slot.dataset.matchKey=tournamentBracketMatchKey(match);
      slot.appendChild(createBracketMatch(match));
      track.appendChild(slot);
    });
    round.appendChild(track);
    bracket.appendChild(round);
  }
  scheduleTournamentBracketConnections(bracket,playoffMatches,totalRounds);
}

function activeTournamentMatchStage(match,totalRounds){
  return match.stage==="qualifying"
    ? "квалификация"
    : tournamentRoundLabel(Number(match.round_no)||1,totalRounds||1);
}

function createTournamentMatchRow(match,totalRounds){
  const row=document.createElement("article");
  row.className=`tournament-match-row${["finished","technical"].includes(match.status)?" completed":""}`;
  const main=document.createElement("div");
  main.className="tournament-match-row-main";
  const pair=document.createElement("strong");
  const first=match.player1_id?`${match.player1_avatar?`${match.player1_avatar} `:""}${match.player1_name}`:"место пока свободно";
  const second=match.player2_id?`${match.player2_avatar?`${match.player2_avatar} `:""}${match.player2_name}`:"место пока свободно";
  pair.textContent=`${first} — ${second}`;
  const state=document.createElement("small");
  state.className="tournament-match-row-state";
  state.textContent=`${activeTournamentMatchStage(match,totalRounds)} · ${tournamentMatchNote(match)}`;
  main.append(pair,state);
  row.append(main);
  const action=createTournamentMatchAction(match);
  if(action)row.appendChild(action);
  return row;
}

function renderTournamentMatches(tournament,matches,totalRounds){
  const panel=$("tournamentQualifiersPanel");
  const wrap=$("tournamentQualifiers");
  wrap.innerHTML="";
  $("tournamentQualifiersProgress").classList.add("hidden");
  const activeMatches=matches
    .filter(match=>
      !["finished","technical","cancelled"].includes(match.status)&&
      match.player1_id&&match.player2_id&&
      (match.game_id||["ready","playing","awaiting_confirmation"].includes(match.status))
    )
    .sort((a,b)=>
      (a.stage==="qualifying"?0:1)-(b.stage==="qualifying"?0:1)||
      (Number(a.round_no)||0)-(Number(b.round_no)||0)||
      (Number(a.position)||0)-(Number(b.position)||0)
    );
  if(tournament.status==="finished"||!activeMatches.length){
    panel.classList.add("hidden");
    return;
  }
  panel.classList.remove("hidden");
  activeMatches.forEach(match=>wrap.appendChild(createTournamentMatchRow(match,totalRounds)));
}

function renderTournamentBoard(data){
  currentTournamentBoard=data;
  $("tournamentView").classList.remove("no-current-tournament");
  const tournament=data.tournament;
  const players=data.players||[];
  const matches=data.matches||[];
  const qualifyingMatches=matches.filter(match=>match.stage==="qualifying");
  const playoffMatches=matches.filter(match=>match.stage!=="qualifying");
  const totalRounds=Math.max(0,...playoffMatches.map(match=>match.round_no));
  currentTournamentId=tournament.id;
  const tournamentNumber=tournamentDisplayNumber(tournament.id);
  const registrationOpen=isTournamentRegistrationOpen(tournament);
  const showWinner=tournament.status==="finished";
  const viewingArchive=!!tournamentsCache.find(item=>item.id===tournament.id)?.archived_at;
  $("tournamentArchiveBackBtn").classList.toggle("hidden",!viewingArchive);
  $("tournamentArchiveBackBtn").textContent=tournamentsCache.some(item=>!item.archived_at&&!["draft","cancelled"].includes(item.status))?"к текущему турниру":"к архиву";
  $("tournamentPageHeadingContent").classList.toggle("hidden",registrationOpen);
  $("tournamentPageEyebrow").textContent=`турнир №${tournamentNumber}`;
  $("tournamentPageEyebrow").classList.toggle("hidden",registrationOpen);
  $("tournamentPageTitle").textContent=tournament.name;
  $("tournamentPageIntro").classList.add("hidden");
  $("tournamentEmpty").classList.add("hidden");
  $("tournamentContent").classList.remove("hidden");
  $("tournamentSectionNav").classList.add("hidden");
  $("tournamentRulesSection").classList.add("hidden");
  const status=tournament.status==="registration"
    ? isTournamentRegistrationOpen(tournament)?"запись открыта":"запись завершена"
    : tournamentStatusLabel(tournament.status);
  $("tournamentStatusBadge").textContent=status;
  $("tournamentStatusBadge").classList.toggle("hidden",registrationOpen);
  $("tournamentFormatBadge").textContent=tournamentFormatLabel(tournament.tournament_format);
  $("tournamentFormatBadge").classList.toggle("hidden",tournament.status!=="finished");
  const meta=$("tournamentMeta");
  meta.innerHTML="";
  meta.classList.add("hidden");
  const summary=$("tournamentCurrentSection");
  summary.classList.toggle("hidden",!registrationOpen&&!showWinner);
  summary.classList.toggle("registration-card",registrationOpen);
  summary.classList.toggle("winner-card",showWinner);
  $("tournamentRegistrationTitle").classList.toggle("hidden",!registrationOpen);
  $("tournamentRegistrationEyebrow").textContent=`турнир №${tournamentNumber}`;
  $("tournamentRegistrationName").textContent=tournament.name;
  $("tournamentSummaryHeading").classList.toggle("hidden",!registrationOpen);
  $("tournamentApplicationDeadline").textContent=`срок подачи заявки — ${tournament.registration_deadline?formatTournamentDate(tournament.registration_deadline):"не указан"}`;
  $("tournamentRegistrationStatus").classList.toggle("hidden",!registrationOpen);
  const resultPanel=$("tournamentResultPanel");
  resultPanel.classList.toggle("hidden",!showWinner);
  if(showWinner){
    $("tournamentWinnerName").textContent=tournament.winner_name||"не определен";
  }
  renderTournamentApplication(tournament,data.my_application);
  renderTournamentParticipants(tournament,players,matches);
  renderTournamentQualifyingBracket(qualifyingMatches);
  renderTournamentBracket(playoffMatches,totalRounds);
  renderTournamentMatches(tournament,matches,totalRounds);
  updateTournamentSectionNav(tournament);
  renderTournamentDirectory();
}

async function loadRating(){
  if(!configured)return;
  const {data,error}=await supabase.rpc("get_leaderboard");
  if(error)return console.error(error);
  const wrap=$("ratingRows");wrap.innerHTML="";
  (data||[]).forEach((r,i)=>{
    const row=document.createElement("div");row.className="rating-row";
    const rank=document.createElement("span");rank.textContent=i+1;
    const name=document.createElement("button");name.type="button";name.className="profile-link";name.textContent=r.display_name;
    name.addEventListener("click",()=>openPlayerProfile(r.user_id));
    row.append(rank,name);
    [r.rating,r.games_played,r.wins,r.losses,`${r.win_rate}%`].forEach(v=>{const s=document.createElement("span");s.textContent=v;row.appendChild(s);});
    wrap.appendChild(row);
  });
  $("ratingEmpty").classList.toggle("hidden",!!data?.length);
}

async function openPlayerProfile(playerId){
  if(!user){openAuth("login");return;}
  const dialog=$("playerProfileDialog");
  dialog.classList.toggle("is-own-profile",playerId===user?.id);
  $("publicProfileName").textContent="загружаем профиль…";
  $("publicProfileAvatar").textContent="🍏";
  $("publicProfileAvatar").classList.remove("hidden");
  $("publicProfileVerified").classList.add("hidden");
  $("publicProfileStats").innerHTML="";
  $("publicProfileHistory").innerHTML="";
  $("publicProfileHistoryMoreList").innerHTML="";
  $("publicProfileHistoryMore").classList.add("hidden");
  $("publicProfileHistoryMore").open=false;
  $("publicProfileHistoryEmpty").classList.add("hidden");
  msg($("publicProfileMessage"),"");
  if(!dialog.open)dialog.showModal();

  try{
    const {data,error}=await supabase.rpc("get_public_player_profile",{p_user_id:playerId});
    if(error)throw error;
    const player=data.profile;
    const matches=data.matches||[];
    $("publicProfileName").textContent=player.display_name;
    $("publicProfileAvatar").textContent=player.avatar_emoji||"🍏";
    $("publicProfileAvatar").classList.remove("hidden");
    if(!player.school_verified){
      $("publicProfileVerified").textContent="ник ожидает проверки";
      $("publicProfileVerified").classList.remove("hidden");
    }

    const rate=player.rated_games?Math.round((player.rated_wins*1000)/player.rated_games)/10:0;
    const stats=[
      [player.rating,"рейтинг"],
      [player.rated_games,"игры в рейтинге"],
      [player.rated_wins,"победы"],
      [player.rated_losses,"поражения"],
      [`${rate}%`,"процент побед"],
    ];
    stats.forEach(([value,label])=>{
      const card=document.createElement("div");card.className="public-stat";
      const strong=document.createElement("strong");strong.textContent=value;
      const span=document.createElement("span");span.textContent=label;
      card.append(strong,span);$("publicProfileStats").appendChild(card);
    });

    const renderProfileMatch=match=>{
      const row=document.createElement("div");row.className="public-match-row";
      const main=document.createElement("div");main.className="public-match-main";
      const opponentLine=document.createElement("div");opponentLine.className="public-match-opponent";
      const versus=document.createElement("span");versus.className="public-match-vs";versus.textContent="vs";
      const opponent=document.createElement("strong");opponent.textContent=match.opponent_name;
      opponentLine.append(versus,opponent);
      const details=document.createElement("small");
      const surrender=match.finish_reason==="surrender"
        ? match.surrendered_by===player.user_id?" · игрок сдался":" · соперник сдался"
        : "";
      const matchType=match.game_type==="rated"?"рейтинговая игра":match.game_type==="tournament"?"турнирный матч":"без рейтинга";
      details.textContent=`${matchType}${surrender}`;
      main.append(opponentLine,details);

      const rating=document.createElement("span");rating.className=`badge public-match-rating ${match.result}`;
      const ratingChange=Number(match.rating_change)||0;
      rating.textContent=match.rating_applied
        ? `рейтинг ${ratingChange>0?"+":ratingChange<0?"−":""}${Math.abs(ratingChange)}`
        : "без рейтинга";
      rating.setAttribute("aria-label",`${match.result==="win"?"победа":"поражение"}, ${rating.textContent}`);
      const date=document.createElement("time");date.dateTime=match.finished_at;date.textContent=formatAdminDate(match.finished_at);
      row.append(main,rating,date);
      if(match.viewer_can_open&&match.game_id){
        row.classList.add("public-match-replay");
        row.tabIndex=0;
        row.setAttribute("role","button");
        row.setAttribute("aria-label",`открыть завершенный матч против ${match.opponent_name}`);
        row.title="открыть завершенный матч";
        row.addEventListener("click",()=>openCompletedMatch(match,row));
        row.addEventListener("keydown",event=>{
          if(event.key==="Enter"||event.key===" "){
            event.preventDefault();
            openCompletedMatch(match,row);
          }
        });
      }
      return row;
    };
    const historyRows=[...matches].sort((a,b)=>new Date(b.finished_at)-new Date(a.finished_at));
    historyRows.slice(0,3).forEach(match=>$("publicProfileHistory").appendChild(renderProfileMatch(match)));
    historyRows.slice(3).forEach(match=>$("publicProfileHistoryMoreList").appendChild(renderProfileMatch(match)));
    const hiddenMatches=Math.max(0,historyRows.length-3);
    $("publicProfileHistoryMore").classList.toggle("hidden",hiddenMatches===0);
    $("publicProfileHistoryMoreLabel").textContent=`остальные матчи · ${hiddenMatches}`;
    $("publicProfileHistoryEmpty").classList.toggle("hidden",historyRows.length>0);
  }catch(error){
    $("publicProfileName").textContent="профиль недоступен";
    msg($("publicProfileMessage"),humanError(error),"error");
  }
}

function formatAdminDate(value){
  if(!value)return "—";
  return new Intl.DateTimeFormat("ru-RU",{
    day:"2-digit",month:"2-digit",year:"numeric",hour:"2-digit",minute:"2-digit"
  }).format(new Date(value));
}

function renderAdminNotifications(data={}){
  adminNotificationsCache=data.items||[];
  const unread=Number(data.unread_count)||0;
  const counter=$("adminNotificationCount");
  counter.textContent=unread>99?"99+":String(unread);
  counter.classList.toggle("hidden",unread===0);
  $("adminMarkAllNotificationsBtn").disabled=unread===0||adminNotificationsLoading;

  const list=$("adminNotificationsList");
  list.innerHTML="";
  adminNotificationsCache.forEach(notification=>{
    const item=document.createElement("button");
    item.type="button";
    item.className=`notification-item${notification.read_at?" read":""}`;
    const dot=document.createElement("span");dot.className="notification-dot";
    const content=document.createElement("span");content.className="notification-content";
    const title=document.createElement("strong");title.textContent=notification.title;
    const body=document.createElement("span");body.textContent=notification.body;
    const date=document.createElement("time");date.dateTime=notification.created_at;date.textContent=formatAdminDate(notification.created_at);
    content.append(title,body,date);item.append(dot,content);list.appendChild(item);
    item.addEventListener("click",()=>openAdminNotification(notification));
  });
  $("adminNotificationsEmpty").classList.toggle("hidden",adminNotificationsCache.length>0);
}

async function fetchCombinedNotifications(){
  const requests=[supabase.rpc("list_user_notifications",{p_limit:30})];
  if(profile?.is_admin)requests.push(supabase.rpc("admin_list_notifications",{p_limit:30}));
  const results=await Promise.all(requests);
  results.forEach(result=>{if(result.error)throw result.error;});
  const userData=results[0].data||{};
  const adminData=profile?.is_admin?(results[1]?.data||{}):{};
  const items=[
    ...(userData.items||[]).map(item=>({...item,source:"user"})),
    ...(adminData.items||[]).map(item=>({...item,source:"admin",item_type:"admin"})),
  ].sort((a,b)=>{
    const unreadDifference=Number(!b.read_at)-Number(!a.read_at);
    return unreadDifference||new Date(b.created_at)-new Date(a.created_at);
  }).slice(0,30);
  return {
    unread_count:(Number(userData.unread_count)||0)+(Number(adminData.unread_count)||0),
    items,
  };
}

async function loadAdminNotifications(silent=true){
  if(!configured||!user||profile?.account_type!=="registered"||adminNotificationsLoading)return;
  adminNotificationsLoading=true;
  if(!silent)msg($("adminNotificationsMessage"),"загружаем…");
  try{
    const data=await fetchCombinedNotifications();
    renderAdminNotifications(data);
    msg($("adminNotificationsMessage"),"");
  }catch(error){
    if(!silent)msg($("adminNotificationsMessage"),humanError(error),"error");
  }finally{
    adminNotificationsLoading=false;
    $("adminMarkAllNotificationsBtn").disabled=!adminNotificationsCache.some(item=>!item.read_at);
  }
}

function closeAdminNotifications(){
  $("adminNotificationsPopover").classList.add("hidden");
  $("adminNotificationBtn").setAttribute("aria-expanded","false");
}

async function toggleAdminNotifications(){
  const popover=$("adminNotificationsPopover");
  const opening=popover.classList.contains("hidden");
  if(!opening){closeAdminNotifications();return;}
  popover.classList.remove("hidden");
  $("adminNotificationBtn").setAttribute("aria-expanded","true");
  await loadAdminNotifications(false);
}

async function markAdminNotificationsRead(notification=null){
  if(adminNotificationsLoading)return false;
  adminNotificationsLoading=true;
  try{
    const requests=[];
    if(!notification){
      requests.push(supabase.rpc("mark_user_notifications_read",{p_item_type:null,p_item_id:null}));
      if(profile?.is_admin)requests.push(supabase.rpc("admin_mark_notifications_read",{p_notification_id:null}));
    }else if(notification.source==="admin"){
      requests.push(supabase.rpc("admin_mark_notifications_read",{p_notification_id:notification.id}));
    }else{
      requests.push(supabase.rpc("mark_user_notifications_read",{
        p_item_type:notification.item_type,p_item_id:notification.id,
      }));
    }
    const results=await Promise.all(requests);
    results.forEach(result=>{if(result.error)throw result.error;});
    renderAdminNotifications(await fetchCombinedNotifications());
    msg($("adminNotificationsMessage"),"");
    return true;
  }catch(error){
    msg($("adminNotificationsMessage"),humanError(error),"error");
    return false;
  }finally{
    adminNotificationsLoading=false;
    $("adminMarkAllNotificationsBtn").disabled=!adminNotificationsCache.some(item=>!item.read_at);
  }
}

async function waitForAdminLoad(){
  for(let attempt=0;attempt<80&&adminLoading;attempt++)await wait(50);
}

async function openAdminNotification(notification){
  if(!notification.read_at)await markAdminNotificationsRead(notification);
  closeAdminNotifications();
  if(notification.source!=="admin"){
    if(notification.game_id){
      const {data,error}=await supabase.from("games").select("*").eq("id",notification.game_id).maybeSingle();
      if(error||!data){
        switchView("play");
        alert(error?humanError(error):"эта игра уже недоступна.");
      }else{
        await openGame(data);
      }
      return;
    }
    if(notification.tournament_id){
      switchView("tournament");
      for(let attempt=0;attempt<80&&tournamentLoading;attempt++)await wait(50);
      try{
        const {data,error}=await supabase.rpc("get_tournament_board",{p_tournament_id:notification.tournament_id});
        if(error)throw error;
        currentTournamentId=notification.tournament_id;
        $("tournamentEmpty").classList.add("hidden");
        $("tournamentContent").classList.remove("hidden");
        renderTournamentBoard(data);
        msg($("tournamentMessage"),"");
      }catch(error){
        msg($("tournamentMessage"),humanError(error),"error");
      }
    }
    return;
  }
  switchView("admin");
  await waitForAdminLoad();

  if(notification.kind==="nickname_pending"){
    adminPlayerFilter="pending";
    renderAdminPlayers();
    requestAnimationFrame(()=>{
      const row=document.querySelector(`[data-admin-player-id="${notification.actor_id}"]`);
      if(!row)return;
      row.classList.add("notification-target");
      row.scrollIntoView({behavior:"smooth",block:"center"});
      setTimeout(()=>row.classList.remove("notification-target"),2200);
    });
    return;
  }

  if(notification.tournament_id){
    await openAdminTournament(notification.tournament_id);
  }
}

function startAdminNotificationPolling(){
  if(adminNotificationsTimer){clearInterval(adminNotificationsTimer);adminNotificationsTimer=null;}
  if(profile?.account_type!=="registered")return;
  loadAdminNotifications(true);
  adminNotificationsTimer=setInterval(()=>loadAdminNotifications(true),20000);
}

function setActiveAdminFilter(selector,dataName,value){
  $$(selector).forEach(button=>button.classList.toggle("active",button.dataset[dataName]===value));
}

async function loadAdmin(){
  const allowed=!!user&&!!profile?.is_admin;
  $("adminDenied").classList.toggle("hidden",allowed);
  $("adminContent").classList.toggle("hidden",!allowed);
  if(!allowed||!configured||adminLoading)return;

  adminLoading=true;
  $("refreshAdminBtn").disabled=true;
  msg($("adminMessage"),"загружаем данные…");
  try{
    const [playersResult,gamesResult,tournamentsResult]=await Promise.all([
      supabase.rpc("admin_list_players"),
      supabase.rpc("admin_list_games",{p_filter:adminGameFilter}),
      supabase.rpc("list_public_tournaments"),
    ]);
    if(playersResult.error)throw playersResult.error;
    if(gamesResult.error)throw gamesResult.error;
    if(tournamentsResult.error)throw tournamentsResult.error;
    adminPlayersCache=playersResult.data||[];
    adminGamesCache=gamesResult.data||[];
    tournamentsCache=tournamentsResult.data||[];
    renderAdminPlayers();
    renderAdminTournaments();
    renderAdminGames();
    loadAdminNotifications(true);
    msg($("adminMessage"),"");
  }catch(error){
    msg($("adminMessage"),humanError(error),"error");
  }finally{
    adminLoading=false;
    $("refreshAdminBtn").disabled=false;
  }
}

function renderAdminPlayers(){
  let rows=adminPlayersCache;
  if(adminPlayerFilter==="pending")rows=rows.filter(row=>row.account_type==="registered"&&!row.school_verified);
  if(adminPlayerFilter==="registered")rows=rows.filter(row=>row.account_type==="registered");
  if(adminPlayerFilter==="guest")rows=rows.filter(row=>row.account_type==="guest");
  setActiveAdminFilter("[data-admin-player-filter]","adminPlayerFilter",adminPlayerFilter);

  const wrap=$("adminPlayers");
  wrap.innerHTML="";
  rows.forEach(player=>{
    const item=document.createElement("div");
    item.className="admin-player-row";
    item.dataset.adminPlayerId=player.user_id;

    const identity=document.createElement("div");
    identity.className="admin-row-main";
    const name=document.createElement("strong");
    name.textContent=`${player.avatar_emoji?`${player.avatar_emoji} `:""}${player.display_name}`;
    const type=document.createElement("small");
    type.textContent=player.is_admin?"администратор":player.account_type==="guest"?"гость":"зарегистрированный игрок";
    identity.append(name,type);

    const stats=document.createElement("div");
    stats.className="admin-row-stats";
    stats.textContent=player.account_type==="registered"
      ? `рейтинг ${player.rating} · игр ${player.rated_games} · ${player.rated_wins}:${player.rated_losses}`
      : `создан ${formatAdminDate(player.created_at)}`;

    const verification=document.createElement("span");
    verification.className="badge";
    verification.textContent=player.account_type==="guest"
      ? "гостевой профиль"
      : player.school_verified?"ник подтвержден":"ждет проверки";

    const actions=document.createElement("div");
    actions.className="admin-row-actions";
    if(player.account_type==="registered"){
      const renameButton=document.createElement("button");
      renameButton.type="button";
      renameButton.textContent="исправить ник";
      renameButton.addEventListener("click",()=>changeSchoolNick(player,renameButton));
      actions.appendChild(renameButton);
      const button=document.createElement("button");
      button.type="button";
      button.textContent=player.school_verified?"снять подтверждение":"подтвердить ник";
      button.addEventListener("click",()=>setSchoolVerified(player,button));
      actions.appendChild(button);
    }
    item.append(identity,stats,verification,actions);
    wrap.appendChild(item);
  });
  $("adminPlayersCount").textContent=rows.length===adminPlayersCache.length?String(rows.length):`${rows.length} из ${adminPlayersCache.length}`;
  $("adminPlayersEmpty").classList.toggle("hidden",rows.length>0);
}

async function changeSchoolNick(player,button){
  const entered=window.prompt("исправьте школьный ник игрока:",player.display_name);
  if(entered===null)return;
  const next=entered.trim().replace(/\s+/g," ");
  if(!next || next.length>48){
    msg($("adminMessage"),"ник должен содержать от 1 до 48 символов.","error");
    return;
  }
  if(next===player.display_name)return;
  if(!window.confirm(`изменить ник «${player.display_name}» на «${next}»? подтверждение ника будет снято.`))return;
  button.disabled=true;
  try{
    const {data,error}=await supabase.rpc("admin_change_school_nick",{p_user_id:player.user_id,p_new_nick:next});
    if(error)throw error;
    player.display_name=data.display_name;
    player.school_verified=data.school_verified;
    renderAdminPlayers();
    loadAdminNotifications(true);
    msg($("adminMessage"),"ник исправлен. игрок получил уведомление; теперь подтвердите ник.","success");
  }catch(error){
    button.disabled=false;
    msg($("adminMessage"),humanError(error),"error");
  }
}

async function setSchoolVerified(player,button){
  const next=!player.school_verified;
  const action=next?"подтвердить":"снять подтверждение у";
  if(!window.confirm(`${action} ника «${player.display_name}»?`))return;
  button.disabled=true;
  try{
    const {error}=await supabase.rpc("admin_set_school_verified",{p_user_id:player.user_id,p_verified:next});
    if(error)throw error;
    player.school_verified=next;
    renderAdminPlayers();
    loadAdminNotifications(true);
    msg($("adminMessage"),next?"ник подтвержден.":"подтверждение снято.","success");
  }catch(error){
    button.disabled=false;
    msg($("adminMessage"),humanError(error),"error");
  }
}

function renderAdminTournaments(){
  const wrap=$("adminTournaments");
  wrap.innerHTML="";
  tournamentsCache.forEach(tournament=>{
    const row=document.createElement("div");row.className="admin-tournament-row";
    const main=document.createElement("div");main.className="admin-row-main";
    const name=document.createElement("strong");name.textContent=tournament.name;
    const state=document.createElement("small");state.textContent=`${tournamentStatusLabel(tournament.status)}${tournament.archived_at?" · в архиве":""}`;
    main.append(name,state);

    const facts=document.createElement("div");facts.className="admin-game-facts";
    [`${tournament.participant_count} из ${tournament.max_players} участников`,tournamentFormatLabel(tournament.tournament_format),qualifierSummary(tournament),registrationDeadlineLabel(tournament),tournament.round_count?`${tournament.round_count} раундов`:"без сетки",formatAdminDate(tournament.created_at)].filter(Boolean).forEach(text=>{
      const flag=document.createElement("span");flag.className="match-flag";flag.textContent=text;facts.appendChild(flag);
    });

    const actions=document.createElement("div");actions.className="admin-row-actions";
    const manage=document.createElement("button");manage.type="button";manage.textContent="управлять";
    manage.addEventListener("click",()=>openAdminTournament(tournament.id));actions.appendChild(manage);
    row.append(main,facts,actions);wrap.appendChild(row);
  });
  $("adminTournamentsCount").textContent=String(tournamentsCache.length);
  $("adminTournamentsEmpty").classList.toggle("hidden",tournamentsCache.length>0);
}

function syncTournamentBoard(data){
  if(!data?.tournament)return;
  const tournament=data.tournament;
  const participantCount=(data.players||[]).filter(player=>player.status==="active").length;
  const roundCount=(data.matches||[]).reduce((max,match)=>Math.max(max,Number(match.round_no)||0),0);
  const summary={...tournament,participant_count:participantCount,round_count:roundCount};
  const index=tournamentsCache.findIndex(item=>item.id===tournament.id);
  if(index>=0)tournamentsCache[index]={...tournamentsCache[index],...summary};
  else tournamentsCache.unshift(summary);
  renderAdminTournaments();
}

async function publishAdminAnnouncement(){
  if(!profile?.is_admin)return;
  const title=cleanName($("adminAnnouncementTitle").value,120);
  const body=cleanName($("adminAnnouncementBody").value,500);
  if(title.length<3){msg($("adminAnnouncementMessage"),"введите заголовок объявления.","error");return;}
  if(body.length<3){msg($("adminAnnouncementMessage"),"введите текст объявления.","error");return;}
  const button=$("adminPublishAnnouncementBtn");
  if(button.dataset.busy==="true")return;
  button.dataset.busy="true";
  button.disabled=true;
  button.textContent="отправляем…";
  msg($("adminAnnouncementMessage"),"отправляем объявление…");
  try{
    const {error}=await supabase.rpc("admin_publish_user_announcement",{p_title:title,p_body:body});
    if(error)throw error;
    $("adminAnnouncementTitle").value="";
    $("adminAnnouncementBody").value="";
    await loadAdminNotifications(true);
    msg($("adminAnnouncementMessage"),"объявление отправлено зарегистрированным игрокам.","success");
  }catch(error){
    msg($("adminAnnouncementMessage"),humanError(error),"error");
  }finally{
    delete button.dataset.busy;
    button.disabled=false;
    button.textContent="отправить объявление";
  }
}

function renderSecurityAudit(data){
  const wrap=$("adminSecurityAuditResults");
  wrap.innerHTML="";
  const items=Array.isArray(data?.items)?data.items:[];
  items.forEach(item=>{
    const row=document.createElement("div");
    row.className=`security-audit-item${item.passed?" passed":""}`;
    const label=document.createElement("span");
    label.textContent=item.label||"проверка защиты";
    row.append(label);
    wrap.append(row);
  });
  wrap.classList.toggle("hidden",items.length===0);
}

async function runSecurityAudit(){
  if(!profile?.is_admin)return;
  const button=$("adminSecurityAuditBtn");
  if(button.dataset.busy==="true")return;
  button.dataset.busy="true";
  button.disabled=true;
  button.textContent="проверяем…";
  msg($("adminSecurityAuditMessage"),"проверяем права базы…");
  try{
    const {data,error}=await supabase.rpc("admin_security_audit");
    if(error)throw error;
    renderSecurityAudit(data);
    msg(
      $("adminSecurityAuditMessage"),
      data?.passed?"основные проверки пройдены.":"найдена настройка, которую нужно исправить.",
      data?.passed?"success":"error",
    );
  }catch(error){
    renderSecurityAudit(null);
    msg($("adminSecurityAuditMessage"),humanError(error),"error");
  }finally{
    delete button.dataset.busy;
    button.disabled=false;
    button.textContent="проверить защиту";
  }
}

async function createAdminTournament(){
  if(adminTournamentBusy)return;
  const name=cleanName($("adminTournamentName").value,80);
  if(name.length<3){msg($("adminMessage"),"введите название турнира.","error");return;}
  const maxPlayers=Number.parseInt($("adminTournamentMaxPlayers").value,10);
  if(!Number.isInteger(maxPlayers)||maxPlayers<2||maxPlayers>128){
    msg($("adminMessage"),"укажите от 2 до 128 участников.","error");return;
  }
  const deadlineValue=$("adminTournamentDeadline").value;
  const deadline=deadlineValue?new Date(deadlineValue):null;
  if(!deadline||Number.isNaN(deadline.getTime())||deadline.getTime()<=Date.now()){
    msg($("adminMessage"),"укажите будущую дату окончания регистрации.","error");return;
  }
  const tournamentFormat=document.querySelector('input[name="tournamentFormat"]:checked')?.value||null;
  const button=$("adminCreateTournamentBtn");
  const storageKey=`fruitkog-tournament-create:${user.id}:${name.toLowerCase()}:${maxPlayers}:${tournamentFormat||"later"}:${deadline.toISOString()}`;
  let requestId=localStorage.getItem(storageKey);
  if(!requestId){requestId=crypto.randomUUID();localStorage.setItem(storageKey,requestId);}
  adminTournamentBusy=true;button.disabled=true;button.textContent="создаем…";
  try{
    const {data,error}=await supabase.rpc("admin_create_tournament",{
      p_name:name,p_request_id:requestId,p_max_players:maxPlayers,p_tournament_format:tournamentFormat,
      p_registration_deadline:deadline.toISOString(),
    });
    if(error)throw error;
    localStorage.removeItem(storageKey);
    $("adminTournamentName").value="";
    $("adminTournamentMaxPlayers").value="32";
    resetTournamentDeadlineInput();
    $("deferredTournamentFormat").checked=true;
    syncTournamentBoard({tournament:data,players:[],matches:[]});
    adminTournamentBusy=false;
    await openAdminTournament(data.id);
    msg($("adminMessage"),"турнир создан. игроки уже могут подавать заявки.","success");
  }catch(error){
    msg($("adminMessage"),humanError(error),"error");
  }finally{
    adminTournamentBusy=false;button.disabled=false;button.textContent="создать турнир";
  }
}

async function openAdminTournament(tournamentId){
  adminCurrentTournamentId=tournamentId;
  adminCurrentTournamentBoard=null;
  $("adminCloseTournamentBtn").classList.add("hidden");
  $("adminArchiveTournamentBtn").classList.add("hidden");
  $("adminDeleteTournamentBtn").classList.add("hidden");
  $("adminStartPlayoffBtn").classList.add("hidden");
  msg($("adminTournamentMessage"),"загружаем турнир…");
  if(!$("adminTournamentDialog").open)$("adminTournamentDialog").showModal();
  try{
    const {data,error}=await supabase.rpc("get_tournament_board",{p_tournament_id:tournamentId});
    if(error)throw error;
    renderAdminTournament(data);
    msg($("adminTournamentMessage"),"");
  }catch(error){
    msg($("adminTournamentMessage"),humanError(error),"error");
  }
}

function qualifierStartIssue(tournament,members,pendingCount){
  const playerCount=members.length;
  const matchCount=Number(tournament.qualifying_matches_per_player)||0;
  const playoffSize=Number(tournament.playoff_size)||0;
  if(!matchCount||!playoffSize)return "сначала сохраните настройки квалификации.";
  if(pendingCount)return "сначала рассмотрите все ожидающие заявки.";
  if(playerCount<2)return "для запуска нужны хотя бы два участника.";
  if(playoffSize>playerCount)return `для плей-офф на ${playoffSize} участников в составе пока недостаточно игроков.`;
  if(matchCount>=playerCount)return `у каждого игрока только ${playerCount-1} возможных соперников. уменьшите число матчей или добавьте участников.`;
  if((playerCount*matchCount)%2===1)return "с таким составом нельзя назначить всем одинаковое число матчей. измените число матчей или состав.";
  return "";
}

function renderAdminTournament(data){
  adminCurrentTournamentBoard=data;
  const tournament=data.tournament;
  const tournamentSummary=tournamentsCache.find(item=>item.id===tournament.id);
  const archived=!!(tournament.archived_at||tournamentSummary?.archived_at);
  const members=(data.players||[]).filter(player=>player.status==="active");
  const applications=data.applications||[];
  const pendingApplications=applications.filter(application=>application.status==="pending");
  const editable=["draft","registration"].includes(tournament.status);
  const registrationOpen=isTournamentRegistrationOpen(tournament);
  const formatEditable=editable&&(tournament.status==="draft"||registrationOpen);
  $("adminTournamentTitle").textContent=tournament.name;
  $("adminTournamentStatus").textContent=tournamentStatusLabel(tournament.status);
  $("adminTournamentMeta").innerHTML="";
  [`${members.length} из ${tournament.max_players} участников`,tournamentFormatLabel(tournament.tournament_format),qualifierSummary(tournament),registrationDeadlineLabel(tournament),`${pendingApplications.length} новых заявок`,tournament.started_at?`начат ${formatAdminDate(tournament.started_at)}`:`создан ${formatAdminDate(tournament.created_at)}`].filter(Boolean).forEach(text=>{
    const flag=document.createElement("span");flag.className="match-flag";flag.textContent=text;$("adminTournamentMeta").appendChild(flag);
  });
  $("adminTournamentApplicationsHint").textContent=editable
    ? registrationOpen
      ? "одобрите заявку, чтобы игрок попал в состав."
      : "срок подачи истек. уже полученные заявки можно рассмотреть."
    : "прием заявок завершен.";
  const qualifyingFormat=tournament.tournament_format==="qualifiers_playoff";
  $("adminTournamentHint").textContent=editable
    ? !tournament.tournament_format
      ? "выберите формат турнира до окончания приема заявок."
      : qualifyingFormat
      ? "настройте число матчей для каждого игрока и размер будущего плей-офф."
      : "одобренных участников можно убрать до жеребьевки."
    : "турнир уже начался: состав зафиксирован.";

  $("adminTournamentFormatStatus").textContent=tournamentFormatLabel(tournament.tournament_format);
  $("adminKnockoutTournamentFormat").checked=tournament.tournament_format==="knockout";
  $("adminQualifiersTournamentFormat").checked=tournament.tournament_format==="qualifiers_playoff";
  $$('#adminTournamentFormatSettings input[name="adminTournamentFormat"]').forEach(input=>{
    input.disabled=!formatEditable||adminTournamentBusy;
  });
  $("adminSaveTournamentFormatBtn").classList.toggle("hidden",!formatEditable);
  $("adminSaveTournamentFormatBtn").disabled=adminTournamentBusy;
  $("adminTournamentFormatHint").textContent=formatEditable
    ? tournament.tournament_format
      ? "формат можно изменить до окончания приема заявок."
      : "выберите формат после того, как станет понятен состав участников."
    : tournament.tournament_format
      ? "формат зафиксирован."
      : "прием заявок завершен, а формат не выбран. продлите срок регистрации, чтобы назначить его.";

  const deadlineSaved=!!tournament.registration_deadline;
  $("adminRegistrationSettingsStatus").textContent=!deadlineSaved
    ? "не указан"
    : registrationOpen?"запись идет":"запись завершена";
  $("adminRegistrationDeadline").value=dateTimeLocalValue(tournament.registration_deadline);
  $("adminRegistrationDeadline").disabled=!editable||adminTournamentBusy;
  $("adminSaveRegistrationDeadlineBtn").classList.toggle("hidden",!editable);
  $("adminSaveRegistrationDeadlineBtn").disabled=adminTournamentBusy;
  $("adminRegistrationSettingsHint").textContent=!editable
    ? registrationDeadlineLabel(tournament)
    : deadlineSaved
      ? "срок можно продлить или сократить до запуска турнира."
      : "укажите срок: после него новые заявки приниматься не будут.";

  const applicationWrap=$("adminTournamentApplications");applicationWrap.innerHTML="";
  pendingApplications.forEach(application=>{
    const card=document.createElement("div");card.className="admin-tournament-application";
    const text=document.createElement("span");
    const name=document.createElement("strong");name.textContent=`${application.avatar_emoji?`${application.avatar_emoji} `:""}${application.display_name}`;
    const note=document.createElement("small");note.textContent=`${application.school_verified?"ник подтвержден":"ник еще не подтвержден"} · заявка ${formatAdminDate(application.created_at)}`;
    text.append(name,note);
    const actions=document.createElement("div");actions.className="admin-row-actions";
    const approve=document.createElement("button");approve.type="button";approve.className="primary";approve.textContent="одобрить";approve.disabled=!editable||adminTournamentBusy;
    const reject=document.createElement("button");reject.type="button";reject.className="danger-outline";reject.textContent="отклонить";reject.disabled=!editable||adminTournamentBusy;
    approve.addEventListener("click",()=>reviewTournamentApplication(tournament.id,application.user_id,"approved",approve));
    reject.addEventListener("click",()=>reviewTournamentApplication(tournament.id,application.user_id,"rejected",reject));
    actions.append(approve,reject);card.append(text,actions);applicationWrap.appendChild(card);
  });
  $("adminTournamentApplicationsCount").textContent=String(pendingApplications.length);
  $("adminTournamentApplicationsEmpty").classList.toggle("hidden",pendingApplications.length>0);

  const wrap=$("adminTournamentPlayers");wrap.innerHTML="";
  members.forEach(player=>{
    const item=document.createElement("div");item.className="admin-tournament-player";
    const text=document.createElement("span");
    const name=document.createElement("strong");name.textContent=`${player.avatar_emoji?`${player.avatar_emoji} `:""}${player.display_name}`;
    const adminPlayer=adminPlayersCache.find(row=>row.user_id===player.user_id);
    const note=document.createElement("small");note.textContent=adminPlayer?.school_verified?"ник подтвержден":"ник еще не подтвержден";
    text.append(name,note);item.appendChild(text);
    if(editable){
      const actions=document.createElement("div");actions.className="admin-row-actions";
      const remove=document.createElement("button");remove.type="button";remove.className="danger-outline";remove.textContent="убрать";remove.disabled=adminTournamentBusy;
      remove.addEventListener("click",()=>removeTournamentParticipant(tournament.id,player,remove));
      actions.appendChild(remove);item.appendChild(actions);
    }
    wrap.appendChild(item);
  });
  $("adminTournamentMembersCount").textContent=String(members.length);
  $("adminTournamentPlayersEmpty").classList.toggle("hidden",members.length>0);

  const settings=$("adminQualifierSettings");
  settings.classList.toggle("hidden",!qualifyingFormat);
  if(qualifyingFormat){
    const qualifierMatches=(data.matches||[]).filter(match=>match.stage==="qualifying");
    const playoffMatches=(data.matches||[]).filter(match=>match.stage==="playoff");
    const completedMatches=qualifierMatches.filter(match=>["finished","technical"].includes(match.status)).length;
    const qualifiersStarted=!!tournament.qualifying_started_at||qualifierMatches.length>0;
    const playoffStarted=playoffMatches.length>0;
    const standings=qualifierMatches.length
      ? calculateQualifierStandings(members,qualifierMatches,tournament.playoff_size)
      : null;
    const savedMatches=Number(tournament.qualifying_matches_per_player)||3;
    const savedPlayoff=Number(tournament.playoff_size)||0;
    const validSizes=[4,8,16].filter(size=>size<=Number(tournament.max_players));
    $("adminQualifierSettingsStatus").textContent=playoffStarted?"плей-офф":standings?.completed?"завершена":qualifiersStarted?"идет":savedPlayoff?"настроена":"не настроена";
    $("adminQualifierMatches").value=String(savedMatches);
    const playoffSelect=$("adminQualifierPlayoffSize");
    playoffSelect.innerHTML="";
    validSizes.forEach(size=>{
      const option=document.createElement("option");
      option.value=String(size);option.textContent=`${size} участников`;playoffSelect.appendChild(option);
    });
    playoffSelect.value=String(validSizes.includes(savedPlayoff)?savedPlayoff:(validSizes.at(-1)||""));
    $("adminQualifierMatches").disabled=!editable||qualifiersStarted||adminTournamentBusy||!validSizes.length;
    playoffSelect.disabled=!editable||qualifiersStarted||adminTournamentBusy||!validSizes.length;
    const startIssue=qualifierStartIssue(tournament,members,pendingApplications.length);
    $("adminQualifierSettingsHint").textContent=qualifiersStarted
      ? "состав и расписание зафиксированы. результаты переносятся из игровых матчей автоматически."
      : !validSizes.length
      ? "лимит турнира должен быть не меньше 4 участников."
      : !savedPlayoff
        ? "сохраните правила квалификации, затем можно будет запустить этап."
        : startIssue||"все готово к запуску квалификации.";
    $("adminQualifierProgress").classList.toggle("hidden",!qualifiersStarted);
    $("adminQualifierProgress").textContent=qualifiersStarted
      ? playoffStarted
        ? "квалификация завершена. сетка плей-офф опубликована."
        : standings?.boundaryTie
        ? `завершено ${completedMatches} из ${qualifierMatches.length} матчей. на границе плей-офф требуется дополнительный матч.`
        : standings?.completed
          ? `завершены все ${qualifierMatches.length} матчей. можно провести жеребьевку плей-офф.`
          : `завершено ${completedMatches} из ${qualifierMatches.length} матчей.`
      : "";
    $("adminSaveQualifierSettingsBtn").classList.toggle("hidden",!editable||qualifiersStarted);
    $("adminSaveQualifierSettingsBtn").disabled=adminTournamentBusy||!validSizes.length;
    $("adminStartQualifiersBtn").classList.toggle("hidden",!editable||qualifiersStarted);
    $("adminStartQualifiersBtn").disabled=adminTournamentBusy||!!startIssue;
    $("adminStartPlayoffBtn").classList.toggle("hidden",tournament.status!=="active"||!qualifiersStarted||playoffStarted);
    $("adminStartPlayoffBtn").disabled=adminTournamentBusy||!standings?.completed||!!standings?.boundaryTie;
  }
  $("adminGenerateTournamentBtn").classList.toggle("hidden",!editable||qualifyingFormat||!tournament.tournament_format);
  $("adminGenerateTournamentBtn").disabled=adminTournamentBusy||members.length<2;
  $("adminGenerateTournamentBtn").textContent="провести жеребьевку";
  const canClose=!['finished','cancelled'].includes(tournament.status);
  $("adminCloseTournamentBtn").classList.remove("hidden");
  $("adminCloseTournamentBtn").disabled=adminTournamentBusy||!canClose;
  $("adminCloseTournamentBtn").textContent=tournament.status==='cancelled'
    ? "турнир закрыт"
    : tournament.status==='finished'
      ? "турнир завершен"
      : "закрыть турнир";
  $("adminArchiveTournamentBtn").classList.toggle("hidden",tournament.status!=="finished");
  $("adminArchiveTournamentBtn").disabled=adminTournamentBusy;
  $("adminArchiveTournamentBtn").textContent=archived?"вернуть из архива":"отправить в архив";
  $("adminDeleteTournamentBtn").classList.remove("hidden");
  $("adminDeleteTournamentBtn").disabled=adminTournamentBusy;
  $("adminDeleteTournamentBtn").textContent="удалить навсегда";
}

async function reviewTournamentApplication(tournamentId,playerId,decision,button){
  if(adminTournamentBusy)return;
  if(decision==="rejected"&&!window.confirm("отклонить эту заявку? игрок сможет подать ее повторно, пока регистрация открыта."))return;
  adminTournamentBusy=true;
  $$("#adminTournamentApplications button,#adminTournamentPlayers button").forEach(item=>item.disabled=true);
  $("adminGenerateTournamentBtn").disabled=true;
  $("adminSaveQualifierSettingsBtn").disabled=true;
  $("adminStartQualifiersBtn").disabled=true;
  button.textContent=decision==="approved"?"одобряем…":"отклоняем…";
  msg($("adminTournamentMessage"),decision==="approved"?"одобряем заявку…":"отклоняем заявку…");
  try{
    const {data,error}=await supabase.rpc("admin_review_tournament_application",{
      p_tournament_id:tournamentId,p_user_id:playerId,p_decision:decision,
    });
    if(error)throw error;
    adminTournamentBusy=false;
    syncTournamentBoard(data);
    renderAdminTournament(data);
    loadAdminNotifications(true);
    msg($("adminTournamentMessage"),decision==="approved"?"заявка одобрена. игрок добавлен в состав.":"заявка отклонена.","success");
  }catch(error){
    adminTournamentBusy=false;
    await openAdminTournament(tournamentId);
    msg($("adminTournamentMessage"),humanError(error),"error");
  }
}

async function removeTournamentParticipant(tournamentId,player,button){
  if(adminTournamentBusy)return;
  if(!window.confirm(`убрать «${player.display_name}» из состава турнира? заявка будет отклонена.`))return;
  adminTournamentBusy=true;
  $$("#adminTournamentApplications button,#adminTournamentPlayers button").forEach(item=>item.disabled=true);
  $("adminGenerateTournamentBtn").disabled=true;
  $("adminSaveQualifierSettingsBtn").disabled=true;
  $("adminStartQualifiersBtn").disabled=true;
  button.textContent="убираем…";
  msg($("adminTournamentMessage"),"убираем участника…");
  try{
    const {data,error}=await supabase.rpc("admin_remove_tournament_player",{p_tournament_id:tournamentId,p_user_id:player.user_id});
    if(error)throw error;
    adminTournamentBusy=false;
    syncTournamentBoard(data);
    renderAdminTournament(data);
    msg($("adminTournamentMessage"),"участник убран из состава.","success");
  }catch(error){
    adminTournamentBusy=false;
    await openAdminTournament(tournamentId);
    msg($("adminTournamentMessage"),humanError(error),"error");
  }
}

async function generateTournament(){
  if(!adminCurrentTournamentId||adminTournamentBusy)return;
  const tournament=adminCurrentTournamentBoard?.tournament;
  if(tournament?.tournament_format==="qualifiers_playoff")return;
  if(!window.confirm("провести случайную жеребьевку? после этого состав турнира будет зафиксирован."))return;
  adminTournamentBusy=true;
  $("adminGenerateTournamentBtn").disabled=true;
  $("adminGenerateTournamentBtn").textContent="строим сетку…";
  try{
    const {data,error}=await supabase.rpc("admin_generate_tournament",{p_tournament_id:adminCurrentTournamentId});
    if(error)throw error;
    adminTournamentBusy=false;
    syncTournamentBoard(data);
    renderAdminTournament(data);
    msg($("adminTournamentMessage"),"жеребьевка проведена. сетка опубликована.","success");
  }catch(error){
    msg($("adminTournamentMessage"),humanError(error),"error");
  }finally{
    adminTournamentBusy=false;
    $("adminGenerateTournamentBtn").textContent="провести жеребьевку";
  }
}

async function configureTournamentQualifiers(tournament){
  if(!tournament||adminTournamentBusy)return;
  const matches=Number.parseInt($("adminQualifierMatches").value,10);
  const playoffSize=Number.parseInt($("adminQualifierPlayoffSize").value,10);
  if(!Number.isInteger(matches)||matches<1||matches>10){
    msg($("adminTournamentMessage"),"укажите от 1 до 10 квалификационных матчей.","error");return;
  }
  if(![4,8,16].includes(playoffSize)||playoffSize>Number(tournament.max_players)){
    msg($("adminTournamentMessage"),"выберите допустимый размер плей-офф.","error");return;
  }
  adminTournamentBusy=true;
  const button=$("adminSaveQualifierSettingsBtn");
  button.disabled=true;
  button.textContent="сохраняем…";
  $("adminStartQualifiersBtn").disabled=true;
  $("adminQualifierMatches").disabled=true;
  $("adminQualifierPlayoffSize").disabled=true;
  try{
    const {data,error}=await supabase.rpc("admin_configure_tournament_qualifiers",{
      p_tournament_id:tournament.id,
      p_qualifying_matches:matches,
      p_playoff_size:playoffSize,
    });
    if(error)throw error;
    adminTournamentBusy=false;
    syncTournamentBoard(data);
    renderAdminTournament(data);
    msg($("adminTournamentMessage"),"настройки квалификации сохранены.","success");
  }catch(error){
    adminTournamentBusy=false;
    if(adminCurrentTournamentBoard)renderAdminTournament(adminCurrentTournamentBoard);
    msg($("adminTournamentMessage"),humanError(error),"error");
  }finally{
    button.textContent="сохранить настройки";
  }
}

async function startTournamentQualifiers(){
  const tournament=adminCurrentTournamentBoard?.tournament;
  if(!tournament||adminTournamentBusy)return;
  const members=(adminCurrentTournamentBoard.players||[]).filter(player=>player.status==="active");
  const pending=(adminCurrentTournamentBoard.applications||[]).filter(application=>application.status==="pending").length;
  const issue=qualifierStartIssue(tournament,members,pending);
  if(issue){msg($("adminTournamentMessage"),issue,"error");return;}
  const totalMatches=(members.length*Number(tournament.qualifying_matches_per_player))/2;
  if(!window.confirm(`запустить квалификацию? будет создано ${totalMatches} матчей, состав и настройки зафиксируются.`))return;

  adminTournamentBusy=true;
  const button=$("adminStartQualifiersBtn");
  button.disabled=true;
  button.textContent="создаем матчи…";
  $("adminSaveQualifierSettingsBtn").disabled=true;
  msg($("adminTournamentMessage"),"составляем расписание и создаем матчи…");
  try{
    const {data,error}=await supabase.rpc("admin_start_tournament_qualifiers",{
      p_tournament_id:tournament.id,
    });
    if(error)throw error;
    adminTournamentBusy=false;
    syncTournamentBoard(data);
    renderAdminTournament(data);
    await Promise.all([loadLobby(),loadAdminNotifications(true)]);
    msg($("adminTournamentMessage"),"квалификация запущена. матчи опубликованы, участники получили уведомления.","success");
  }catch(error){
    adminTournamentBusy=false;
    if(adminCurrentTournamentBoard)renderAdminTournament(adminCurrentTournamentBoard);
    msg($("adminTournamentMessage"),humanError(error),"error");
  }finally{
    button.textContent="запустить квалификацию";
  }
}

async function startTournamentPlayoff(){
  const tournament=adminCurrentTournamentBoard?.tournament;
  if(!tournament||adminTournamentBusy)return;
  const qualifierMatches=(adminCurrentTournamentBoard.matches||[]).filter(match=>match.stage==="qualifying");
  const standings=calculateQualifierStandings(
    adminCurrentTournamentBoard.players||[],qualifierMatches,tournament.playoff_size
  );
  if(!standings.completed){
    msg($("adminTournamentMessage"),"сначала завершите все квалификационные матчи.","error");return;
  }
  if(standings.boundaryTie){
    msg($("adminTournamentMessage"),"на границе выхода осталось равенство. сначала нужен дополнительный матч.","error");return;
  }
  if(!window.confirm("провести жеребьевку плей-офф? равные участники будут распределены случайно, остальные займут места по результатам квалификации."))return;

  adminTournamentBusy=true;
  const button=$("adminStartPlayoffBtn");
  button.disabled=true;
  button.textContent="строим сетку…";
  msg($("adminTournamentMessage"),"распределяем места и создаем матчи плей-офф…");
  try{
    const {data,error}=await supabase.rpc("admin_start_tournament_playoff",{
      p_tournament_id:tournament.id,
    });
    if(error)throw error;
    adminTournamentBusy=false;
    syncTournamentBoard(data);
    renderAdminTournament(data);
    if(currentTournamentId===tournament.id)renderTournamentBoard(data);
    await Promise.all([loadLobby(),loadAdminNotifications(true)]);
    msg($("adminTournamentMessage"),"жеребьевка проведена. сетка и первые матчи плей-офф опубликованы.","success");
  }catch(error){
    adminTournamentBusy=false;
    if(adminCurrentTournamentBoard)renderAdminTournament(adminCurrentTournamentBoard);
    msg($("adminTournamentMessage"),humanError(error),"error");
  }finally{
    button.textContent="провести жеребьевку плей-офф";
  }
}

async function saveTournamentRegistrationDeadline(){
  const tournament=adminCurrentTournamentBoard?.tournament;
  if(!tournament||adminTournamentBusy)return;
  const value=$("adminRegistrationDeadline").value;
  const deadline=value?new Date(value):null;
  if(!deadline||Number.isNaN(deadline.getTime())||deadline.getTime()<=Date.now()){
    msg($("adminTournamentMessage"),"укажите будущую дату окончания регистрации.","error");return;
  }
  adminTournamentBusy=true;
  const button=$("adminSaveRegistrationDeadlineBtn");
  button.disabled=true;button.textContent="сохраняем…";
  try{
    const {data,error}=await supabase.rpc("admin_set_tournament_registration_deadline",{
      p_tournament_id:tournament.id,
      p_registration_deadline:deadline.toISOString(),
    });
    if(error)throw error;
    adminTournamentBusy=false;
    syncTournamentBoard(data);
    renderAdminTournament(data);
    msg($("adminTournamentMessage"),"срок регистрации сохранен.","success");
  }catch(error){
    adminTournamentBusy=false;
    if(adminCurrentTournamentBoard)renderAdminTournament(adminCurrentTournamentBoard);
    msg($("adminTournamentMessage"),humanError(error),"error");
  }finally{
    button.textContent="сохранить срок";
  }
}

async function saveTournamentFormat(){
  const tournament=adminCurrentTournamentBoard?.tournament;
  if(!tournament||adminTournamentBusy)return;
  const selected=document.querySelector('input[name="adminTournamentFormat"]:checked')?.value;
  if(!selected){
    msg($("adminTournamentMessage"),"выберите формат турнира.","error");
    return;
  }
  adminTournamentBusy=true;
  const button=$("adminSaveTournamentFormatBtn");
  button.disabled=true;
  button.textContent="сохраняем…";
  try{
    const {data,error}=await supabase.rpc("admin_set_tournament_format",{
      p_tournament_id:tournament.id,
      p_tournament_format:selected,
    });
    if(error)throw error;
    adminTournamentBusy=false;
    syncTournamentBoard(data);
    renderAdminTournament(data);
    msg($("adminTournamentMessage"),"формат турнира сохранен.","success");
  }catch(error){
    adminTournamentBusy=false;
    if(adminCurrentTournamentBoard)renderAdminTournament(adminCurrentTournamentBoard);
    msg($("adminTournamentMessage"),humanError(error),"error");
  }finally{
    button.textContent="сохранить формат";
  }
}

async function closeAdminTournament(tournament,button){
  if(adminTournamentBusy)return;
  if(!window.confirm(`закрыть турнир «${tournament.name}»? состав, сетка и результаты сохранятся.`))return;
  adminTournamentBusy=true;
  button.disabled=true;
  button.textContent="закрываем…";
  try{
    const {data,error}=await supabase.rpc("admin_close_tournament",{p_tournament_id:tournament.id});
    if(error)throw error;
    adminTournamentBusy=false;
    syncTournamentBoard(data);
    renderAdminTournament(data);
    loadAdminNotifications(true);
    msg($("adminTournamentMessage"),"турнир закрыт. все данные сохранены.","success");
  }catch(error){
    button.disabled=false;
    button.textContent="закрыть турнир";
    msg($("adminTournamentMessage"),humanError(error),"error");
  }finally{
    adminTournamentBusy=false;
  }
}

async function setAdminTournamentArchived(tournament,button){
  if(adminTournamentBusy||tournament.status!=="finished")return;
  const summary=tournamentsCache.find(item=>item.id===tournament.id);
  const nextArchived=!(tournament.archived_at||summary?.archived_at);
  const action=nextArchived?"отправить в архив":"вернуть из архива";
  if(!window.confirm(`${action} турнир «${tournament.name}»?`))return;
  adminTournamentBusy=true;
  button.disabled=true;
  button.textContent=nextArchived?"архивируем…":"возвращаем…";
  try{
    const {data,error}=await supabase.rpc("admin_set_tournament_archived",{
      p_tournament_id:tournament.id,
      p_archived:nextArchived,
    });
    if(error)throw error;
    const archivedAt=nextArchived?new Date().toISOString():null;
    const cached=tournamentsCache.find(item=>item.id===tournament.id);
    if(cached)cached.archived_at=archivedAt;
    if(data?.tournament)data.tournament.archived_at=archivedAt;
    if(nextArchived&&currentTournamentId===tournament.id){
      currentTournamentId=null;
      openedArchivedTournamentId=null;
    }
    adminTournamentBusy=false;
    syncTournamentBoard(data);
    renderAdminTournament(data);
    await loadTournaments();
    msg($("adminTournamentMessage"),nextArchived?"турнир отправлен в архив.":"турнир снова показан на странице.","success");
  }catch(error){
    msg($("adminTournamentMessage"),humanError(error),"error");
  }finally{
    adminTournamentBusy=false;
    button.disabled=false;
  }
}

async function deleteAdminTournament(tournament,button){
  if(adminTournamentBusy)return;
  if(!window.confirm(`удалить турнир «${tournament.name}» навсегда? восстановить его не получится.`))return;
  const hasTournamentHistory=tournament.status!=="registration"||Number(tournament.round_count)>0;
  if(hasTournamentHistory&&!window.confirm("в турнире уже есть сетка или история. турнирные данные будут удалены, но сыгранные матчи и рейтинг сохранятся. точно удалить?"))return;
  adminTournamentBusy=true;
  button.disabled=true;
  button.textContent="удаляем…";
  try{
    const {error}=await supabase.rpc("admin_delete_tournament",{p_tournament_id:tournament.id});
    if(error)throw error;
    tournamentsCache=tournamentsCache.filter(item=>item.id!==tournament.id);
    renderAdminTournaments();
    if(adminCurrentTournamentId===tournament.id){
      adminCurrentTournamentId=null;
      if($("adminTournamentDialog").open)$("adminTournamentDialog").close();
    }
    loadAdminNotifications(true);
    msg($("adminMessage"),"турнир удален.","success");
  }catch(error){
    button.disabled=false;
    button.textContent="удалить навсегда";
    msg($("adminMessage"),humanError(error),"error");
  }finally{
    adminTournamentBusy=false;
  }
}

function adminGameTypeLabel(row){
  if(row.game_type==="tournament")return "турнирная";
  if(row.game_type==="rated"&&row.rating_applied)return `рейтинговая · ${row.rating_delta??0} очков`;
  if(row.game_type==="rated")return "рейтинговая";
  if(row.rating_skip_reason==="pair_daily_limit")return "без рейтинга · лимит пары";
  if(row.rating_skip_reason==="guest")return "без рейтинга · гость";
  return "без рейтинга";
}

function adminGameSummary(row){
  if(row.status==="playing"){
    const name=row.current_turn===row.player1_id?row.player1_name:row.player2_name;
    return `сейчас ходит ${name||"—"}`;
  }
  if(row.status==="finished"){
    const winner=row.winner_id===row.player1_id?row.player1_name:row.player2_name;
    return row.finish_reason==="surrender"?`победитель: ${winner} · соперник сдался`:`победитель: ${winner}`;
  }
  if(row.status==="cancelled")return row.admin_cancel_reason||"комната закрыта";
  if(row.status==="paused")return row.pause_reason||"ожидает решения администратора";
  return statusLabel(row.status);
}

function renderAdminGames(){
  setActiveAdminFilter("[data-admin-game-filter]","adminGameFilter",adminGameFilter);
  const wrap=$("adminGames");
  wrap.innerHTML="";
  adminGamesCache.forEach(row=>{
    const item=document.createElement("div");
    item.className="admin-game-row";

    const main=document.createElement("div");
    main.className="admin-row-main";
    const names=document.createElement("strong");
    names.textContent=row.player2_name?`${row.player1_name} — ${row.player2_name}`:`${row.player1_name} ждет соперника`;
    const summary=document.createElement("small");
    summary.textContent=adminGameSummary(row);
    main.append(names,summary);

    const facts=document.createElement("div");
    facts.className="admin-game-facts";
    [statusLabel(row.status),adminGameTypeLabel(row),`${row.shot_count} ходов`,formatAdminDate(row.updated_at)].forEach(text=>{
      const flag=document.createElement("span");flag.className="match-flag";flag.textContent=text;facts.appendChild(flag);
    });
    if(row.player2_id){
      const pair=document.createElement("span");pair.className="match-flag";
      pair.textContent=`пара за 24 часа: ${row.pair_finished_24h}, сдач: ${row.pair_surrenders_24h}`;
      facts.appendChild(pair);
    }

    const actions=document.createElement("div");
    actions.className="admin-row-actions";
    const details=document.createElement("button");
    details.type="button";details.textContent="подробности";
    details.addEventListener("click",()=>openAdminGame(row.id));
    actions.appendChild(details);
    if(["waiting","placing","playing","paused"].includes(row.status)){
      const close=document.createElement("button");
      close.type="button";close.className="danger-outline";close.textContent="закрыть матч";
      close.addEventListener("click",()=>adminCancelGame(row.id));
      actions.appendChild(close);
    }
    item.append(main,facts,actions);
    wrap.appendChild(item);
  });
  $("adminGamesCount").textContent=String(adminGamesCache.length);
  $("adminGamesEmpty").classList.toggle("hidden",adminGamesCache.length>0);
}

function renderAdminBoard(container,fleet,gameShots,ownerId){
  resetBoard(container);
  const shipCells=new Set((fleet?.ships||[]).flatMap(ship=>ship.cells||[]));
  container.querySelectorAll(".board-cell").forEach(cell=>{
    if(shipCells.has(cell.dataset.cell))cell.classList.add("ship");
    cell.disabled=true;
  });
  gameShots.filter(shot=>shot.target_id===ownerId).forEach(shot=>{
    const cell=container.querySelector(`[data-cell="${shot.cell}"]`);
    if(!cell)return;
    cell.classList.remove("ship");
    cell.classList.add(shot.result==="miss"?"miss":"hit");
  });
}

async function openAdminGame(gameId){
  adminCurrentGameId=gameId;
  msg($("adminGameMessage"),"загружаем матч…");
  $("adminGameDialog").showModal();
  try{
    const {data,error}=await supabase.rpc("admin_get_game_details",{p_game_id:gameId});
    if(error)throw error;
    const current=data.game;
    const fleets=data.fleets||[];
    const gameShots=data.shots||[];
    $("adminGameTitle").textContent=current.player2_name?`${current.player1_name} — ${current.player2_name}`:`${current.player1_name} ждет соперника`;
    $("adminGameStatus").textContent=statusLabel(current.status);
    $("adminBoard1Title").textContent=`поле: ${current.player1_name}`;
    $("adminBoard2Title").textContent=`поле: ${current.player2_name||"игрок 2"}`;
    $("adminGameMeta").innerHTML="";
    const meta=[
      `режим: ${adminGameTypeLabel(current)}`,
      `создан: ${formatAdminDate(current.created_at)}`,
      `обновлен: ${formatAdminDate(current.updated_at)}`,
      `ходов: ${gameShots.length}`,
    ];
    if(current.finish_reason)meta.push(`завершение: ${current.finish_reason==="surrender"?"сдача":"флот уничтожен"}`);
    if(current.admin_cancel_reason)meta.push(`причина закрытия: ${current.admin_cancel_reason}`);
    meta.forEach(text=>{const span=document.createElement("span");span.className="match-flag";span.textContent=text;$("adminGameMeta").appendChild(span);});

    const outcome=$("adminGameOutcome");
    outcome.replaceChildren();
    outcome.className="admin-game-outcome hidden";
    if(current.status==="finished"&&current.winner_id){
      const winner=current.winner_id===current.player1_id?current.player1_name:current.player2_name;
      const loser=current.winner_id===current.player1_id?current.player2_name:current.player1_name;
      const title=document.createElement("strong");
      title.textContent=`победитель: ${winner}`;
      outcome.appendChild(title);
      if(current.finish_reason==="surrender"){
        const note=document.createElement("span");
        note.textContent=`${loser} сдался`;
        outcome.appendChild(note);
      }
      outcome.classList.remove("hidden");
    }else if(current.status==="cancelled"){
      const title=document.createElement("strong");
      title.textContent="победителя нет";
      const note=document.createElement("span");
      note.textContent=current.admin_cancel_reason?`матч закрыт администратором: ${current.admin_cancel_reason}`:"матч был закрыт до завершения";
      outcome.append(title,note);
      outcome.classList.add("cancelled");
      outcome.classList.remove("hidden");
    }

    renderAdminBoard($("adminBoard1"),fleets.find(fleet=>fleet.owner_id===current.player1_id),gameShots,current.player1_id);
    renderAdminBoard($("adminBoard2"),fleets.find(fleet=>fleet.owner_id===current.player2_id),gameShots,current.player2_id);
    $("adminShotLog").innerHTML="";
    gameShots.forEach(shot=>{
      const line=document.createElement("li");
      const shooter=shot.shooter_id===current.player1_id?current.player1_name:current.player2_name;
      line.textContent=`${shooter}: ${shot.cell} — ${resultLabel(shot,gameShots)} · ${formatAdminDate(shot.created_at)}`;
      $("adminShotLog").appendChild(line);
    });
    if(!gameShots.length){const line=document.createElement("li");line.textContent="ходов пока нет";$("adminShotLog").appendChild(line);}
    $("adminCancelGameBtn").classList.toggle("hidden",!["waiting","placing","playing","paused"].includes(current.status));
    msg($("adminGameMessage"),"");
  }catch(error){
    msg($("adminGameMessage"),humanError(error),"error");
  }
}

async function adminCancelGame(gameId){
  const reason=window.prompt("почему закрываем матч? эта причина будет видна только администратору.","зависший матч");
  if(reason===null)return;
  if(!window.confirm("закрыть матч без победителя и без изменения рейтинга?"))return;
  try{
    const {error}=await supabase.rpc("admin_cancel_game",{p_game_id:gameId,p_reason:reason});
    if(error)throw error;
    if($("adminGameDialog").open)$("adminGameDialog").close();
    adminCurrentGameId=null;
    await loadAdmin();
    msg($("adminMessage"),"матч закрыт. поля и журнал сохранены для администратора.","success");
  }catch(error){
    const target=$("adminGameDialog").open?$("adminGameMessage"):$("adminMessage");
    msg(target,humanError(error),"error");
  }
}

function wire(){
  $$("[data-view]").forEach(b=>b.addEventListener("click",()=>switchView(b.dataset.view)));
  $("openAuthBtn").addEventListener("click",()=>openAuth("login"));
  $("adminNotificationBtn").addEventListener("click",toggleAdminNotifications);
  $("adminMarkAllNotificationsBtn").addEventListener("click",()=>markAdminNotificationsRead(null));
  document.addEventListener("pointerdown",event=>{
    if(!$("adminNotificationShell").contains(event.target))closeAdminNotifications();
    $$(".lobby-mode-help[open], .placement-help[open], .tournament-results-help[open], .auth-field-help[open]").forEach(details=>{
      if(!details.contains(event.target))details.removeAttribute("open");
    });
  });
  document.addEventListener("keydown",event=>{
    if(event.key==="Escape"){
      closeAdminNotifications();
      $$(".lobby-mode-help[open], .placement-help[open], .tournament-results-help[open], .auth-field-help[open]").forEach(details=>details.removeAttribute("open"));
    }
  });
  $("needAuthBtn").addEventListener("click",()=>openAuth("register"));
  $("loginTab").addEventListener("click",()=>setAuthTab("login"));
  $("registerTab").addEventListener("click",()=>setAuthTab("register"));
  $("guestTab").addEventListener("click",()=>setAuthTab("guest"));
  $("registerBtn").addEventListener("click",register);
  $("loginBtn").addEventListener("click",login);
  $("forgotPasswordBtn").addEventListener("click",()=>{
    $("passwordEmail").value=$("loginEmail").value.trim();
    msg($("passwordRequestMessage"));
    showPasswordDialog();
  });
  $("sendPasswordLinkBtn").addEventListener("click",sendPasswordLink);
  $("updatePasswordBtn").addEventListener("click",updatePassword);
  $("guestBtn").addEventListener("click",guestLogin);
  $("logoutBtn").addEventListener("click",logout);
  $("openPlayerProfileBtn").addEventListener("click",()=>{
    $("profileDialog").close();
    if(profile?.account_type==="registered")openPlayerProfile(profile.user_id);
  });
  $("createGameBtn").addEventListener("click",createGame);
  $("refreshGamesBtn").addEventListener("click",loadLobby);
  $("refreshTournamentBtn").addEventListener("click",loadTournaments);
  $$('[data-tournament-demo]').forEach(button=>button.addEventListener("click",()=>{
    renderTournamentDemoState(button.dataset.tournamentDemo);
    $("tournamentView").scrollIntoView({behavior:"smooth",block:"start"});
  }));
  $("tournamentArchiveBackBtn").addEventListener("click",()=>{
    if(TOURNAMENT_DEMO_ENABLED){renderTournamentDemoState("none");return;}
    openedArchivedTournamentId=null;
    currentTournamentId=null;
    loadTournaments();
  });
  $$('[data-tournament-section]').forEach(button=>button.addEventListener("click",()=>{
    activateTournamentSection(button.dataset.tournamentSection);
  }));
  $("tournamentApplicationBtn").addEventListener("click",changeTournamentApplication);
  $("refreshAdminBtn").addEventListener("click",loadAdmin);
  $("adminSecurityAuditBtn").addEventListener("click",runSecurityAudit);
  $("adminPublishAnnouncementBtn").addEventListener("click",publishAdminAnnouncement);
  $("adminCreateTournamentBtn").addEventListener("click",createAdminTournament);
  $("adminSaveRegistrationDeadlineBtn").addEventListener("click",saveTournamentRegistrationDeadline);
  $("adminSaveTournamentFormatBtn").addEventListener("click",saveTournamentFormat);
  $("adminSaveQualifierSettingsBtn").addEventListener("click",()=>configureTournamentQualifiers(adminCurrentTournamentBoard?.tournament));
  $("adminStartQualifiersBtn").addEventListener("click",startTournamentQualifiers);
  $("adminStartPlayoffBtn").addEventListener("click",startTournamentPlayoff);
  $("adminGenerateTournamentBtn").addEventListener("click",generateTournament);
  $("adminCloseTournamentBtn").addEventListener("click",()=>{
    const tournament=tournamentsCache.find(item=>item.id===adminCurrentTournamentId);
    if(tournament)closeAdminTournament(tournament,$("adminCloseTournamentBtn"));
  });
  $("adminArchiveTournamentBtn").addEventListener("click",()=>{
    const tournament=adminCurrentTournamentBoard?.tournament;
    if(tournament)setAdminTournamentArchived(tournament,$("adminArchiveTournamentBtn"));
  });
  $("adminDeleteTournamentBtn").addEventListener("click",()=>{
    const tournament=tournamentsCache.find(item=>item.id===adminCurrentTournamentId);
    if(tournament)deleteAdminTournament(tournament,$("adminDeleteTournamentBtn"));
  });
  $("adminCloseTournamentDialogBtn").addEventListener("click",()=>$("adminTournamentDialog").close());
  $$('[data-admin-player-filter]').forEach(button=>button.addEventListener("click",()=>{
    adminPlayerFilter=button.dataset.adminPlayerFilter;renderAdminPlayers();
  }));
  $$('[data-admin-game-filter]').forEach(button=>button.addEventListener("click",async()=>{
    adminGameFilter=button.dataset.adminGameFilter;
    setActiveAdminFilter("[data-admin-game-filter]","adminGameFilter",adminGameFilter);
    await loadAdmin();
  }));
  $("adminCancelGameBtn").addEventListener("click",()=>adminCurrentGameId&&adminCancelGame(adminCurrentGameId));
  $("adminCloseDialogBtn").addEventListener("click",()=>$("adminGameDialog").close());
  $$('[data-game-filter]').forEach(button=>button.addEventListener("click",()=>{
    activeFilter=button.dataset.gameFilter;renderActiveGames();
  }));
  syncVegetableMode();
  $("backLobbyBtn").addEventListener("click",returnToLobby);
  $("closeGameBtn").addEventListener("click",()=>exitPreGame());
  $("surrenderGameBtn").addEventListener("click",surrenderGame);
  $("placementBoard").addEventListener("pointermove",movePlacementDrag);
  $("placementBoard").addEventListener("pointerup",endPlacementDrag);
  $("placementBoard").addEventListener("pointercancel",cancelPlacementDrag);
  $("resetFleetBtn").addEventListener("click",()=>{placement=emptyPlacement();savePlacementDraft();renderPlacement();});
  $("readyBtn").addEventListener("click",ready);
}

async function handleSession(session){
  const generation=++sessionGeneration;
  const nextUser=session?.user||null;
  if(adminNotificationsTimer){clearInterval(adminNotificationsTimer);adminNotificationsTimer=null;}
  adminNotificationsCache=[];
  renderAdminNotifications({items:[],unread_count:0});
  closeAdminNotifications();
  authReady=false;
  user=nextUser;
  profile=null;
  renderAccount();
  if(user){
    const loadedProfile=await fetchProfile(user.id);
    if(generation!==sessionGeneration)return;
    if(!loadedProfile){
      setTimeout(()=>{
        if(generation===sessionGeneration&&user?.id===nextUser.id)handleSession(session);
      },1500);
      return;
    }
    profile=loadedProfile;
  }
  authReady=true;
  renderAccount();
  startAdminNotificationPolling();
  if(user){
    await subscribeToLobby();
    await loadLobby();
    if(generation!==sessionGeneration)return;
    await restoreGame();
  }
  restoreSavedView();
}

async function init(){
  wire();
  updateTournamentDemoControls();
  document.body.dataset.view="home";
  resetTournamentDeadlineInput();
  buildBoard($("placementBoard"),null);buildBoard($("ownBoard"),null);buildBoard($("enemyBoard"),null);
  buildBoard($("adminBoard1"),null);buildBoard($("adminBoard2"),null);

  if(!configured){
    if(TOURNAMENT_DEMO_ENABLED){
      authReady=true;
      renderAccount();
      restoreSavedView();
      return;
    }
    $("setupWarning").classList.remove("hidden");
    return;
  }

  supabase=createClient(SUPABASE_URL,SUPABASE_PUBLISHABLE_KEY);
  supabase.auth.onAuthStateChange((_event,session)=>{
    if(_event==="PASSWORD_RECOVERY")setTimeout(()=>showPasswordDialog(true),0);
    if (guestSetupInProgress) return;
    if (authReady && (session?.user?.id||null)===(user?.id||null)) return;
    setTimeout(()=>handleSession(session),0);
  });
  const {data}=await supabase.auth.getSession();
  await handleSession(data.session);

  await loadRating();
}
init();
