// Рейтинг игроков и публичный профиль.
import { app } from "./state.js?v=118";
import { configured } from "./constants.js?v=118";
import { $, formatAdminDate, msg } from "./helpers.js?v=118";
import { humanError } from "./errors.js?v=118";
import { openAuth } from "./auth.js?v=118";
import { openCompletedMatch } from "./lobby.js?v=118";

export async function loadRating(){
  if(!configured)return;
  const {data,error}=await app.supabase.rpc("get_leaderboard");
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

export async function openPlayerProfile(playerId){
  if(!app.user){openAuth("login");return;}
  const generation=++app.playerProfileGeneration;
  const dialog=$("playerProfileDialog");
  dialog.classList.toggle("is-own-profile",playerId===app.user?.id);
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
    const {data,error}=await app.supabase.rpc("get_public_player_profile",{p_user_id:playerId});
    if(generation!==app.playerProfileGeneration)return;   // уже открыт профиль другого игрока
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
