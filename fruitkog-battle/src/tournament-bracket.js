// Турнирные сетки: квалификация, плей-офф, линии между матчами.
import { app } from "./state.js?v=118";
import { $, $$ } from "./helpers.js?v=118";
import { createTournamentMatchAction, isTournamentMatchAvailableToCurrentPlayer, openTournamentMatch, tournamentMatchNote, tournamentRoundLabel } from "./tournament.js?v=118";

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
    const byeSlot=!player.id&&match.result_reason==="bye";
    if(player.id&&player.id===match.winner_id)line.classList.add("winner");
    if(!player.id)line.classList.add("empty");
    if(byeSlot)line.classList.add("bye");
    line.textContent=player.id
      ? `${player.avatar?`${player.avatar} `:""}${player.name}`
      : byeSlot?"свободный проход":"место пока свободно";
    if(player.id&&player.id===match.winner_id&&match.result_reason==="technical")line.textContent+=" · техпобеда";
    card.appendChild(line);
  });
  return card;
}

export function renderTournamentQualifyingBracket(qualifyingMatches){
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
  if(drawVersion!==app.tournamentBracketDrawVersion||!bracket?.isConnected)return;
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
  app.tournamentBracketResizeObserver?.disconnect();
  app.tournamentBracketResizeObserver=null;
  const drawVersion=++app.tournamentBracketDrawVersion;
  const draw=()=>drawTournamentBracketConnections(bracket,playoffMatches,totalRounds,drawVersion);
  requestAnimationFrame(()=>requestAnimationFrame(draw));
  if("ResizeObserver" in window){
    app.tournamentBracketResizeObserver=new ResizeObserver(()=>requestAnimationFrame(draw));
    app.tournamentBracketResizeObserver.observe(bracket);
  }
  document.fonts?.ready.then(draw);
}

export function renderTournamentBracket(playoffMatches,totalRounds){
  const panel=$("tournamentBracketPanel");
  panel.classList.toggle("hidden",!playoffMatches.length);
  const bracket=$("tournamentBracket");
  bracket.innerHTML="";
  bracket.classList.remove("is-large");
  if(!playoffMatches.length){
    app.tournamentBracketResizeObserver?.disconnect();
    app.tournamentBracketResizeObserver=null;
    app.tournamentBracketDrawVersion+=1;
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

export function renderTournamentMatches(tournament,matches,totalRounds){
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
