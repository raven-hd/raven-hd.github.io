// Картинки профиля используются только во «Фруктовом бое».
import { app } from "./state.js?v=125";
import { $, msg } from "./helpers.js?v=125";
import { humanError } from "./errors.js?v=125";

const vegetables = ["tomato", "celery", "mushroom", "eggplant", "garlic", "corn"];
const expressions = ["happy", "grumpy", "cool", "surprised"];
const names = {tomato:"помидор", celery:"сельдерей", mushroom:"гриб", eggplant:"баклажан", garlic:"чеснок", corn:"кукуруза"};
const moods = {happy:"радостный", grumpy:"сердитый", cool:"крутой", surprised:"удивленный"};
export const avatarIds = vegetables.flatMap(vegetable => expressions.map(expression => `${vegetable}-${expression}`));
const allowedIds = new Set(avatarIds);

function avatarUrl(id) {
  return `./assets/avatars/${id}.webp`;
}

export function renderFruitkogAvatar(element, userId, fallback="") {
  if (!element) return;
  const id = app.fruitkogAvatarCache.get(userId);
  element.replaceChildren();
  if (allowedIds.has(id)) {
    const image = document.createElement("img");
    image.src = avatarUrl(id);
    image.alt = "";
    image.decoding = "async";
    element.appendChild(image);
  } else {
    element.textContent = fallback;
  }
  element.classList.toggle("hidden", !id && !fallback);
}

export async function loadFruitkogAvatars(ids,refresh=false) {
  const unique = [...new Set(ids.filter(id=>id&&(refresh||!app.fruitkogAvatarLoaded.has(id))))];
  if (!unique.length || !app.user) return;
  const {data,error} = await app.supabase.from("fruitkog_avatars")
    .select("user_id,avatar_id").in("user_id",unique);
  if (error) {
    console.error("не удалось загрузить аватары",error);
    return;
  }
  const currentIds = unique.filter(id=>refresh||!app.fruitkogAvatarLoaded.has(id));
  currentIds.forEach(id=>app.fruitkogAvatarCache.delete(id));
  currentIds.forEach(id=>app.fruitkogAvatarLoaded.add(id));
  (data||[]).forEach(row=>{
    if(currentIds.includes(row.user_id)&&allowedIds.has(row.avatar_id))app.fruitkogAvatarCache.set(row.user_id,row.avatar_id);
  });
}

export function openAvatarPicker() {
  if (app.profile?.account_type !== "registered") return;
  const grid = $("avatarPickerGrid");
  grid.replaceChildren();
  msg($("avatarPickerMessage"),"");
  const selected = app.fruitkogAvatarCache.get(app.user.id);
  for (const id of avatarIds) {
    const [vegetable, expression] = id.split("-");
    const button = document.createElement("button");
    button.type = "button";
    button.className = "avatar-choice";
    button.dataset.avatarId = id;
    button.setAttribute("aria-label",`${names[vegetable]}, ${moods[expression]}`);
    button.setAttribute("aria-pressed",String(id === selected));
    const image = document.createElement("img");
    image.src = avatarUrl(id);
    image.alt = "";
    image.loading = "lazy";
    button.appendChild(image);
    button.addEventListener("click",()=>{
      grid.querySelectorAll(".avatar-choice").forEach(choice=>choice.setAttribute("aria-pressed",String(choice===button)));
      $("saveAvatarBtn").disabled = false;
    });
    grid.appendChild(button);
  }
  $("saveAvatarBtn").disabled = true;
  $("avatarPickerDialog").showModal();
}

export async function saveAvatarChoice() {
  if (app.profile?.account_type !== "registered" || !app.user) return;
  const userId = app.user.id;
  const id = $("avatarPickerGrid").querySelector('.avatar-choice[aria-pressed="true"]')?.dataset.avatarId;
  if (!allowedIds.has(id)) return;
  $("saveAvatarBtn").disabled = true;
  try {
    const {error} = await app.supabase.from("fruitkog_avatars")
      .upsert({user_id:userId,avatar_id:id},{onConflict:"user_id"});
    if (error) throw error;
    if (app.user?.id !== userId) return;
    app.fruitkogAvatarCache.set(userId,id);
    app.fruitkogAvatarLoaded.add(userId);
    renderFruitkogAvatar($("profileAvatar"),userId,app.profile?.avatar_emoji||"🍏");
    renderFruitkogAvatar($("publicProfileAvatar"),userId,app.profile?.avatar_emoji||"🍏");
    renderFruitkogAvatar($("accountAvatar"),userId,app.profile?.avatar_emoji||"");
    $("avatarPickerDialog").close();
  } catch(e) {
    console.error("не удалось сохранить аватар",e);
    msg($("avatarPickerMessage"),e.code==="PGRST205"
      ? "выбор аватара пока недоступен: таблица аватаров не найдена. сообщите администратору."
      : humanError(e),"error");
    $("saveAvatarBtn").disabled = false;
  }
}
