// Колокольчик уведомлений администратора.
import { app } from "./state.js?v=118";
import { configured } from "./constants.js?v=118";
import { $, formatAdminDate, msg, wait } from "./helpers.js?v=118";
import { humanError } from "./errors.js?v=118";
import { switchView } from "./navigation.js?v=118";
import { openGame } from "./room.js?v=118";
import { renderTournamentBoard } from "./tournament.js?v=118";
import { renderAdminPlayers } from "./admin.js?v=118";
import { openAdminTournament } from "./admin-tournaments.js?v=118";

export function renderAdminNotifications(data={}){
  app.adminNotificationsCache=data.items||[];
  const unread=Number(data.unread_count)||0;
  const counter=$("adminNotificationCount");
  counter.textContent=unread>99?"99+":String(unread);
  counter.classList.toggle("hidden",unread===0);
  $("adminMarkAllNotificationsBtn").disabled=unread===0||app.adminNotificationsLoading;

  const list=$("adminNotificationsList");
  list.innerHTML="";
  app.adminNotificationsCache.forEach(notification=>{
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
  $("adminNotificationsEmpty").classList.toggle("hidden",app.adminNotificationsCache.length>0);
}

async function fetchCombinedNotifications(){
  const requests=[app.supabase.rpc("list_user_notifications",{p_limit:30})];
  if(app.profile?.is_admin)requests.push(app.supabase.rpc("admin_list_notifications",{p_limit:30}));
  const results=await Promise.all(requests);
  results.forEach(result=>{if(result.error)throw result.error;});
  const userData=results[0].data||{};
  const adminData=app.profile?.is_admin?(results[1]?.data||{}):{};
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

export async function loadAdminNotifications(silent=true){
  if(!configured||!app.user||app.profile?.account_type!=="registered"||app.adminNotificationsLoading)return;
  app.adminNotificationsLoading=true;
  if(!silent)msg($("adminNotificationsMessage"),"загружаем…");
  try{
    const data=await fetchCombinedNotifications();
    renderAdminNotifications(data);
    msg($("adminNotificationsMessage"),"");
  }catch(error){
    if(!silent)msg($("adminNotificationsMessage"),humanError(error),"error");
  }finally{
    app.adminNotificationsLoading=false;
    $("adminMarkAllNotificationsBtn").disabled=!app.adminNotificationsCache.some(item=>!item.read_at);
  }
}

export function closeAdminNotifications(){
  $("adminNotificationsPopover").classList.add("hidden");
  $("adminNotificationBtn").setAttribute("aria-expanded","false");
}

export async function toggleAdminNotifications(){
  const popover=$("adminNotificationsPopover");
  const opening=popover.classList.contains("hidden");
  if(!opening){closeAdminNotifications();return;}
  popover.classList.remove("hidden");
  $("adminNotificationBtn").setAttribute("aria-expanded","true");
  await loadAdminNotifications(false);
}

export async function markAdminNotificationsRead(notification=null){
  if(app.adminNotificationsLoading)return false;
  app.adminNotificationsLoading=true;
  try{
    const requests=[];
    if(!notification){
      requests.push(app.supabase.rpc("mark_user_notifications_read",{p_item_type:null,p_item_id:null}));
      if(app.profile?.is_admin)requests.push(app.supabase.rpc("admin_mark_notifications_read",{p_notification_id:null}));
    }else if(notification.source==="admin"){
      requests.push(app.supabase.rpc("admin_mark_notifications_read",{p_notification_id:notification.id}));
    }else{
      requests.push(app.supabase.rpc("mark_user_notifications_read",{
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
    app.adminNotificationsLoading=false;
    $("adminMarkAllNotificationsBtn").disabled=!app.adminNotificationsCache.some(item=>!item.read_at);
  }
}

async function waitForAdminLoad(){
  for(let attempt=0;attempt<80&&app.adminLoading;attempt++)await wait(50);
}

async function openAdminNotification(notification){
  if(!notification.read_at)await markAdminNotificationsRead(notification);
  closeAdminNotifications();
  if(notification.source!=="admin"){
    if(notification.game_id){
      const {data,error}=await app.supabase.from("games").select("*").eq("id",notification.game_id).maybeSingle();
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
      for(let attempt=0;attempt<80&&app.tournamentLoading;attempt++)await wait(50);
      try{
        const {data,error}=await app.supabase.rpc("get_tournament_board",{p_tournament_id:notification.tournament_id});
        if(error)throw error;
        app.currentTournamentId=notification.tournament_id;
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
    app.adminPlayerFilter="pending";
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

export function startAdminNotificationPolling(){
  if(app.adminNotificationsTimer){clearInterval(app.adminNotificationsTimer);app.adminNotificationsTimer=null;}
  if(app.profile?.account_type!=="registered")return;
  loadAdminNotifications(true);
  app.adminNotificationsTimer=setInterval(()=>{if(!document.hidden)loadAdminNotifications(true);},20000);
}
