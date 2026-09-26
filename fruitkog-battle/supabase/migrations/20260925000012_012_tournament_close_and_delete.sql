-- обновление 13: закрытие и полное удаление турниров.
-- выполните после 011_tournament_admin_fixes.sql.

create or replace function public.admin_close_tournament(p_tournament_id uuid)
returns jsonb
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
  if t.status='cancelled' then return public.get_tournament_board(t.id); end if;
  if t.status='finished' then raise exception 'Tournament already finished'; end if;

  update public.tournament_matches
  set status='cancelled',result_reason='cancelled',resolved_at=coalesce(resolved_at,now())
  where tournament_id=t.id
    and status not in('finished','technical','cancelled');

  update public.tournaments
  set status='cancelled',finished_at=coalesce(finished_at,now()),updated_at=now()
  where id=t.id;

  return public.get_tournament_board(t.id);
end;
$$;

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

  -- Удаляются турнир, заявки, состав и сетка. Связанные записи games
  -- остаются в общей истории вместе с уже примененными изменениями рейтинга.
  delete from public.tournaments where id=t.id;
  return t.id;
end;
$$;

revoke execute on function public.admin_close_tournament(uuid) from public,anon;
revoke execute on function public.admin_delete_tournament(uuid) from public,anon;
grant execute on function public.admin_close_tournament(uuid) to authenticated;
grant execute on function public.admin_delete_tournament(uuid) to authenticated;
