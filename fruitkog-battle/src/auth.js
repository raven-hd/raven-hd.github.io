// Вход и выход, регистрация, гостевой профиль, пароль, блок аккаунта в шапке, обработка сессии.
import { app } from "./state.js?v=118";
import { $, cleanName, msg, wait } from "./helpers.js?v=118";
import { humanError } from "./errors.js?v=118";
import { restoreSavedView, switchView } from "./navigation.js?v=118";
import { loadLobby, renderCreateOptions, subscribeToLobby } from "./lobby.js?v=118";
import { restoreGame, setGameUrl } from "./room.js?v=118";
import { closeAdminNotifications, renderAdminNotifications, startAdminNotificationPolling } from "./admin-notifications.js?v=118";

export function setAuthTab(name) {
  const names = ["login","register","guest"];
  names.forEach(n => {
    if (n === name && !$(`${n}Tab`).classList.contains("active")) {
      const message = $(`${n}Message`);
      if (message) msg(message);
    }
    $(`${n}Tab`).classList.toggle("active", n === name);
    $(`${n}Pane`).classList.toggle("hidden", n !== name);
  });
}

export function openAuth(tab="login") {
  for (const name of ["login", "register", "guest"]) {
    const message = $(`${name}Message`);
    if (message) msg(message, "");
  }
  for (const id of ["registerNick", "registerEmail", "registerPassword", "registerPassword2", "loginPassword"]) {
    const input = $(id);
    if (input) input.value = "";
  }
  setAuthTab(tab);
  $("authDialog").showModal();
}

export function renderAccount() {
  $("authLoadingBox").classList.toggle("hidden",app.authReady);
  $("needAuthBox").classList.toggle("hidden",!app.authReady || !!app.user);
  $("lobby").classList.toggle("hidden",!app.authReady || !app.user);
  renderCreateOptions();
  $("adminNavBtn").classList.toggle("hidden",!app.profile?.is_admin);
  $("adminNotificationShell").classList.toggle("hidden",app.profile?.account_type!=="registered");

  const slot = $("accountSlot");
  slot.innerHTML = "";

  if (!app.authReady && app.authError) {
    // профиль так и не загрузился (нет сети, сервер не отвечает) — не держим человека на
    // «восстанавливаем вход…»: можно повторить (это же произойдет само, когда появится сеть
    // или человек вернется на вкладку) или выйти из аккаунта
    const retry = document.createElement("button");
    retry.type = "button";
    retry.textContent = "профиль не загрузился · повторить";
    retry.addEventListener("click", () => retryProfileLoad());
    const leave = document.createElement("button");
    leave.type = "button";
    leave.textContent = "выйти";
    leave.addEventListener("click", async () => {
      if (app.user?.is_anonymous
          && !window.confirm("выйти из гостевого профиля? восстановить его не получится.")) return;
      await logout();
    });
    slot.append(retry, leave);
    return;
  }

  if (!app.authReady) {
    const loading = document.createElement("button");
    loading.type = "button";
    loading.disabled = true;
    loading.textContent = "восстанавливаем вход…";
    slot.appendChild(loading);
    return;
  }

  if (!app.user) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.textContent = "войти";
    btn.addEventListener("click", () => openAuth("login"));
    slot.appendChild(btn);
    return;
  }

  if (!app.profile) {
    const loading = document.createElement("button");
    loading.type = "button";
    loading.disabled = true;
    loading.textContent = "загружаем профиль…";
    slot.appendChild(loading);
    return;
  }

  const btn = document.createElement("button");
  btn.type = "button";
  if (app.profile.avatar_emoji) {
    const avatar = document.createElement("span");
    avatar.className = "account-avatar";
    avatar.textContent = app.profile.avatar_emoji;
    btn.appendChild(avatar);
  }
  const accountName = document.createElement("span");
  accountName.className = "account-name";
  accountName.textContent = app.profile.display_name;
  btn.appendChild(accountName);
  if(app.profile.account_type === "registered" && !app.profile.school_verified){
    const warning = document.createElement("span");
    warning.className = "account-warning-badge";
    warning.textContent = "!";
    warning.setAttribute("aria-label","ник ожидает проверки");
    warning.title = "ник ожидает проверки";
    btn.appendChild(warning);
  }
  btn.addEventListener("click", () => {
    $("profileAvatar").textContent = app.profile.avatar_emoji || "🍏";
    $("profileAvatar").classList.remove("hidden");
    $("profileName").textContent = app.profile.display_name;
    $("profileEmail").textContent = app.profile.account_type === "guest"
      ? "гостевой аккаунт без email"
      : (app.user.email || "");
    $("profileStatus").textContent = app.profile.account_type === "guest"
      ? "гость: доступны игры без рейтинга; рейтинг и турниры недоступны"
      : app.profile.school_verified
        ? ""
        : "школьный ник ожидает подтверждения администратора";
    $("profileStatus").classList.toggle("hidden",app.profile.account_type === "registered" && app.profile.school_verified);
    $("openPlayerProfileBtn").classList.toggle("hidden",app.profile.account_type!=="registered");
    $("profileDialog").showModal();
  });
  slot.appendChild(btn);
}

// профиль: {profile} — загружен; {profile:null,error:null} — профиля нет; {error} — не удалось
async function fetchProfile(userId) {
  let lastError = null;
  for (let attempt=0;attempt<3;attempt++) {
    const {data,error} = await app.supabase.from("profiles")
      .select("user_id,display_name,account_type,school_verified,is_admin,avatar_emoji,rating,rated_games,rated_wins,rated_losses,created_at")
      .eq("user_id",userId).maybeSingle();
    if (!error && data) return {profile:data,error:null};
    lastError = error;
    if (error && !error.code) break;   // нет связи: библиотека уже сама повторила запрос несколько раз
    if (attempt<2) await wait(350*(attempt+1));
  }
  if (lastError) console.error(lastError);
  return {profile:null,error:lastError};
}

export async function register() {
  const nick = cleanName($("registerNick").value);
  const email = $("registerEmail").value.trim();
  const pass = $("registerPassword").value;
  const pass2 = $("registerPassword2").value;

  if (!nick || !email || !pass) return msg($("registerMessage"),"заполните все поля.","error");
  if (pass.length < 8) return msg($("registerMessage"),"пароль должен содержать минимум 8 символов.","error");
  if (pass !== pass2) return msg($("registerMessage"),"пароли не совпадают.","error");

  $("registerBtn").disabled = true;
  try {
    const {data:available,error:checkError} = await app.supabase.rpc("is_school_nick_available",{p_nick:nick});
    if (checkError) throw checkError;
    if (!available) throw new Error("School nick already registered");

    const {data,error} = await app.supabase.auth.signUp({
      email,
      password: pass,
      options: { data: { school_nick: nick } }
    });
    if (error) throw error;

    if (data.session) {
      msg($("registerMessage"),"аккаунт создан.","success");
      $("authDialog").close();
    } else {
      msg($("registerMessage"),"аккаунт создан. подтвердите email по письму, затем войдите.","success");
    }
  } catch (e) {
    msg($("registerMessage"),humanError(e),"error");
  } finally {
    $("registerBtn").disabled = false;
  }
}

export async function login() {
  const email = $("loginEmail").value.trim();
  const password = $("loginPassword").value;
  if (!email || !password) return msg($("loginMessage"),"введите email и пароль.","error");

  $("loginBtn").disabled = true;
  try {
    const {error} = await app.supabase.auth.signInWithPassword({email,password});
    if(error)throw error;
    $("authDialog").close();
  } catch(e) {
    msg($("loginMessage"),humanError(e),"error");
  } finally {
    $("loginBtn").disabled = false;
  }
}

export function showPasswordDialog(update=false){
  $("passwordRequestPane").classList.toggle("hidden",update);
  $("passwordUpdatePane").classList.toggle("hidden",!update);
  if($("authDialog").open)$("authDialog").close();
  if(!$("passwordDialog").open)$("passwordDialog").showModal();
}

export async function sendPasswordLink(){
  const email=$("passwordEmail").value.trim();
  if(!$("passwordEmail").checkValidity()||!email)
    return msg($("passwordRequestMessage"),"укажите корректный email.","error");
  const button=$("sendPasswordLinkBtn");button.disabled=true;
  try{
    const redirectTo=location.origin+location.pathname;
    const {error}=await app.supabase.auth.resetPasswordForEmail(email,{redirectTo});
    if(error)throw error;
    msg($("passwordRequestMessage"),"если аккаунт с таким email существует, письмо со ссылкой придет на почту.","success");
  }catch(e){msg($("passwordRequestMessage"),humanError(e),"error");}
  finally{button.disabled=false;}
}

export async function updatePassword(){
  const password=$("newPassword").value;
  if(password.length<8)return msg($("passwordUpdateMessage"),"пароль должен содержать минимум 8 символов.","error");
  if(password!==$("newPassword2").value)return msg($("passwordUpdateMessage"),"пароли не совпадают.","error");
  const button=$("updatePasswordBtn");button.disabled=true;
  try{
    const {error}=await app.supabase.auth.updateUser({password});
    if(error)throw error;
    $("newPassword").value="";$("newPassword2").value="";
    msg($("passwordUpdateMessage"),"пароль изменен. теперь можно войти с новым паролем.","success");
    history.replaceState(null,"",location.pathname);
  }catch(e){msg($("passwordUpdateMessage"),humanError(e),"error");}
  finally{button.disabled=false;}
}

export async function guestLogin() {
  $("guestBtn").disabled = true;
  app.guestSetupInProgress = true;
  try {
    const {data,error} = await app.supabase.auth.signInAnonymously();
    if (error) throw error;
    const {error:claimError} = await app.supabase.rpc("claim_random_guest");
    if (claimError) {
      await app.supabase.auth.signOut();
      throw claimError;
    }
    await handleSession(data.session);
    $("authDialog").close();
  } catch(e) {
    msg($("guestMessage"),humanError(e),"error");
  } finally {
    app.guestSetupInProgress = false;
    $("guestBtn").disabled = false;
  }
}

export async function logout() {
  if (app.profile?.account_type === "guest") {
    const confirmed = window.confirm("выйти из гостевого профиля? восстановить его не получится. комнаты, в которых бой еще не начался, будут освобождены.");
    if (!confirmed) return;
    try {
      const {data:rowsData,error:rowsError}=await app.supabase.rpc("list_active_games");
      if(rowsError)throw rowsError;
      const rows=rowsData||[];
      for (const row of rows.filter(item => item.is_participant)) {
        if (row.player1_id === app.user.id && ["waiting","placing"].includes(row.status)) {
          const {error} = await app.supabase.rpc("cancel_game",{p_game_id:row.id});
          if (error) throw error;
        } else if (row.player2_id === app.user.id && row.status === "placing") {
          const {error} = await app.supabase.rpc("leave_game",{p_game_id:row.id});
          if (error) throw error;
        }
      }
    } catch (error) {
      alert(`не удалось освободить гостевые комнаты: ${humanError(error)}`);
      return;
    }
  }
  if (app.realtimeChannel) await app.supabase.removeChannel(app.realtimeChannel);
  if (app.lobbyChannel) await app.supabase.removeChannel(app.lobbyChannel);
  app.realtimeChannel = null;
  app.lobbyChannel = null;
  app.game = null;
  app.spectatorMode = false;
  setGameUrl(null);
  await app.supabase.auth.signOut();
  $("profileDialog").close();
  switchView("home");
}

// профиль не загрузился — пробуем снова: по кнопке, при появлении сети и при возвращении на вкладку
export function retryProfileLoad(){
  if(!app.authError||!app.user||document.hidden)return;
  app.authError=false;
  app.profileRetries=0;
  renderAccount();
  const giveUp=error=>{if(error)console.error(error);app.authError=true;renderAccount();};
  app.supabase.auth.getSession()
    .then(({data,error})=>data?.session?handleSession(data.session):giveUp(error))   // сессию не прочитать (нет сети) — оставляем кнопки
    .catch(giveUp);
}

export async function handleSession(session){
  const generation=++app.sessionGeneration;
  const nextUser=session?.user||null;
  if(app.adminNotificationsTimer){clearInterval(app.adminNotificationsTimer);app.adminNotificationsTimer=null;}
  app.adminNotificationsCache=[];
  renderAdminNotifications({items:[],unread_count:0});
  closeAdminNotifications();
  app.authReady=false;
  app.user=nextUser;
  app.profile=null;
  if(!nextUser){app.authError=false;app.profileRetryUser=null;app.profileRetries=0;}
  renderAccount();
  if(app.user){
    if(app.profileRetryUser!==nextUser.id){app.profileRetryUser=nextUser.id;app.profileRetries=0;app.authError=false;}
    let {profile:loadedProfile,error:profileError}=await fetchProfile(app.user.id);
    if(generation!==app.sessionGeneration)return;
    // гость без профиля: вкладку закрыли между входом и выдачей имени. выдаем имя сейчас —
    // повторный вызов безопасен и вернет уже выданное имя (при обрыве сети не пробуем)
    if(!loadedProfile&&!profileError&&nextUser.is_anonymous&&!app.guestSetupInProgress){
      await app.supabase.rpc("claim_random_guest");
      if(generation!==app.sessionGeneration)return;
      ({profile:loadedProfile}=await fetchProfile(app.user.id));
      if(generation!==app.sessionGeneration)return;
    }
    if(!loadedProfile){
      // первые две неудачи — молча пробуем снова. дальше показываем «повторить» и «выйти»,
      // а сами пробуем реже — раз в 15 секунд, пока профиль не загрузится
      app.profileRetries+=1;
      if(app.profileRetries>2&&!app.authError){app.authError=true;renderAccount();}
      setTimeout(()=>{
        if(generation===app.sessionGeneration&&app.user?.id===nextUser.id)handleSession(session);
      },app.profileRetries>2?15000:1500);
      return;
    }
    app.profileRetries=0;
    app.authError=false;
    app.profile=loadedProfile;
  }
  app.authReady=true;
  renderAccount();
  startAdminNotificationPolling();
  if(app.user){
    await subscribeToLobby();
    await loadLobby();
    if(generation!==app.sessionGeneration)return;
    await restoreGame();
  }
  restoreSavedView();
}
