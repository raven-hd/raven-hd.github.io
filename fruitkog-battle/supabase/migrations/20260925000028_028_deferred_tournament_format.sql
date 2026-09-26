-- обновление базы 28: формат турнира можно выбрать до окончания регистрации.
-- выполните после 027_match_archive_visibility.sql.

begin;

alter table public.tournaments
  alter column tournament_format drop not null,
  alter column tournament_format drop default;

create or replace function public.admin_create_tournament(
  p_name text,
  p_request_id uuid,
  p_max_players integer,
  p_tournament_format text,
  p_registration_deadline timestamptz
)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  uid uuid:=auth.uid();
  clean_name text:=left(trim(regexp_replace(coalesce(p_name,''),'\s+',' ','g')),80);
  limit_players integer:=coalesce(p_max_players,32);
  selected_format text:=nullif(trim(coalesce(p_tournament_format,'')),'');
  t public.tournaments%rowtype;
begin
  perform public.require_game_admin();
  if char_length(clean_name)<3 then raise exception 'Tournament name required'; end if;
  if p_request_id is null then raise exception 'Request id required'; end if;
  if limit_players not between 2 and 128 then raise exception 'Invalid tournament size'; end if;
  if selected_format is not null and selected_format not in('knockout','qualifiers_playoff') then
    raise exception 'Invalid tournament format';
  end if;
  if p_registration_deadline is null or p_registration_deadline<=now() then
    raise exception 'Invalid registration deadline';
  end if;

  select * into t from public.tournaments
  where created_by=uid and create_request_id=p_request_id;
  if found then return to_jsonb(t); end if;

  insert into public.tournaments(
    name,slug,status,created_by,tournament_format,max_players,registration_deadline,create_request_id,updated_at
  ) values(
    clean_name,'tournament-'||lower(substr(replace(gen_random_uuid()::text,'-',''),1,12)),
    'registration',uid,selected_format,limit_players,p_registration_deadline,p_request_id,now()
  ) returning * into t;
  return to_jsonb(t);
end;
$$;

create or replace function public.admin_set_tournament_format(
  p_tournament_id uuid,
  p_tournament_format text
)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  t public.tournaments%rowtype;
  selected_format text:=nullif(trim(coalesce(p_tournament_format,'')),'');
begin
  perform public.require_game_admin();
  if selected_format is null or selected_format not in('knockout','qualifiers_playoff') then
    raise exception 'Invalid tournament format';
  end if;

  select * into t from public.tournaments where id=p_tournament_id for update;
  if not found then raise exception 'Tournament not found'; end if;
  if t.status not in('draft','registration') then raise exception 'Tournament format locked'; end if;
  if t.status='registration' and (t.registration_deadline is null or t.registration_deadline<=now()) then
    raise exception 'Tournament format locked';
  end if;
  if t.qualifying_started_at is not null or exists(
    select 1 from public.tournament_matches where tournament_id=t.id
  ) then raise exception 'Tournament format locked'; end if;

  update public.tournaments
  set tournament_format=selected_format,
      qualifying_matches_per_player=case
        when tournament_format is distinct from selected_format then null
        else qualifying_matches_per_player
      end,
      playoff_size=case
        when tournament_format is distinct from selected_format then null
        else playoff_size
      end,
      updated_at=now()
  where id=t.id;

  return public.get_tournament_board(t.id);
end;
$$;

create or replace function public.enforce_tournament_format_before_start()
returns trigger
language plpgsql
set search_path=''
as $$
begin
  if new.status in('active','finished') and new.tournament_format is null then
    raise exception 'Tournament format required';
  end if;
  return new;
end;
$$;

drop trigger if exists tournaments_require_format_before_start on public.tournaments;
create trigger tournaments_require_format_before_start
before insert or update on public.tournaments
for each row execute function public.enforce_tournament_format_before_start();

revoke execute on function public.admin_create_tournament(text,uuid,integer,text,timestamptz) from public,anon;
revoke execute on function public.admin_set_tournament_format(uuid,text) from public,anon;
revoke execute on function public.enforce_tournament_format_before_start() from public,anon,authenticated;
grant execute on function public.admin_create_tournament(text,uuid,integer,text,timestamptz) to authenticated;
grant execute on function public.admin_set_tournament_format(uuid,text) to authenticated;

commit;
