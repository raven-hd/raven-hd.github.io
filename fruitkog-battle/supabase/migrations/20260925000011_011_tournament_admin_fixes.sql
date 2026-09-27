-- обновление 12: удаление тестовых турниров.
-- выполните после 010_tournament_foundation.sql.

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
  if t.status not in('draft','registration') then
    raise exception 'Tournament can no longer be deleted';
  end if;

  delete from public.tournaments where id=t.id;
  return t.id;
end;
$$;

revoke execute on function public.admin_delete_tournament(uuid) from public,anon;
grant execute on function public.admin_delete_tournament(uuid) to authenticated;
