-- обновление 118: укрепление после повторной проверки безопасности и устойчивости.
-- выполните после 037. повторный запуск безопасен.
--
-- что меняется (подробности — у каждого блока ниже):
--   1. новые таблицы и последовательности в public больше не открываются браузеру
--      автоматически — права выдаются только явно (как и так принято в проекте с 023).
--      новые функции Postgres по-прежнему открывает всем (PUBLIC) — их закрываем явно, а
--      встроенная проверка защиты и тест-сторож такие функции замечают; проверка защиты
--      теперь видит и перегрузки открытых функций, и открытые представления;
--   2. ники: пробелы любого вида (неразрывный, широкий, табуляция) превращаются в обычный
--      пробел и обрезаются по краям, а ники с невидимыми и служебными символами (нулевой
--      ширины, смена направления текста, «пустой» символ Брайля, теги) отклоняются: раньше
--      так можно было сделать ник, неотличимый от чужого;
--   3. вход в комнату и выход из нее — не больше 20 раз в минуту; после выхода гостя
--      (или игрока сверх суточного лимита пары) рейтинговая комната снова становится рейтинговой,
--      если ее создатель по-прежнему может играть на рейтинг; счетчик лимитов больше не
--      спотыкается о два одновременных первых запроса;
--   4. заявки на турнир и их отзыв — не больше 5 раз за 10 минут (иначе можно заспамить админа);
--   5. общий архив матчей отдает последние 100 матчей, а не все сразу;
--   6. лимит 5 открытых комнат считается после блокировки — параллельные запросы его не обходят;
--   7. турнирную комнату нельзя «открыть заново» даже админу: в пару не сядет посторонний;
--      в плей-офф проходит дальше только победитель, который играл в этой паре.

-- ── 1. права по умолчанию ────────────────────────────────────────────────────
-- Supabase по умолчанию дает anon и authenticated полные права на все новые таблицы,
-- последовательности и функции, созданные в public. В проекте все права выдаются явно,
-- поэтому автоматическую выдачу выключаем: забытая строка revoke больше не откроет всем
-- новую таблицу. С функциями так не получится: право выполнять новую функцию Postgres сам
-- дает всем (PUBLIC), и отключить это можно только глобально, для всех схем сразу. Поэтому
-- каждую новую функцию по-прежнему закрываем явно (revoke ... from public, anon,
-- authenticated), а забытую сразу покажут «проверить защиту» и тест-сторож.
alter default privileges for role postgres in schema public revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public revoke execute on functions from anon, authenticated;

-- ── 2. ники: одинаковые пробелы, без невидимых символов ────────────────────
-- символы записаны кодами (\uXXXX), а не как есть: невидимый символ в тексте файла легко
-- потерять или испортить при копировании в SQL Editor — и тогда проверка сломается незаметно.

-- пробелы любого вида (неразрывный, широкий, табуляция, перенос строки…) — один обычный
-- пробел, по краям — ничего. иначе «Иван Петров» с неразрывным пробелом внутри или в конце
-- прошел бы как новый ник, хотя на экране выглядит так же. не зависит от настроек языка базы.
create or replace function public.normalize_school_nick(p_nick text)
returns text
language sql immutable set search_path=''
as $$
  select btrim(regexp_replace(coalesce(p_nick,''),
    '[\u0009-\u000D\u0020\u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]+', ' ', 'g'));
$$;
revoke all on function public.normalize_school_nick(text) from public,anon,authenticated;

-- невидимые и служебные символы: управляющие, мягкий перенос, нулевой ширины (в том числе
-- соединитель эмодзи), смена направления текста, «пустые» буквы хангыля и символ Брайля,
-- селекторы вариантов, теги. проверяется уже очищенный ник (после normalize_school_nick).
create or replace function public.nick_has_hidden_chars(p_nick text)
returns boolean
language sql immutable set search_path=''
as $$
  select coalesce(p_nick,'') ~ (
    '[\u0001-\u001F\u007F-\u009F\u00AD\u034F\u061C\u115F\u1160\u17B4\u17B5\u180B-\u180F'
    || '\u200B-\u200F\u2028-\u202E\u2060-\u206F\u2800\u3164\uFE00-\uFE0F\uFEFF\uFFA0\uFFF9-\uFFFB'
    || '\U0001BCA0-\U0001BCA3\U0001D173-\U0001D17A\U000E0000-\U000E007F\U000E0100-\U000E01EF]'
  );
$$;
revoke all on function public.nick_has_hidden_chars(text) from public,anon,authenticated;

-- регистрация (001): ник очищается так же, как во всех проверках; с невидимыми символами — отказ
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare nick text;
begin
  if new.email is null then
    return new;
  end if;

  nick := btrim(left(public.normalize_school_nick(new.raw_user_meta_data->>'school_nick'), 48));
  if length(nick) < 1 then raise exception 'School nick required'; end if;
  if public.nick_has_hidden_chars(nick) then raise exception 'School nick has hidden characters'; end if;

  if exists(select 1 from public.profiles where account_type='registered' and lower(display_name)=lower(nick)) then
    raise exception 'School nick already registered';
  end if;

  insert into public.profiles(user_id,display_name,account_type)
  values(new.id,nick,'registered');

  return new;
end;
$$;

-- проверка ника перед регистрацией (003): такой ник «недоступен»
create or replace function public.is_school_nick_available(p_nick text)
returns boolean
language sql
security definer
stable
set search_path=''
as $$
  with cleaned as (
    select lower(btrim(left(public.normalize_school_nick(p_nick),48))) as nick
  )
  select
    (select nick from cleaned) not in (
      'сочный томат',
      'хрустящий огурец',
      'боевой баклажан',
      'задумчивая тыква',
      'спелое яблоко',
      'веселая груша',
      'солнечный персик',
      'бодрая морковь',
      'серьезная вишня',
      'смелый арбуз'
    )
    and not exists(
      select 1 from public.profiles
      where account_type='registered'
        and lower(display_name)=(select nick from cleaned)
    )
    and not public.nick_has_hidden_chars((select nick from cleaned));
$$;

-- исправление ника админом (030)
create or replace function public.admin_change_school_nick(p_user_id uuid,p_new_nick text)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  old_profile public.profiles%rowtype;
  new_profile public.profiles%rowtype;
  cleaned text:=public.normalize_school_nick(p_new_nick);
begin
  perform public.require_game_admin();
  if p_user_id is null then raise exception 'Registered profile not found'; end if;
  if length(cleaned)<1 or length(cleaned)>48 then raise exception 'Invalid school nick length'; end if;
  if public.nick_has_hidden_chars(cleaned) then raise exception 'School nick has hidden characters'; end if;

  select * into old_profile from public.profiles
  where user_id=p_user_id and account_type='registered' for update;
  if not found then raise exception 'Registered profile not found'; end if;
  if old_profile.display_name=cleaned then return to_jsonb(old_profile); end if;

  if exists(select 1 from public.profiles
            where account_type='registered' and user_id<>p_user_id
              and lower(display_name)=lower(cleaned)) then
    raise exception 'School nick already registered';
  end if;

  update public.profiles
  set display_name=cleaned,school_verified=false
  where user_id=p_user_id returning * into new_profile;

  -- games store player names as snapshots; keep them consistent with the profile.
  update public.games set player1_name=cleaned where player1_id=p_user_id;
  update public.games set player2_name=cleaned where player2_id=p_user_id;

  perform public.push_user_notification(
    p_user_id,'nickname_changed','школьный ник изменен',
    'администратор исправил ваш школьный ник: «'||cleaned||'».',
    null,null,null,'nickname-changed:'||gen_random_uuid()::text
  );
  return to_jsonb(new_profile);
end;
$$;

-- ── 3. вход в комнату и выход ─────────────────────────────────────────────────
-- счетчик лимитов (034): строка счетчика создается атомарно. раньше два одновременных
-- первых действия одного игрока оба не находили строку, оба пытались ее вставить, и второе
-- падало с непонятной ошибкой. теперь второй запрос дожидается первого и считается следующим.
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

  insert into public.action_rate_limits(user_id, action, window_started, count)
  values (uid, p_action, now(), 0)
  on conflict (user_id, action) do nothing;

  select * into r
  from public.action_rate_limits
  where user_id = uid and action = p_action
  for update;

  -- Окно истекло — начинаем счёт заново.
  if r.window_started < now() - p_window then
    update public.action_rate_limits
    set window_started = now(), count = 1
    where user_id = uid and action = p_action;
    return;
  end if;

  -- Лимит в текущем окне исчерпан. Перевод для игрока — в humanError() в src/errors.js.
  if r.count >= p_limit then
    raise exception 'Rate limit exceeded';
  end if;

  update public.action_rate_limits
  set count = count + 1
  where user_id = uid and action = p_action;
end;
$$;
revoke all on function public.enforce_rate_limit(text, integer, interval) from public,anon,authenticated;

-- вход (035): лимит частоты; турнирные игры войти нельзя (их занимают только игроки пары)
create or replace function public.join_public_game(p_game_id uuid)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  uid uuid:=auth.uid();
  p public.profiles%rowtype;
  creator public.profiles%rowtype;
  g public.games%rowtype;
  existing_game_id uuid;
  recent_rated_count integer:=0;
  actual_type text;
  skip_reason text;
  v_pair_limit integer:=public.game_setting('pair_daily_limit',3);
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into p from public.profiles where user_id=uid;
  if not found then raise exception 'Profile required'; end if;

  select * into g from public.games where id=p_game_id for update;
  if not found then raise exception 'Game not found'; end if;
  if g.player1_id=uid then raise exception 'Cannot join your own game'; end if;
  if g.player2_id=uid and g.status in('placing','playing','paused') then
    return to_jsonb(g);
  end if;
  if g.visibility<>'public' or g.status<>'waiting' or g.player2_id is not null
     or g.game_type='tournament' then
    raise exception 'Game is full';
  end if;
  -- вход и выход вместе — не больше 20 раз в минуту (иначе можно гонять всех по кругу
  -- обновлять зал и засыпать создателя уведомлениями «соперник присоединился»)
  perform public.enforce_rate_limit('join_leave', 20, interval '1 minute');

  perform locked.user_id
  from public.profiles locked
  where locked.user_id in(uid,g.player1_id)
  order by locked.user_id
  for update;

  select * into creator from public.profiles where user_id=g.player1_id;

  select active_game.id into existing_game_id
  from public.games active_game
  where active_game.id<>g.id
    and active_game.game_type<>'tournament'
    and active_game.status in('placing','playing','paused')
    and (
      (active_game.player1_id=g.player1_id and active_game.player2_id=uid)
      or
      (active_game.player1_id=uid and active_game.player2_id=g.player1_id)
    )
  order by active_game.updated_at desc
  limit 1;

  if existing_game_id is not null then
    raise exception 'Pair already has active game: %',existing_game_id;
  end if;

  actual_type:=g.game_type;
  skip_reason:=g.rating_skip_reason;
  if g.game_type='rated' then
    if p.account_type='guest' or creator.account_type='guest' then
      actual_type:='casual';
      skip_reason:='guest';
    else
      select count(*)::integer into recent_rated_count
      from public.games prior
      where prior.rating_applied=true
        and prior.finished_at>now()-interval '24 hours'
        and (
          (prior.player1_id=g.player1_id and prior.player2_id=uid)
          or
          (prior.player1_id=uid and prior.player2_id=g.player1_id)
        );
      if recent_rated_count>=v_pair_limit then
        actual_type:='casual';
        skip_reason:='pair_daily_limit';
      end if;
    end if;
  end if;

  update public.games
  set player2_id=uid,player2_name=p.display_name,status='placing',
      game_type=actual_type,rating_skip_reason=skip_reason,
      player2_action_at=now(),updated_at=now()
  where public.games.id=g.id returning * into g;
  return to_jsonb(g);
end;
$$;

-- выход второго игрока (002): лимит частоты и возврат рейтингового режима
create or replace function public.leave_game(p_game_id uuid)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare uid uuid:=auth.uid();g public.games%rowtype;restore_rated boolean;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into g from public.games where id=p_game_id for update;
  if not found then raise exception 'Game not found'; end if;
  if g.player2_id<>uid then raise exception 'Only the second player can leave'; end if;
  if g.status<>'placing' then raise exception 'Game can no longer be left'; end if;
  perform public.enforce_rate_limit('join_leave', 20, interval '1 minute');

  -- рейтинговую комнату понизили до обычной только из-за вошедшего (гость или суточный
  -- лимит пары) — после его выхода возвращаем то, что выбрал создатель. но только если
  -- создатель по-прежнему может играть на рейтинг (ник подтвержден): если админ за это время
  -- исправил ему ник, комната остается обычной — иначе выход (и выход гостя из аккаунта) упал бы
  restore_rated:=g.game_type='casual' and g.rating_skip_reason is not null
    and exists(select 1 from public.profiles c
               where c.user_id=g.player1_id and c.account_type='registered' and c.school_verified);

  delete from public.fleets where game_id=g.id;
  update public.games
  set player2_id=null,player2_name=null,player1_ready=false,player2_ready=false,
      player1_action_at=now(),player2_action_at=null,status='waiting',current_turn=null,updated_at=now(),
      game_type=case when restore_rated then 'rated' else game_type end,
      rating_skip_reason=case when restore_rated then null else rating_skip_reason end
  where public.games.id=g.id returning * into g;
  return to_jsonb(g);
end;
$$;

-- ── 4. заявки на турнир (017): подать и отозвать — вместе не больше 5 раз за 10 минут ──
create or replace function public.apply_to_tournament(p_tournament_id uuid)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  uid uuid:=auth.uid();
  t public.tournaments%rowtype;
  p public.profiles%rowtype;
begin
  if uid is null then raise exception 'Authentication required'; end if;

  select * into t from public.tournaments where id=p_tournament_id for update;
  if not found then raise exception 'Tournament not found'; end if;
  if t.status<>'registration' or (t.registration_deadline is not null and t.registration_deadline<=now()) then
    raise exception 'Tournament registration closed';
  end if;

  select * into p from public.profiles where user_id=uid;
  if not found or p.account_type<>'registered' then raise exception 'Registered profile required'; end if;

  if exists(
    select 1 from public.tournament_applications
    where tournament_id=t.id and user_id=uid and status='approved'
  ) then return public.get_tournament_board(t.id); end if;

  perform public.enforce_rate_limit('tournament_application', 5, interval '10 minutes');
  insert into public.tournament_applications(
    tournament_id,user_id,status,created_at,updated_at,reviewed_at,reviewed_by
  ) values(t.id,uid,'pending',now(),now(),null,null)
  on conflict(tournament_id,user_id) do update
  set status='pending',updated_at=now(),reviewed_at=null,reviewed_by=null;

  update public.tournaments set updated_at=now() where id=t.id;
  return public.get_tournament_board(t.id);
end;
$$;

create or replace function public.withdraw_tournament_application(p_tournament_id uuid)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  uid uuid:=auth.uid();
  t public.tournaments%rowtype;
begin
  if uid is null then raise exception 'Authentication required'; end if;

  select * into t from public.tournaments where id=p_tournament_id for update;
  if not found then raise exception 'Tournament not found'; end if;
  if t.status<>'registration' or (t.registration_deadline is not null and t.registration_deadline<=now()) then
    raise exception 'Tournament registration closed';
  end if;
  if not exists(
    select 1 from public.tournament_applications
    where tournament_id=t.id and user_id=uid and status in('pending','approved')
  ) then raise exception 'Tournament application not found'; end if;

  perform public.enforce_rate_limit('tournament_application', 5, interval '10 minutes');
  delete from public.tournament_players
  where tournament_id=t.id and user_id=uid;

  update public.tournament_applications
  set status='withdrawn',updated_at=now(),reviewed_at=null,reviewed_by=null
  where tournament_id=t.id and user_id=uid;

  update public.tournaments set updated_at=now() where id=t.id;
  return public.get_tournament_board(t.id);
end;
$$;

-- ── 5. общий архив матчей (027): последние 100, а не все матчи за все время ──
create or replace function public.list_match_history()
returns table(
  game_id uuid,
  player1_name text,
  player2_name text,
  winner_name text,
  game_type text,
  finish_reason text,
  rating_applied boolean,
  rating_delta integer,
  rating_skip_reason text,
  tournament_rating_applied boolean,
  tournament_rating_delta integer,
  finished_at timestamptz,
  viewer_can_open boolean
)
language sql
security definer
stable
set search_path=''
as $$
  select
    g.id,
    g.player1_name,
    g.player2_name,
    case
      when g.winner_id=g.player1_id then g.player1_name
      when g.winner_id=g.player2_id then g.player2_name
      else '—'
    end,
    g.game_type,
    coalesce(g.finish_reason,'fleet_destroyed'),
    g.rating_applied,
    g.rating_delta,
    g.rating_skip_reason,
    g.tournament_rating_applied,
    g.tournament_rating_delta,
    g.finished_at,
    coalesce(auth.uid() in(g.player1_id,g.player2_id),false)
  from public.games g
  where auth.uid() is not null
    and g.status='finished'
    and g.finished_at is not null
  order by g.finished_at desc
  limit 100;
$$;

-- ── 6. лимиты создания игр (034): сначала блокировка, потом подсчет ──────────
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

  -- Не более 15 новых игр в минуту с одного аккаунта. проверка стоит первой: она блокирует
  -- строку счетчика, и одновременные запросы одного игрока дальше идут по очереди — поэтому
  -- следующий подсчет открытых комнат не обойти параллельными запросами.
  perform public.enforce_rate_limit('create_game', 15, interval '1 minute');

  -- Не более 5 своих открытых (ожидающих соперника) комнат одновременно.
  select count(*) into open_rooms
  from public.games
  where player1_id = new.player1_id
    and status = 'waiting'
    and game_type <> 'tournament';

  if open_rooms >= 5 then
    raise exception 'Too many open rooms';
  end if;

  return new;
end;
$$;

-- ── 7. турнирные комнаты (019) ──────────────────────────────────────────────
-- раньше админ был исключен из проверки целиком, и, выйдя из турнирной комнаты как второй
-- игрок, мог «открыть» ее заново — тогда в пару мог сесть посторонний и пройти дальше.
-- теперь турнирную комнату нельзя вернуть в ожидание и нельзя поменять в ней игроков никому;
-- закрыть ее (отменить игру) может только админ — это «закрыть матч», техпобеда, переигровка,
-- закрытие и удаление турнира.
create or replace function public.protect_tournament_match_room()
returns trigger
language plpgsql security definer set search_path=''
as $$
begin
  if old.game_type='tournament' and old.status='placing' then
    if new.status='waiting'
       or new.player1_id is distinct from old.player1_id
       or new.player2_id is distinct from old.player2_id then
      raise exception 'Tournament match cannot be left';
    end if;
    if new.status='cancelled' and not public.is_game_admin(auth.uid()) then
      raise exception 'Tournament match cannot be left';
    end if;
  end if;
  return new;
end;
$$;

-- продвижение победителя плей-офф (037): только игрок этой пары
create or replace function public.advance_playoff_winner(p_match_id uuid)
returns void
language plpgsql set search_path=''
as $$
declare
  current_match public.tournament_matches%rowtype;
  next_match public.tournament_matches%rowtype;
  next_p1 uuid;
  next_p2 uuid;
  new_game_id uuid;
begin
  select * into current_match from public.tournament_matches where id=p_match_id;
  -- дальше проходит только игрок этой пары (защита на случай, если в игру как-то попал посторонний)
  if not found or current_match.stage<>'playoff' or current_match.winner_id is null
     or (current_match.winner_id is distinct from current_match.player1_id
         and current_match.winner_id is distinct from current_match.player2_id) then
    return;
  end if;

  if current_match.next_match_id is null then
    -- финал — единственная пара последнего раунда. в старых сетках без связей (до 036)
    -- у пар первого раунда тоже нет следующей пары: там турнир не завершаем
    if exists(
      select 1 from public.tournament_matches
      where tournament_id=current_match.tournament_id and stage='playoff'
        and id<>current_match.id and round_no>=current_match.round_no
    ) then
      return;
    end if;
    update public.tournaments
    set status='finished',finished_at=coalesce(finished_at,now()),updated_at=now()
    where id=current_match.tournament_id;
    perform public.apply_tournament_ratings(current_match.tournament_id);
    return;
  end if;

  select * into next_match
  from public.tournament_matches
  where id=current_match.next_match_id
  for update;

  next_p1:=case when current_match.next_slot=1 then current_match.winner_id else next_match.player1_id end;
  next_p2:=case when current_match.next_slot=2 then current_match.winner_id else next_match.player2_id end;

  if next_p1 is not null and next_p2 is not null and next_match.game_id is null then
    new_game_id:=public.create_tournament_room(next_p1,next_p2);
    update public.tournament_matches
    set player1_id=next_p1,player2_id=next_p2,game_id=new_game_id,status='ready'
    where id=next_match.id;
  else
    update public.tournament_matches
    set player1_id=next_p1,player2_id=next_p2
    where id=next_match.id;
  end if;

  update public.tournaments set updated_at=now() where id=current_match.tournament_id;
end;
$$;

-- ── встроенная проверка защиты (037): видит представления и перегрузки ──────
create or replace function public.admin_security_audit()
returns jsonb
language plpgsql
security definer
stable
set search_path=''
as $$
declare
  all_rls_enabled boolean;
  direct_changes_blocked boolean;
  internal_tables_hidden boolean;
  fleet_policy_safe boolean;
  rpc_allowlist_safe boolean;
  result jsonb;
begin
  perform public.require_game_admin();

  select not exists(
    select 1
    from pg_class c
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public'
      and c.relkind in('r','p')
      and not c.relrowsecurity
  ) into all_rls_enabled;

  select not exists(
    select 1
    from pg_class c
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public'
      and c.relkind in('r','p','v','m','f')
      and (
        has_table_privilege('anon',c.oid,'INSERT')
        or has_table_privilege('anon',c.oid,'UPDATE')
        or has_table_privilege('anon',c.oid,'DELETE')
        or has_table_privilege('authenticated',c.oid,'INSERT')
        or has_table_privilege('authenticated',c.oid,'UPDATE')
        or has_table_privilege('authenticated',c.oid,'DELETE')
      )
  ) into direct_changes_blocked;

  select not exists(
    select 1
    from pg_class c
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public'
      and c.relkind in('r','p','v','m','f')
      and c.relname not in('profiles','games','fleets','shots')
      and (
        has_table_privilege('anon',c.oid,'SELECT')
        or has_table_privilege('authenticated',c.oid,'SELECT')
      )
  ) into internal_tables_hidden;

  select coalesce(
    bool_or(
      coalesce(qual,'') ilike '%owner_id%'
      and coalesce(qual,'') ilike '%finished%'
      and coalesce(qual,'') ilike '%visibility%'
    ),false
  )
  from pg_policies
  where schemaname='public'
    and tablename='fleets'
    and policyname='own fleet readable'
  into fleet_policy_safe;

  select not exists(
    select 1
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and (
        has_function_privilege('anon',p.oid,'EXECUTE')
        or has_function_privilege('authenticated',p.oid,'EXECUTE')
      )
      and p.proname not in(
        'is_school_nick_available','get_leaderboard','list_public_tournaments',
        'get_tournament_board','claim_random_guest','is_game_admin','list_active_games',
        'create_game','join_public_game','cancel_game','leave_game','ready_with_fleet',
        'shoot','surrender_game','list_match_history','get_public_player_profile',
        'apply_to_tournament','withdraw_tournament_application','list_user_notifications',
        'mark_user_notifications_read','admin_list_players','admin_set_school_verified',
        'admin_list_games','admin_get_game_details','admin_cancel_game',
        'admin_list_notifications','admin_mark_notifications_read',
        'admin_publish_user_announcement','admin_create_tournament',
        'admin_set_tournament_registration_deadline','admin_review_tournament_application',
        'admin_add_tournament_player','admin_remove_tournament_player',
        'admin_configure_tournament_qualifiers','admin_generate_tournament',
        'admin_start_tournament_qualifiers','admin_start_tournament_playoff',
        'admin_close_tournament','admin_delete_tournament','admin_security_audit',
        'admin_set_tournament_archived','admin_set_tournament_format',
        'admin_change_school_nick','admin_get_game_settings','admin_update_game_setting',
        'get_public_game_settings','admin_award_technical_win','admin_replay_tournament_match'
      )
  ) into rpc_allowlist_safe;

  -- у открытой браузеру функции должна быть ровно одна версия: вторая (перегрузка с тем же
  -- именем) прошла бы проверку белого списка по имени, хотя ее никто сознательно не открывал
  rpc_allowlist_safe:=rpc_allowlist_safe and not exists(
    select 1
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and (
        has_function_privilege('anon',p.oid,'EXECUTE')
        or has_function_privilege('authenticated',p.oid,'EXECUTE')
      )
    group by p.proname
    having count(*)>1
  );

  result:=jsonb_build_object(
    'passed',all_rls_enabled and direct_changes_blocked and internal_tables_hidden
      and fleet_policy_safe and rpc_allowlist_safe,
    'checked_at',now(),
    'items',jsonb_build_array(
      jsonb_build_object('key','rls','label','защита строк включена у всех таблиц','passed',all_rls_enabled),
      jsonb_build_object('key','writes','label','прямое изменение таблиц из браузера запрещено','passed',direct_changes_blocked),
      jsonb_build_object('key','tables','label','внутренние таблицы скрыты от браузера','passed',internal_tables_hidden),
      jsonb_build_object('key','fleets','label','чужие расстановки скрыты до завершения матча','passed',fleet_policy_safe),
      jsonb_build_object('key','rpc','label','служебные функции закрыты','passed',rpc_allowlist_safe)
    )
  );

  return result;
end;
$$;

-- ── права (как и раньше; функции переопределены, права сохраняются — повторяем явно) ──
revoke all on function public.join_public_game(uuid) from public,anon;
grant execute on function public.join_public_game(uuid) to authenticated;
revoke all on function public.leave_game(uuid) from public,anon;
grant execute on function public.leave_game(uuid) to authenticated;
revoke all on function public.apply_to_tournament(uuid) from public,anon;
grant execute on function public.apply_to_tournament(uuid) to authenticated;
revoke all on function public.withdraw_tournament_application(uuid) from public,anon;
grant execute on function public.withdraw_tournament_application(uuid) to authenticated;
revoke all on function public.list_match_history() from public,anon;
grant execute on function public.list_match_history() to authenticated;
revoke all on function public.admin_change_school_nick(uuid,text) from public,anon;
grant execute on function public.admin_change_school_nick(uuid,text) to authenticated;
revoke all on function public.is_school_nick_available(text) from public;
grant execute on function public.is_school_nick_available(text) to anon,authenticated;
revoke all on function public.admin_security_audit() from public,anon;
grant execute on function public.admin_security_audit() to authenticated;
revoke all on function public.handle_new_auth_user() from public,anon,authenticated;
revoke all on function public.enforce_game_creation_guards() from public,anon,authenticated;
revoke all on function public.protect_tournament_match_room() from public,anon,authenticated;
revoke all on function public.advance_playoff_winner(uuid) from public,anon,authenticated;
