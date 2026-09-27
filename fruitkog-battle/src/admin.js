// Админ-панель: загрузка, игроки, матчи, объявления, проверка защиты.
import { app } from "./state.js?v=118";
import { configured } from "./constants.js?v=118";
import { $, $$, cleanName, cleanText, formatAdminDate, msg } from "./helpers.js?v=118";
import { humanError } from "./errors.js?v=118";
import { statusLabel } from "./room.js?v=118";
import { resetBoard } from "./board.js?v=118";
import { resultLabel } from "./battle.js?v=118";
import { qualifierSummary, registrationDeadlineLabel, tournamentFormatLabel, tournamentStatusLabel } from "./tournament.js?v=118";
import { loadAdminNotifications } from "./admin-notifications.js?v=118";
import { loadAdminGameSettings } from "./admin-settings.js?v=118";
import { openAdminTournament } from "./admin-tournaments.js?v=118";

export function setActiveAdminFilter(selector,dataName,value){
  $$(selector).forEach(button=>button.classList.toggle("active",button.dataset[dataName]===value));
}

export async function loadAdmin(){
  const allowed=!!app.user&&!!app.profile?.is_admin;
  $("adminDenied").classList.toggle("hidden",allowed);
  $("adminContent").classList.toggle("hidden",!allowed);
  if(!allowed||!configured||app.adminLoading)return;

  app.adminLoading=true;
  $("refreshAdminBtn").disabled=true;
  msg($("adminMessage"),"загружаем данные…");
  try{
    const [playersResult,gamesResult,tournamentsResult]=await Promise.all([
      app.supabase.rpc("admin_list_players"),
      app.supabase.rpc("admin_list_games",{p_filter:app.adminGameFilter}),
      app.supabase.rpc("list_public_tournaments"),
    ]);
    if(playersResult.error)throw playersResult.error;
    if(gamesResult.error)throw gamesResult.error;
    if(tournamentsResult.error)throw tournamentsResult.error;
    app.adminPlayersCache=playersResult.data||[];
    app.adminGamesCache=gamesResult.data||[];
    app.tournamentsCache=tournamentsResult.data||[];
    renderAdminPlayers();
    renderAdminTournaments();
    renderAdminGames();
    loadAdminNotifications(true);
    loadAdminGameSettings();
    msg($("adminMessage"),"");
  }catch(error){
    msg($("adminMessage"),humanError(error),"error");
  }finally{
    app.adminLoading=false;
    $("refreshAdminBtn").disabled=false;
  }
}

export function renderAdminPlayers(){
  let rows=app.adminPlayersCache;
  if(app.adminPlayerFilter==="pending")rows=rows.filter(row=>row.account_type==="registered"&&!row.school_verified);
  if(app.adminPlayerFilter==="registered")rows=rows.filter(row=>row.account_type==="registered");
  if(app.adminPlayerFilter==="guest")rows=rows.filter(row=>row.account_type==="guest");
  setActiveAdminFilter("[data-admin-player-filter]","adminPlayerFilter",app.adminPlayerFilter);

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
  $("adminPlayersCount").textContent=rows.length===app.adminPlayersCache.length?String(rows.length):`${rows.length} из ${app.adminPlayersCache.length}`;
  $("adminPlayersEmpty").classList.toggle("hidden",rows.length>0);
}

async function changeSchoolNick(player,button){
  const entered=window.prompt("исправьте школьный ник игрока:",player.display_name);
  if(entered===null)return;
  const next=cleanName(entered,1000);   // как при регистрации: пробелы и невидимые символы
  if(!next || next.length>48){
    msg($("adminMessage"),"ник должен содержать от 1 до 48 символов.","error");
    return;
  }
  if(next===player.display_name)return;
  if(!window.confirm(`изменить ник «${player.display_name}» на «${next}»? подтверждение ника будет снято.`))return;
  button.disabled=true;
  try{
    const {data,error}=await app.supabase.rpc("admin_change_school_nick",{p_user_id:player.user_id,p_new_nick:next});
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
    const {error}=await app.supabase.rpc("admin_set_school_verified",{p_user_id:player.user_id,p_verified:next});
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

export function renderAdminTournaments(){
  const wrap=$("adminTournaments");
  wrap.innerHTML="";
  app.tournamentsCache.forEach(tournament=>{
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
  $("adminTournamentsCount").textContent=String(app.tournamentsCache.length);
  $("adminTournamentsEmpty").classList.toggle("hidden",app.tournamentsCache.length>0);
}

export function syncTournamentBoard(data){
  if(!data?.tournament)return;
  const tournament=data.tournament;
  const participantCount=(data.players||[]).filter(player=>player.status==="active").length;
  const roundCount=(data.matches||[]).reduce((max,match)=>Math.max(max,Number(match.round_no)||0),0);
  const summary={...tournament,participant_count:participantCount,round_count:roundCount};
  const index=app.tournamentsCache.findIndex(item=>item.id===tournament.id);
  if(index>=0)app.tournamentsCache[index]={...app.tournamentsCache[index],...summary};
  else app.tournamentsCache.unshift(summary);
  renderAdminTournaments();
}

export async function publishAdminAnnouncement(){
  if(!app.profile?.is_admin)return;
  const title=cleanText($("adminAnnouncementTitle").value,120);
  const body=cleanText($("adminAnnouncementBody").value,500);
  if(title.length<3){msg($("adminAnnouncementMessage"),"введите заголовок объявления.","error");return;}
  if(body.length<3){msg($("adminAnnouncementMessage"),"введите текст объявления.","error");return;}
  const button=$("adminPublishAnnouncementBtn");
  if(button.dataset.busy==="true")return;
  button.dataset.busy="true";
  button.disabled=true;
  button.textContent="отправляем…";
  msg($("adminAnnouncementMessage"),"отправляем объявление…");
  try{
    const {error}=await app.supabase.rpc("admin_publish_user_announcement",{p_title:title,p_body:body});
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

export async function runSecurityAudit(){
  if(!app.profile?.is_admin)return;
  const button=$("adminSecurityAuditBtn");
  if(button.dataset.busy==="true")return;
  button.dataset.busy="true";
  button.disabled=true;
  button.textContent="проверяем…";
  msg($("adminSecurityAuditMessage"),"проверяем права базы…");
  try{
    const {data,error}=await app.supabase.rpc("admin_security_audit");
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
  setActiveAdminFilter("[data-admin-game-filter]","adminGameFilter",app.adminGameFilter);
  const wrap=$("adminGames");
  wrap.innerHTML="";
  app.adminGamesCache.forEach(row=>{
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
  $("adminGamesCount").textContent=String(app.adminGamesCache.length);
  $("adminGamesEmpty").classList.toggle("hidden",app.adminGamesCache.length>0);
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
  app.adminCurrentGameId=gameId;
  msg($("adminGameMessage"),"загружаем матч…");
  $("adminGameDialog").showModal();
  try{
    const {data,error}=await app.supabase.rpc("admin_get_game_details",{p_game_id:gameId});
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
    msg($("adminGameMessage"),current.game_type==="tournament"&&["waiting","placing","playing","paused"].includes(current.status)
      ? "это турнирный матч: если он сорвался, удобнее засчитать техническую победу или назначить переигровку в управлении турниром — игра закроется сама."
      : "");
  }catch(error){
    msg($("adminGameMessage"),humanError(error),"error");
  }
}

export async function adminCancelGame(gameId){
  const reason=window.prompt("почему закрываем матч? причина сохранится в карточке матча. участники матча технически могут ее прочитать, поэтому не пишите ничего личного.","зависший матч");
  if(reason===null)return;
  if(!window.confirm("закрыть матч без победителя и без изменения рейтинга?"))return;
  try{
    const {error}=await app.supabase.rpc("admin_cancel_game",{p_game_id:gameId,p_reason:reason});
    if(error)throw error;
    if($("adminGameDialog").open)$("adminGameDialog").close();
    app.adminCurrentGameId=null;
    await loadAdmin();
    msg($("adminMessage"),"матч закрыт. поля и журнал сохранены для администратора.","success");
  }catch(error){
    const target=$("adminGameDialog").open?$("adminGameMessage"):$("adminMessage");
    msg(target,humanError(error),"error");
  }
}
