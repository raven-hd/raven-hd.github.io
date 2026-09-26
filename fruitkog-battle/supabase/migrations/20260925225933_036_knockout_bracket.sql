-- обновление 116: турнир в формате «плей-офф» проводится до финала.
-- выполните после 035. повторный запуск безопасен.
--
-- раньше жеребьевка (admin_generate_tournament из 015) создавала только пары первого раунда —
-- без игровых комнат и без следующих раундов, поэтому турнир застревал сразу после жеребьевки.
-- теперь она строит всю сетку сразу, так же как плей-офф после квалификации (021):
--   * размер сетки — ближайшая степень двойки (2, 4, 8 … 128), посев случайный;
--   * если участников меньше, чем мест в сетке, лишние места достаются по жребию
--     нескольким участникам — они проходят первый раунд без игры («свободный проход»).
--     в каждой паре первого раунда не больше одного пустого места, поэтому со второго
--     раунда играют все;
--   * для пар, где оба игрока известны, сразу создаются игровые комнаты. дальше победители
--     продвигаются автоматически (триггер sync_tournament_match_from_game из 022), а финал
--     завершает турнир и начисляет турнирный рейтинг. свободный проход рейтинг не меняет:
--     рейтинг начисляется только за сыгранные матчи.
-- требование четного числа участников снято.
--
-- заодно (найдено при проверке):
--   * жеребьевка сразу проверяет, что у всех участников подтвержден ник, и отвечает понятной
--     ошибкой — раньше комната не создавалась, и жеребьевка падала или проходила «как повезет»;
--   * прошедшие без игры получают уведомление;
--   * комнату следующего раунда, которую сервер создает сразу после завершенного матча, больше
--     не блокирует снятое подтверждение ника у одного из соперников (например, админ исправил
--     ник посреди турнира). раньше из-за этого отклонялся ход, которым соперник завершал матч;
--   * удаление турнира отменяет его незавершенные игры — иначе они оставались у игроков
--     в списке «мои», а выйти из турнирной комнаты нельзя.

alter table public.tournament_matches drop constraint if exists tournament_matches_result_reason_check;
alter table public.tournament_matches add constraint tournament_matches_result_reason_check
check(result_reason is null or result_reason in('game','technical','replay','cancelled','bye'));

create or replace function public.admin_generate_tournament(p_tournament_id uuid)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  t public.tournaments%rowtype;
  participant_ids uuid[];
  participant_count integer;
  bracket_size integer:=2;
  total_rounds integer:=1;
  seed_slots integer[]:=array[1,2];
  expanded_slots integer[];
  current_size integer:=2;
  slot_idx integer;
  round_idx integer;
  round_match_count integer;
  match_pos integer;
  seed1 integer;
  seed2 integer;
  p1 uuid;
  p2 uuid;
  p1_name text;
  p2_name text;
  bye_player uuid;
  -- кто попадает во второй раунд сразу после свободного прохода: индекс = позиция пары первого раунда
  round2_players uuid[];
  new_code text;
  new_game_id uuid;
  next_id uuid;
  bye_rec record;
begin
  perform public.require_game_admin();
  select * into t from public.tournaments where id=p_tournament_id for update;
  if not found then raise exception 'Tournament not found'; end if;
  if t.status not in('draft','registration') then raise exception 'Tournament already started'; end if;
  if t.tournament_format is null then raise exception 'Tournament format required'; end if;
  if t.tournament_format<>'knockout' then
    raise exception 'Qualifying stage setup required';
  end if;
  if exists(select 1 from public.tournament_matches where tournament_id=t.id and game_id is not null) then
    raise exception 'Tournament already has games';
  end if;

  select array_agg(tp.user_id order by random()),count(*)::integer
  into participant_ids,participant_count
  from public.tournament_players tp
  where tp.tournament_id=t.id and tp.status='active';

  if participant_count<2 then raise exception 'Tournament needs two players'; end if;
  if participant_count>t.max_players then raise exception 'Tournament is full'; end if;
  if exists(
    select 1 from public.tournament_players tp
    left join public.profiles p on p.user_id=tp.user_id
    where tp.tournament_id=t.id and tp.status='active'
      and (p.user_id is null or p.account_type<>'registered' or not p.school_verified)
  ) then
    raise exception 'Tournament players must be verified';
  end if;

  -- размер сетки: ближайшая степень двойки, не меньше числа участников
  while bracket_size<participant_count loop
    bracket_size:=bracket_size*2;
    total_rounds:=total_rounds+1;
  end loop;

  -- стандартный порядок посева (как в 021): 1–8, 4–5, 2–7, 3–6 … сильнейшие номера посева
  -- получают пустые места, поэтому пустых мест в одной паре не бывает двух
  while current_size<bracket_size loop
    expanded_slots:=array[]::integer[];
    current_size:=current_size*2;
    for slot_idx in 1..array_length(seed_slots,1) loop
      expanded_slots:=array_append(expanded_slots,seed_slots[slot_idx]);
      expanded_slots:=array_append(expanded_slots,current_size+1-seed_slots[slot_idx]);
    end loop;
    seed_slots:=expanded_slots;
  end loop;

  delete from public.tournament_matches where tournament_id=t.id;
  update public.tournament_players set seed=null where tournament_id=t.id;
  for slot_idx in 1..participant_count loop
    update public.tournament_players
    set seed=slot_idx
    where tournament_id=t.id and user_id=participant_ids[slot_idx];
  end loop;

  round2_players:=array_fill(null::uuid,array[bracket_size/2]);

  for round_idx in 1..total_rounds loop
    round_match_count:=(bracket_size/power(2,round_idx))::integer;
    for match_pos in 1..round_match_count loop
      p1:=null;p2:=null;bye_player:=null;new_game_id:=null;

      if round_idx=1 then
        seed1:=seed_slots[(match_pos-1)*2+1];
        seed2:=seed_slots[(match_pos-1)*2+2];
        if seed1<=participant_count then p1:=participant_ids[seed1]; end if;
        if seed2<=participant_count then p2:=participant_ids[seed2]; end if;
        if p1 is null or p2 is null then
          bye_player:=coalesce(p1,p2);
          round2_players[match_pos]:=bye_player;
        end if;
      elsif round_idx=2 then
        -- оба участника пары второго раунда известны, если оба прошли без игры
        p1:=round2_players[(match_pos-1)*2+1];
        p2:=round2_players[(match_pos-1)*2+2];
      end if;

      if bye_player is not null then
        insert into public.tournament_matches(
          tournament_id,stage,round_no,position,player1_id,player2_id,winner_id,
          status,result_reason,resolved_at
        ) values(
          t.id,'playoff',round_idx,match_pos,bye_player,null,bye_player,
          'technical','bye',now()
        );
        continue;
      end if;

      if p1 is not null and p2 is not null then
        select display_name into p1_name from public.profiles where user_id=p1;
        select display_name into p2_name from public.profiles where user_id=p2;
        loop
          new_code:=upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
          exit when not exists(select 1 from public.games where code=new_code);
        end loop;
        insert into public.games(
          code,game_type,visibility,player1_id,player1_name,player2_id,player2_name,
          status,player1_action_at,player2_action_at,updated_at
        ) values(
          new_code,'tournament','public',p1,p1_name,p2,p2_name,
          'placing',now(),now(),now()
        ) returning id into new_game_id;
      end if;

      insert into public.tournament_matches(
        tournament_id,stage,round_no,position,player1_id,player2_id,game_id,status
      ) values(
        t.id,'playoff',round_idx,match_pos,p1,p2,new_game_id,
        case when new_game_id is not null then 'ready' else 'pending' end
      );
    end loop;
  end loop;

  -- связи «победитель пары → место в следующей паре» (как в 021)
  for round_idx in 1..(total_rounds-1) loop
    round_match_count:=(bracket_size/power(2,round_idx))::integer;
    for match_pos in 1..round_match_count loop
      select id into next_id
      from public.tournament_matches
      where tournament_id=t.id and stage='playoff'
        and round_no=round_idx+1 and position=ceil(match_pos/2.0)::integer;
      update public.tournament_matches
      set next_match_id=next_id,
          next_slot=case when mod(match_pos,2)=1 then 1 else 2 end
      where tournament_id=t.id and stage='playoff'
        and round_no=round_idx and position=match_pos;
    end loop;
  end loop;

  for bye_rec in
    select m.id,m.winner_id,nx.game_id as next_game_id
    from public.tournament_matches m
    join public.tournament_matches nx on nx.id=m.next_match_id
    where m.tournament_id=t.id and m.result_reason='bye'
  loop
    perform public.push_user_notification(
      bye_rec.winner_id,
      'tournament_match_assigned',
      'первый раунд — без игры',
      'по жребию вы проходите первый раунд турнира «'||t.name||'» без игры. '
        ||case when bye_rec.next_game_id is not null
          then 'соперник во втором раунде уже известен — комната открыта.'
          else 'соперник во втором раунде определится после матча первого раунда — придет уведомление.'
        end,
      bye_rec.next_game_id,t.id,bye_rec.id,
      'tournament-bye:'||bye_rec.id::text
    );
  end loop;

  update public.tournaments
  set status='active',started_at=now(),finished_at=null,updated_at=now()
  where id=t.id;

  return public.get_tournament_board(t.id);
end;
$$;

-- права — как и раньше: только вошедшим пользователям, внутри функция пускает только админа
revoke all on function public.admin_generate_tournament(uuid) from public,anon;
grant execute on function public.admin_generate_tournament(uuid) to authenticated;

-- комната следующего раунда создается сервером внутри триггера sync_tournament_match_from_game,
-- то есть прямо во время хода, которым соперник завершает матч. участники турнира уже прошли
-- проверку ника при одобрении заявки и при жеребьевке; если здесь отказать (например, админ
-- исправил ник и подтверждение снялось), откатится ход соперника. поэтому для таких комнат
-- (турнирная игра, создаваемая триггером) проверка пропускается; остальное — как в 031.
create or replace function public.require_verified_competitive_players()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
  if tg_op='INSERT' and new.game_type='tournament' and pg_trigger_depth()>1 then
    return new;
  end if;
  if new.game_type in ('rated','tournament')
     and new.status in ('waiting','placing','playing','paused') then
    if not exists (
      select 1 from public.profiles p
      where p.user_id=new.player1_id and p.account_type='registered'
        and p.school_verified=true
    ) or (new.player2_id is not null and not exists (
      select 1 from public.profiles p
      where p.user_id=new.player2_id and p.account_type='registered'
        and p.school_verified=true
    )) then
      raise exception 'Verified school nick required';
    end if;
  end if;
  return new;
end;
$$;

-- удаление турнира: сначала отменяются его незавершенные игры (как при закрытии турнира),
-- потом удаляются турнир, заявки, состав и сетка. завершенные игры остаются в общей истории.
create or replace function public.admin_delete_tournament(p_tournament_id uuid)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare
  t public.tournaments%rowtype;
begin
  perform public.require_game_admin();

  select * into t
  from public.tournaments
  where id=p_tournament_id
  for update;

  if not found then raise exception 'Tournament not found'; end if;

  update public.games g
  set status='cancelled',current_turn=null,winner_id=null,finished_at=null,
      finish_reason=null,surrendered_by=null,updated_at=now(),
      admin_cancelled_by=auth.uid(),admin_cancelled_at=now(),
      admin_cancel_reason='турнир удален администратором'
  from public.tournament_matches tm
  where tm.tournament_id=t.id and tm.game_id=g.id
    and g.status in('waiting','placing','playing','paused');

  delete from public.tournaments where id=t.id;
  return t.id;
end;
$$;

revoke all on function public.admin_delete_tournament(uuid) from public,anon;
grant execute on function public.admin_delete_tournament(uuid) to authenticated;
revoke all on function public.require_verified_competitive_players() from public,anon,authenticated;

