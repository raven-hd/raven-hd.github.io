// Публичные ачивки и подтверждение кандидатов администратором.
import { app } from "./state.js?v=131";
import { $, formatAdminDate, msg } from "./helpers.js?v=131";
import { humanError } from "./errors.js?v=131";

export const ACHIEVEMENT_TITLES = Object.freeze({
  tournament_player:"участник турнира",
  tournament_winner:"победитель турнира",
  games_50:"50 игр",
  rating_leader:"лидер рейтинга",
});
const ICONS=Object.freeze({
  tournament_player:"🌱",tournament_winner:"🏆",games_50:"⚓",rating_leader:"⭐",
});

export async function renderPlayerAchievements(playerId,generation){
  const section=$("publicProfileAchievements");
  const grid=$("publicProfileAchievementGrid");
  grid.replaceChildren();
  section.classList.add("hidden");
  const {data,error}=await app.supabase.rpc("list_player_achievements",{p_user_id:playerId});
  if(generation!==app.playerProfileGeneration)return;
  if(error){
    // Позволяет смотреть профили в черновой ветке до установки миграции.
    if(error.code!=="PGRST202")console.warn("не удалось загрузить ачивки",error);
    return;
  }
  for(const item of data||[]){
    const card=document.createElement("div");
    card.className="achievement-card";
    const symbol=document.createElement("span");
    symbol.className="achievement-icon";
    symbol.textContent=ICONS[item.code]||"✦";
    symbol.setAttribute("aria-hidden","true");
    const copy=document.createElement("div");
    const title=document.createElement("strong");
    title.textContent=ACHIEVEMENT_TITLES[item.code]||"ачивка";
    const detail=document.createElement("small");
    detail.textContent=item.tournament_name||item.evidence||"";
    const date=document.createElement("time");
    date.dateTime=item.approved_at||item.earned_at;
    date.textContent=formatAdminDate(date.dateTime);
    copy.append(title,detail,date);
    card.append(symbol,copy);
    grid.appendChild(card);
  }
  section.classList.toggle("hidden",!grid.childElementCount);
}

export function openAchievementReview(notification){
  if(!app.profile?.is_admin)return;
  const dialog=$("achievementReviewDialog");
  dialog.dataset.achievementId=notification.id;
  $("achievementReviewPlayer").textContent=notification.player_name;
  $("achievementReviewTitle").textContent=ACHIEVEMENT_TITLES[notification.code]||"ачивка";
  $("achievementReviewEvidence").textContent=[
    notification.tournament_name,notification.evidence,
  ].filter(Boolean).join(" · ");
  msg($("achievementReviewMessage"),"");
  $("achievementApproveBtn").disabled=false;
  $("achievementRejectBtn").disabled=false;
  if(!dialog.open)dialog.showModal();
}

export async function decideAchievement(approve){
  const dialog=$("achievementReviewDialog");
  const id=dialog.dataset.achievementId;
  if(!id||!app.profile?.is_admin)return false;
  $("achievementApproveBtn").disabled=true;
  $("achievementRejectBtn").disabled=true;
  msg($("achievementReviewMessage"),"сохраняем…");
  try{
    const {error}=await app.supabase.rpc("admin_decide_achievement",{
      p_achievement_id:id,p_approve:approve,
    });
    if(error)throw error;
    dialog.close();
    dialog.dataset.achievementId="";
    return true;
  }catch(error){
    msg($("achievementReviewMessage"),humanError(error),"error");
    return false;
  }finally{
    $("achievementApproveBtn").disabled=false;
    $("achievementRejectBtn").disabled=false;
  }
}
