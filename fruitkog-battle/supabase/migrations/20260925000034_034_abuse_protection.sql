-- обновление 34: защита от злоупотреблений авторизованным пользователем.
-- выполнять после 033_current_security_audit.sql.
--
-- Что делает:
--   1) Лимит частоты действий (переиспользуемый) — по образцу login_attempt_limits.
--   2) Антифлуд создания игр + предел одновременно открытых комнат на аккаунт.
--   3) Предел размера расстановки (защита от раздувания данных в fleets).
--
-- Принцип тот же, что в 031: интерфейс можно обойти, эти правила — нельзя,
-- потому что они живут в самой базе (триггеры), а не в браузере.
--
-- Ничего из существующих функций (create_game/shoot/ready_with_fleet) НЕ переписывается —
-- защита добавлена отдельными триггерами, чтобы не задеть игровую логику.
-- Турнирные партии (game_type='tournament') создаёт админ/система — лимиты к ним НЕ применяются.

begin;

-- ---------------------------------------------------------------------------
-- 1) Универсальный ограничитель частоты действий.
--    Таблица доступна только служебным функциям (owner обходит RLS),
--    напрямую из браузера её не прочитать и не изменить.
-- ---------------------------------------------------------------------------
create table if not exists public.action_rate_limits (
  user_id uuid not null references auth.users(id) on delete cascade,
  action text not null,
  window_started timestamptz not null default now(),
  count integer not null default 0,
  primary key (user_id, action)
);

alter table public.action_rate_limits enable row level security;
revoke all on public.action_rate_limits from anon, authenticated;

-- Вызывается ТОЛЬКО изнутри других серверных функций/триггеров.
-- Наружу закрыта (revoke), поэтому в белый список admin_security_audit() не попадает.
create or replace function public.enforce_rate_limit(
  p_action text,
  p_limit integer,
  p_window interval
)
returns void
language plpgsql
security definer
set search_path=''
as $$
declare
  uid uuid := auth.uid();
  r public.action_rate_limits%rowtype;
begin
  if uid is null then raise exception 'Authentication required'; end if;

  select * into r
  from public.action_rate_limits
  where user_id = uid and action = p_action
  for update;

  if not found then
    insert into public.action_rate_limits(user_id, action, window_started, count)
    values (uid, p_action, now(), 1);
    return;
  end if;

  -- Окно истекло — начинаем счёт заново.
  if r.window_started < now() - p_window then
    update public.action_rate_limits
    set window_started = now(), count = 1
    where user_id = uid and action = p_action;
    return;
  end if;

  -- Лимит в текущем окне исчерпан.
  -- Сообщение — английский ключ по соглашению проекта; перевод для игрока — в humanError() в app.js.
  if r.count >= p_limit then
    raise exception 'Rate limit exceeded';
  end if;

  update public.action_rate_limits
  set count = count + 1
  where user_id = uid and action = p_action;
end;
$$;

revoke execute on function public.enforce_rate_limit(text, integer, interval)
from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2) Антифлуд создания игр + предел открытых комнат.
--    Срабатывает при создании обычной (casual/rated) комнаты.
--    Турнирные партии пропускаются без проверок.
-- ---------------------------------------------------------------------------
create or replace function public.enforce_game_creation_guards()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  open_rooms integer;
begin
  -- Турнирные игры создаёт администратор/система — лимиты к ним не применяются.
  if new.game_type = 'tournament' then
    return new;
  end if;

  -- Лимиты — только для действий игроков. Вставки без пользователя (SQL Editor, миграции,
  -- тесты, серверные задачи) не ограничиваем. Обойти это из браузера нельзя:
  -- create_game сама требует вход (auth.uid() не может быть пустым на этом пути).
  if auth.uid() is null then
    return new;
  end if;

  -- Не более 5 своих открытых (ожидающих соперника) комнат одновременно.
  select count(*) into open_rooms
  from public.games
  where player1_id = new.player1_id
    and status = 'waiting'
    and game_type <> 'tournament';

  if open_rooms >= 5 then
    raise exception 'Too many open rooms';
  end if;

  -- Не более 15 новых игр в минуту с одного аккаунта.
  perform public.enforce_rate_limit('create_game', 15, interval '1 minute');

  return new;
end;
$$;

revoke execute on function public.enforce_game_creation_guards()
from public, anon, authenticated;

drop trigger if exists enforce_game_creation_guards_trigger on public.games;
create trigger enforce_game_creation_guards_trigger
before insert on public.games
for each row execute function public.enforce_game_creation_guards();

-- ---------------------------------------------------------------------------
-- 3) Предел размера расстановки.
--    Корректный флот из 10 кораблей весит ~0.5 КБ; 8 КБ — с огромным запасом.
--    Отсекает попытки сохранить раздутый JSON с мусорными полями.
-- ---------------------------------------------------------------------------
create or replace function public.enforce_fleet_size()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  if pg_column_size(new.ships) > 8192 then
    raise exception 'Invalid fleet';  -- тот же ключ, что у assert_valid_fleet: «сервер отклонил расстановку»
  end if;
  return new;
end;
$$;

revoke execute on function public.enforce_fleet_size()
from public, anon, authenticated;

drop trigger if exists enforce_fleet_size_trigger on public.fleets;
create trigger enforce_fleet_size_trigger
before insert or update on public.fleets
for each row execute function public.enforce_fleet_size();

commit;
