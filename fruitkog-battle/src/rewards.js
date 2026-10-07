// Будущие награды Fruitkog: безопасное чтение и тестовый режим.
// ?reward-demo=1 включает локальные тестовые награды без обращения к Supabase.

import { app } from "./state.js?v=127";

export const DEFAULT_REWARDS = Object.freeze({
  mushroom_skin_unlocked:false,
  auto_miss_uses:0,
  square_ship_uses:0,
  selected_ship_skin:"vegetable",
});

function normalizedRewards(value={}){
  return {
    mushroom_skin_unlocked:!!value.mushroom_skin_unlocked,
    auto_miss_uses:Math.max(0,Number(value.auto_miss_uses)||0),
    square_ship_uses:Math.max(0,Number(value.square_ship_uses)||0),
    selected_ship_skin:value.selected_ship_skin==="mushroom"?"mushroom":"vegetable",
  };
}

export function rewardDemoEnabled(){
  return new URLSearchParams(location.search).get("reward-demo")==="1";
}

export function rewardDemoState(){
  return {
    mushroom_skin_unlocked:true,
    auto_miss_uses:30,
    square_ship_uses:15,
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
  return gameAllowsBoosts(game)&&Number(activeRewards().auto_miss_uses)>0;
}

export function canUseSquareShip(game=app.game){
  return gameAllowsBoosts(game)&&Number(activeRewards().square_ship_uses)>0;
}

export function squareShipUses(){
  return Math.max(0,Number(activeRewards().square_ship_uses)||0);
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
