-- SPAWN Finance · Books (accounting layer)  — 2026-11-20
-- New objects only (prefix bk_). Nothing existing is altered.
-- Rollback: drop the bk_* tables/functions and the 'books-sync' cron job.

create table if not exists bk_settings(key text primary key, value text, updated_at timestamptz default now(), updated_by text);
insert into bk_settings(key,value) values ('books_start','2026-12-01') on conflict do nothing;

create table if not exists bk_funds(
  code text primary key, name text not null, type text not null check (type in ('cash','bank','ewallet','card')),
  bank text, last4 text, opening numeric(14,2) not null default 0, opening_date date, active boolean not null default true,
  sort int not null default 100, note text, created_at timestamptz default now());
create table if not exists bk_accounts(
  code text primary key, name text not null, type text not null check (type in ('asset','liability','equity','income','expense')),
  active boolean not null default true, sort int not null default 100, created_at timestamptz default now());

create table if not exists bk_lines(
  id bigserial primary key, entry_date date not null, fund text not null references bk_funds(code) on update cascade,
  acct text, ref text, descr text, party text, area text,
  amt_in numeric(14,2) not null default 0, amt_out numeric(14,2) not null default 0,
  source text not null default 'manual', source_id text, grp text, kind text, auto boolean not null default false,
  note text, created_by text, created_at timestamptz default now(), updated_at timestamptz, updated_by text,
  voided_at timestamptz, voided_by text, void_reason text, client_id uuid,
  user_touched boolean not null default false);
create unique index if not exists bk_lines_src on bk_lines(source, source_id) where source <> 'manual';
create unique index if not exists bk_lines_client on bk_lines(client_id) where client_id is not null;
create index if not exists bk_lines_date on bk_lines(entry_date, fund);
create index if not exists bk_lines_acct on bk_lines(acct);

create table if not exists bk_stmt(
  id bigserial primary key, fund text not null references bk_funds(code) on update cascade, stmt_date date, descr text, ref text,
  amt_in numeric(14,2) not null default 0, amt_out numeric(14,2) not null default 0,
  match_line bigint references bk_lines(id), source text not null default 'manual', source_id text,
  created_by text, created_at timestamptz default now(), voided_at timestamptz, voided_by text, client_id uuid);
create unique index if not exists bk_stmt_src on bk_stmt(source, source_id) where source <> 'manual';
create unique index if not exists bk_stmt_client on bk_stmt(client_id) where client_id is not null;
create index if not exists bk_stmt_fund on bk_stmt(fund, stmt_date);

create table if not exists bk_recon(
  fund text not null references bk_funds(code) on update cascade, month date not null, opening numeric(14,2), ending numeric(14,2),
  done_at timestamptz, done_by text, updated_at timestamptz default now(), primary key(fund, month));
create table if not exists bk_counts(
  fund text not null references bk_funds(code) on update cascade, count_date date not null, actual numeric(14,2) not null, detail jsonb,
  counted_by text, at timestamptz default now(), primary key(fund, count_date));
create table if not exists bk_sync_log(id bigserial primary key, at timestamptz default now(), ms int, lines int, stmt int, note text);

alter table bk_settings enable row level security;  alter table bk_funds enable row level security;
alter table bk_accounts enable row level security;  alter table bk_lines enable row level security;
alter table bk_stmt enable row level security;      alter table bk_recon enable row level security;
alter table bk_counts enable row level security;    alter table bk_sync_log enable row level security;

-- seed funds (owner can edit / add in Accounts)
insert into bk_funds(code,name,type,bank,sort,opening_date) values
 ('1010','Office cash','cash',null,10,null),
 ('1020','Sir Wendell fund','cash',null,20,'2026-12-01'),
 ('1031','PBB','bank','PBB',30,'2026-12-01'),
 ('1040','GCash wallet','ewallet','GCash',40,'2026-12-01'),
 ('2011','RCBC card','card','RCBC',51,'2026-12-01'),
 ('2012','Eastwest card','card','Eastwest',52,'2026-12-01'),
 ('2013','Metrobank card','card','Metrobank',53,'2026-12-01'),
 ('2014','Security Bank card','card','Security Bank',54,'2026-12-01'),
 ('2015','PNB card','card','PNB',55,'2026-12-01'),
 ('2016','BPI card','card','BPI',56,'2026-12-01')
on conflict do nothing;

insert into bk_accounts(code,name,type,sort) values
 ('1200','Staff loans & advances','asset',120),('1300','Collector shortages (utang)','asset',130),
 ('1500','Network equipment','asset',150),('1900','Suspense – unidentified','asset',190),
 ('3010','Owner draws / personal','equity',310),('3020','Opening balances','equity',320),
 ('4010','Piso WiFi income','income',410),('4020','Subscriber income','income',420),
 ('4080','Interest income','income',480),('4090','Cash over / short','income',490),('4095','Other income','income',495),
 ('5010','Bandwidth & upstream','expense',510),('5015','Rent & pole rental','expense',515),
 ('5020','Salaries & benefits','expense',520),('5030','Network & vendo materials','expense',530),
 ('5040','Fuel & transport','expense',540),('5045','Collector field expenses','expense',545),
 ('5050','Repairs & maintenance','expense',550),('5060','Utilities','expense',560),('5070','Meals','expense',570),
 ('5080','Bugi (old coins) loss','expense',580),('5085','Bank charges & fees','expense',585),
 ('5087','Permits, taxes & government','expense',587),('5090','Other expenses','expense',590)
on conflict do nothing;

-- ---------- helpers ----------
create or replace function bk_user(p_pin text, out o_name text, out o_role text)
returns record language plpgsql security definer set search_path=public as $$
declare v record;
begin
  select * into v from fin_auth(p_pin);
  if v.o_err is not null then raise exception '%', v.o_err; end if;
  o_name := v.o_name; o_role := v.o_role;
end $$;

create or replace function bk_start() returns date language sql stable security definer set search_path=public as
$$ select coalesce(nullif((select value from bk_settings where key='books_start'),'')::date, date '2026-12-01') $$;

-- category guesser: card/bank names → fund transfer; category labels; keywords
create or replace function bk_guess(p_text text, p_default text default null)
returns text language plpgsql stable security definer set search_path=public as $$
declare t text := lower(coalesce(p_text,'')); f record;
begin
  if t = '' then return p_default; end if;
  -- card payment?  "rcbc credit card", "eastwest (card ending 4002)"
  for f in select code, lower(coalesce(bank,name)) b from bk_funds where type='card' and active loop
    if t like '%'||f.b||'%' and (t like '%card%' or t like '%credit%' or t like '%autodebit%') then return f.code; end if;
  end loop;
  -- bank transfer / deposit?
  for f in select code, lower(coalesce(bank,name)) b from bk_funds where type in ('bank','ewallet') and active loop
    if t like '%'||f.b||'%' and (t like '%deposit%' or t like '%transfer%' or t like '%fund%' or t like '%cash in%') then return f.code; end if;
  end loop;
  if t like '%sir wendell%' and (t like '%coh%' or t like '%fund%' or t like '%turn%') then return '1020'; end if;
  -- category labels used by the office
  if t ~ '(fuel|gasolin|gasolina|diesel|petrol|\mgas\M|fare|transpo|pamasahe|tricycle|jeep)' then return '5040'; end if;
  if t ~ '(salar|sweldo|wage|payroll|13th|\msss\M|philhealth|pag-?ibig|benefit|labor\M|allowance)' then return '5020'; end if;
  if t ~ '(meal|snack|merienda|lunch|dinner|breakfast|kaon|food|coffee|bugas|rice|water\s*(refill|gallon))' then return '5070'; end if;
  if t ~ '(fiber|fibre|router|onu|\mont\M|olt|gpon|splitter|nap box|clamp|connector|coin ?slot|nodemcu|esp8266|patch|cable|\mlan\M|pole\b|vendo|supplies|supply|module|sfp|mikrotik|tp-?link|antenna|adapter|charger|relay|wire|tape|screw|bracket|pvc|hose|queenslink|shopee|lazada|parcel|shipping|shipment)' then return '5030'; end if;
  if t ~ '(repair|maint|vulcaniz|change oil|tire|wheel|brake|mechanic|welding|paint)' then return '5050'; end if;
  if t ~ '(elec|zaneco|zamcelco|kuryente|water bill|globe bill|smart bill|\mbill\M|utilit|internet bill|load\M|prepaid)' then return '5060'; end if;
  if t ~ '(bandwidth|upstream|eastern tele|pldt|converge|\misp\M|transit|dedicated|\mdito\M|starlink)' then return '5010'; end if;
  if t ~ '(rent|rental|pole rental|lease)' then return '5015'; end if;
  if t ~ '(permit|bir\M|\mdst\M|tax|license|licence|lgu|barangay|clearance|registration|ntc|penalty|notar)' then return '5087'; end if;
  if t ~ '(bank charge|service charge|svc chg|\mfee\M|remittance|cash out|charge bayad|interbank|instapay|pesonet)' then return '5085'; end if;
  if t ~ '(interest earned|interest income)' then return '4080'; end if;
  if t ~ '(advance|\mvale\M|utang|loan)' then return '1200'; end if;
  if t ~ '(bugi|old coin|daot)' then return '5080'; end if;
  if t ~ '(\mhome\M|personal|owner|withdraw|\mdraw\M|grocery|tuition|family)' then return '3010'; end if;
  if t ~ '(harvest|hand-?in|piso|vendo income|coins?\M)' then return '4010'; end if;
  if t ~ '(subscri|monthly|install|fiber plan|pppoe)' then return '4020'; end if;
  if t ~ '(short|over\M|adjust)' then return '4090'; end if;
  return p_default;
end $$;

-- ---------- sync from the office books ----------
create or replace function bk_sync_run() returns jsonb language plpgsql security definer set search_path=public as $$
declare t0 timestamptz := clock_timestamp(); s date := bk_start(); cut date := coalesce(fin_cash_cutover(), date '2026-10-31');
        n_lines int := 0; n_stmt int := 0; bank1 text; r record; v_acct text; v_in numeric; v_out numeric; exp_cash numeric; dif numeric;
begin
  select code into bank1 from bk_funds where type='bank' and active order by sort limit 1;

  -- A. office cash book
  for r in select e.*, d.bank as dep_bank, d.reference_no as dep_ref from fin_cash_entries e left join fin_deposits d on d.id=e.deposit_id
           where e.entry_date >= s and e.entry_date >= cut loop
    if r.kind = 'opening' then
      n_lines := n_lines + bk_put('cashbook', r.id||':o', r.entry_date, '1010', '3020', null, 'Opening balance (cash book)', null, null, r.amount, 0, 'opening', r.voided_at, r.created_by);
    elsif r.kind in ('collection','office_collection') then
      if r.harvest_total is not null then
        exp_cash := r.harvest_total - coalesce(r.less_expense,0) - coalesce(r.less_bugi,0);
        dif := r.amount - exp_cash;
        n_lines := n_lines + bk_put('cashbook', r.id||':a', r.entry_date, '1010', '4010', null, 'Harvest hand-in (75% share)', r.collector, r.area, r.harvest_total, 0, 'handin', r.voided_at, r.created_by);
        if coalesce(r.less_expense,0) > 0 then n_lines := n_lines + bk_put('cashbook', r.id||':x', r.entry_date, '1010', '5045', null, 'Collector expense (deducted from hand-in)', r.collector, r.area, 0, r.less_expense, 'handin', r.voided_at, r.created_by); end if;
        if coalesce(r.less_bugi,0) > 0 then n_lines := n_lines + bk_put('cashbook', r.id||':b', r.entry_date, '1010', '5080', null, 'Bugi (old coins) in hand-in', r.collector, r.area, 0, r.less_bugi, 'handin', r.voided_at, r.created_by); end if;
        if dif < -0.004 then n_lines := n_lines + bk_put('cashbook', r.id||':s', r.entry_date, '1010', '4090', null, 'Short on hand-in', r.collector, r.area, 0, -dif, 'handin', r.voided_at, r.created_by);
        elsif dif > 0.004 then n_lines := n_lines + bk_put('cashbook', r.id||':s', r.entry_date, '1010', '4090', null, 'Over on hand-in', r.collector, r.area, dif, 0, 'handin', r.voided_at, r.created_by); end if;
      else
        n_lines := n_lines + bk_put('cashbook', r.id||':a', r.entry_date, '1010', '4010', null, case when r.kind='office_collection' then 'Office collection' else 'Harvest hand-in (75% share)' end, r.collector, r.area, r.amount, 0, 'handin', r.voided_at, r.created_by);
      end if;
    elsif r.kind = 'expense' then
      v_acct := coalesce(bk_guess(coalesce(r.category,'')||' '||coalesce(r.memo,''), null), '5090');
      n_lines := n_lines + bk_put('cashbook', r.id||':e', r.entry_date, '1010', v_acct, null, coalesce(nullif(r.memo,''), r.category, 'Expense'), r.party, r.area, 0, r.amount, 'expense', r.voided_at, r.created_by);
    elsif r.kind = 'deposit' then
      select code into v_acct from bk_funds where type='bank' and active and r.dep_bank is not null and lower(coalesce(bank,name)) = lower(r.dep_bank) limit 1;
      n_lines := n_lines + bk_put('cashbook', r.id||':d', r.entry_date, '1010', coalesce(v_acct, bank1, '1900'), r.dep_ref, 'Deposit to '||coalesce(r.dep_bank,'bank'), r.party, 'Office', 0, r.amount, 'deposit', r.voided_at, r.created_by);
    elsif r.kind in ('advance','co') then
      n_lines := n_lines + bk_put('cashbook', r.id||':v', r.entry_date, '1010', '1200', null, case when r.kind='co' then 'Cash out to '||coalesce(r.party,'') else 'Cash advance' end, r.party, r.area, 0, r.amount, 'advance', r.voided_at, r.created_by);
    elsif r.kind = 'repay' then
      n_lines := n_lines + bk_put('cashbook', r.id||':r', r.entry_date, '1010', '1200', null, 'Advance repaid', r.party, r.area, r.amount, 0, 'repay', r.voided_at, r.created_by);
    elsif r.kind = 'bugi_found' then
      n_lines := n_lines + bk_put('cashbook', r.id||':g', r.entry_date, '1010', '5080', null, 'Bugi found while counting', r.collector, r.area, 0, r.amount, 'bugi', r.voided_at, r.created_by);
    elsif r.kind in ('adjust_in','other_in') then
      v_acct := coalesce(bk_guess(r.memo, null), case when r.kind='adjust_in' then '4090' else '4095' end);
      n_lines := n_lines + bk_put('cashbook', r.id||':i', r.entry_date, '1010', v_acct, null, coalesce(nullif(r.memo,''), case when r.kind='adjust_in' then 'Adjustment (in)' else 'Other money in' end), r.party, r.area, r.amount, 0, r.kind, r.voided_at, r.created_by);
    elsif r.kind in ('adjust_out','other_out') then
      v_acct := coalesce(bk_guess(r.memo, null), case when r.kind='adjust_out' then '4090' else '5090' end);
      n_lines := n_lines + bk_put('cashbook', r.id||':u', r.entry_date, '1010', v_acct, null, coalesce(nullif(r.memo,''), case when r.kind='adjust_out' then 'Adjustment (out)' else 'Other money out' end), r.party, r.area, 0, r.amount, r.kind, r.voided_at, r.created_by);
    else
      n_lines := n_lines + bk_put('cashbook', r.id||':?', r.entry_date, '1010', '1900', null, r.kind||' '||coalesce(r.memo,''), r.party, r.area, case when r.direction>0 then r.amount else 0 end, case when r.direction<0 then r.amount else 0 end, r.kind, r.voided_at, r.created_by);
    end if;
  end loop;

  -- B. office subscriber payments (cash / gcash effect)
  for r in select * from fin_payments where entry_date >= s loop
    if coalesce(r.cash_effect,0) <> 0 then
      n_lines := n_lines + bk_put('payment', r.id||':c', r.entry_date, '1010', '4020', coalesce(r.or_no, r.gcash_ref), 'Subscriber payment', r.customer, r.area, greatest(r.cash_effect,0), greatest(-r.cash_effect,0), 'subpay', r.voided_at, r.created_by);
    end if;
    if coalesce(r.gcash_effect,0) <> 0 then
      n_lines := n_lines + bk_put('payment', r.id||':g', r.entry_date, '1040', '4020', coalesce(r.gcash_ref, r.or_no), 'Subscriber payment (GCash)', r.customer, r.area, greatest(r.gcash_effect,0), greatest(-r.gcash_effect,0), 'subpay', r.voided_at, r.created_by);
    end if;
  end loop;

  -- C. expense books: admin (Sir Wendell fund) always; daily book only before the cash-book cutover
  for r in select * from expenses where expense_date >= s and (book = 'admin' or (book = 'daily' and expense_date < cut)) loop
    v_acct := coalesce(bk_guess(coalesce(r.description,'')||' '||coalesce(r.category,'')||' '||coalesce(r.vendor,''), null), case when r.is_capex then '1500' else '5090' end);
    if r.is_capex and v_acct like '5%' then v_acct := '1500'; end if;
    n_lines := n_lines + bk_put('expenses', r.id::text, r.expense_date, case when r.book='admin' or r.paid_from ilike 'sir wendell%' then '1020' else '1010' end, v_acct, r.source_ref, coalesce(nullif(r.description,''), r.category, 'Expense'), coalesce(r.vendor, r.co), r.area, 0, r.amount, 'expense', r.voided_at, r.created_by);
  end loop;

  -- D. subscriber payments received straight to GCash / bank (collector app, autopay)
  for r in select * from subscriber_payments where payment_date >= s and lower(coalesce(pay_method,'')) in ('gcash','bank') loop
    n_lines := n_lines + bk_put('subpay', r.id::text, r.payment_date, case when lower(r.pay_method)='gcash' then '1040' else coalesce(bank1,'1010') end, '4020',
                 coalesce(r.gcash_ref, r.bank_ref, r.invoice_no), 'Subscriber payment ('||r.pay_method||')', r.subscriber_name, r.area, r.amount, 0, 'subpay', r.voided_at, r.collector);
  end loop;

  -- E. cash receipts sheet (daily piso income) — only before the cash-book cutover
  for r in select * from cash_receipts where receipt_date >= s and receipt_date < cut loop
    if coalesce(r.piso_wifi,0) <> 0 then n_lines := n_lines + bk_put('receipts', r.id||':p', r.receipt_date, '1010', '4010', null, 'Piso WiFi collections (cash receipts)', null, null, r.piso_wifi, 0, 'handin', null, 'sheet'); end if;
    if coalesce(r.subscriber_collection,0) <> 0 then n_lines := n_lines + bk_put('receipts', r.id||':s', r.receipt_date, '1010', '4020', null, 'Subscriber collections (cash receipts)', null, null, r.subscriber_collection, 0, 'subpay', null, 'sheet'); end if;
    if coalesce(r.amount_deposited,0) <> 0 then n_lines := n_lines + bk_put('receipts', r.id||':d', coalesce(r.date_deposited, r.receipt_date), '1010', coalesce(bank1,'1900'), null, 'Deposit (cash receipts)', null, 'Office', 0, r.amount_deposited, 'deposit', null, 'sheet'); end if;
  end loop;

  -- F. GCash wallet history → statement lines for the GCash fund
  insert into bk_stmt(fund, stmt_date, descr, ref, amt_in, amt_out, source, source_id, created_by)
  select '1040', (g.tx_at at time zone 'Asia/Manila')::date, g.description, g.ref,
         case when g.direction='in' then abs(g.amount) else 0 end, case when g.direction<>'in' then abs(g.amount) else 0 end, 'gcash_tx', g.ref, 'gcash export'
  from gcash_tx g where (g.tx_at at time zone 'Asia/Manila')::date >= s
  on conflict (source, source_id) where source <> 'manual' do nothing;
  get diagnostics n_stmt = row_count;

  insert into bk_sync_log(ms, lines, stmt) values (extract(milliseconds from clock_timestamp()-t0)::int, n_lines, n_stmt);
  delete from bk_sync_log where at < now() - interval '14 days';
  return jsonb_build_object('ok',true,'lines',n_lines,'stmt',n_stmt);
end $$;

-- upsert one imported line; amounts/date/void follow the source, user edits to category/party/area/descr are kept
create or replace function bk_put(p_src text, p_sid text, p_date date, p_fund text, p_acct text, p_ref text, p_descr text, p_party text, p_area text,
                                  p_in numeric, p_out numeric, p_kind text, p_void timestamptz, p_by text)
returns int language plpgsql security definer set search_path=public as $$
declare n int;
begin
  insert into bk_lines(entry_date, fund, acct, ref, descr, party, area, amt_in, amt_out, source, source_id, kind, auto, created_by, voided_at, voided_by)
  values (p_date, p_fund, p_acct, p_ref, p_descr, p_party, p_area, round(coalesce(p_in,0),2), round(coalesce(p_out,0),2), p_src, p_sid, p_kind, true, p_by, p_void, case when p_void is not null then 'source' end)
  on conflict (source, source_id) where source <> 'manual' do update set
    entry_date = excluded.entry_date, amt_in = excluded.amt_in, amt_out = excluded.amt_out,
    voided_at = coalesce(bk_lines.voided_at, excluded.voided_at),
    acct  = case when bk_lines.user_touched then bk_lines.acct  else coalesce(excluded.acct, bk_lines.acct) end,
    party = coalesce(bk_lines.party, excluded.party), area = coalesce(bk_lines.area, excluded.area),
    ref   = coalesce(bk_lines.ref, excluded.ref), descr = case when bk_lines.user_touched then bk_lines.descr else excluded.descr end,
    updated_at = now()
  where bk_lines.entry_date is distinct from excluded.entry_date or bk_lines.amt_in <> excluded.amt_in or bk_lines.amt_out <> excluded.amt_out
     or (bk_lines.voided_at is null and excluded.voided_at is not null) or (not bk_lines.user_touched and (bk_lines.acct is distinct from excluded.acct or bk_lines.descr is distinct from excluded.descr))
     or (bk_lines.party is null and excluded.party is not null) or (bk_lines.area is null and excluded.area is not null) or (bk_lines.ref is null and excluded.ref is not null);
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------- balances ----------
create or replace function bk_fund_bal(p_fund text, p_upto date, p_strict boolean default false)
returns numeric language sql stable security definer set search_path=public as $$
  select round(coalesce((select case when f.opening_date is null or f.opening_date <= p_upto then f.opening else 0 end from bk_funds f where f.code = p_fund),0)
       + coalesce((select sum(case when l.fund = p_fund then l.amt_in - l.amt_out else l.amt_out - l.amt_in end) from bk_lines l
                   where l.voided_at is null and (l.fund = p_fund or l.acct = p_fund) and (case when p_strict then l.entry_date < p_upto else l.entry_date <= p_upto end)),0), 2)
$$;

-- ---------- RPCs (all PIN-checked) ----------
create or replace function bk_boot(p_pin text) returns jsonb language plpgsql security definer set search_path=public as $$
declare u record;
begin
  select * into u from bk_user(p_pin);
  return jsonb_build_object('ok',true,'name',u.o_name,'role',u.o_role,'is_owner',u.o_role='owner','today',fin_today(),
    'start', bk_start(), 'cutover', fin_cash_cutover(),
    'funds',(select coalesce(jsonb_agg(to_jsonb(f) order by f.sort, f.code),'[]') from bk_funds f),
    'accts',(select coalesce(jsonb_agg(to_jsonb(a) order by a.sort, a.code),'[]') from bk_accounts a),
    'parties',(select coalesce(jsonb_agg(p order by n desc),'[]') from (select party p, count(*) n from bk_lines where party is not null and voided_at is null group by party order by n desc limit 300) x),
    'areas', (select jsonb_agg(a) from unnest(array['Dipolog','Dapitan','Sindangan','Sinaman','Roxas','Polanco','Minaog','Gulayon/Igot','Office']) a),
    'last_sync',(select max(at) from bk_sync_log),
    'needs',(select count(*) from bk_lines where voided_at is null and (acct is null or acct = '1900' or acct = fund)));
end $$;

create or replace function bk_lines_get(p_pin text, p_from date, p_to date, p_fund text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare u record;
begin
  select * into u from bk_user(p_pin);
  return jsonb_build_object('ok',true,
    'open',(select jsonb_object_agg(code, bk_fund_bal(code, p_from, true)) from bk_funds),
    'matched',(select coalesce(jsonb_agg(distinct match_line),'[]') from bk_stmt where match_line is not null and voided_at is null),
    'lines',(select coalesce(jsonb_agg(jsonb_build_object('id',l.id,'date',l.entry_date,'fund',l.fund,'acct',l.acct,'ref',l.ref,'desc',l.descr,'party',l.party,'area',l.area,
                'in',l.amt_in,'out',l.amt_out,'src',l.source,'kind',l.kind,'auto',l.auto,'void',l.voided_at is not null,'by',l.created_by,'grp',l.grp) order by l.entry_date, l.id),'[]')
             from bk_lines l where l.entry_date between p_from and p_to and (p_fund is null or l.fund = p_fund or l.acct = p_fund)));
end $$;

create or replace function bk_line_set(p_pin text, p_id bigint, p_client_id uuid, p_vals jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare u record; l bk_lines; v jsonb := coalesce(p_vals,'{}'::jsonb); nin numeric; nout numeric; d date;
begin
  select * into u from bk_user(p_pin);
  if p_id is not null then select * into l from bk_lines where id = p_id; if not found then raise exception 'not_found'; end if;
  elsif p_client_id is not null then select * into l from bk_lines where client_id = p_client_id; end if;
  if l.id is not null and l.voided_at is not null then raise exception 'line_is_void'; end if;
  if l.id is not null and l.source <> 'manual' and (v ? 'in' or v ? 'out' or v ? 'date' or v ? 'fund') then raise exception 'imported_amounts_locked'; end if;
  if v ? 'date' then d := (v->>'date')::date; if d > fin_today() + 1 then raise exception 'future_date'; end if; end if;
  if v ? 'fund' and not exists (select 1 from bk_funds where code = v->>'fund') then raise exception 'bad_fund'; end if;
  if v ? 'acct' and nullif(v->>'acct','') is not null and not exists (select 1 from bk_accounts where code = v->>'acct' union all select 1 from bk_funds where code = v->>'acct') then raise exception 'bad_account'; end if;
  nin := round(coalesce((v->>'in')::numeric, l.amt_in, 0),2); nout := round(coalesce((v->>'out')::numeric, l.amt_out, 0),2);
  if v ? 'in' and nin <> 0 then nout := 0; end if; if v ? 'out' and nout <> 0 then nin := 0; end if;
  if nin < 0 then nout := -nin; nin := 0; end if; if nout < 0 then nin := -nout; nout := 0; end if;
  if l.id is null then
    insert into bk_lines(entry_date, fund, acct, ref, descr, party, area, amt_in, amt_out, source, kind, auto, created_by, client_id, user_touched)
    values (coalesce(d, fin_today()), coalesce(v->>'fund','1010'), nullif(v->>'acct',''), nullif(v->>'ref',''), nullif(v->>'desc',''), nullif(v->>'party',''), nullif(v->>'area',''),
            nin, nout, 'manual', coalesce(v->>'kind','manual'), coalesce((v->>'auto')::boolean,false), u.o_name, p_client_id, true)
    returning * into l;
  else
    update bk_lines set entry_date = coalesce(d, entry_date), fund = coalesce(v->>'fund', fund),
      acct = case when v ? 'acct' then nullif(v->>'acct','') else acct end, ref = case when v ? 'ref' then nullif(v->>'ref','') else ref end,
      descr = case when v ? 'desc' then nullif(v->>'desc','') else descr end, party = case when v ? 'party' then nullif(v->>'party','') else party end,
      area = case when v ? 'area' then nullif(v->>'area','') else area end, amt_in = nin, amt_out = nout,
      auto = case when v ? 'acct' then coalesce((v->>'auto')::boolean,false) else auto end,
      user_touched = true, updated_at = now(), updated_by = u.o_name where id = l.id returning * into l;
  end if;
  -- a changed amount breaks any bank match
  update bk_stmt s set match_line = null where s.match_line = l.id and round(s.amt_in - s.amt_out,2) <> round(case when s.fund = l.fund then l.amt_in - l.amt_out else l.amt_out - l.amt_in end,2);
  return jsonb_build_object('ok',true,'id',l.id);
end $$;

create or replace function bk_line_void(p_pin text, p_id bigint, p_reason text default null, p_restore boolean default false)
returns jsonb language plpgsql security definer set search_path=public as $$
declare u record; l bk_lines;
begin
  select * into u from bk_user(p_pin);
  select * into l from bk_lines where id = p_id; if not found then raise exception 'not_found'; end if;
  if l.source <> 'manual' and not p_restore then raise exception 'void_in_source_app'; end if;
  if p_restore then update bk_lines set voided_at = null, voided_by = null, void_reason = null, updated_at = now(), updated_by = u.o_name where id = p_id;
  else update bk_lines set voided_at = now(), voided_by = u.o_name, void_reason = p_reason, updated_at = now() where id = p_id;
       update bk_stmt set match_line = null where match_line = p_id; end if;
  return jsonb_build_object('ok',true);
end $$;

create or replace function bk_position(p_pin text, p_asof date) returns jsonb language plpgsql security definer set search_path=public as $$
declare u record; ms date := date_trunc('month', p_asof)::date;
begin
  select * into u from bk_user(p_pin);
  return jsonb_build_object('ok',true,'asof',p_asof,
   'funds',(select coalesce(jsonb_agg(jsonb_build_object('code',f.code,'name',f.name,'type',f.type,
      'start', bk_fund_bal(f.code, ms, true),
      'in', coalesce((select sum(case when l.fund=f.code then l.amt_in else l.amt_out end) from bk_lines l where l.voided_at is null and (l.fund=f.code or l.acct=f.code) and l.entry_date between ms and p_asof and (case when l.fund=f.code then l.amt_in else l.amt_out end)>0),0),
      'out', coalesce((select sum(case when l.fund=f.code then l.amt_out else l.amt_in end) from bk_lines l where l.voided_at is null and (l.fund=f.code or l.acct=f.code) and l.entry_date between ms and p_asof and (case when l.fund=f.code then l.amt_out else l.amt_in end)>0),0),
      'book', bk_fund_bal(f.code, p_asof, false),
      'actual',(select actual from bk_counts c where c.fund=f.code and c.count_date=p_asof),
      'recon',(select done_at from bk_recon r where r.fund=f.code and r.month=ms)) order by f.sort, f.code),'[]') from bk_funds f where f.active),
   'days',(select coalesce(jsonb_agg(jsonb_build_object('d',d,'in',i,'out',o,'close',c) order by d),'[]') from (
      select d, coalesce((select sum(l.amt_in) from bk_lines l join bk_funds f on f.code=l.fund where l.voided_at is null and l.entry_date=d and f.type<>'card' and not exists (select 1 from bk_funds g where g.code=l.acct)),0) i,
                coalesce((select sum(l.amt_out) from bk_lines l join bk_funds f on f.code=l.fund where l.voided_at is null and l.entry_date=d and f.type<>'card' and not exists (select 1 from bk_funds g where g.code=l.acct)),0) o,
                (select sum(bk_fund_bal(f.code, d, false)) from bk_funds f where f.active and f.type<>'card') c
      from (select gs::date d from generate_series(p_asof - 6, p_asof, interval '1 day') gs) g) x),
   'needs',(select count(*) from bk_lines where voided_at is null and entry_date <= p_asof and (acct is null or acct='1900' or acct=fund)));
end $$;

create or replace function bk_count_set(p_pin text, p_fund text, p_date date, p_actual numeric, p_detail jsonb default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare u record;
begin
  select * into u from bk_user(p_pin);
  if p_actual is null then delete from bk_counts where fund=p_fund and count_date=p_date;
  else insert into bk_counts(fund,count_date,actual,detail,counted_by) values (p_fund,p_date,round(p_actual,2),p_detail,u.o_name)
       on conflict (fund,count_date) do update set actual=excluded.actual, detail=excluded.detail, counted_by=excluded.counted_by, at=now(); end if;
  return jsonb_build_object('ok',true);
end $$;

-- bank reconciliation
create or replace function bk_recon_get(p_pin text, p_fund text, p_month date) returns jsonb language plpgsql security definer set search_path=public as $$
declare u record; ms date := date_trunc('month', p_month)::date; me date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
begin
  select * into u from bk_user(p_pin);
  return jsonb_build_object('ok',true,'fund',p_fund,'month',ms,
   'recon',(select to_jsonb(r) from bk_recon r where r.fund=p_fund and r.month=ms),
   'open_book', bk_fund_bal(p_fund, ms, true), 'end_book', bk_fund_bal(p_fund, me, false),
   'stmt',(select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'date',s.stmt_date,'desc',s.descr,'ref',s.ref,'in',s.amt_in,'out',s.amt_out,'match',s.match_line,'src',s.source) order by s.stmt_date, s.id),'[]')
           from bk_stmt s where s.fund=p_fund and s.voided_at is null and (s.stmt_date between ms and me or (s.stmt_date is null and s.created_at >= ms))),
   'book',(select coalesce(jsonb_agg(jsonb_build_object('id',l.id,'date',l.entry_date,'ref',l.ref,'desc',coalesce(l.descr,''),'party',l.party,'acct',l.acct,
             'amt', round(case when l.fund=p_fund then l.amt_in - l.amt_out else l.amt_out - l.amt_in end,2),
             'matched', exists(select 1 from bk_stmt s where s.match_line=l.id and s.voided_at is null)) order by l.entry_date, l.id),'[]')
           from bk_lines l where l.voided_at is null and (l.fund=p_fund or l.acct=p_fund) and l.entry_date between ms and me
             and round(case when l.fund=p_fund then l.amt_in - l.amt_out else l.amt_out - l.amt_in end,2) <> 0));
end $$;

create or replace function bk_stmt_set(p_pin text, p_fund text, p_rows jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare u record; r jsonb; n int := 0; sid bigint; nin numeric; nout numeric; ms date;
begin
  select * into u from bk_user(p_pin);
  for r in select * from jsonb_array_elements(p_rows) loop
    nin := round(coalesce((r->>'in')::numeric,0),2); nout := round(coalesce((r->>'out')::numeric,0),2);
    if nin < 0 then nout := -nin; nin := 0; end if; if nout < 0 then nin := -nout; nout := 0; end if;
    if r ? 'id' and (r->>'id') is not null then
      select date_trunc('month', stmt_date)::date into ms from bk_stmt where id = (r->>'id')::bigint;
      if exists (select 1 from bk_recon x where x.fund=p_fund and x.month=ms and x.done_at is not null) then raise exception 'month_reconciled'; end if;
      if (r->>'void')::boolean then update bk_stmt set voided_at=now(), voided_by=u.o_name, match_line=null where id=(r->>'id')::bigint;
      else update bk_stmt set stmt_date = case when r ? 'date' then nullif(r->>'date','')::date else stmt_date end,
             descr = case when r ? 'desc' then r->>'desc' else descr end, ref = case when r ? 'ref' then r->>'ref' else ref end,
             amt_in = case when r ? 'in' or r ? 'out' then nin else amt_in end, amt_out = case when r ? 'in' or r ? 'out' then nout else amt_out end,
             match_line = case when (r ? 'in' or r ? 'out') then null else match_line end
           where id=(r->>'id')::bigint; end if;
    else
      insert into bk_stmt(fund, stmt_date, descr, ref, amt_in, amt_out, created_by, client_id)
      values (p_fund, nullif(r->>'date','')::date, r->>'desc', r->>'ref', nin, nout, u.o_name, nullif(r->>'client_id','')::uuid)
      on conflict (client_id) where client_id is not null do nothing;
    end if;
    n := n + 1;
  end loop;
  return jsonb_build_object('ok',true,'n',n);
end $$;

create or replace function bk_match(p_pin text, p_stmt bigint, p_line bigint) returns jsonb language plpgsql security definer set search_path=public as $$
declare u record; s bk_stmt; l bk_lines; a numeric;
begin
  select * into u from bk_user(p_pin);
  select * into s from bk_stmt where id=p_stmt; if not found then raise exception 'not_found'; end if;
  if exists (select 1 from bk_recon x where x.fund=s.fund and x.month=date_trunc('month',s.stmt_date)::date and x.done_at is not null) then raise exception 'month_reconciled'; end if;
  if p_line is null then update bk_stmt set match_line=null where id=p_stmt; return jsonb_build_object('ok',true); end if;
  select * into l from bk_lines where id=p_line and voided_at is null; if not found then raise exception 'not_found'; end if;
  a := round(case when l.fund=s.fund then l.amt_in-l.amt_out else l.amt_out-l.amt_in end,2);
  if a <> round(s.amt_in - s.amt_out,2) then raise exception 'amounts_differ'; end if;
  if exists (select 1 from bk_stmt where match_line=p_line and voided_at is null and id<>p_stmt) then raise exception 'already_matched'; end if;
  update bk_stmt set match_line=p_line where id=p_stmt;
  return jsonb_build_object('ok',true);
end $$;

create or replace function bk_automatch(p_pin text, p_fund text, p_month date) returns jsonb language plpgsql security definer set search_path=public as $$
declare u record; ms date := date_trunc('month', p_month)::date; me date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date; s record; lid bigint; n int := 0;
begin
  select * into u from bk_user(p_pin);
  if exists (select 1 from bk_recon x where x.fund=p_fund and x.month=ms and x.done_at is not null) then raise exception 'month_reconciled'; end if;
  for s in select * from bk_stmt where fund=p_fund and voided_at is null and match_line is null and stmt_date between ms and me and round(amt_in-amt_out,2) <> 0 order by stmt_date, id loop
    select l.id into lid from bk_lines l
      where l.voided_at is null and (l.fund=p_fund or l.acct=p_fund)
        and round(case when l.fund=p_fund then l.amt_in-l.amt_out else l.amt_out-l.amt_in end,2) = round(s.amt_in-s.amt_out,2)
        and abs(l.entry_date - s.stmt_date) <= 4
        and not exists (select 1 from bk_stmt z where z.match_line=l.id and z.voided_at is null)
      order by (case when s.ref is not null and l.ref is not null and regexp_replace(l.ref,'\D','','g') <> '' and regexp_replace(s.ref,'\D','','g') like '%'||regexp_replace(l.ref,'\D','','g')||'%' then 0 else 1 end), abs(l.entry_date - s.stmt_date), l.id
      limit 1;
    if lid is not null then update bk_stmt set match_line=lid where id=s.id; n := n+1; end if;
  end loop;
  return jsonb_build_object('ok',true,'n',n);
end $$;

create or replace function bk_stmt_to_book(p_pin text, p_stmt bigint) returns jsonb language plpgsql security definer set search_path=public as $$
declare u record; s bk_stmt; g text; l bk_lines; a numeric;
begin
  select * into u from bk_user(p_pin);
  select * into s from bk_stmt where id=p_stmt and voided_at is null; if not found then raise exception 'not_found'; end if;
  if s.match_line is not null then raise exception 'already_matched'; end if;
  a := round(s.amt_in - s.amt_out, 2);
  g := bk_guess(s.descr, null);
  if g is null then g := case when a < 0 and lower(coalesce(s.descr,'')) ~ '(charge|fee|svc|chg|penalt|tax)' then '5085' when a > 0 and lower(coalesce(s.descr,'')) ~ 'interest' then '4080' end; end if;
  insert into bk_lines(entry_date, fund, acct, ref, descr, area, amt_in, amt_out, source, kind, auto, created_by, user_touched)
  values (coalesce(s.stmt_date, fin_today()), s.fund, g, s.ref, coalesce(s.descr,'Bank item'), 'Office', greatest(a,0), greatest(-a,0), 'manual', 'bankitem', g is not null, u.o_name, true)
  returning * into l;
  update bk_stmt set match_line = l.id where id = p_stmt;
  return jsonb_build_object('ok',true,'id',l.id,'acct',g);
end $$;

create or replace function bk_recon_set(p_pin text, p_fund text, p_month date, p_vals jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare u record; ms date := date_trunc('month', p_month)::date; v jsonb := coalesce(p_vals,'{}'::jsonb);
begin
  select * into u from bk_user(p_pin);
  insert into bk_recon(fund, month) values (p_fund, ms) on conflict do nothing;
  if v ? 'opening' then update bk_recon set opening = nullif(v->>'opening','')::numeric, updated_at=now() where fund=p_fund and month=ms; end if;
  if v ? 'ending'  then update bk_recon set ending  = nullif(v->>'ending','')::numeric,  updated_at=now() where fund=p_fund and month=ms; end if;
  if v ? 'done' then
    if (v->>'done')::boolean then update bk_recon set done_at=now(), done_by=u.o_name, updated_at=now() where fund=p_fund and month=ms;
    else if u.o_role <> 'owner' then raise exception 'owner_only'; end if; update bk_recon set done_at=null, done_by=null, updated_at=now() where fund=p_fund and month=ms; end if;
  end if;
  return jsonb_build_object('ok',true);
end $$;

-- reports
create or replace function bk_report(p_pin text, p_month date) returns jsonb language plpgsql security definer set search_path=public as $$
declare u record; ms date := date_trunc('month', p_month)::date; me date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
begin
  select * into u from bk_user(p_pin);
  return jsonb_build_object('ok',true,'month',ms,
   -- P&L by area (income/expense accounts only, month)
   'pl',(select coalesce(jsonb_agg(jsonb_build_object('acct',acct,'area',area,'amt',amt)),'[]') from (
      select l.acct, coalesce(nullif(l.area,''),'—') area, round(sum(case when a.type='income' then l.amt_in - l.amt_out else l.amt_out - l.amt_in end),2) amt
      from bk_lines l join bk_accounts a on a.code=l.acct where l.voided_at is null and l.entry_date between ms and me and a.type in ('income','expense') group by 1,2) x),
   -- balances at month end for every account & fund
   'bal',(select coalesce(jsonb_agg(jsonb_build_object('code',code,'name',name,'type',type,'bal',bal)),'[]') from (
      select f.code, f.name, case when f.type='card' then 'liability' else 'asset' end type, bk_fund_bal(f.code, me, false) bal from bk_funds f
      union all
      select a.code, a.name, a.type, round(coalesce((select sum(case when a.type in ('asset','expense') then l.amt_out - l.amt_in else l.amt_in - l.amt_out end) from bk_lines l where l.voided_at is null and l.acct=a.code and l.entry_date <= me),0)
             + case when a.code='3020' then coalesce((select sum(f.opening) from bk_funds f where f.opening_date is not null and f.opening_date <= me),0) else 0 end, 2) bal
      from bk_accounts a) y where bal <> 0),
   'needs',(select count(*) from bk_lines where voided_at is null and entry_date <= me and (acct is null or acct='1900' or acct=fund)));
end $$;

-- accounts admin (owner)
create or replace function bk_fund_set(p_pin text, p_code text, p_vals jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare u record; v jsonb := coalesce(p_vals,'{}'::jsonb); nc text;
begin
  select * into u from bk_user(p_pin); if u.o_role <> 'owner' then raise exception 'owner_only'; end if;
  nc := coalesce(nullif(v->>'code',''), p_code);
  if nc !~ '^\d{3,5}$' then raise exception 'code_3_to_5_digits'; end if;
  if p_code is null then
    if exists (select 1 from bk_funds where code=nc union all select 1 from bk_accounts where code=nc) then raise exception 'code_in_use'; end if;
    insert into bk_funds(code,name,type,bank,last4,opening,opening_date,sort) values (nc, coalesce(v->>'name','New fund'), coalesce(v->>'type','bank'), v->>'bank', right(regexp_replace(coalesce(v->>'last4',''),'\D','','g'),4), coalesce((v->>'opening')::numeric,0), nullif(v->>'opening_date','')::date, coalesce((v->>'sort')::int,100));
  else
    if nc <> p_code then
      if exists (select 1 from bk_funds where code=nc union all select 1 from bk_accounts where code=nc) then raise exception 'code_in_use'; end if;
      update bk_funds set code=nc where code=p_code;  -- fund FKs cascade; acct is a plain column
      update bk_lines set acct=nc where acct=p_code;
    end if;
    update bk_funds set name=coalesce(v->>'name',name), type=coalesce(v->>'type',type), bank=case when v ? 'bank' then nullif(v->>'bank','') else bank end,
      last4=case when v ? 'last4' then right(regexp_replace(coalesce(v->>'last4',''),'\D','','g'),4) else last4 end,
      opening=coalesce((v->>'opening')::numeric,opening), opening_date=case when v ? 'opening_date' then nullif(v->>'opening_date','')::date else opening_date end,
      active=coalesce((v->>'active')::boolean,active), sort=coalesce((v->>'sort')::int,sort) where code=nc;
  end if;
  return jsonb_build_object('ok',true,'code',nc);
end $$;

create or replace function bk_account_set(p_pin text, p_code text, p_vals jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare u record; v jsonb := coalesce(p_vals,'{}'::jsonb); nc text;
begin
  select * into u from bk_user(p_pin); if u.o_role <> 'owner' then raise exception 'owner_only'; end if;
  nc := coalesce(nullif(v->>'code',''), p_code);
  if nc !~ '^\d{3,5}$' then raise exception 'code_3_to_5_digits'; end if;
  if p_code is null then
    if exists (select 1 from bk_funds where code=nc union all select 1 from bk_accounts where code=nc) then raise exception 'code_in_use'; end if;
    insert into bk_accounts(code,name,type,sort) values (nc, coalesce(v->>'name','New account'), coalesce(v->>'type','expense'), coalesce((v->>'sort')::int, nc::int));
  else
    if nc <> p_code then
      if exists (select 1 from bk_funds where code=nc union all select 1 from bk_accounts where code=nc) then raise exception 'code_in_use'; end if;
      update bk_accounts set code=nc where code=p_code; update bk_lines set acct=nc where acct=p_code;
    end if;
    update bk_accounts set name=coalesce(v->>'name',name), type=coalesce(v->>'type',type), active=coalesce((v->>'active')::boolean,active), sort=coalesce((v->>'sort')::int,sort) where code=nc;
  end if;
  return jsonb_build_object('ok',true,'code',nc);
end $$;

create or replace function bk_setting_set(p_pin text, p_key text, p_value text) returns jsonb language plpgsql security definer set search_path=public as $$
declare u record;
begin
  select * into u from bk_user(p_pin); if u.o_role <> 'owner' then raise exception 'owner_only'; end if;
  if p_key = 'books_start' then perform p_value::date; end if;
  insert into bk_settings(key,value,updated_by) values (p_key,p_value,u.o_name) on conflict (key) do update set value=excluded.value, updated_at=now(), updated_by=excluded.updated_by;
  return jsonb_build_object('ok',true);
end $$;

create or replace function bk_sync(p_pin text) returns jsonb language plpgsql security definer set search_path=public as $$
declare u record;
begin select * into u from bk_user(p_pin); return bk_sync_run(); end $$;

-- lock down: only the RPCs touch the tables
revoke all on bk_settings, bk_funds, bk_accounts, bk_lines, bk_stmt, bk_recon, bk_counts, bk_sync_log from anon, authenticated;
revoke execute on function bk_sync_run(), bk_put(text,text,date,text,text,text,text,text,text,numeric,numeric,text,timestamptz,text) from anon, authenticated, public;

-- cron: pull the office books into the journal every 15 minutes (offset from the other jobs)
select cron.schedule('books-sync', '3,18,33,48 * * * *', $$select public.bk_sync_run()$$)
where not exists (select 1 from cron.job where jobname = 'books-sync');

-- ============================================================================
-- APPLIED 2026-11-20 to cviraqfhphhsonjmrtvu as migrations books_part1_schema_sync, books_part2_rpcs,
-- books_fix_guess_and_office_collection (the fix below supersedes bk_guess/bk_sync_run above):
--   * office_collection cash-book lines → 4020 Subscriber income (fin_payments cash side is NOT imported separately)
--   * bk_guess: "coin wrapper" → 5030, bare "gcash" → GCash wallet transfer, aircon → 5050, netflix → 3010
-- Verified: bk_fund_bal('1010') == fin_cash_balance() (₱65,803.00 on 2026-11-20); balance sheet check = 0.00.
-- Trial import currently runs from books_start = 2026-10-31 (cash-book cutover). Owner can change it in Books → Accounts.
-- Cron: books-sync at 3,18,33,48 * * * * → bk_sync_run().
-- Rollback: select cron.unschedule('books-sync'); drop function bk_boot,bk_lines_get,bk_line_set,bk_line_void,bk_position,bk_count_set,
--   bk_recon_get,bk_stmt_set,bk_match,bk_automatch,bk_stmt_to_book,bk_recon_set,bk_report,bk_fund_set,bk_account_set,bk_setting_set,bk_sync,
--   bk_sync_run,bk_put,bk_fund_bal,bk_guess,bk_start,bk_user cascade; drop table bk_stmt,bk_recon,bk_counts,bk_lines,bk_accounts,bk_funds,bk_settings,bk_sync_log;
