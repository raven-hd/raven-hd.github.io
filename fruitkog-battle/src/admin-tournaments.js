// Админ-панель: создание и проведение турниров.
import { app } from "./state.js?v=118";
import { $, $$, cleanText, formatAdminDate, msg, newRequestId, safeStorage } from "./helpers.js?v=118";
import { humanError } from "./errors.js?v=118";
import { loadLobby } from "./lobby.js?v=118";
import { calculateQualifierStandings, dateTimeLocalValue, isTournamentRegistrationOpen, loadTournaments, qualifierSummary, registrationDeadlineLabel, renderTournamentBoard, resetTournamentDeadlineInput, tournamentFormatLabel, tournamentMatchNote, tournamentRoundLabel, tournamentStatusLabel } from "./tournament.js?v=118";
import { loadAdminNotifications } from "./admin-notifications.js?v=118";
import { renderAdminTournaments, syncTournamentBoard } from "./admin.js?v=118";
import { ruPlural } from "./settings.js?v=118";

export async function createAdminTournament(){
  if(app.adminTournamentBusy)return;
  const name=cleanText($("adminTournamentName").value,80);
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
  const storageKey=`fruitkog-tournament-create:${app.user.id}:${name.toLowerCase()}:${maxPlayers}:${tournamentFormat||"later"}:${deadline.toISOString()}`;
  let requestId=safeStorage.get(storageKey);
  if(!requestId){requestId=newRequestId();safeStorage.set(storageKey,requestId);}
  app.adminTournamentBusy=true;button.disabled=true;button.textContent="создаем…";
  try{
    const {data,error}=await app.supabase.rpc("admin_create_tournament",{
      p_name:name,p_request_id:requestId,p_max_players:maxPlayers,p_tournament_format:tournamentFormat,
      p_registration_deadline:deadline.toISOString(),
    });
    if(error)throw error;
    safeStorage.remove(storageKey);
    $("adminTournamentName").value="";
    $("adminTournamentMaxPlayers").value="32";
    resetTournamentDeadlineInput();
    $("deferredTournamentFormat").checked=true;
    syncTournamentBoard({tournament:data,players:[],matches:[]});
    app.adminTournamentBusy=false;
    await openAdminTournament(data.id);
    msg($("adminMessage"),"турнир создан. игроки уже могут подавать заявки.","success");
  }catch(error){
    msg($("adminMessage"),humanError(error),"error");
  }finally{
    app.adminTournamentBusy=false;button.disabled=false;button.textContent="создать турнир";
  }
}

export async function openAdminTournament(tournamentId){
  app.adminCurrentTournamentId=tournamentId;
  app.adminCurrentTournamentBoard=null;
  $("adminCloseTournamentBtn").classList.add("hidden");
  $("adminArchiveTournamentBtn").classList.add("hidden");
  $("adminDeleteTournamentBtn").classList.add("hidden");
  $("adminStartPlayoffBtn").classList.add("hidden");
  msg($("adminTournamentMessage"),"загружаем турнир…");
  if(!$("adminTournamentDialog").open)$("adminTournamentDialog").showModal();
  try{
    const {data,error}=await app.supabase.rpc("get_tournament_board",{p_tournament_id:tournamentId});
    if(error)throw error;
    renderAdminTournament(data);
    msg($("adminTournamentMessage"),"");
  }catch(error){
    msg($("adminTournamentMessage"),humanError(error),"error");
  }
}

// Подсказка для «плей-офф»: сетка — ближайшая степень двойки, лишние места — свободный проход.
function knockoutBracketHint(count){
  if(count<2)return "";
  let size=2;
  while(size<count)size*=2;
  const byes=size-count;
  if(!byes)return ` сейчас ${count} ${ruPlural(count,["участник","участника","участников"])} — все играют с первого раунда.`;
  return ` сейчас ${count} ${ruPlural(count,["участник","участника","участников"])}: сетка на ${size}, `
    +`${byes} ${ruPlural(byes,["игрок","игрока","игроков"])} по жребию ${ruPlural(byes,["пройдет","пройдут","пройдут"])} первый раунд без игры.`;
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
  app.adminCurrentTournamentBoard=data;
  const tournament=data.tournament;
  const tournamentSummary=app.tournamentsCache.find(item=>item.id===tournament.id);
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
      : `одобренных участников можно убрать до жеребьевки.${knockoutBracketHint(members.length)}`
    : "турнир уже начался: состав зафиксирован.";

  $("adminTournamentFormatStatus").textContent=tournamentFormatLabel(tournament.tournament_format);
  $("adminKnockoutTournamentFormat").checked=tournament.tournament_format==="knockout";
  $("adminQualifiersTournamentFormat").checked=tournament.tournament_format==="qualifiers_playoff";
  $$('#adminTournamentFormatSettings input[name="adminTournamentFormat"]').forEach(input=>{
    input.disabled=!formatEditable||app.adminTournamentBusy;
  });
  $("adminSaveTournamentFormatBtn").classList.toggle("hidden",!formatEditable);
  $("adminSaveTournamentFormatBtn").disabled=app.adminTournamentBusy;
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
  $("adminRegistrationDeadline").disabled=!editable||app.adminTournamentBusy;
  $("adminSaveRegistrationDeadlineBtn").classList.toggle("hidden",!editable);
  $("adminSaveRegistrationDeadlineBtn").disabled=app.adminTournamentBusy;
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
    const approve=document.createElement("button");approve.type="button";approve.className="primary";approve.textContent="одобрить";approve.disabled=!editable||app.adminTournamentBusy;
    const reject=document.createElement("button");reject.type="button";reject.className="danger-outline";reject.textContent="отклонить";reject.disabled=!editable||app.adminTournamentBusy;
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
    const adminPlayer=app.adminPlayersCache.find(row=>row.user_id===player.user_id);
    const note=document.createElement("small");note.textContent=adminPlayer?.school_verified?"ник подтвержден":"ник еще не подтвержден";
    text.append(name,note);item.appendChild(text);
    if(editable){
      const actions=document.createElement("div");actions.className="admin-row-actions";
      const remove=document.createElement("button");remove.type="button";remove.className="danger-outline";remove.textContent="убрать";remove.disabled=app.adminTournamentBusy;
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
    $("adminQualifierMatches").disabled=!editable||qualifiersStarted||app.adminTournamentBusy||!validSizes.length;
    playoffSelect.disabled=!editable||qualifiersStarted||app.adminTournamentBusy||!validSizes.length;
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
    $("adminSaveQualifierSettingsBtn").disabled=app.adminTournamentBusy||!validSizes.length;
    $("adminStartQualifiersBtn").classList.toggle("hidden",!editable||qualifiersStarted);
    $("adminStartQualifiersBtn").disabled=app.adminTournamentBusy||!!startIssue;
    $("adminStartPlayoffBtn").classList.toggle("hidden",tournament.status!=="active"||!qualifiersStarted||playoffStarted);
    $("adminStartPlayoffBtn").disabled=app.adminTournamentBusy||!standings?.completed||!!standings?.boundaryTie;
  }
  $("adminGenerateTournamentBtn").classList.toggle("hidden",!editable||qualifyingFormat||!tournament.tournament_format);
  $("adminGenerateTournamentBtn").disabled=app.adminTournamentBusy||members.length<2;
  $("adminGenerateTournamentBtn").textContent="провести жеребьевку";
  const canClose=!['finished','cancelled'].includes(tournament.status);
  $("adminCloseTournamentBtn").classList.remove("hidden");
  $("adminCloseTournamentBtn").disabled=app.adminTournamentBusy||!canClose;
  $("adminCloseTournamentBtn").textContent=tournament.status==='cancelled'
    ? "турнир закрыт"
    : tournament.status==='finished'
      ? "турнир завершен"
      : "закрыть турнир";
  $("adminArchiveTournamentBtn").classList.toggle("hidden",tournament.status!=="finished");
  $("adminArchiveTournamentBtn").disabled=app.adminTournamentBusy;
  $("adminArchiveTournamentBtn").textContent=archived?"вернуть из архива":"отправить в архив";
  $("adminDeleteTournamentBtn").classList.remove("hidden");
  $("adminDeleteTournamentBtn").disabled=app.adminTournamentBusy;
  $("adminDeleteTournamentBtn").textContent="удалить навсегда";
  renderAdminTournamentMatches(data);
}

// Незавершенные пары, где уже известны оба игрока: если матч сорвался, админ засчитывает
// техническую победу или назначает переигровку (миграция 037).
function renderAdminTournamentMatches(data){
  const tournament=data.tournament;
  const matches=data.matches||[];
  const active=tournament.status==="active";
  const playoffRounds=Math.max(0,...matches.filter(match=>match.stage!=="qualifying").map(match=>Number(match.round_no)||0));
  const open=active
    ? matches.filter(match=>match.player1_id&&match.player2_id&&!["finished","technical"].includes(match.status))
    : [];
  const wrap=$("adminTournamentMatches");
  wrap.innerHTML="";
  $("adminTournamentMatchesSection").classList.toggle("hidden",!active);
  $("adminTournamentMatchesCount").textContent=String(open.length);
  $("adminTournamentMatchesEmpty").classList.toggle("hidden",open.length>0);
  open.forEach(match=>{
    const card=document.createElement("div");card.className="admin-tournament-application admin-tournament-match";
    const text=document.createElement("span");
    const pair=document.createElement("strong");pair.textContent=`${match.player1_name} — ${match.player2_name}`;
    const stage=match.stage==="qualifying"?"квалификация":tournamentRoundLabel(Number(match.round_no)||1,playoffRounds||1);
    const state=match.status==="cancelled"?"игра закрыта администратором, результата нет":tournamentMatchNote(match);
    const note=document.createElement("small");note.textContent=`${stage} · ${state}`;
    text.append(pair,note);
    const actions=document.createElement("div");actions.className="admin-row-actions";
    [[match.player1_id,match.player1_name],[match.player2_id,match.player2_name]].forEach(([playerId,name])=>{
      const win=document.createElement("button");win.type="button";win.textContent=`победа: ${name}`;
      win.disabled=app.adminTournamentBusy;
      win.addEventListener("click",()=>awardTechnicalWin(tournament.id,match,playerId,name,win));
      actions.appendChild(win);
    });
    const replay=document.createElement("button");replay.type="button";replay.className="danger-outline";replay.textContent="переигровка";
    replay.disabled=app.adminTournamentBusy;
    replay.addEventListener("click",()=>replayTournamentMatch(tournament.id,match,replay));
    actions.appendChild(replay);
    card.append(text,actions);wrap.appendChild(card);
  });
}

async function awardTechnicalWin(tournamentId,match,winnerId,winnerName,button){
  if(app.adminTournamentBusy)return;
  const loserName=winnerId===match.player1_id?match.player2_name:match.player1_name;
  const matches=app.adminCurrentTournamentBoard?.matches||[];
  const isFinal=match.stage!=="qualifying"&&!match.next_match_id
    &&!matches.some(other=>other.id!==match.id&&other.stage!=="qualifying"&&Number(other.round_no)>=Number(match.round_no));
  if(!window.confirm(`засчитать техническую победу игроку «${winnerName}» в матче с «${loserName}»? текущая игра этой пары будет закрыта, рейтинг за матч не изменится.`
    +(isFinal?" это финал: турнир завершится, и будет начислен турнирный рейтинг за сыгранные матчи.":"")))return;
  await runTournamentMatchAction(tournamentId,button,"засчитываем…","admin_award_technical_win",
    {p_match_id:match.id,p_winner_id:winnerId},
    data=>data.tournament.status==="finished"?"техническая победа засчитана. турнир завершен.":"техническая победа засчитана.");
}

async function replayTournamentMatch(tournamentId,match,button){
  if(app.adminTournamentBusy)return;
  if(!window.confirm(`назначить переигровку «${match.player1_name}» — «${match.player2_name}»? текущая игра пары будет закрыта, игрокам откроется новая комната.`))return;
  await runTournamentMatchAction(tournamentId,button,"назначаем…","admin_replay_tournament_match",
    {p_match_id:match.id},
    ()=>"переигровка назначена: игрокам открыта новая комната.");
}

async function runTournamentMatchAction(tournamentId,button,busyText,rpcName,args,successText){
  app.adminTournamentBusy=true;
  $$("#adminTournamentMatches button").forEach(item=>item.disabled=true);
  button.textContent=busyText;
  msg($("adminTournamentMessage"),busyText);
  try{
    const {data,error}=await app.supabase.rpc(rpcName,args);
    if(error)throw error;
    app.adminTournamentBusy=false;
    syncTournamentBoard(data);
    renderAdminTournament(data);
    if(app.currentTournamentId===data.tournament.id)renderTournamentBoard(data);
    await Promise.all([loadLobby(),loadAdminNotifications(true)]);
    msg($("adminTournamentMessage"),successText(data),"success");
  }catch(error){
    app.adminTournamentBusy=false;
    await openAdminTournament(tournamentId);
    msg($("adminTournamentMessage"),humanError(error),"error");
  }
}

async function reviewTournamentApplication(tournamentId,playerId,decision,button){
  if(app.adminTournamentBusy)return;
  if(decision==="rejected"&&!window.confirm("отклонить эту заявку? игрок сможет подать ее повторно, пока регистрация открыта."))return;
  app.adminTournamentBusy=true;
  $$("#adminTournamentApplications button,#adminTournamentPlayers button").forEach(item=>item.disabled=true);
  $("adminGenerateTournamentBtn").disabled=true;
  $("adminSaveQualifierSettingsBtn").disabled=true;
  $("adminStartQualifiersBtn").disabled=true;
  button.textContent=decision==="approved"?"одобряем…":"отклоняем…";
  msg($("adminTournamentMessage"),decision==="approved"?"одобряем заявку…":"отклоняем заявку…");
  try{
    const {data,error}=await app.supabase.rpc("admin_review_tournament_application",{
      p_tournament_id:tournamentId,p_user_id:playerId,p_decision:decision,
    });
    if(error)throw error;
    app.adminTournamentBusy=false;
    syncTournamentBoard(data);
    renderAdminTournament(data);
    loadAdminNotifications(true);
    msg($("adminTournamentMessage"),decision==="approved"?"заявка одобрена. игрок добавлен в состав.":"заявка отклонена.","success");
  }catch(error){
    app.adminTournamentBusy=false;
    await openAdminTournament(tournamentId);
    msg($("adminTournamentMessage"),humanError(error),"error");
  }
}

async function removeTournamentParticipant(tournamentId,player,button){
  if(app.adminTournamentBusy)return;
  if(!window.confirm(`убрать «${player.display_name}» из состава турнира? заявка будет отклонена.`))return;
  app.adminTournamentBusy=true;
  $$("#adminTournamentApplications button,#adminTournamentPlayers button").forEach(item=>item.disabled=true);
  $("adminGenerateTournamentBtn").disabled=true;
  $("adminSaveQualifierSettingsBtn").disabled=true;
  $("adminStartQualifiersBtn").disabled=true;
  button.textContent="убираем…";
  msg($("adminTournamentMessage"),"убираем участника…");
  try{
    const {data,error}=await app.supabase.rpc("admin_remove_tournament_player",{p_tournament_id:tournamentId,p_user_id:player.user_id});
    if(error)throw error;
    app.adminTournamentBusy=false;
    syncTournamentBoard(data);
    renderAdminTournament(data);
    msg($("adminTournamentMessage"),"участник убран из состава.","success");
  }catch(error){
    app.adminTournamentBusy=false;
    await openAdminTournament(tournamentId);
    msg($("adminTournamentMessage"),humanError(error),"error");
  }
}

export async function generateTournament(){
  if(!app.adminCurrentTournamentId||app.adminTournamentBusy)return;
  const tournament=app.adminCurrentTournamentBoard?.tournament;
  if(tournament?.tournament_format==="qualifiers_playoff")return;
  if(!window.confirm("провести случайную жеребьевку? после этого состав турнира будет зафиксирован."))return;
  app.adminTournamentBusy=true;
  $("adminGenerateTournamentBtn").disabled=true;
  $("adminGenerateTournamentBtn").textContent="строим сетку…";
  try{
    const {data,error}=await app.supabase.rpc("admin_generate_tournament",{p_tournament_id:app.adminCurrentTournamentId});
    if(error)throw error;
    app.adminTournamentBusy=false;
    syncTournamentBoard(data);
    renderAdminTournament(data);
    if(app.currentTournamentId===data.tournament.id)renderTournamentBoard(data);
    await Promise.all([loadLobby(),loadAdminNotifications(true)]);
    msg($("adminTournamentMessage"),"жеребьевка проведена. сетка и первые матчи опубликованы.","success");
  }catch(error){
    app.adminTournamentBusy=false;
    if(app.adminCurrentTournamentBoard)renderAdminTournament(app.adminCurrentTournamentBoard);   // вернуть кнопку
    msg($("adminTournamentMessage"),humanError(error),"error");
  }finally{
    app.adminTournamentBusy=false;
    $("adminGenerateTournamentBtn").textContent="провести жеребьевку";
  }
}

export async function configureTournamentQualifiers(tournament){
  if(!tournament||app.adminTournamentBusy)return;
  const matches=Number.parseInt($("adminQualifierMatches").value,10);
  const playoffSize=Number.parseInt($("adminQualifierPlayoffSize").value,10);
  if(!Number.isInteger(matches)||matches<1||matches>10){
    msg($("adminTournamentMessage"),"укажите от 1 до 10 квалификационных матчей.","error");return;
  }
  if(![4,8,16].includes(playoffSize)||playoffSize>Number(tournament.max_players)){
    msg($("adminTournamentMessage"),"выберите допустимый размер плей-офф.","error");return;
  }
  app.adminTournamentBusy=true;
  const button=$("adminSaveQualifierSettingsBtn");
  button.disabled=true;
  button.textContent="сохраняем…";
  $("adminStartQualifiersBtn").disabled=true;
  $("adminQualifierMatches").disabled=true;
  $("adminQualifierPlayoffSize").disabled=true;
  try{
    const {data,error}=await app.supabase.rpc("admin_configure_tournament_qualifiers",{
      p_tournament_id:tournament.id,
      p_qualifying_matches:matches,
      p_playoff_size:playoffSize,
    });
    if(error)throw error;
    app.adminTournamentBusy=false;
    syncTournamentBoard(data);
    renderAdminTournament(data);
    msg($("adminTournamentMessage"),"настройки квалификации сохранены.","success");
  }catch(error){
    app.adminTournamentBusy=false;
    if(app.adminCurrentTournamentBoard)renderAdminTournament(app.adminCurrentTournamentBoard);
    msg($("adminTournamentMessage"),humanError(error),"error");
  }finally{
    button.textContent="сохранить настройки";
  }
}

export async function startTournamentQualifiers(){
  const tournament=app.adminCurrentTournamentBoard?.tournament;
  if(!tournament||app.adminTournamentBusy)return;
  const members=(app.adminCurrentTournamentBoard.players||[]).filter(player=>player.status==="active");
  const pending=(app.adminCurrentTournamentBoard.applications||[]).filter(application=>application.status==="pending").length;
  const issue=qualifierStartIssue(tournament,members,pending);
  if(issue){msg($("adminTournamentMessage"),issue,"error");return;}
  const totalMatches=(members.length*Number(tournament.qualifying_matches_per_player))/2;
  if(!window.confirm(`запустить квалификацию? будет создано ${totalMatches} матчей, состав и настройки зафиксируются.`))return;

  app.adminTournamentBusy=true;
  const button=$("adminStartQualifiersBtn");
  button.disabled=true;
  button.textContent="создаем матчи…";
  $("adminSaveQualifierSettingsBtn").disabled=true;
  msg($("adminTournamentMessage"),"составляем расписание и создаем матчи…");
  try{
    const {data,error}=await app.supabase.rpc("admin_start_tournament_qualifiers",{
      p_tournament_id:tournament.id,
    });
    if(error)throw error;
    app.adminTournamentBusy=false;
    syncTournamentBoard(data);
    renderAdminTournament(data);
    await Promise.all([loadLobby(),loadAdminNotifications(true)]);
    msg($("adminTournamentMessage"),"квалификация запущена. матчи опубликованы, участники получили уведомления.","success");
  }catch(error){
    app.adminTournamentBusy=false;
    if(app.adminCurrentTournamentBoard)renderAdminTournament(app.adminCurrentTournamentBoard);
    msg($("adminTournamentMessage"),humanError(error),"error");
  }finally{
    button.textContent="запустить квалификацию";
  }
}

export async function startTournamentPlayoff(){
  const tournament=app.adminCurrentTournamentBoard?.tournament;
  if(!tournament||app.adminTournamentBusy)return;
  const qualifierMatches=(app.adminCurrentTournamentBoard.matches||[]).filter(match=>match.stage==="qualifying");
  const standings=calculateQualifierStandings(
    app.adminCurrentTournamentBoard.players||[],qualifierMatches,tournament.playoff_size
  );
  if(!standings.completed){
    msg($("adminTournamentMessage"),"сначала завершите все квалификационные матчи.","error");return;
  }
  if(standings.boundaryTie){
    msg($("adminTournamentMessage"),"на границе выхода осталось равенство. сначала нужен дополнительный матч.","error");return;
  }
  if(!window.confirm("провести жеребьевку плей-офф? равные участники будут распределены случайно, остальные займут места по результатам квалификации."))return;

  app.adminTournamentBusy=true;
  const button=$("adminStartPlayoffBtn");
  button.disabled=true;
  button.textContent="строим сетку…";
  msg($("adminTournamentMessage"),"распределяем места и создаем матчи плей-офф…");
  try{
    const {data,error}=await app.supabase.rpc("admin_start_tournament_playoff",{
      p_tournament_id:tournament.id,
    });
    if(error)throw error;
    app.adminTournamentBusy=false;
    syncTournamentBoard(data);
    renderAdminTournament(data);
    if(app.currentTournamentId===tournament.id)renderTournamentBoard(data);
    await Promise.all([loadLobby(),loadAdminNotifications(true)]);
    msg($("adminTournamentMessage"),"жеребьевка проведена. сетка и первые матчи плей-офф опубликованы.","success");
  }catch(error){
    app.adminTournamentBusy=false;
    if(app.adminCurrentTournamentBoard)renderAdminTournament(app.adminCurrentTournamentBoard);
    msg($("adminTournamentMessage"),humanError(error),"error");
  }finally{
    button.textContent="провести жеребьевку плей-офф";
  }
}

export async function saveTournamentRegistrationDeadline(){
  const tournament=app.adminCurrentTournamentBoard?.tournament;
  if(!tournament||app.adminTournamentBusy)return;
  const value=$("adminRegistrationDeadline").value;
  const deadline=value?new Date(value):null;
  if(!deadline||Number.isNaN(deadline.getTime())||deadline.getTime()<=Date.now()){
    msg($("adminTournamentMessage"),"укажите будущую дату окончания регистрации.","error");return;
  }
  app.adminTournamentBusy=true;
  const button=$("adminSaveRegistrationDeadlineBtn");
  button.disabled=true;button.textContent="сохраняем…";
  try{
    const {data,error}=await app.supabase.rpc("admin_set_tournament_registration_deadline",{
      p_tournament_id:tournament.id,
      p_registration_deadline:deadline.toISOString(),
    });
    if(error)throw error;
    app.adminTournamentBusy=false;
    syncTournamentBoard(data);
    renderAdminTournament(data);
    msg($("adminTournamentMessage"),"срок регистрации сохранен.","success");
  }catch(error){
    app.adminTournamentBusy=false;
    if(app.adminCurrentTournamentBoard)renderAdminTournament(app.adminCurrentTournamentBoard);
    msg($("adminTournamentMessage"),humanError(error),"error");
  }finally{
    button.textContent="сохранить срок";
  }
}

export async function saveTournamentFormat(){
  const tournament=app.adminCurrentTournamentBoard?.tournament;
  if(!tournament||app.adminTournamentBusy)return;
  const selected=document.querySelector('input[name="adminTournamentFormat"]:checked')?.value;
  if(!selected){
    msg($("adminTournamentMessage"),"выберите формат турнира.","error");
    return;
  }
  app.adminTournamentBusy=true;
  const button=$("adminSaveTournamentFormatBtn");
  button.disabled=true;
  button.textContent="сохраняем…";
  try{
    const {data,error}=await app.supabase.rpc("admin_set_tournament_format",{
      p_tournament_id:tournament.id,
      p_tournament_format:selected,
    });
    if(error)throw error;
    app.adminTournamentBusy=false;
    syncTournamentBoard(data);
    renderAdminTournament(data);
    msg($("adminTournamentMessage"),"формат турнира сохранен.","success");
  }catch(error){
    app.adminTournamentBusy=false;
    if(app.adminCurrentTournamentBoard)renderAdminTournament(app.adminCurrentTournamentBoard);
    msg($("adminTournamentMessage"),humanError(error),"error");
  }finally{
    button.textContent="сохранить формат";
  }
}

export async function closeAdminTournament(tournament,button){
  if(app.adminTournamentBusy)return;
  if(!window.confirm(`закрыть турнир «${tournament.name}»? состав, сетка и результаты сохранятся.`))return;
  app.adminTournamentBusy=true;
  button.disabled=true;
  button.textContent="закрываем…";
  try{
    const {data,error}=await app.supabase.rpc("admin_close_tournament",{p_tournament_id:tournament.id});
    if(error)throw error;
    app.adminTournamentBusy=false;
    syncTournamentBoard(data);
    renderAdminTournament(data);
    loadAdminNotifications(true);
    msg($("adminTournamentMessage"),"турнир закрыт. все данные сохранены.","success");
  }catch(error){
    button.disabled=false;
    button.textContent="закрыть турнир";
    msg($("adminTournamentMessage"),humanError(error),"error");
  }finally{
    app.adminTournamentBusy=false;
  }
}

export async function setAdminTournamentArchived(tournament,button){
  if(app.adminTournamentBusy||tournament.status!=="finished")return;
  const summary=app.tournamentsCache.find(item=>item.id===tournament.id);
  const nextArchived=!(tournament.archived_at||summary?.archived_at);
  const action=nextArchived?"отправить в архив":"вернуть из архива";
  if(!window.confirm(`${action} турнир «${tournament.name}»?`))return;
  app.adminTournamentBusy=true;
  button.disabled=true;
  button.textContent=nextArchived?"архивируем…":"возвращаем…";
  try{
    const {data,error}=await app.supabase.rpc("admin_set_tournament_archived",{
      p_tournament_id:tournament.id,
      p_archived:nextArchived,
    });
    if(error)throw error;
    const archivedAt=nextArchived?new Date().toISOString():null;
    const cached=app.tournamentsCache.find(item=>item.id===tournament.id);
    if(cached)cached.archived_at=archivedAt;
    if(data?.tournament)data.tournament.archived_at=archivedAt;
    if(nextArchived&&app.currentTournamentId===tournament.id){
      app.currentTournamentId=null;
      app.openedArchivedTournamentId=null;
    }
    app.adminTournamentBusy=false;
    syncTournamentBoard(data);
    renderAdminTournament(data);
    await loadTournaments();
    msg($("adminTournamentMessage"),nextArchived?"турнир отправлен в архив.":"турнир снова показан на странице.","success");
  }catch(error){
    msg($("adminTournamentMessage"),humanError(error),"error");
  }finally{
    app.adminTournamentBusy=false;
    button.disabled=false;
  }
}

export async function deleteAdminTournament(tournament,button){
  if(app.adminTournamentBusy)return;
  if(!window.confirm(`удалить турнир «${tournament.name}» навсегда? восстановить его не получится.`))return;
  const hasTournamentHistory=tournament.status!=="registration"||Number(tournament.round_count)>0;
  if(hasTournamentHistory&&!window.confirm("в турнире уже есть сетка или история. турнирные данные будут удалены, но сыгранные матчи и рейтинг сохранятся. точно удалить?"))return;
  app.adminTournamentBusy=true;
  button.disabled=true;
  button.textContent="удаляем…";
  try{
    const {error}=await app.supabase.rpc("admin_delete_tournament",{p_tournament_id:tournament.id});
    if(error)throw error;
    app.tournamentsCache=app.tournamentsCache.filter(item=>item.id!==tournament.id);
    renderAdminTournaments();
    if(app.adminCurrentTournamentId===tournament.id){
      app.adminCurrentTournamentId=null;
      if($("adminTournamentDialog").open)$("adminTournamentDialog").close();
    }
    loadAdminNotifications(true);
    msg($("adminMessage"),"турнир удален.","success");
  }catch(error){
    button.disabled=false;
    button.textContent="удалить навсегда";
    msg($("adminMessage"),humanError(error),"error");
  }finally{
    app.adminTournamentBusy=false;
  }
}
