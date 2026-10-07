// Будущие награды Fruitkog: безопасное чтение и тестовый режим.
// ?reward-demo=1 включает локальные тестовые награды без обращения к Supabase.

import { app } from "./state.js?v=127";

export const DEFAULT_REWARDS = Object.freeze({
  mushroom_skin_unlocked:false,
  mushroom_skin_expires_at:null,
  auto_miss_uses:0,
  auto_miss_unlimited:false,
  auto_miss_expires_at:null,
  square_ship_uses:0,
  square_ship_unlimited:false,
  square_ship_expires_at:null,
  selected_ship_skin:"vegetable",
});

function normalizedRewards(value={}){
  return {
    mushroom_skin_unlocked:!!value.mushroom_skin_unlocked,
    mushroom_skin_expires_at:value.mushroom_skin_expires_at||null,
    auto_miss_uses:Math.max(0,Number(value.auto_miss_uses)||0),
    auto_miss_unlimited:!!value.auto_miss_unlimited,
    auto_miss_expires_at:value.auto_miss_expires_at||null,
    square_ship_uses:Math.max(0,Number(value.square_ship_uses)||0),
    square_ship_unlimited:!!value.square_ship_unlimited,
    square_ship_expires_at:value.square_ship_expires_at||null,
    selected_ship_skin:value.selected_ship_skin==="mushroom"?"mushroom":"vegetable",
  };
}

export function rewardDemoEnabled(){
  return new URLSearchParams(location.search).get("reward-demo")==="1";
}

export function rewardDemoState(){
  return {
    mushroom_skin_unlocked:true,
    mushroom_skin_expires_at:null,
    auto_miss_uses:30,
    auto_miss_unlimited:false,
    auto_miss_expires_at:null,
    square_ship_uses:15,
    square_ship_unlimited:false,
    square_ship_expires_at:null,
    selected_ship_skin:"mushroom",
  };
}

export function resetMyRewards(){
  app.rewards={...DEFAULT_REWARDS};
  app.rewardsUserId=null;
}

export async function loadMyRewards(){
  if(!app.user||app.profile?.account_type!=="registered"){
    resetMyRewards();
    return app.rewards;
  }

  if(rewardDemoEnabled()){
    app.rewards=rewardDemoState();
    app.rewardsUserId=app.user.id;
    return app.rewards;
  }

  try{
    const {data,error}=await app.supabase.rpc("get_my_fruitkog_rewards");
    if(error)throw error;
    app.rewards=normalizedRewards(data);
    app.rewardsUserId=app.user.id;
  }catch(error){
    // До применения будущей миграции основной backend этой RPC не знает.
    // В таком случае интерфейс просто считает, что наград еще нет.
    console.warn("Fruitkog rewards are not available yet",error);
    resetMyRewards();
  }
  return app.rewards;
}

export function gameAllowsBoosts(game=app.game){
  return !!game&&game.game_type!=="tournament";
}

export function activeRewards(){
  if(rewardDemoEnabled())return rewardDemoState();
  return app.rewardsUserId===app.user?.id?(app.rewards||DEFAULT_REWARDS):DEFAULT_REWARDS;
}

export function canUseAutoMisses(game=app.game){
  const rewards=activeRewards();
  return gameAllowsBoosts(game)&&(rewards.auto_miss_unlimited||Number(rewards.auto_miss_uses)>0);
}

export function canUseSquareShip(game=app.game){
  const rewards=activeRewards();
  return gameAllowsBoosts(game)&&(rewards.square_ship_unlimited||Number(rewards.square_ship_uses)>0);
}

export function squareShipUsesLabel(){
  const rewards=activeRewards();
  return rewards.square_ship_unlimited?"∞":String(Math.max(0,Number(rewards.square_ship_uses)||0));
}

export function autoMissUsesLabel(){
  const rewards=activeRewards();
  return rewards.auto_miss_unlimited?"∞":String(Math.max(0,Number(rewards.auto_miss_uses)||0));
}

export function canUseMushroomSkin(){
  return !!activeRewards().mushroom_skin_unlocked;
}

export async function selectShipSkin(skin){
  const wanted=skin==="mushroom"?"mushroom":"vegetable";
  if(wanted==="mushroom"&&!canUseMushroomSkin())throw new Error("грибной скин пока недоступен");

  if(rewardDemoEnabled()){
    app.rewards={...activeRewards(),selected_ship_skin:wanted};
    app.rewardsUserId=app.user?.id||null;
    return app.rewards;
  }

  const {data,error}=await app.supabase.rpc("set_fruitkog_ship_skin",{p_skin:wanted});
  if(error)throw error;
  app.rewards=normalizedRewards(data);
  app.rewardsUserId=app.user?.id||null;
  return app.rewards;
}


export function resetGameBoosts(){
  app.gameBoosts={game_id:null,auto_miss_enabled:false,square_ship_used:false};
}

export async function loadMyGameBoosts(gameId=app.game?.id){
  if(!gameId||!app.user){
    resetGameBoosts();
    return app.gameBoosts;
  }

  if(rewardDemoEnabled()){
    app.gameBoosts={
      game_id:gameId,
      auto_miss_enabled:!!app.placement?.useAutoMiss,
      square_ship_used:!!app.placement?.useSquareShip,
    };
    return app.gameBoosts;
  }

  try{
    const {data,error}=await app.supabase.rpc("get_my_game_boosts",{p_game_id:gameId});
    if(error)throw error;
    app.gameBoosts={
      game_id:gameId,
      auto_miss_enabled:!!data?.auto_miss_enabled,
      square_ship_used:!!data?.square_ship_used,
    };
  }catch(error){
    console.warn("Fruitkog game boosts are not available yet",error);
    resetGameBoosts();
  }
  return app.gameBoosts;
}

export function autoMissEnabledForGame(gameId=app.game?.id){
  if(rewardDemoEnabled())return !!app.placement?.useAutoMiss;
  return app.gameBoosts?.game_id===gameId&&!!app.gameBoosts?.auto_miss_enabled;
}
