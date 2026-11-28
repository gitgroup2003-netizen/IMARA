-- 0005: one-call bootstrap, append-only ledger guard, payment burst limit, reconciliation and
-- founder metrics views, and sample data for demos. Run AFTER 0004. TEST MODE.

create index if not exists services_country_sort on public.services (country, category, sort);
insert into public.settings (key, value) values ('demo_mode', 1) on conflict (key) do nothing;

-- Ledger guard: transactions can never be edited, and one user cannot fire more than 10 payments a minute.
create or replace function public.guard_transactions()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then raise exception 'Transactions are append-only'; end if;
  if new.kind = 'payment' and (select count(*) from public.transactions
       where user_id = new.user_id and kind = 'payment' and created_at > now() - interval '1 minute') >= 10 then
    raise exception 'Too many payments. Please wait a minute.';
  end if;
  return new;
end $$;
drop trigger if exists tx_guard on public.transactions;
create trigger tx_guard before insert or update on public.transactions
for each row execute function public.guard_transactions();

-- One round trip loads everything the app needs after login (important on slow mobile networks).
create or replace function public.app_bootstrap()
returns json language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'profile', (select row_to_json(p) from public.profiles p where p.user_id = auth.uid()),
    'wallet', (select row_to_json(w) from (select balance_usd from public.wallets where user_id = auth.uid()) w),
    'limits', public.my_limits(),
    'fee_rate', (select value from public.settings where key = 'fee_rate'),
    'countries', (select coalesce(json_agg(c order by c.name), '[]') from public.countries c),
    'currencies', (select coalesce(json_agg(c), '[]') from public.currencies c),
    'services', (select coalesce(json_agg(s order by s.sort), '[]') from public.services s
                 where s.country = (select country from public.profiles where user_id = auth.uid())),
    'recent', (select coalesce(json_agg(t), '[]') from (select * from public.transactions
                 where user_id = auth.uid() order by created_at desc, id desc limit 30) t));
$$;
revoke all on function public.app_bootstrap() from public, anon;
grant execute on function public.app_bootstrap() to authenticated;

-- Reconciliation: every wallet balance must equal deposits minus payments. Any difference is a bug or tampering.
create or replace view public.reconciliation_report with (security_invoker = true) as
select w.user_id, w.balance_usd as wallet_usd,
  coalesce(sum(case when t.kind = 'deposit' then t.amount_usd when t.kind = 'payment' then -t.amount_usd end), 0) as ledger_usd,
  w.balance_usd - coalesce(sum(case when t.kind = 'deposit' then t.amount_usd when t.kind = 'payment' then -t.amount_usd end), 0) as difference
from public.wallets w left join public.transactions t on t.user_id = w.user_id
group by w.user_id, w.balance_usd;

-- Founder metrics: daily payments, volume and active users (read it in the SQL editor).
create or replace view public.metrics_daily with (security_invoker = true) as
select date_trunc('day', created_at)::date as day,
  count(*) filter (where kind = 'payment') as payments,
  coalesce(sum(amount_usd) filter (where kind = 'payment'), 0) as volume_usd,
  count(distinct user_id) filter (where kind = 'payment') as active_users
from public.transactions group by 1 order by 1 desc;
revoke all on public.reconciliation_report, public.metrics_daily from anon, authenticated;
grant select on public.reconciliation_report, public.metrics_daily to service_role;

-- Sample data so a demo never opens on an empty wallet. Only loads into an empty wallet; switch off with demo_mode = 0.
create or replace function public.seed_demo()
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); v_p public.profiles; v_c public.currencies; r record;
  v_usd numeric; v_fee numeric; v_total numeric; i int := 0;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if (select value from public.settings where key = 'demo_mode') is distinct from 1 then
    raise exception 'Sample data is switched off'; end if;
  if exists (select 1 from public.transactions where user_id = v_uid) then
    raise exception 'Sample data only loads into an empty wallet'; end if;
  select * into v_p from public.profiles where user_id = v_uid;
  select * into v_c from public.currencies where code = v_p.currency;
  insert into public.transactions (user_id, kind, service, amount_usd, created_at) values
    (v_uid, 'deposit', 'Test deposit', 100, now() - interval '12 days'),
    (v_uid, 'deposit', 'Test deposit', 100, now() - interval '5 days');
  update public.wallets set balance_usd = balance_usd + 200 where user_id = v_uid;
  for r in select name from public.services where country = v_p.country order by md5(id) limit 8 loop
    i := i + 1;
    v_usd := round(2 + i * 2.1, 2); v_fee := round(v_usd * 0.01, 2); v_total := v_usd + v_fee;
    insert into public.transactions (user_id, kind, service, recipient, amount_local, currency, amount_usd, fee_usd, rate, created_at)
    values (v_uid, 'payment', r.name, 'sample', round(v_usd * v_c.per_usd), v_c.code, v_total, v_fee, v_c.per_usd, now() - i * interval '19 hours');
    update public.wallets set balance_usd = balance_usd - v_total where user_id = v_uid;
  end loop;
end $$;
revoke all on function public.seed_demo() from public, anon;
grant execute on function public.seed_demo() to authenticated;
