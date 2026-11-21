-- OPTIONAL (not applied yet). Lets the Petty cash grid suggest from the whole
-- Vendo Monitor daily expense book (expenses table) and read expense_categories live.
-- Without it the grid uses a built-in list of common items + petty cash history.
create or replace function public.pc_suggest(p_pin text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v record;
begin
  select * into v from fin_auth(p_pin);
  if v.o_err is not null then return jsonb_build_object('ok',false,'error',v.o_err); end if;
  return jsonb_build_object('ok', true,
    'cats', (select coalesce(jsonb_agg(jsonb_build_object('name', name, 'color', color) order by sort_order), '[]'::jsonb)
               from expense_categories where active),
    'past', (select coalesce(jsonb_agg(jsonb_build_object('w', w, 'c', c, 'n', n, 'k', k) order by k desc), '[]'::jsonb) from (
       select w, c, n, count(*) k from (
         select trim(description) w, category c, nullif(trim(co),'') n from expenses
          where voided_at is null and nullif(trim(description),'') is not null and expense_date > current_date - 400
         union all
         select trim(e.what), e.category, p.name from pc_expenses e
           join pc_releases r on r.id = e.release_id left join pc_people p on p.id = r.person_id
          where e.voided_at is null
       ) s group by w, c, n order by count(*) desc limit 600) t));
end $$;
revoke all on function public.pc_suggest(text) from public;
grant execute on function public.pc_suggest(text) to anon, authenticated;
