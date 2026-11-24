-- 0003: live exchange rates with history, KYC tiers, daily limits and balance caps.
-- Run AFTER 0002. TEST MODE: all money is fake.

-- Rate history is append-only and public-read (it will power an honest "value kept" chart).
create table if not exists public.rate_history (
  id bigint generated always as identity primary key,
  currency text not null references public.currencies(code),
  per_usd numeric not null check (per_usd > 0),
  source text not null,
  fetched_at timestamptz not null default now()
);
create index if not exists rate_history_cur_time on public.rate_history (currency, fetched_at desc);
alter table public.rate_history enable row level security;
drop policy if exists "read rate history" on public.rate_history;
create policy "read rate history" on public.rate_history for select to anon, authenticated using (true);
insert into public.rate_history (currency, per_usd, source)
select code, per_usd, 'seed' from public.currencies
where not exists (select 1 from public.rate_history);

insert into public.settings (key, value) values ('max_rate_move', 0.05) on conflict (key) do nothing;

-- Only the service role (the scheduled Edge Function) may change rates, and never by more
-- than max_rate_move in one step: a bad feed cannot silently reprice every payment.
create or replace function public.set_rate(p_currency text, p_per_usd numeric, p_source text)
returns json language plpgsql security definer set search_path = '' as $$
declare v_old numeric; v_max numeric;
begin
  select per_usd into v_old from public.currencies where code = p_currency;
  if v_old is null then raise exception 'Unknown currency %', p_currency; end if;
  if p_per_usd is null or p_per_usd <= 0 then raise exception 'Invalid rate'; end if;
  select value into v_max from public.settings where key = 'max_rate_move';
  if abs(p_per_usd - v_old) / v_old > coalesce(v_max, 0.05) then
    raise exception 'Rate move too large (% to %). Review manually.', v_old, p_per_usd;
  end if;
  update public.currencies set per_usd = p_per_usd, updated_at = now() where code = p_currency;
  insert into public.rate_history (currency, per_usd, source) values (p_currency, p_per_usd, p_source);
  return json_build_object('currency', p_currency, 'old', v_old, 'new', p_per_usd);
end $$;
revoke all on function public.set_rate(text, numeric, text) from public, anon, authenticated;
grant execute on function public.set_rate(text, numeric, text) to service_role;

-- KYC tiers: limits grow with verification. New users start at tier 0.
alter table public.profiles add column if not exists kyc_tier int not null default 0;
create table if not exists public.kyc_tiers (
  tier int primary key, name text not null,
  daily_limit_usd numeric not null, balance_cap_usd numeric not null
);
insert into public.kyc_tiers (tier, name, daily_limit_usd, balance_cap_usd)
values (0,'Basic',100,200), (1,'Verified',1000,5000) on conflict (tier) do nothing;
alter table public.kyc_tiers enable row level security;
drop policy if exists "read tiers" on public.kyc_tiers;
create policy "read tiers" on public.kyc_tiers for select to authenticated using (true);

create or replace function public.my_limits()
returns json language sql stable security definer set search_path = '' as $$
  select json_build_object('tier', t.name, 'daily_limit_usd', t.daily_limit_usd, 'balance_cap_usd', t.balance_cap_usd,
    'spent_24h_usd', coalesce((select sum(x.amount_usd) from public.transactions x
       where x.user_id = auth.uid() and x.kind = 'payment' and x.created_at >= now() - interval '24 hours'), 0))
  from public.profiles p join public.kyc_tiers t on t.tier = p.kyc_tier where p.user_id = auth.uid();
$$;
revoke all on function public.my_limits() from public, anon;
grant execute on function public.my_limits() to authenticated;

-- Test deposits now respect the balance cap.
create or replace function public.test_deposit(p_amount numeric)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_cap numeric; v_bal numeric;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 100 then
    raise exception 'Test deposits must be between 1 and 100 USD';
  end if;
  select t.balance_cap_usd, w.balance_usd into v_cap, v_bal
  from public.profiles p join public.kyc_tiers t on t.tier = p.kyc_tier
  join public.wallets w on w.user_id = p.user_id where p.user_id = v_uid for update of w;
  if v_bal + p_amount > v_cap then raise exception 'Balance cap reached for your tier'; end if;
  update public.wallets set balance_usd = balance_usd + p_amount where user_id = v_uid;
  insert into public.transactions (user_id, kind, amount_usd, service) values (v_uid, 'deposit', p_amount, 'Test deposit');
end $$;

-- Payments now enforce the rolling 24-hour limit for the user's tier.
create or replace function public.pay_service(p_service_id text, p_recipient text, p_amount_local numeric, p_idem uuid default null)
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_p public.profiles; v_s public.services; v_c public.currencies; v_t public.transactions;
  v_fee_rate numeric; v_usd numeric; v_fee numeric; v_total numeric; v_limit numeric; v_spent numeric;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  select * into v_p from public.profiles where user_id = v_uid;
  if not found then raise exception 'Profile not found'; end if;
  select * into v_s from public.services where id = p_service_id and country = v_p.country;
  if not found then raise exception 'Service not available in your country'; end if;
  select * into v_c from public.currencies where code = v_p.currency;

  if p_idem is not null then
    select * into v_t from public.transactions where user_id = v_uid and idempotency_key = p_idem;
    if found then
      return json_build_object('total_usd', v_t.amount_usd, 'fee_usd', v_t.fee_usd, 'rate', v_t.rate,
        'amount_local', v_t.amount_local, 'currency', v_t.currency, 'service', v_t.service);
    end if;
  end if;

  if p_amount_local is null or p_amount_local < v_c.per_usd * 0.25 then raise exception 'Amount is too small'; end if;
  if p_amount_local > v_c.per_usd * 500 then raise exception 'Amount is above the test limit'; end if;
  if coalesce(length(trim(p_recipient)), 0) < 6 then raise exception 'Enter a valid phone, meter or account number'; end if;

  select value into v_fee_rate from public.settings where key = 'fee_rate';
  v_usd := round(p_amount_local / v_c.per_usd, 2);
  v_fee := round(v_usd * v_fee_rate, 2);
  v_total := v_usd + v_fee;

  select t.daily_limit_usd into v_limit from public.kyc_tiers t where t.tier = v_p.kyc_tier;
  perform 1 from public.wallets where user_id = v_uid for update;   -- serialise this user's payments
  select coalesce(sum(amount_usd), 0) into v_spent from public.transactions
   where user_id = v_uid and kind = 'payment' and created_at >= now() - interval '24 hours';
  if v_spent + v_total > v_limit then raise exception 'Daily limit reached for your tier'; end if;

  update public.wallets set balance_usd = balance_usd - v_total where user_id = v_uid and balance_usd >= v_total;
  if not found then raise exception 'Not enough balance for this payment'; end if;

  insert into public.transactions (user_id, kind, service, recipient, amount_local, currency, amount_usd, fee_usd, rate, idempotency_key)
  values (v_uid, 'payment', v_s.name, trim(p_recipient), p_amount_local, v_c.code, v_total, v_fee, v_c.per_usd, p_idem);

  return json_build_object('total_usd', v_total, 'fee_usd', v_fee, 'rate', v_c.per_usd,
    'amount_local', p_amount_local, 'currency', v_c.code, 'service', v_s.name);
end $$;
