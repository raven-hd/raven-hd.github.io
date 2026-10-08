-- Новые функции наград доступны только вошедшим игрокам.
-- Без этого PostgreSQL оставляет право EXECUTE для PUBLIC по умолчанию.
-- Ветка fruitkog-rewards; не применять к живой базе до завершения турнира.

begin;

revoke execute on function public.get_my_fruitkog_rewards()
from public,anon;
grant execute on function public.get_my_fruitkog_rewards()
to authenticated;

revoke execute on function public.set_fruitkog_ship_skin(text)
from public,anon;
grant execute on function public.set_fruitkog_ship_skin(text)
to authenticated;

commit;
