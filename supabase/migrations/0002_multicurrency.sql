-- 0002: countries, currencies, profiles, service catalogue, idempotent multi-currency payments.
-- Run AFTER 0001_init.sql. TEST MODE: all money is fake.

create table if not exists public.countries (
  code text primary key, name text not null, currency text not null, dial text not null
);
create table if not exists public.currencies (
  code text primary key, name text not null, symbol text not null,
  decimals int not null default 0 check (decimals between 0 and 4),
  per_usd numeric not null check (per_usd > 0),   -- units of local currency per 1 USD
  updated_at timestamptz not null default now()
);
create table if not exists public.services (
  id text primary key, country text not null references public.countries(code),
  name text not null, short text not null, field_label text not null,
  color text not null, text_color text not null default '#ffffff', badge text not null, sort int not null default 0
);
create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null, phone text,
  country text not null references public.countries(code),
  currency text not null references public.currencies(code),
  created_at timestamptz not null default now()
);

-- Seed data. Rates are DEMO values: refresh them before any presentation (see README).
insert into public.currencies (code, name, symbol, decimals, per_usd) values
  ('UGX','Ugandan shilling','USh',0,3600), ('KES','Kenyan shilling','KSh',0,130)
on conflict (code) do nothing;
insert into public.countries (code, name, currency, dial) values
  ('UG','Uganda','UGX','+256'), ('KE','Kenya','KES','+254')
on conflict (code) do nothing;
insert into public.services (id, country, name, short, field_label, color, text_color, badge, sort) values
  ('ug-mtn','UG','MTN airtime','MTN','Phone number','#F2C230','#2B2300','MTN',1),
  ('ug-airtel','UG','Airtel airtime','Airtel','Phone number','#D62F2F','#ffffff','Ai',2),
  ('ug-umeme','UG','UMEME electricity','UMEME','Meter number','#2A6FDB','#ffffff','U',3),
  ('ug-nwsc','UG','NWSC water','Water','Water account number','#1E9BD7','#ffffff','W',4),
  ('ug-momo','UG','Send to mobile money','Send','Phone number','#0B5F58','#ffffff','S',5),
  ('ke-safaricom','KE','Safaricom airtime','Safaricom','Phone number','#3FA535','#ffffff','Sf',1),
  ('ke-airtel','KE','Airtel airtime','Airtel','Phone number','#D62F2F','#ffffff','Ai',2),
  ('ke-kplc','KE','Kenya Power tokens','Power','Meter number','#F2A900','#2B1D00','KP',3),
  ('ke-water','KE','Water bill','Water','Account number','#1E9BD7','#ffffff','W',4),
  ('ke-mpesa','KE','Send to M-Pesa','Send','Phone number','#0B5F58','#ffffff','M',5)
on conflict (id) do nothing;

-- Transactions become currency-aware (existing rows were UGX).
do $$ begin
  if exists (select 1 from information_schema.columns
             where table_schema='public' and table_name='transactions' and column_name='amount_ugx') then
    alter table public.transactions rename column amount_ugx to amount_local;
  end if;
end $$;
alter table public.transactions add column if not exists currency text not null default 'UGX';
alter table public.transactions add column if not exists idempotency_key uuid;
create unique index if not exists tx_idem on public.transactions (user_id, idempotency_key) where idempotency_key is not null;

-- Row-level security: reference data is public-read (the sign-up form needs it); profiles are private.
alter table public.countries enable row level security;
alter table public.currencies enable row level security;
alter table public.services enable row level security;
alter table public.profiles enable row level security;
drop policy if exists "read countries" on public.countries;
create policy "read countries" on public.countries for select to anon, authenticated using (true);
drop policy if exists "read currencies" on public.currencies;
create policy "read currencies" on public.currencies for select to anon, authenticated using (true);
drop policy if exists "read services" on public.services;
create policy "read services" on public.services for select to anon, authenticated using (true);
drop policy if exists "read own profile" on public.profiles;
create policy "read own profile" on public.profiles for select to authenticated using (user_id = auth.uid());

-- New users: profile + wallet, built from sign-up metadata, validated server-side.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_country text := upper(coalesce(new.raw_user_meta_data->>'country','UG')); v_cur text; v_name text;
begin
  select currency into v_cur from public.countries where code = v_country;
  if v_cur is null then raise exception 'Unsupported country'; end if;
  v_name := left(trim(coalesce(new.raw_user_meta_data->>'full_name','')), 80);
  insert into public.profiles (user_id, full_name, phone, country, currency)
  values (new.id, coalesce(nullif(v_name,''), split_part(new.email,'@',1)), left(new.raw_user_meta_data->>'phone', 20), v_country, v_cur);
  insert into public.wallets (user_id) values (new.id) on conflict do nothing;
  return new;
end $$;

-- Backfill accounts created before this migration (default Uganda).
insert into public.profiles (user_id, full_name, country, currency)
select id, split_part(email,'@',1), 'UG', 'UGX' from auth.users on conflict do nothing;

-- Payments: server sets the price; the idempotency key makes retries safe (no double charge).
drop function if exists public.pay_service(text, text, numeric);
create or replace function public.pay_service(p_service_id text, p_recipient text, p_amount_local numeric, p_idem uuid default null)
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_p public.profiles; v_s public.services; v_c public.currencies; v_t public.transactions;
  v_fee_rate numeric; v_usd numeric; v_fee numeric; v_total numeric;
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

  update public.wallets set balance_usd = balance_usd - v_total where user_id = v_uid and balance_usd >= v_total;
  if not found then raise exception 'Not enough balance for this payment'; end if;

  insert into public.transactions (user_id, kind, service, recipient, amount_local, currency, amount_usd, fee_usd, rate, idempotency_key)
  values (v_uid, 'payment', v_s.name, trim(p_recipient), p_amount_local, v_c.code, v_total, v_fee, v_c.per_usd, p_idem);

  return json_build_object('total_usd', v_total, 'fee_usd', v_fee, 'rate', v_c.per_usd,
    'amount_local', p_amount_local, 'currency', v_c.code, 'service', v_s.name);
end $$;

revoke all on function public.pay_service(text, text, numeric, uuid) from public, anon;
grant execute on function public.pay_service(text, text, numeric, uuid) to authenticated;
