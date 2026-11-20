-- SPAWN Finance: restart the cash book on a new date + write on behalf of staff
-- 2026-11-20

create table if not exists fin_cash_restarts(
  id bigserial primary key,
  restart_date date not null,
  counted numeric not null check (counted >= 0),
  prev_balance numeric not null,
  entry_id bigint references fin_cash_entries(id),
  memo text,
  created_by text,
  created_at timestamptz not null default now(),
  voided_at timestamptz
);
create unique index if not exists fin_cash_restarts_live_date on fin_cash_restarts(restart_date) where voided_at is null;
alter table fin_cash_restarts enable row level security;

-- the book's first day = the latest restart, else the first opening
create or replace function fin_opening_date() returns date
language sql stable security definer set search_path to 'public' as $$
  select coalesce((select max(restart_date) from fin_cash_restarts where voided_at is null),
                  (select min(entry_date) from fin_cash_entries where kind = 'opening' and voided_at is null));
$$;

-- owner restarts the book: one line makes the balance equal the drawer count on that date
create or replace function fin_cash_restart(p_pin text, p_client_id uuid, p_date date, p_count numeric, p_memo text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v record; d date; prev numeric; dif numeric; e fin_cash_entries; rid bigint; amt_txt text;
begin
  select * into v from fin_auth(p_pin);
  if v.o_err is not null then return jsonb_build_object('ok',false,'error',v.o_err); end if;
  if v.o_role <> 'owner' then raise exception 'owner_only'; end if;
  if p_client_id is null then raise exception 'client_id_required'; end if;
  select * into e from fin_cash_entries where client_id = p_client_id;
  if found then return jsonb_build_object('ok',true,'duplicate',true,'restart_date',e.entry_date,'balance',fin_cash_balance(e.entry_date)); end if;
  d := coalesce(p_date, fin_today());
  if d > fin_today() then raise exception 'future_date'; end if;
  if p_count is null or p_count < 0 then raise exception 'amount_must_be_positive'; end if;
  if not exists (select 1 from fin_cash_entries where kind = 'opening' and voided_at is null) then raise exception 'no_opening_yet'; end if;
  if exists (select 1 from fin_cash_entries where voided_at is null and entry_date >= d) then raise exception 'entries_on_or_after_date'; end if;
  if exists (select 1 from fin_cash_restarts where voided_at is null and restart_date >= d) then raise exception 'restart_exists'; end if;
  if exists (select 1 from fin_cash_days where entry_date = d and locked_at is not null) then raise exception 'day_locked'; end if;
  prev := fin_cash_balance(d);
  dif := p_count - prev;
  amt_txt := regexp_replace(to_char(p_count, 'FM999,999,990.00'), '\.00$', '');
  insert into fin_cash_restarts(restart_date, counted, prev_balance, memo, created_by)
  values (d, p_count, prev, nullif(trim(p_memo),''), v.o_name) returning id into rid;
  insert into fin_cash_entries(entry_date, kind, amount, category, memo, custodian, created_by, client_id)
  values (d, case when dif < 0 then 'adjust_out' else 'adjust_in' end, abs(dif), 'Book restart',
          'Book restarted — drawer counted ₱' || amt_txt || coalesce(' · ' || nullif(trim(p_memo),''), ''),
          v.o_name, v.o_name, p_client_id)
  returning * into e;
  update fin_cash_restarts set entry_id = e.id where id = rid;
  return jsonb_build_object('ok',true,'restart_date',d,'counted',p_count,'previous',prev,'difference',dif,'balance',fin_cash_balance(d));
end $$;

-- voiding the restart line undoes the restart
create or replace function fin_cash_restart_void_sync() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(new.category,'') = 'Book restart' then
    update fin_cash_restarts set voided_at = new.voided_at where entry_id = new.id;
  end if;
  return new;
end $$;
drop trigger if exists trg_fin_cash_restart_void on fin_cash_entries;
create trigger trg_fin_cash_restart_void after update of voided_at on fin_cash_entries
for each row execute function fin_cash_restart_void_sync();

-- counts/handovers: the owner can record them for a staff member (p_from)
drop function if exists fin_cash_count(text, uuid, text, numeric, numeric, numeric, numeric, text, text, date);
create or replace function fin_cash_count(p_pin text, p_client_id uuid, p_kind text, p_packs_5 numeric, p_packs_1 numeric, p_bills numeric, p_loose numeric,
                                          p_handed_to text default null, p_memo text default null, p_entry_date date default null, p_from text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v record; d date; r fin_cash_counts; v_to text; v_from text;
begin
  select * into v from fin_auth(p_pin);
  if v.o_err is not null then return jsonb_build_object('ok',false,'error',v.o_err); end if;
  if p_client_id is null then raise exception 'client_id_required'; end if;
  select * into r from fin_cash_counts where client_id = p_client_id;
  if found then
    return jsonb_build_object('ok',true,'duplicate',true,'id',r.id,'counted_total',r.counted_total,
                              'book_balance',r.book_balance,'difference',r.difference);
  end if;
  if p_kind not in ('count','handover') then raise exception 'kind_must_be_count_or_handover'; end if;
  if least(coalesce(p_packs_5,0),coalesce(p_packs_1,0),coalesce(p_bills,0),coalesce(p_loose,0)) < 0 then raise exception 'negative_amount'; end if;
  d := coalesce(p_entry_date, fin_today());
  if d > fin_today() then raise exception 'future_date'; end if;
  if exists (select 1 from fin_cash_days where entry_date = d and locked_at is not null) then raise exception 'day_locked'; end if;
  v_from := v.o_name;
  if nullif(trim(p_from),'') is not null and lower(trim(p_from)) <> lower(v.o_name) then
    if v.o_role <> 'owner' then raise exception 'owner_only'; end if;
    select a.name into v_from from office_accounts a where a.active and lower(a.name) = lower(trim(p_from)) order by a.id limit 1;
    if v_from is null then raise exception 'from_unknown'; end if;
  end if;
  if p_kind = 'handover' then
    select a.name into v_to from office_accounts a
     where a.active and lower(a.name) = lower(trim(p_handed_to)) order by a.id limit 1;
    if v_to is null then raise exception 'handed_to_unknown'; end if;
    if v_to = v_from then raise exception 'handover_to_self'; end if;
  end if;
  insert into fin_cash_counts(entry_date, kind, counted_by, handed_from, handed_to,
                              packs_5, packs_1, bills, loose, book_balance, memo, created_by, client_id)
  values (d, p_kind, v_from,
          case when p_kind = 'handover' then v_from end, v_to,
          coalesce(p_packs_5,0), coalesce(p_packs_1,0), coalesce(p_bills,0), coalesce(p_loose,0),
          fin_cash_balance(d), nullif(trim(p_memo),''), v.o_name, p_client_id)
  returning * into r;
  if coalesce(r.difference,0) <> 0 then
    insert into fin_cash_entries(entry_date, kind, amount, party, category, memo, custodian, created_by, client_id)
    values (d, case when r.difference < 0 then 'adjust_out' else 'adjust_in' end, abs(r.difference),
            coalesce(r.handed_from, r.counted_by), case when r.difference < 0 then 'Drawer short' else 'Drawer over' end,
            'Drawer count — ' || case when p_kind = 'handover' then 'handover to ' || coalesce(v_to,'?') else 'check' end || coalesce(' · ' || nullif(trim(p_memo),''),''),
            v_from, v.o_name, gen_random_uuid());
    update fin_shorts set count_id = r.id where source_entry_id = currval(pg_get_serial_sequence('fin_cash_entries','id'));
  end if;
  return jsonb_build_object('ok',true,'id',r.id,'counted_total',r.counted_total,
                            'book_balance',r.book_balance,'difference',r.difference);
end $$;
grant execute on function fin_cash_count(text, uuid, text, numeric, numeric, numeric, numeric, text, text, date, text) to anon, authenticated;
grant execute on function fin_cash_restart(text, uuid, date, numeric, text) to anon, authenticated;

-- Books: the restart line posts the difference between Books' office cash and the drawer count to suspense (to check)
do $do$
declare s text;
begin
  s := pg_get_functiondef('public.bk_sync_cashbook'::regproc);
  if position('Book restart' in s) = 0 then
    s := replace(s, $x$    elsif r.kind = 'adjust_in' then$x$,
$x$    elsif r.kind in ('adjust_in','adjust_out') and coalesce(r.category,'') = 'Book restart' then
      dif := coalesce((select counted from fin_cash_restarts where entry_id = r.id), 0) - bk_fund_bal('1010', r.entry_date, true);
      n := n + bk_put('cashbook', r.id||':R', r.entry_date, '1010', '1900', null, 'Book restart — difference between Books and the drawer count (check)', r.created_by, 'Office', greatest(dif,0), greatest(-dif,0), 'restart', r.voided_at, r.created_by);
    elsif r.kind = 'adjust_in' then$x$);
    if position('Book restart' in s) = 0 then raise exception 'bk_sync_cashbook patch failed'; end if;
    execute s;
  end if;
end $do$;
