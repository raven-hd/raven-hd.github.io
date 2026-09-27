// Бой: выстрелы, история ходов, экран зрителя.
import { app } from "./state.js?v=118";
import { PRODUCE_BY_SHIP_LENGTH } from "./constants.js?v=118";
import { $, msg } from "./helpers.js?v=118";
import { humanError } from "./errors.js?v=118";
import { refreshGame } from "./room.js?v=118";
import { buildBoard, cellToCoords, coordsToCell, renderFleetSkins, resetBoard, sunkShipsFromShots } from "./board.js?v=118";

// true — данные обновлены. false — не получилось (нет сети, таймаут) или игрок уже ушел из матча:
// тогда прежние данные не трогаем, чтобы поле не «обнулилось» до следующего обновления
export async function refreshBattleData(){
  const game = app.game;
  let fleetQuery = app.supabase.from("fleets").select("owner_id,ships").eq("game_id",game.id);
  if (game.status !== "finished") fleetQuery = fleetQuery.eq("owner_id",app.user.id);
  const [fleetRes,shotsRes]=await Promise.all([
    fleetQuery,
    app.supabase.from("shots").select("*").eq("game_id",game.id).order("id",{ascending:true}),
  ]);
  if (app.game !== game || !app.user) return false;   // игрок ушел из матча, пока грузились данные
  if (fleetRes.error || shotsRes.error) {
    console.error(fleetRes.error || shotsRes.error);
    return false;
  }
  const fleets = fleetRes.data || [];
  app.myFleet = fleets.find(fleet => fleet.owner_id === app.user.id) || null;
  app.opponentFleet = app.game.status === "finished"
    ? fleets.find(fleet => fleet.owner_id !== app.user.id) || null
    : null;
  app.shots=shotsRes.data||[];
  return true;
}

export async function refreshSpectatorData(){
  const game = app.game;
  const requests = [
    app.supabase.from("shots").select("*").eq("game_id",game.id).order("id",{ascending:true}),
  ];
  if (game.status === "finished") {
    requests.push(app.supabase.from("fleets").select("owner_id,ships").eq("game_id",game.id));
  }
  const [shotsRes,fleetsRes] = await Promise.all(requests);
  if (app.game !== game) return false;
  if (shotsRes.error || fleetsRes?.error) {
    console.error(shotsRes.error || fleetsRes.error);
    return false;
  }
  app.shots = shotsRes.data || [];
  app.spectatorFleets = fleetsRes?.data || [];
  return true;
}

function opponentName(){ return app.game.player1_id===app.user.id?app.game.player2_name:app.game.player1_name; }

function foundProduceName(shot,allShots=app.shots){
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

export function resultLabel(shot,allShots=app.shots){
  if(!shot)return "ход";
  if(shot.result==="miss")return "мимо";
  if(shot.result==="hit")return "заметил плод";
  if(["sunk","win"].includes(shot.result))return `нашел «${foundProduceName(shot,allShots)}»`;
  return shot.result;
}

function finishedGameSummary(){
  if(app.game?.status!=="finished")return "";
  const winner=app.game.winner_id===app.game.player1_id?app.game.player1_name:app.game.player2_name;
  if(app.game.finish_reason==="surrender"){
    const surrendered=app.game.surrendered_by===app.game.player1_id?app.game.player1_name:app.game.player2_name;
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
  $("shotLog").start=Math.max(app.shots.length,1);
  [...app.shots].reverse().forEach((shot,index)=>{
    const li=document.createElement("li");
    li.value=app.shots.length-index;
    li.textContent=`${shooterLabel(shot)}: ${shot.cell} — ${resultLabel(shot)}`;
    $("shotLog").appendChild(li);
  });
}

function appendHitMarker(cell){
  const marker=document.createElement("span");marker.className="hit-marker";marker.setAttribute("aria-hidden","true");
  const icon=document.createElement("i");icon.className="fa-solid fa-xmark";marker.append(icon);cell.append(marker);
}

export function renderBattle(){
  $("shotBar").classList.remove("hidden");
  $("ownBoardTitle").textContent="ваша грядка";
  $("enemyBoardTitle").textContent="грядка соперника";
  buildBoard($("ownBoard"),null);
  buildBoard($("enemyBoard"),cell=>fire(cell));
  resetBoard($("ownBoard"));
  resetBoard($("enemyBoard"));

  const ownShots=app.shots.filter(s=>s.target_id===app.user.id);
  const enemyShots=app.shots.filter(s=>s.shooter_id===app.user.id);
  renderFleetSkins($("ownBoard"),app.myFleet?.ships,ownShots);
  renderFleetSkins($("enemyBoard"),app.game.status==="finished"?app.opponentFleet?.ships:sunkShipsFromShots(enemyShots),enemyShots);
  const own=new Set((app.myFleet?.ships||[]).flatMap(s=>s.cells));
  $("ownBoard").querySelectorAll(".board-cell").forEach(b=>{if(own.has(b.dataset.cell))b.classList.add("ship");});
  if (app.game.status === "finished") {
    const opponent = new Set((app.opponentFleet?.ships || []).flatMap(ship => ship.cells));
    $("enemyBoard").querySelectorAll(".board-cell").forEach(cell => {
      if (opponent.has(cell.dataset.cell)) cell.classList.add("ship");
    });
  }

  app.shots.forEach(s=>{
    const board=s.shooter_id===app.user.id?$("enemyBoard"):$("ownBoard");
    const b=board.querySelector(`[data-cell="${s.cell}"]`);
    if(!b)return;
    b.classList.remove("ship");
    b.classList.add(s.result==="miss"?"miss":"hit");b.disabled=true;
    if(s.result!=="miss")appendHitMarker(b);
  });

  const myTurn=app.game.status==="playing"&&app.game.current_turn===app.user.id;
  $("enemyBoard").querySelectorAll(".board-cell").forEach(b=>{
    if(!myTurn||app.shotInProgress||b.classList.contains("hit")||b.classList.contains("miss"))b.disabled=true;
  });
  $("shotHint").textContent=app.shotInProgress?"выстрел отправлен…":myTurn?"нажмите на клетку соперника":"ожидаем ход соперника";

  if(app.game.status==="finished"){
    $("turnTitle").textContent=app.game.winner_id===app.user.id?"вы победили":`${opponentName()} победил`;
    $("battleBadge").textContent=app.game.finish_reason==="surrender"
      ? (app.game.surrendered_by===app.user.id?"вы сдались":"соперник сдался")
      : "матч завершен";
  }else if(app.game.status==="paused"){
    $("turnTitle").textContent="матч приостановлен";$("battleBadge").textContent="ожидает администратора";
  }else if(myTurn){
    $("turnTitle").textContent="ваш ход";$("battleBadge").textContent="ваш ход";
  }else{
    $("turnTitle").textContent=`ходит ${opponentName()}`;$("battleBadge").textContent="ход соперника";
  }

  renderShotHistory(shot=>shot.shooter_id===app.user.id?"вы":opponentName());
}

export function renderSpectatorBattle(){
  $("shotBar").classList.add("hidden");
  $("ownBoardTitle").textContent=`грядка: ${app.game.player1_name}`;
  $("enemyBoardTitle").textContent=`грядка: ${app.game.player2_name}`;
  buildBoard($("ownBoard"),null);
  buildBoard($("enemyBoard"),null);
  resetBoard($("ownBoard"));
  resetBoard($("enemyBoard"));

  if (app.game.status === "finished") {
    app.spectatorFleets.forEach(fleet => {
      const board = fleet.owner_id === app.game.player1_id ? $("ownBoard") : $("enemyBoard");
      renderFleetSkins(board,fleet.ships,app.shots.filter(s=>s.target_id===fleet.owner_id));
      const cells = new Set((fleet.ships || []).flatMap(ship => ship.cells));
      board.querySelectorAll(".board-cell").forEach(cell => {
        if (cells.has(cell.dataset.cell)) cell.classList.add("ship");
      });
    });
  }

  if(app.game.status!=="finished"){
    [app.game.player1_id,app.game.player2_id].forEach((owner,index)=>{
      const boardShots=app.shots.filter(s=>s.target_id===owner);
      renderFleetSkins($(index===0?"ownBoard":"enemyBoard"),sunkShipsFromShots(boardShots),boardShots);
    });
  }

  app.shots.forEach(shot => {
    const board = shot.target_id === app.game.player1_id ? $("ownBoard") : $("enemyBoard");
    const cell = board.querySelector(`[data-cell="${shot.cell}"]`);
    if (!cell) return;
    cell.classList.remove("ship");
    cell.classList.add(shot.result === "miss" ? "miss" : "hit");
    if(shot.result!=="miss")appendHitMarker(cell);
    cell.disabled = true;
  });

  $("ownBoard").querySelectorAll(".board-cell").forEach(cell => cell.disabled=true);
  $("enemyBoard").querySelectorAll(".board-cell").forEach(cell => cell.disabled=true);

  if (app.game.status === "finished") {
    const winner = app.game.winner_id === app.game.player1_id ? app.game.player1_name : app.game.player2_name;
    $("turnTitle").textContent=`победил ${winner}`;
    $("battleBadge").textContent=app.game.finish_reason==="surrender"?"завершен сдачей":"матч завершен";
  } else if (app.game.status === "paused") {
    $("turnTitle").textContent="матч приостановлен";
    $("battleBadge").textContent="ожидает администратора";
  } else {
    const turnName = app.game.current_turn === app.game.player1_id ? app.game.player1_name : app.game.player2_name;
    $("turnTitle").textContent=`ходит ${turnName}`;
    $("battleBadge").textContent="наблюдение";
  }

  renderShotHistory(shot=>shot.shooter_id===app.game.player1_id?app.game.player1_name:app.game.player2_name);
  msg($("battleMessage"),"");
}

async function fire(cell){
  if(app.shotInProgress||app.game?.status!=="playing"||app.game.current_turn!==app.user.id)return;
  if(app.shots.some(shot=>shot.shooter_id===app.user.id&&shot.cell===cell))return;
  app.shotInProgress=true;
  const pending=$("enemyBoard").querySelector(`[data-cell="${cell}"]`);
  pending?.classList.add("shot-pending");
  pending?.setAttribute("aria-busy","true");
  $("enemyBoard").querySelectorAll(".board-cell").forEach(item=>item.disabled=true);
  $("shotHint").textContent="выстрел отправлен…";
  msg($("battleMessage"),"");
  try{
    const {data,error}=await app.supabase.rpc("shoot",{p_game_id:app.game.id,p_cell:cell});
    if(error)throw error;
    // The RPC result is authoritative; show it before the follow-up reads finish.
    if(app.game?.status==="playing"&&data?.cell===cell&&["miss","hit","sunk","win"].includes(data.result)){
      const targetId=app.game.player1_id===app.user.id?app.game.player2_id:app.game.player1_id;
      if(!app.shots.some(shot=>shot.shooter_id===app.user.id&&shot.cell===cell)){
        app.shots.push({game_id:app.game.id,shooter_id:app.user.id,target_id:targetId,cell,result:data.result});
      }
      if(data.result==="miss")app.game.current_turn=targetId;
      if(data.result==="win"){
        app.game.status="finished";
        app.game.winner_id=app.user.id;
        app.game.current_turn=null;
      }
      renderBattle();
    }
    await refreshGame();
  }catch(e){
    msg($("battleMessage"),humanError(e),"error");
  }finally{
    app.shotInProgress=false;
    if(app.game&&["playing","paused","finished"].includes(app.game.status))renderBattle();
  }
}
