// Точка входа: привязка кнопок и запуск приложения.
import { createClient } from "../vendor/supabase.js?v=118";
import { SUPABASE_PUBLISHABLE_KEY, SUPABASE_URL } from "../config.js?v=118";
import { app } from "./state.js?v=118";
import { TOURNAMENT_DEMO_ENABLED, configured } from "./constants.js?v=118";
import { $, $$, bind, msg } from "./helpers.js?v=118";
import { loadPublicGameSettings } from "./settings.js?v=118";
import { restoreSavedView, switchView } from "./navigation.js?v=118";
import { guestLogin, handleSession, login, logout, openAuth, register, renderAccount, retryProfileLoad, sendPasswordLink, setAuthTab, showPasswordDialog, updatePassword } from "./auth.js?v=118";
import { createGame, loadLobby, renderActiveGames, resyncLobby } from "./lobby.js?v=118";
import { exitPreGame, resyncGame, returnToLobby, surrenderGame } from "./room.js?v=118";
import { buildBoard, syncVegetableMode } from "./board.js?v=118";
import { cancelPlacementDrag, emptyPlacement, endPlacementDrag, movePlacementDrag, ready, renderPlacement, savePlacementDraft } from "./placement.js?v=118";
import { activateTournamentSection, changeTournamentApplication, loadTournaments, resetTournamentDeadlineInput } from "./tournament.js?v=118";
import { renderTournamentDemoState, updateTournamentDemoControls } from "./tournament-demo.js?v=118";
import { loadRating, openPlayerProfile } from "./rating.js?v=118";
import { closeAdminNotifications, markAdminNotificationsRead, toggleAdminNotifications } from "./admin-notifications.js?v=118";
import { adminCancelGame, loadAdmin, publishAdminAnnouncement, renderAdminPlayers, runSecurityAudit, setActiveAdminFilter } from "./admin.js?v=118";
import { closeAdminTournament, configureTournamentQualifiers, createAdminTournament, deleteAdminTournament, generateTournament, saveTournamentFormat, saveTournamentRegistrationDeadline, setAdminTournamentArchived, startTournamentPlayoff, startTournamentQualifiers } from "./admin-tournaments.js?v=118";

function wire(){
  // Только кнопки меню. У <body> тоже есть data-view (там хранится текущий раздел), и раньше
  // обработчик вешался и на него: любой клик по странице заново открывал текущий раздел и
  // перезагружал его данные (в админке — 6 запросов на каждый клик), а медленный ответ мог
  // затереть свежий результат действия (например, только что поданную заявку на турнир).
  $$("button[data-view]").forEach(b=>b.addEventListener("click",()=>switchView(b.dataset.view)));
  bind("openAuthBtn","click",()=>openAuth("login"));
  bind("adminNotificationBtn","click",toggleAdminNotifications);
  bind("adminMarkAllNotificationsBtn","click",()=>markAdminNotificationsRead(null));
  document.addEventListener("pointerdown",event=>{
    if(!$("adminNotificationShell").contains(event.target))closeAdminNotifications();
    $$(".lobby-mode-help[open], .placement-help[open], .tournament-results-help[open], .auth-field-help[open]").forEach(details=>{
      if(!details.contains(event.target))details.removeAttribute("open");
    });
  });
  document.addEventListener("keydown",event=>{
    if(event.key==="Escape"){
      closeAdminNotifications();
      $$(".lobby-mode-help[open], .placement-help[open], .tournament-results-help[open], .auth-field-help[open]").forEach(details=>details.removeAttribute("open"));
    }
  });
  bind("needAuthBtn","click",()=>openAuth("register"));
  bind("loginTab","click",()=>setAuthTab("login"));
  bind("registerTab","click",()=>setAuthTab("register"));
  bind("guestTab","click",()=>setAuthTab("guest"));
  bind("registerBtn","click",register);
  bind("loginBtn","click",login);
  bind("forgotPasswordBtn","click",()=>{
    $("passwordEmail").value=$("loginEmail").value.trim();
    msg($("passwordRequestMessage"));
    showPasswordDialog();
  });
  bind("sendPasswordLinkBtn","click",sendPasswordLink);
  bind("updatePasswordBtn","click",updatePassword);
  bind("guestBtn","click",guestLogin);
  bind("logoutBtn","click",logout);
  bind("openPlayerProfileBtn","click",()=>{
    $("profileDialog").close();
    if(app.profile?.account_type==="registered")openPlayerProfile(app.profile.user_id);
  });
  bind("createGameBtn","click",createGame);
  bind("refreshGamesBtn","click",loadLobby);
  bind("refreshTournamentBtn","click",loadTournaments);
  $$('[data-tournament-demo]').forEach(button=>button.addEventListener("click",()=>{
    renderTournamentDemoState(button.dataset.tournamentDemo);
    $("tournamentView").scrollIntoView({behavior:"smooth",block:"start"});
  }));
  bind("tournamentArchiveBackBtn","click",()=>{
    if(TOURNAMENT_DEMO_ENABLED){renderTournamentDemoState("none");return;}
    app.openedArchivedTournamentId=null;
    app.currentTournamentId=null;
    loadTournaments();
  });
  $$('[data-tournament-section]').forEach(button=>button.addEventListener("click",()=>{
    activateTournamentSection(button.dataset.tournamentSection);
  }));
  bind("tournamentApplicationBtn","click",changeTournamentApplication);
  bind("refreshAdminBtn","click",loadAdmin);
  bind("adminSecurityAuditBtn","click",runSecurityAudit);
  bind("adminPublishAnnouncementBtn","click",publishAdminAnnouncement);
  bind("adminCreateTournamentBtn","click",createAdminTournament);
  bind("adminSaveRegistrationDeadlineBtn","click",saveTournamentRegistrationDeadline);
  bind("adminSaveTournamentFormatBtn","click",saveTournamentFormat);
  bind("adminSaveQualifierSettingsBtn","click",()=>configureTournamentQualifiers(app.adminCurrentTournamentBoard?.tournament));
  bind("adminStartQualifiersBtn","click",startTournamentQualifiers);
  bind("adminStartPlayoffBtn","click",startTournamentPlayoff);
  bind("adminGenerateTournamentBtn","click",generateTournament);
  bind("adminCloseTournamentBtn","click",()=>{
    const tournament=app.tournamentsCache.find(item=>item.id===app.adminCurrentTournamentId);
    if(tournament)closeAdminTournament(tournament,$("adminCloseTournamentBtn"));
  });
  bind("adminArchiveTournamentBtn","click",()=>{
    const tournament=app.adminCurrentTournamentBoard?.tournament;
    if(tournament)setAdminTournamentArchived(tournament,$("adminArchiveTournamentBtn"));
  });
  bind("adminDeleteTournamentBtn","click",()=>{
    const tournament=app.tournamentsCache.find(item=>item.id===app.adminCurrentTournamentId);
    if(tournament)deleteAdminTournament(tournament,$("adminDeleteTournamentBtn"));
  });
  bind("adminCloseTournamentDialogBtn","click",()=>$("adminTournamentDialog").close());
  $$('[data-admin-player-filter]').forEach(button=>button.addEventListener("click",()=>{
    app.adminPlayerFilter=button.dataset.adminPlayerFilter;renderAdminPlayers();
  }));
  $$('[data-admin-game-filter]').forEach(button=>button.addEventListener("click",async()=>{
    app.adminGameFilter=button.dataset.adminGameFilter;
    setActiveAdminFilter("[data-admin-game-filter]","adminGameFilter",app.adminGameFilter);
    await loadAdmin();
  }));
  bind("adminCancelGameBtn","click",()=>app.adminCurrentGameId&&adminCancelGame(app.adminCurrentGameId));
  bind("adminCloseDialogBtn","click",()=>$("adminGameDialog").close());
  $$('[data-game-filter]').forEach(button=>button.addEventListener("click",()=>{
    app.activeFilter=button.dataset.gameFilter;renderActiveGames();
  }));
  syncVegetableMode();
  bind("backLobbyBtn","click",returnToLobby);
  bind("closeGameBtn","click",()=>exitPreGame());
  bind("surrenderGameBtn","click",surrenderGame);
  bind("placementBoard","pointermove",movePlacementDrag);
  bind("placementBoard","pointerup",endPlacementDrag);
  bind("placementBoard","pointercancel",cancelPlacementDrag);
  bind("resetFleetBtn","click",()=>{app.placement=emptyPlacement();savePlacementDraft();renderPlacement();});
  bind("readyBtn","click",ready);
}

async function init(){
  wire();
  updateTournamentDemoControls();
  document.body.dataset.view="home";
  resetTournamentDeadlineInput();
  buildBoard($("placementBoard"),null);buildBoard($("ownBoard"),null);buildBoard($("enemyBoard"),null);
  buildBoard($("adminBoard1"),null);buildBoard($("adminBoard2"),null);

  if(!configured){
    if(TOURNAMENT_DEMO_ENABLED){
      app.authReady=true;
      renderAccount();
      restoreSavedView();
      return;
    }
    $("setupWarning").classList.remove("hidden");
    return;
  }

  // один зависший запрос не должен навсегда оставлять кнопки в состоянии «загружаем…».
  // вход, регистрация и письма ждут дольше: при регистрации сервер в это время отправляет
  // письмо, и обрыв посередине оставил бы созданный аккаунт с сообщением об ошибке.
  // в старых браузерах (iOS до 16) AbortSignal.timeout нет — там запросы идут без таймаута, как раньше
  const timedFetch=(url,options={})=>{
    if(options.signal||typeof AbortSignal.timeout!=="function")return fetch(url,options);
    const href=typeof url==="string"?url:(url?.url||String(url));
    const limit=href.includes("/auth/v1/")?60000:15000;
    return fetch(url,{...options,signal:AbortSignal.timeout(limit)});
  };
  app.supabase=createClient(SUPABASE_URL,SUPABASE_PUBLISHABLE_KEY,{global:{fetch:timedFetch}});
  // вернулись на вкладку или появилась сеть — догоняем матч и зал (и профиль, если он не
  // загрузился); пока матч открыт — опрос раз в 20 с
  const resync=()=>{resyncGame();resyncLobby();retryProfileLoad();};
  document.addEventListener("visibilitychange",resync);
  window.addEventListener("online",resync);
  setInterval(resyncGame,20000);
  loadPublicGameSettings();
  app.supabase.auth.onAuthStateChange((_event,session)=>{
    if(_event==="PASSWORD_RECOVERY")setTimeout(()=>showPasswordDialog(true),0);
    if (app.guestSetupInProgress) return;
    if (app.authReady && (session?.user?.id||null)===(app.user?.id||null)) return;
    setTimeout(()=>handleSession(session),0);
  });
  const {data}=await app.supabase.auth.getSession();
  await handleSession(data.session);

  await loadRating();
}

init();
