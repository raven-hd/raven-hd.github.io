// Универсальная выдача наград игрокам из админ-панели.
import { app } from "./state.js?v=127";
import { $, formatAdminDate, msg } from "./helpers.js?v=127";
import { humanError } from "./errors.js?v=127";

let currentPlayer=null;

function rewardLabel(code){
  return ({
    mushroom_skin:"грибной скин",
    auto_miss:"автопромахи",
    square_ship:"корабль 2×2",
  })[code]||code;
}

function expiryFromForm(){
  const mode=$("adminRewardExpiryMode").value;
  if(mode==="never")return null;
  if(mode==="date"){
    const raw=$("adminRewardExpiryDate").value;
    if(!raw)throw new Error("укажите дату окончания награды");
    const date=new Date(raw);
    if(Number.isNaN(date.getTime()))throw new Error("неверная дата окончания награды");
    return date.toISOString();
  }
  const days=Number(mode);
  if(!Number.isFinite(days)||days<=0)throw new Error("неверный срок награды");
  return new Date(Date.now()+days*24*60*60*1000).toISOString();
}

function syncRewardFields(){
  const reward=$("adminRewardType").value;
  const isSkin=reward==="mushroom_skin";
  $("adminRewardUseModeField").classList.toggle("hidden",isSkin);
  $("adminRewardUsesField").classList.toggle("hidden",isSkin||$("adminRewardUseMode").value!=="games");
  $("adminRewardExpiryDateField").classList.toggle("hidden",$("adminRewardExpiryMode").value!=="date");
}

async function loadRewardHistory(){
  if(!currentPlayer)return;
  const wrap=$("adminRewardHistory");
  wrap.innerHTML="";
  msg($("adminRewardMessage"),"");
  try{
    const {data,error}=await app.supabase.rpc("admin_list_fruitkog_rewards",{p_user_id:currentPlayer.user_id});
    if(error)throw error;
    const rows=data||[];
    rows.forEach(item=>{
      const row=document.createElement("div");
      row.className="admin-reward-history-row";

      const main=document.createElement("div");
      main.className="admin-row-main";
      const title=document.createElement("strong");
      title.textContent=rewardLabel(item.reward_code);

      const facts=document.createElement("small");
      const useText=item.reward_code==="mushroom_skin"
        ? "скин"
        : item.unlimited
          ? "без лимита игр"
          : `осталось игр: ${item.remaining_uses}`;
      const expiryText=item.expires_at
        ? `до ${formatAdminDate(item.expires_at)}`
        : "без срока";
      const sourceText=item.source?` · ${item.source}`:"";
      facts.textContent=`${useText} · ${expiryText}${sourceText}`;
      main.append(title,facts);

      const status=document.createElement("span");
      status.className="badge";
      status.textContent=item.active?"активна":item.revoked_at?"отозвана":"истекла";

      const actions=document.createElement("div");
      actions.className="admin-row-actions";
      if(item.active){
        const revoke=document.createElement("button");
        revoke.type="button";
        revoke.textContent="отозвать";
        revoke.addEventListener("click",async()=>{
          if(!window.confirm(`отозвать награду «${rewardLabel(item.reward_code)}» у ${currentPlayer.display_name}?`))return;
          revoke.disabled=true;
          try{
            const {error}=await app.supabase.rpc("admin_revoke_fruitkog_reward",{p_entitlement_id:item.id});
            if(error)throw error;
            await loadRewardHistory();
          }catch(error){
            revoke.disabled=false;
            msg($("adminRewardMessage"),humanError(error),"error");
          }
        });
        actions.appendChild(revoke);
      }

      row.append(main,status,actions);
      wrap.appendChild(row);
    });
    $("adminRewardHistoryEmpty").classList.toggle("hidden",rows.length>0);
  }catch(error){
    msg($("adminRewardMessage"),humanError(error),"error");
  }
}

export async function openAdminRewards(player){
  if(!app.profile?.is_admin||player?.account_type!=="registered")return;
  currentPlayer=player;
  $("adminRewardPlayerName").textContent=player.display_name;
  $("adminRewardType").value="auto_miss";
  $("adminRewardUseMode").value="games";
  $("adminRewardUses").value="5";
  $("adminRewardExpiryMode").value="never";
  $("adminRewardExpiryDate").value="";
  $("adminRewardSource").value="";
  syncRewardFields();
  msg($("adminRewardMessage"),"");
  if(!$("adminRewardDialog").open)$("adminRewardDialog").showModal();
  await loadRewardHistory();
}

export function bindAdminRewards(){
  $("adminRewardType")?.addEventListener("change",syncRewardFields);
  $("adminRewardUseMode")?.addEventListener("change",syncRewardFields);
  $("adminRewardExpiryMode")?.addEventListener("change",syncRewardFields);
  $("adminRewardCloseBtn")?.addEventListener("click",()=>$("adminRewardDialog").close());
  $("adminRewardGrantBtn")?.addEventListener("click",async()=>{
    if(!currentPlayer)return;
    const button=$("adminRewardGrantBtn");
    button.disabled=true;
    msg($("adminRewardMessage"),"");
    try{
      const reward=$("adminRewardType").value;
      const uses=reward==="mushroom_skin"
        ? null
        : $("adminRewardUseMode").value==="unlimited"
          ? null
          : Number($("adminRewardUses").value);
      if(reward!=="mushroom_skin"&&(!Number.isInteger(uses)||uses<1)){
        throw new Error("количество игр должно быть целым числом больше нуля");
      }
      const expiresAt=expiryFromForm();
      const source=$("adminRewardSource").value.trim()||null;
      const {error}=await app.supabase.rpc("admin_grant_fruitkog_reward",{
        p_user_id:currentPlayer.user_id,
        p_reward_code:reward,
        p_uses:uses,
        p_expires_at:expiresAt,
        p_source:source,
      });
      if(error)throw error;
      msg($("adminRewardMessage"),"награда выдана.","success");
      await loadRewardHistory();
    }catch(error){
      msg($("adminRewardMessage"),humanError(error),"error");
    }finally{
      button.disabled=false;
    }
  });
}
