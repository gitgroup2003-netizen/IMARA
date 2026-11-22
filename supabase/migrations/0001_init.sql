-- IMARA: step 1 database (TEST MODE, fake money only)
-- Paste this whole file into Supabase > SQL Editor > New query > Run.

create table if not exists public.settings (
  key text primary key,
  value numeric not null
);
insert into public.settings (key, value) values ('ugx_per_usd', 3700), ('fee_rate', 0.01)
on conflict (key) do nothing;

create table if not exists public.wallets (
  user_id uuid primary key references auth.users(id) on delete cascade,
  balance_usd numeric(14,2) not null default 0 check (balance_usd >= 0),
  created_at timestamptz not null default now()
);

create table if not exists public.transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null,                -- 'deposit' or 'payment'
  service text,
  recipient text,
  amount_ugx numeric,
  amount_usd numeric(14,2) not null,
  fee_usd numeric(14,2) not null default 0,
  rate numeric,
  status text not null default 'test_success',
  created_at timestamptz not null default now()
);
create index if not exists tx_user_time on public.transactions (user_id, created_at desc);

-- Security: users can only READ their own rows. No one can write balances from the app.
alter table public.settings enable row level security;
alter table public.wallets enable row level security;
alter table public.transactions enable row level security;

drop policy if exists "read settings" on public.settings;
create policy "read settings" on public.settings for select to authenticated using (true);
drop policy if exists "read own wallet" on public.wallets;
create policy "read own wallet" on public.wallets for select to authenticated using (user_id = auth.uid());
drop policy if exists "read own transactions" on public.transactions;
create policy "read own transactions" on public.transactions for select to authenticated using (user_id = auth.uid());

-- Every new sign-up gets an empty wallet.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.wallets (user_id) values (new.id) on conflict do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute function public.handle_new_user();

-- Make a wallet for anyone who already signed up.
insert into public.wallets (user_id) select id from auth.users on conflict do nothing;

-- TEST ONLY: add fake dollars (max 100 per tap).
create or replace function public.test_deposit(p_amount numeric)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 100 then
    raise exception 'Test deposits must be between 1 and 100 USD';
  end if;
  update public.wallets set balance_usd = balance_usd + p_amount where user_id = v_uid;
  insert into public.transactions (user_id, kind, amount_usd, service)
  values (v_uid, 'deposit', p_amount, 'Test deposit');
end $$;

-- Pay a service in UGX from the USD balance. The server sets the price, never the app.
create or replace function public.pay_service(p_service text, p_recipient text, p_amount_ugx numeric)
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_rate numeric; v_fee_rate numeric;
  v_usd numeric; v_fee numeric; v_total numeric;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;
  if p_amount_ugx is null or p_amount_ugx < 1000 then raise exception 'Minimum payment is 1,000 UGX'; end if;
  if coalesce(length(trim(p_recipient)), 0) < 6 then raise exception 'Enter a valid phone or meter number'; end if;

  select value into v_rate from public.settings where key = 'ugx_per_usd';
  select value into v_fee_rate from public.settings where key = 'fee_rate';
  v_usd := round(p_amount_ugx / v_rate, 2);
  v_fee := round(v_usd * v_fee_rate, 2);
  v_total := v_usd + v_fee;

  update public.wallets set balance_usd = balance_usd - v_total
  where user_id = v_uid and balance_usd >= v_total;
  if not found then raise exception 'Not enough balance for this payment'; end if;

  insert into public.transactions (user_id, kind, service, recipient, amount_ugx, amount_usd, fee_usd, rate)
  values (v_uid, 'payment', p_service, trim(p_recipient), p_amount_ugx, v_total, v_fee, v_rate);

  return json_build_object('total_usd', v_total, 'fee_usd', v_fee, 'rate', v_rate, 'amount_ugx', p_amount_ugx);
end $$;

revoke all on function public.test_deposit(numeric) from public, anon;
revoke all on function public.pay_service(text, text, numeric) from public, anon;
grant execute on function public.test_deposit(numeric) to authenticated;
grant execute on function public.pay_service(text, text, numeric) to authenticated;
