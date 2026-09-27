// Демо-турнир для предпросмотра (?tournament-demo=1). В базу ничего не пишет.
import { app } from "./state.js?v=118";
import { TOURNAMENT_DEMO_ENABLED, TOURNAMENT_DEMO_STATES } from "./constants.js?v=118";
import { $, $$, msg } from "./helpers.js?v=118";
import { renderTournamentBoard, renderTournamentDirectory } from "./tournament.js?v=118";

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

export function buildTournamentDemoBoard(state){
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

export function tournamentDemoSummary(board){
  const tournament=board.tournament;
  return {
    ...tournament,
    participant_count:(board.players||[]).length,
    round_count:Math.max(0,...(board.matches||[]).filter(match=>match.stage==="playoff").map(match=>Number(match.round_no)||0)),
  };
}

export function updateTournamentDemoControls(){
  $("tournamentDemoPanel").classList.toggle("hidden",!TOURNAMENT_DEMO_ENABLED);
  $$('[data-tournament-demo]').forEach(button=>button.classList.toggle("active",button.dataset.tournamentDemo===app.tournamentDemoState));
}

export function renderTournamentDemoState(state=app.tournamentDemoState){
  app.tournamentDemoState=TOURNAMENT_DEMO_STATES.has(state)?state:"none";
  const url=new URL(location.href);
  url.searchParams.set("tournament-demo","1");
  url.searchParams.set("tournament-state",app.tournamentDemoState);
  history.replaceState(null,"",url);
  updateTournamentDemoControls();
  msg($("tournamentMessage"),"");
  msg($("tournamentApplicationMessage"),"");

  const archivedBoard=buildTournamentDemoBoard("archived");
  if(app.tournamentDemoState==="none"){
    app.tournamentsCache=[tournamentDemoSummary(archivedBoard)];
    app.currentTournamentId=null;
    app.openedArchivedTournamentId=null;
    app.currentTournamentBoard=null;
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

  const board=buildTournamentDemoBoard(app.tournamentDemoState);
  const summary=tournamentDemoSummary(board);
  app.tournamentsCache=[summary,tournamentDemoSummary(archivedBoard)];
  app.currentTournamentId=board.tournament.id;
  app.openedArchivedTournamentId=null;
  renderTournamentBoard(board);
  renderTournamentDirectory();
}
