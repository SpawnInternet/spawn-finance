-- SPAWN Finance · Petty cash (imprest ₱50,000, alert at ₱15,000)
-- Release cash to personnel → they upload receipts → office confirms receipts + change (QR / code) → owner tops up.
-- 2026-11-21

create table if not exists pc_config(
  id int primary key default 1 check (id = 1),
  fund numeric not null default 50000,
  alert_at numeric not null default 15000,
  warn_release numeric not null default 5000,
  start_date date not null default date '2026-11-23',
  updated_at timestamptz default now(),
  updated_by text
);
insert into pc_config(id) values (1) on conflict do nothing;

create table if not exists pc_people(
  id bigserial primary key,
  name text not null,
  kind text not null default 'other',
  code text not null unique,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index if not exists pc_people_name on pc_people(lower(name));

create sequence if not exists pc_pcv_seq;
create table if not exists pc_replenish(
  id bigserial primary key,
  amount numeric not null check (amount > 0),
  source text not null default 'Office drawer',
  note text,
  approved_by text not null,
  approved_at timestamptz not null default now(),
  n_releases int not null default 0,
  client_id uuid unique
);
create table if not exists pc_releases(
  id bigserial primary key,
  pcv int not null unique default nextval('pc_pcv_seq'),
  release_date date not null default fin_today(),
  person_id bigint not null references pc_people(id),
  amount numeric not null check (amount > 0),
  purpose text,
  direct boolean not null default false,
  released_by text not null,
  created_at timestamptz not null default now(),
  client_id uuid unique,
  change_returned numeric not null default 0,
  receipts_ok boolean,
  close_note text,
  closed_at timestamptz,
  closed_by text,
  replenish_id bigint references pc_replenish(id),
  voided_at timestamptz,
  voided_by text,
  void_reason text
);
create index if not exists pc_releases_cycle on pc_releases(replenish_id) where voided_at is null;
create table if not exists pc_expenses(
  id bigserial primary key,
  release_id bigint not null references pc_releases(id),
  exp_date date not null default fin_today(),
  amount numeric not null check (amount > 0),
  what text not null,
  category text,
  receipt_path text,
  no_receipt_reason text,
  entered_by text not null,
  by_self boolean not null default false,
  created_at timestamptz not null default now(),
  client_id uuid unique,
  voided_at timestamptz,
  voided_by text
);
create index if not exists pc_expenses_rel on pc_expenses(release_id) where voided_at is null;
alter table pc_config enable row level security;
alter table pc_people enable row level security;
alter table pc_replenish enable row level security;
alter table pc_releases enable row level security;
alter table pc_expenses enable row level security;

-- receipt photos (same pattern as harvest-photos: anyone with the app can upload, file names are random)
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('pc-receipts','pc-receipts', true, 3145728, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
do $p$ begin
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='pc_receipts_insert') then
    create policy pc_receipts_insert on storage.objects for insert to anon, authenticated with check (bucket_id = 'pc-receipts');
  end if;
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='pc_receipts_select') then
    create policy pc_receipts_select on storage.objects for select to anon, authenticated using (bucket_id = 'pc-receipts');
  end if;
end $p$;

-- ---------- helpers ----------
create or replace function pc_new_code() returns text language plpgsql as $$
declare a text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; c text; i int;
begin
  loop
    c := '';
    for i in 1..6 loop c := c || substr(a, 1 + floor(random() * length(a))::int, 1); end loop;
    exit when not exists (select 1 from pc_people where code = c);
  end loop;
  return c;
end $$;

-- everyone who can hold petty cash: staff (linemen, office), collectors, office accounts
create or replace function pc_roster_names() returns table(name text, kind text)
language sql stable security definer set search_path to 'public' as $$
  select distinct on (lower(n)) n, k from (
    select coalesce(display_name, name) n, 'staff' k, 1 o from staff where active and role <> 'wendell'
    union all select name, 'collector', 2 from collectors where active
    union all select name, 'office', 3 from office_accounts where active
    union all select name, kind, 4 from pc_people where active
  ) x order by lower(n), o;
$$;

create or replace function pc_person(p_name text) returns pc_people
language plpgsql security definer set search_path to 'public' as $$
declare r pc_people; k text;
begin
  if nullif(trim(p_name),'') is null then raise exception 'person_required'; end if;
  select * into r from pc_people where lower(name) = lower(trim(p_name));
  if found then return r; end if;
  select x.kind into k from pc_roster_names() x where lower(x.name) = lower(trim(p_name)) limit 1;
  insert into pc_people(name, kind, code) values (trim(p_name), coalesce(k,'other'), pc_new_code()) returning * into r;
  return r;
end $$;

-- personnel login: name + their existing PIN (staff, collector or office account)
create or replace function pc_person_auth(p_name text, p_pin text, out o_person pc_people, out o_err text)
language plpgsql security definer set search_path to 'public' as $$
declare v_ip text; v_n int; ok boolean := false;
begin
  begin v_ip := nullif(current_setting('request.headers', true), '')::json->>'x-forwarded-for'; exception when others then v_ip := null; end;
  v_ip := coalesce(nullif(trim(split_part(v_ip, ',', 1)), ''), 'unknown');
  select count(*) into v_n from fin_auth_fail f where f.ip = v_ip and f.at > now() - interval '10 minutes';
  if v_n >= 8 then o_err := 'too_many_attempts'; return; end if;
  select true into ok from staff s where s.active and lower(coalesce(s.display_name, s.name)) = lower(trim(p_name)) and spawn_pin_ok(s.pin_hash, p_pin) limit 1;
  if not coalesce(ok,false) then select true into ok from collectors c where c.active and lower(c.name) = lower(trim(p_name)) and spawn_pin_ok(c.pin_hash, p_pin) limit 1; end if;
  if not coalesce(ok,false) then select true into ok from office_accounts a where a.active and lower(a.name) = lower(trim(p_name)) and spawn_pin_ok(a.pin_hash, p_pin) limit 1; end if;
  if not coalesce(ok,false) then
    insert into fin_auth_fail(ip) values (v_ip);
    o_err := 'bad_pin'; return;
  end if;
  o_person := pc_person(p_name);
end $$;

create or replace view pc_v_releases as
select r.*, p.name as person, p.kind as person_kind, p.code as person_code,
       'PCV-' || lpad(r.pcv::text, 4, '0') as pcv_no,
       coalesce(e.spent,0) as spent, coalesce(e.n,0) as n_exp, coalesce(e.n_nor,0) as n_no_receipt,
       r.amount - coalesce(e.spent,0) - r.change_returned as unaccounted,
       case when r.voided_at is not null then 'void'
            when r.closed_at is not null then 'closed'
            when coalesce(e.n,0) = 0 and r.release_date < fin_today() then 'flagged'
            when coalesce(e.n,0) = 0 then 'open'
            when coalesce(e.n_nor,0) > 0 or r.amount - coalesce(e.spent,0) <> 0 then 'flagged'
            else 'uploaded' end as status,
       concat_ws(' · ',
         case when r.voided_at is null and r.closed_at is null and coalesce(e.n,0) = 0 and r.release_date < fin_today() then 'No expenses uploaded yet' end,
         case when r.voided_at is null and r.closed_at is null and coalesce(e.n,0) > 0 and r.amount - coalesce(e.spent,0) > 0 then 'Change ₱' || trim(to_char(r.amount - coalesce(e.spent,0), 'FM999,999,990.##')) || ' to return' end,
         case when r.voided_at is null and r.closed_at is null and r.amount - coalesce(e.spent,0) < 0 then 'Spent ₱' || trim(to_char(coalesce(e.spent,0) - r.amount, 'FM999,999,990.##')) || ' more than released' end,
         case when r.voided_at is null and r.closed_at is null and coalesce(e.n_nor,0) > 0 then e.n_nor || ' without receipt photo' end
       ) as flag_reason
  from pc_releases r
  join pc_people p on p.id = r.person_id
  left join (select release_id, sum(amount) spent, count(*) n,
                    count(*) filter (where receipt_path is null) n_nor
               from pc_expenses where voided_at is null group by release_id) e on e.release_id = r.id;

create or replace function pc_box() returns jsonb
language sql stable security definer set search_path to 'public' as $$
  with c as (select * from pc_config where id = 1),
       cyc as (select * from pc_v_releases where voided_at is null and replenish_id is null)
  select jsonb_build_object(
    'fund', c.fund, 'alert_at', c.alert_at, 'warn_release', c.warn_release, 'start_date', c.start_date,
    'confirmed', coalesce((select sum(amount - change_returned) from cyc where closed_at is not null),0),
    'pending', coalesce((select sum(amount - change_returned) from cyc where closed_at is null),0),
    'cash', c.fund - coalesce((select sum(amount - change_returned) from cyc),0),
    'n_pending', (select count(*) from cyc where closed_at is null),
    'n_flagged', (select count(*) from cyc where status = 'flagged'),
    'n_confirmed', (select count(*) from cyc where closed_at is not null),
    'alert', (c.fund - coalesce((select sum(amount - change_returned) from cyc),0)) <= c.alert_at)
  from c;
$$;

create or replace function pc_releases_json(p_person_id bigint default null, p_days int default 45) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select coalesce(jsonb_agg(to_jsonb(r) - 'client_id' || jsonb_build_object('expenses', coalesce((
            select jsonb_agg(jsonb_build_object('id', e.id, 'date', e.exp_date, 'amount', e.amount, 'what', e.what, 'category', e.category,
                                                'receipt_path', e.receipt_path, 'no_receipt_reason', e.no_receipt_reason,
                                                'entered_by', e.entered_by, 'by_self', e.by_self, 'at', e.created_at) order by e.id)
              from pc_expenses e where e.release_id = r.id and e.voided_at is null), '[]'::jsonb))
          order by (r.closed_at is not null), r.release_date desc, r.pcv desc), '[]'::jsonb)
    from pc_v_releases r
   where (p_person_id is null or r.person_id = p_person_id)
     and ((r.voided_at is null and (r.replenish_id is null or r.release_date >= fin_today() - p_days))
          or (r.voided_at is not null and r.voided_at > now() - interval '3 days'));
$$;

-- add one expense line (shared by office and personnel)
create or replace function pc__exp_add(p_release_id bigint, p_by text, p_self boolean, p_client_id uuid, p_amount numeric, p_what text,
                                       p_category text, p_receipt_path text, p_no_receipt text, p_date date)
returns pc_expenses language plpgsql security definer set search_path to 'public' as $$
declare r pc_releases; e pc_expenses;
begin
  if p_client_id is null then raise exception 'client_id_required'; end if;
  select * into e from pc_expenses where client_id = p_client_id;
  if found then return e; end if;
  select * into r from pc_releases where id = p_release_id for update;
  if not found or r.voided_at is not null then raise exception 'release_not_found'; end if;
  if r.closed_at is not null then raise exception 'release_closed'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'amount_must_be_positive'; end if;
  if nullif(trim(p_what),'') is null then raise exception 'what_required'; end if;
  if nullif(trim(p_receipt_path),'') is null and nullif(trim(p_no_receipt),'') is null then raise exception 'receipt_or_reason_required'; end if;
  insert into pc_expenses(release_id, exp_date, amount, what, category, receipt_path, no_receipt_reason, entered_by, by_self, client_id)
  values (r.id, least(coalesce(p_date, fin_today()), fin_today()), p_amount, trim(p_what), nullif(trim(p_category),''),
          nullif(trim(p_receipt_path),''), nullif(trim(p_no_receipt),''), p_by, p_self, p_client_id)
  returning * into e;
  return e;
end $$;

-- ---------- office (SPAWN Finance PIN) ----------
create or replace function pc_boot(p_pin text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v record;
begin
  select * into v from fin_auth(p_pin);
  if v.o_err is not null then return jsonb_build_object('ok',false,'error',v.o_err); end if;
  return jsonb_build_object('ok', true, 'me', v.o_name, 'is_owner', v.o_role = 'owner', 'today', fin_today(),
    'box', pc_box(),
    'people', (select coalesce(jsonb_agg(jsonb_build_object('name', name, 'kind', kind) order by kind, name), '[]'::jsonb) from pc_roster_names()),
    'releases', pc_releases_json(null, 45),
    'replenish', (select coalesce(jsonb_agg(to_jsonb(x) - 'client_id' order by x.approved_at desc), '[]'::jsonb)
                    from (select * from pc_replenish order by approved_at desc limit 20) x));
end $$;

create or replace function pc_release_add(p_pin text, p_client_id uuid, p_person text, p_amount numeric, p_purpose text default null, p_date date default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v record; p pc_people; r pc_releases; cash numeric;
begin
  select * into v from fin_auth(p_pin);
  if v.o_err is not null then return jsonb_build_object('ok',false,'error',v.o_err); end if;
  if p_client_id is null then raise exception 'client_id_required'; end if;
  select * into r from pc_releases where client_id = p_client_id;
  if found then return jsonb_build_object('ok',true,'duplicate',true,'id',r.id,'pcv',r.pcv,'box',pc_box()); end if;
  if p_amount is null or p_amount <= 0 then raise exception 'amount_must_be_positive'; end if;
  if coalesce(p_date, fin_today()) > fin_today() then raise exception 'future_date'; end if;
  cash := (pc_box()->>'cash')::numeric;
  if p_amount > cash then raise exception 'not_enough_cash'; end if;
  p := pc_person(p_person);
  insert into pc_releases(release_date, person_id, amount, purpose, released_by, client_id)
  values (coalesce(p_date, fin_today()), p.id, p_amount, nullif(trim(p_purpose),''), v.o_name, p_client_id) returning * into r;
  return jsonb_build_object('ok',true,'id',r.id,'pcv',r.pcv,'person',p.name,'box',pc_box());
end $$;

-- office pays something itself straight from the box: release + expense + closed in one step
create or replace function pc_direct_add(p_pin text, p_client_id uuid, p_amount numeric, p_what text, p_category text default null,
                                         p_receipt_path text default null, p_no_receipt text default null, p_person text default null, p_date date default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v record; p pc_people; r pc_releases; e pc_expenses; cash numeric;
begin
  select * into v from fin_auth(p_pin);
  if v.o_err is not null then return jsonb_build_object('ok',false,'error',v.o_err); end if;
  if p_client_id is null then raise exception 'client_id_required'; end if;
  select * into r from pc_releases where client_id = p_client_id;
  if found then return jsonb_build_object('ok',true,'duplicate',true,'id',r.id,'pcv',r.pcv,'box',pc_box()); end if;
  if p_amount is null or p_amount <= 0 then raise exception 'amount_must_be_positive'; end if;
  if coalesce(p_date, fin_today()) > fin_today() then raise exception 'future_date'; end if;
  cash := (pc_box()->>'cash')::numeric;
  if p_amount > cash then raise exception 'not_enough_cash'; end if;
  p := pc_person(coalesce(nullif(trim(p_person),''), v.o_name));
  insert into pc_releases(release_date, person_id, amount, purpose, direct, released_by, client_id)
  values (coalesce(p_date, fin_today()), p.id, p_amount, nullif(trim(p_what),''), true, v.o_name, p_client_id) returning * into r;
  e := pc__exp_add(r.id, v.o_name, false, gen_random_uuid(), p_amount, p_what, p_category, p_receipt_path, p_no_receipt, coalesce(p_date, fin_today()));
  update pc_releases set closed_at = now(), closed_by = v.o_name, receipts_ok = (e.receipt_path is not null), change_returned = 0
   where id = r.id;
  return jsonb_build_object('ok',true,'id',r.id,'pcv',r.pcv,'box',pc_box());
end $$;

create or replace function pc_exp_add_office(p_pin text, p_client_id uuid, p_release_id bigint, p_amount numeric, p_what text,
                                             p_category text default null, p_receipt_path text default null, p_no_receipt text default null, p_date date default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v record; e pc_expenses;
begin
  select * into v from fin_auth(p_pin);
  if v.o_err is not null then return jsonb_build_object('ok',false,'error',v.o_err); end if;
  e := pc__exp_add(p_release_id, v.o_name, false, p_client_id, p_amount, p_what, p_category, p_receipt_path, p_no_receipt, p_date);
  return jsonb_build_object('ok',true,'id',e.id,'box',pc_box());
end $$;

create or replace function pc_exp_void_office(p_pin text, p_id bigint) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v record; e pc_expenses;
begin
  select * into v from fin_auth(p_pin);
  if v.o_err is not null then return jsonb_build_object('ok',false,'error',v.o_err); end if;
  select * into e from pc_expenses where id = p_id and voided_at is null;
  if not found then raise exception 'not_found'; end if;
  if exists (select 1 from pc_releases where id = e.release_id and closed_at is not null) then raise exception 'release_closed'; end if;
  update pc_expenses set voided_at = now(), voided_by = v.o_name where id = p_id;
  return jsonb_build_object('ok',true,'box',pc_box());
end $$;

-- office scans the person's QR (or types the 6-letter code): their open releases
create or replace function pc_by_code(p_pin text, p_code text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v record; p pc_people; c text;
begin
  select * into v from fin_auth(p_pin);
  if v.o_err is not null then return jsonb_build_object('ok',false,'error',v.o_err); end if;
  c := upper(regexp_replace(coalesce(p_code,''), '^.*:', ''));
  c := regexp_replace(c, '[^A-Z0-9]', '', 'g');
  select * into p from pc_people where code = c;
  if not found then raise exception 'code_not_found'; end if;
  return jsonb_build_object('ok',true,'person',p.name,'code',p.code,
    'releases', (select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_array_elements(pc_releases_json(p.id, 14)) x
                  where x->>'status' not in ('closed','void')));
end $$;

-- office confirms: physical receipts received + change returned (negative = office paid the person the extra)
create or replace function pc_close(p_pin text, p_release_id bigint, p_change_returned numeric, p_receipts_ok boolean, p_note text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v record; r pc_v_releases; short numeric;
begin
  select * into v from fin_auth(p_pin);
  if v.o_err is not null then return jsonb_build_object('ok',false,'error',v.o_err); end if;
  select * into r from pc_v_releases where id = p_release_id;
  if not found or r.voided_at is not null then raise exception 'release_not_found'; end if;
  if r.closed_at is not null then raise exception 'release_closed'; end if;
  short := r.amount - r.spent - coalesce(p_change_returned, 0);
  if short <> 0 and nullif(trim(p_note),'') is null then raise exception 'note_required_for_difference'; end if;
  update pc_releases set change_returned = coalesce(p_change_returned,0), receipts_ok = coalesce(p_receipts_ok,false),
         close_note = nullif(trim(p_note),''), closed_at = now(), closed_by = v.o_name
   where id = p_release_id;
  return jsonb_build_object('ok',true,'short',short,'box',pc_box());
end $$;

create or replace function pc_reopen(p_pin text, p_release_id bigint) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v record; r pc_releases;
begin
  select * into v from fin_auth(p_pin);
  if v.o_err is not null then return jsonb_build_object('ok',false,'error',v.o_err); end if;
  select * into r from pc_releases where id = p_release_id;
  if not found or r.closed_at is null then raise exception 'not_found'; end if;
  if r.replenish_id is not null then raise exception 'already_replenished'; end if;
  update pc_releases set closed_at = null, closed_by = null, receipts_ok = null, close_note = null, change_returned = 0 where id = p_release_id;
  return jsonb_build_object('ok',true,'box',pc_box());
end $$;

create or replace function pc_release_void(p_pin text, p_release_id bigint, p_reason text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v record; r pc_releases;
begin
  select * into v from fin_auth(p_pin);
  if v.o_err is not null then return jsonb_build_object('ok',false,'error',v.o_err); end if;
  select * into r from pc_releases where id = p_release_id;
  if not found or r.voided_at is not null then raise exception 'not_found'; end if;
  if r.replenish_id is not null then raise exception 'already_replenished'; end if;
  if nullif(trim(p_reason),'') is null then raise exception 'reason_required'; end if;
  if v.o_role <> 'owner' and (r.closed_at is not null or exists (select 1 from pc_expenses where release_id = r.id and voided_at is null)) then
    raise exception 'owner_only';
  end if;
  update pc_releases set voided_at = now(), voided_by = v.o_name, void_reason = trim(p_reason) where id = p_release_id;
  update pc_expenses set voided_at = now(), voided_by = v.o_name where release_id = p_release_id and voided_at is null;
  return jsonb_build_object('ok',true,'box',pc_box());
end $$;

-- owner tops the box back up by the confirmed receipts
create or replace function pc_replenish_add(p_pin text, p_client_id uuid, p_source text default 'Office drawer', p_note text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v record; amt numeric; n int; rid bigint;
begin
  select * into v from fin_auth(p_pin);
  if v.o_err is not null then return jsonb_build_object('ok',false,'error',v.o_err); end if;
  if v.o_role <> 'owner' then raise exception 'owner_only'; end if;
  if p_client_id is null then raise exception 'client_id_required'; end if;
  if exists (select 1 from pc_replenish where client_id = p_client_id) then return jsonb_build_object('ok',true,'duplicate',true,'box',pc_box()); end if;
  select coalesce(sum(amount - change_returned),0), count(*) into amt, n
    from pc_releases where voided_at is null and replenish_id is null and closed_at is not null;
  if amt <= 0 then raise exception 'nothing_to_replenish'; end if;
  insert into pc_replenish(amount, source, note, approved_by, n_releases, client_id)
  values (amt, coalesce(nullif(trim(p_source),''),'Office drawer'), nullif(trim(p_note),''), v.o_name, n, p_client_id) returning id into rid;
  update pc_releases set replenish_id = rid where voided_at is null and replenish_id is null and closed_at is not null;
  return jsonb_build_object('ok',true,'id',rid,'amount',amt,'n',n,'box',pc_box());
end $$;

create or replace function pc_config_set(p_pin text, p_fund numeric, p_alert numeric, p_warn numeric, p_start date) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v record;
begin
  select * into v from fin_auth(p_pin);
  if v.o_err is not null then return jsonb_build_object('ok',false,'error',v.o_err); end if;
  if v.o_role <> 'owner' then raise exception 'owner_only'; end if;
  if coalesce(p_fund,0) <= 0 or coalesce(p_alert,-1) < 0 or p_alert >= p_fund then raise exception 'bad_settings'; end if;
  update pc_config set fund = p_fund, alert_at = p_alert, warn_release = coalesce(p_warn, warn_release),
         start_date = coalesce(p_start, start_date), updated_at = now(), updated_by = v.o_name where id = 1;
  return jsonb_build_object('ok',true,'box',pc_box());
end $$;

-- ---------- personnel (their own PIN) ----------
create or replace function pc_roster() returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select coalesce(jsonb_agg(name order by name), '[]'::jsonb) from pc_roster_names();
$$;

create or replace function pc_me(p_name text, p_pin text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare a record;
begin
  select * into a from pc_person_auth(p_name, p_pin);
  if a.o_err is not null then return jsonb_build_object('ok',false,'error',a.o_err); end if;
  return jsonb_build_object('ok',true,'name',(a.o_person).name,'code',(a.o_person).code,'today',fin_today(),
                            'releases', pc_releases_json((a.o_person).id, 14));
end $$;

create or replace function pc_my_exp_add(p_name text, p_pin text, p_client_id uuid, p_release_id bigint, p_amount numeric, p_what text,
                                         p_category text default null, p_receipt_path text default null, p_no_receipt text default null, p_date date default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a record; e pc_expenses;
begin
  select * into a from pc_person_auth(p_name, p_pin);
  if a.o_err is not null then return jsonb_build_object('ok',false,'error',a.o_err); end if;
  if not exists (select 1 from pc_releases where id = p_release_id and person_id = (a.o_person).id) then raise exception 'release_not_found'; end if;
  e := pc__exp_add(p_release_id, (a.o_person).name, true, p_client_id, p_amount, p_what, p_category, p_receipt_path, p_no_receipt, p_date);
  return jsonb_build_object('ok',true,'id',e.id);
end $$;

create or replace function pc_my_exp_void(p_name text, p_pin text, p_id bigint) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare a record; e pc_expenses;
begin
  select * into a from pc_person_auth(p_name, p_pin);
  if a.o_err is not null then return jsonb_build_object('ok',false,'error',a.o_err); end if;
  select e2.* into e from pc_expenses e2 join pc_releases r on r.id = e2.release_id
   where e2.id = p_id and e2.voided_at is null and r.person_id = (a.o_person).id and r.closed_at is null;
  if not found then raise exception 'not_found'; end if;
  update pc_expenses set voided_at = now(), voided_by = (a.o_person).name where id = p_id;
  return jsonb_build_object('ok',true);
end $$;

grant execute on function pc_boot(text), pc_release_add(text,uuid,text,numeric,text,date), pc_direct_add(text,uuid,numeric,text,text,text,text,text,date),
  pc_exp_add_office(text,uuid,bigint,numeric,text,text,text,text,date), pc_exp_void_office(text,bigint), pc_by_code(text,text),
  pc_close(text,bigint,numeric,boolean,text), pc_reopen(text,bigint), pc_release_void(text,bigint,text), pc_replenish_add(text,uuid,text,text),
  pc_config_set(text,numeric,numeric,numeric,date), pc_roster(), pc_me(text,text),
  pc_my_exp_add(text,text,uuid,bigint,numeric,text,text,text,text,date), pc_my_exp_void(text,text,bigint) to anon, authenticated;
revoke execute on function pc__exp_add(bigint,text,boolean,uuid,numeric,text,text,text,text,date), pc_person(text), pc_person_auth(text,text),
  pc_new_code(), pc_roster_names(), pc_box(), pc_releases_json(bigint,int) from anon, authenticated, public;
