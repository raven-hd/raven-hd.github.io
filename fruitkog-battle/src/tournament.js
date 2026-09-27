// Публичная страница турнира: список, участники, заявки, результаты.
import { app } from "./state.js?v=118";
import { TOURNAMENT_DEMO_ENABLED, configured } from "./constants.js?v=118";
import { $, $$, formatAdminDate, msg } from "./helpers.js?v=118";
import { humanError } from "./errors.js?v=118";
import { openAuth } from "./auth.js?v=118";
import { observeGame, openGame } from "./room.js?v=118";
import { renderTournamentBracket, renderTournamentMatches, renderTournamentQualifyingBracket } from "./tournament-bracket.js?v=118";
import { buildTournamentDemoBoard, renderTournamentDemoState, tournamentDemoSummary } from "./tournament-demo.js?v=118";
import { syncTournamentBoard } from "./admin.js?v=118";

export function tournamentStatusLabel(status){
  return ({
    draft:"черновик",
    registration:"регистрация",
    active:"идет турнир",
    finished:"завершен",
    cancelled:"отменен",
  })[status]||status;
}

export function tournamentFormatLabel(format){
  return ({
    knockout:"плей-офф",
    qualifiers_playoff:"квалификация + плей-офф",
  })[format]||"формат еще не выбран";
}

export function qualifierSummary(tournament){
  if(tournament?.tournament_format!=="qualifiers_playoff")return "";
  const matches=Number(tournament.qualifying_matches_per_player)||0;
  const playoff=Number(tournament.playoff_size)||0;
  if(!matches||!playoff)return "квалификация еще не настроена";
  const matchesWord=matches===1?"матч":matches>=2&&matches<=4?"матча":"матчей";
  return `${matches} ${matchesWord} у каждого · плей-офф на ${playoff}`;
}

export function isTournamentRegistrationOpen(tournament){
  if(tournament?.status!=="registration")return false;
  return !tournament.registration_deadline||new Date(tournament.registration_deadline).getTime()>Date.now();
}

export function registrationDeadlineLabel(tournament){
  if(!tournament?.registration_deadline)return "срок записи не указан";
  const prefix=isTournamentRegistrationOpen(tournament)?"запись до":"запись завершена";
  return `${prefix}: ${formatAdminDate(tournament.registration_deadline)}`;
}

export function dateTimeLocalValue(value){
  const date=value?new Date(value):new Date(Date.now()+7*24*60*60*1000);
  if(Number.isNaN(date.getTime()))return "";
  const shifted=new Date(date.getTime()-date.getTimezoneOffset()*60000);
  return shifted.toISOString().slice(0,16);
}

export function resetTournamentDeadlineInput(){
  $("adminTournamentDeadline").value=dateTimeLocalValue();
}

export function tournamentRoundLabel(roundNo,totalRounds,status){
  if(roundNo===totalRounds)return "финал";
  if(roundNo===totalRounds-1)return "полуфинал";
  if(roundNo===totalRounds-2)return "четвертьфинал";
  return `раунд ${roundNo}`;
}

export function tournamentStageLabel(match){
  if(match?.game_type!=="tournament")return "";
  if(match.tournament_stage==="qualifying")return "квалификация";
  if(match.tournament_stage==="playoff"){
    return tournamentRoundLabel(Number(match.tournament_round_no)||1,Number(match.tournament_total_rounds)||1);
  }
  return "турнирный матч";
}

export function tournamentMatchNote(match){
  const note=tournamentMatchStateNote(match);
  return match.result_reason==="replay"&&!["finished","technical","cancelled"].includes(match.status)
    ? `переигровка · ${note}`
    : note;
}

function tournamentMatchStateNote(match){
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

export function calculateQualifierStandings(players,matches,playoffSize){
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

export function activateTournamentSection(targetId){
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

export async function openTournamentMatch(match,button){
  if(!match?.game_id||button?.dataset.busy==="true")return;
  if(TOURNAMENT_DEMO_ENABLED){
    msg($("tournamentMessage"),"это предпросмотр: демонстрационный матч не открывается.","success");
    return;
  }
  const oldText=button?.textContent;
  if(button){button.dataset.busy="true";button.disabled=true;button.textContent="открываем…";}
  try{
    const {data,error}=await app.supabase.from("games").select("*").eq("id",match.game_id).maybeSingle();
    if(error)throw error;
    if(!data)throw new Error("Game not found");
    const participant=[data.player1_id,data.player2_id].includes(app.user?.id);
    if(data.status==="finished"&&!participant){
      throw new Error("просмотр завершенного матча доступен только его участникам");
    }
    if(participant)await openGame(data);
    else await observeGame(data);
    if(button&&app.currentView!=="game"){button.disabled=false;button.textContent=oldText;delete button.dataset.busy;}
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
  button.disabled=app.tournamentApplicationBusy;
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

  if(!app.user){
    $("tournamentApplicationText").textContent=registrationOpen
      ? "войдите или зарегистрируйтесь, чтобы подать заявку."
      : "регистрация в этот турнир закрыта.";
    button.textContent="войти / зарегистрироваться";
    button.dataset.action="auth";
    button.classList.toggle("hidden",!registrationOpen);
    return;
  }

  if(app.profile?.account_type!=="registered"){
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
    button.textContent=app.tournamentApplicationBusy?"отзываем…":"отозвать заявку";
    button.className="danger-outline";
    button.dataset.action="withdraw";
  }else if(status==="approved"){
    button.textContent=app.tournamentApplicationBusy?"отказываемся…":"отказаться от участия";
    button.className="danger-outline";
    button.dataset.action="withdraw";
  }else{
    button.textContent=app.tournamentApplicationBusy?"отправляем…":status==="rejected"?"подать повторно":"подать заявку";
    button.dataset.action="apply";
  }
}

export async function changeTournamentApplication(){
  if(!app.currentTournamentBoard||app.tournamentApplicationBusy)return;
  if(TOURNAMENT_DEMO_ENABLED){
    msg($("tournamentApplicationMessage"),"это предпросмотр: заявка не отправляется.","success");
    return;
  }
  const button=$("tournamentApplicationBtn");
  const action=button.dataset.action;
  if(action==="auth"){openAuth("register");return;}
  if(!["apply","withdraw"].includes(action))return;
  if(action==="withdraw"&&!window.confirm("отозвать заявку? если она уже одобрена, вы будете исключены из состава турнира."))return;

  app.tournamentApplicationBusy=true;
  renderTournamentApplication(app.currentTournamentBoard.tournament,app.currentTournamentBoard.my_application);
  msg($("tournamentApplicationMessage"),action==="apply"?"отправляем заявку…":"отзываем заявку…");
  try{
    const rpc=action==="apply"?"apply_to_tournament":"withdraw_tournament_application";
    const {data,error}=await app.supabase.rpc(rpc,{p_tournament_id:app.currentTournamentBoard.tournament.id});
    if(error)throw error;
    app.currentTournamentBoard=data;
    app.tournamentApplicationBusy=false;
    app.tournamentLoadGeneration++;   // ответ идущей загрузки страницы уже устарел
    syncTournamentBoard(data);
    renderTournamentBoard(data);
    msg($("tournamentApplicationMessage"),action==="apply"?"заявка отправлена.":"заявка отозвана.","success");
  }catch(error){
    app.tournamentApplicationBusy=false;
    renderTournamentApplication(app.currentTournamentBoard.tournament,app.currentTournamentBoard.my_application);
    msg($("tournamentApplicationMessage"),humanError(error),"error");
  }
}

export async function loadTournaments(){
  if(TOURNAMENT_DEMO_ENABLED){renderTournamentDemoState();return;}
  if(!configured||app.tournamentLoading)return;
  app.tournamentLoading=true;
  const generation=++app.tournamentLoadGeneration;
  $("refreshTournamentBtn").disabled=true;
  msg($("tournamentMessage"),"загружаем турнир…");
  msg($("tournamentApplicationMessage"),"");
  try{
    const {data,error}=await app.supabase.rpc("list_public_tournaments");
    if(error)throw error;
    app.tournamentsCache=data||[];
    const selected=app.tournamentsCache.find(row=>
      row.id===app.currentTournamentId&&(!row.archived_at||row.id===app.openedArchivedTournamentId)
    );
    const visibleCurrent=app.tournamentsCache.filter(row=>!row.archived_at&&!["draft","cancelled"].includes(row.status));
    const current=selected
      ||visibleCurrent.find(row=>row.status==="active")
      ||visibleCurrent.find(isTournamentRegistrationOpen)
      ||visibleCurrent.find(row=>row.status==="registration")
      ||visibleCurrent.find(row=>row.status==="finished")
      ||null;
    const nextTournamentId=current?.id||null;
    if(current&&!current.archived_at)app.openedArchivedTournamentId=null;
    app.currentTournamentId=nextTournamentId;

    $("tournamentEmpty").classList.toggle("hidden",!!current);
    $("tournamentContent").classList.toggle("hidden",!current);
    $("tournamentSectionNav").classList.add("hidden");
    $("tournamentPageIntro").classList.add("hidden");
    $("tournamentArchiveBackBtn").classList.toggle("hidden",!app.openedArchivedTournamentId);
    if(!app.currentTournamentId){
      app.currentTournamentBoard=null;
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

    const boardResult=await app.supabase.rpc("get_tournament_board",{p_tournament_id:app.currentTournamentId});
    if(boardResult.error)throw boardResult.error;
    if(generation!==app.tournamentLoadGeneration){msg($("tournamentMessage"),"");return;}   // пока грузилось, игрок подал или отозвал заявку
    renderTournamentBoard(boardResult.data);
    msg($("tournamentMessage"),"");
  }catch(error){
    msg($("tournamentMessage"),humanError(error),"error");
  }finally{
    app.tournamentLoading=false;
    $("refreshTournamentBtn").disabled=false;
  }
}

async function openPublicTournament(tournamentId,button){
  if(!tournamentId||app.tournamentLoading)return;
  if(TOURNAMENT_DEMO_ENABLED){
    renderTournamentDemoState("finished");
    const archivedBoard=buildTournamentDemoBoard("archived");
    app.tournamentsCache=[tournamentDemoSummary(archivedBoard)];
    app.openedArchivedTournamentId=archivedBoard.tournament.id;
    renderTournamentBoard(archivedBoard);
    $("tournamentView").scrollIntoView({behavior:"smooth",block:"start"});
    return;
  }
  const oldText=button?.textContent;
  if(button){button.disabled=true;button.textContent="открываем…";}
  app.tournamentLoading=true;
  try{
    const {data,error}=await app.supabase.rpc("get_tournament_board",{p_tournament_id:tournamentId});
    if(error)throw error;
    app.openedArchivedTournamentId=app.tournamentsCache.find(item=>item.id===tournamentId)?.archived_at?tournamentId:null;
    app.currentTournamentId=tournamentId;
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
    app.tournamentLoading=false;
    if(button){button.disabled=false;button.textContent=oldText;}
  }
}

export function renderTournamentDirectory(){
  const panel=$("tournamentOtherPanel");
  const wrap=$("tournamentOtherList");
  if(!panel||!wrap)return;
  const others=app.tournamentsCache.filter(tournament=>tournament.archived_at&&tournament.id!==app.currentTournamentId);
  panel.classList.toggle("hidden",app.currentTournamentId!==null||others.length===0);
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
  const chronological=[...app.tournamentsCache]
    .filter(item=>item.status!=="draft")
    .sort((a,b)=>new Date(a.created_at||0)-new Date(b.created_at||0));
  const index=chronological.findIndex(item=>item.id===tournamentId);
  return index>=0?index+1:1;
}

export function createTournamentMatchAction(match){
  const completed=["finished","technical"].includes(match.status);
  const participant=[match.player1_id,match.player2_id].includes(app.user?.id)
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

export function isTournamentMatchAvailableToCurrentPlayer(match){
  if(!match?.game_id)return false;
  const participant=[match.player1_id,match.player2_id].includes(app.user?.id);
  const watchable=["playing","paused"].includes(match.game_status);
  const demoParticipant=TOURNAMENT_DEMO_ENABLED&&[match.player1_id,match.player2_id].includes("demo-player-1");
  const completed=["finished","technical"].includes(match.status)||match.game_status==="finished";
  return completed?(participant||demoParticipant):(participant||watchable||demoParticipant);
}

export function renderTournamentBoard(data){
  app.currentTournamentBoard=data;
  $("tournamentView").classList.remove("no-current-tournament");
  const tournament=data.tournament;
  const players=data.players||[];
  const matches=data.matches||[];
  const qualifyingMatches=matches.filter(match=>match.stage==="qualifying");
  const playoffMatches=matches.filter(match=>match.stage!=="qualifying");
  const totalRounds=Math.max(0,...playoffMatches.map(match=>match.round_no));
  app.currentTournamentId=tournament.id;
  const tournamentNumber=tournamentDisplayNumber(tournament.id);
  const registrationOpen=isTournamentRegistrationOpen(tournament);
  const showWinner=tournament.status==="finished";
  const viewingArchive=!!app.tournamentsCache.find(item=>item.id===tournament.id)?.archived_at;
  $("tournamentArchiveBackBtn").classList.toggle("hidden",!viewingArchive);
  $("tournamentArchiveBackBtn").textContent=app.tournamentsCache.some(item=>!item.archived_at&&!["draft","cancelled"].includes(item.status))?"к текущему турниру":"к архиву";
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
