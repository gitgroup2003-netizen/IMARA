\set A '''aaaaaaaa-0000-0000-0000-000000000001'''
\set B '''aaaaaaaa-0000-0000-0000-000000000002'''
\set L '''aaaaaaaa-0000-0000-0000-000000000009'''

create schema t; grant usage on schema t to anon, authenticated, service_role;
create function t.eq(label text, got text, want text) returns void language plpgsql as $$
begin if got is distinct from want then raise exception 'FAIL %: got %, wanted %', label, got, want; end if;
  raise notice 'ok  %', label; end $$;
create function t.expect_fail(q text, frag text) returns void language plpgsql as $$
begin
  begin execute q;
  exception when others then
    if sqlerrm ilike '%' || frag || '%' then raise notice 'ok  fails: %', frag; return; end if;
    raise exception 'FAIL: "%" raised "%" (wanted "%")', q, sqlerrm, frag;
  end;
  raise exception 'FAIL: expected "%" to fail with "%"', q, frag;
end $$;
grant execute on all functions in schema t to anon, authenticated, service_role;

-- Sign-up and migration
insert into auth.users (id, email, raw_user_meta_data) values
  (:A, 'a@x.com', '{"full_name":"Amina Wanjiru","country":"KE","phone":"+254700000001"}'),
  (:B, 'b@x.com', '{"full_name":"Bob","country":"UG"}');
select t.eq('KE user gets KES', (select currency from public.profiles where user_id = :A), 'KES');
select t.eq('UG user gets UGX', (select currency from public.profiles where user_id = :B), 'UGX');
select t.eq('wallet created', (select count(*) from public.wallets where user_id = :A)::text, '1');
select t.eq('legacy user backfilled', (select country from public.profiles where user_id = :L), 'UG');
select t.eq('legacy amount kept', (select amount_local::text from public.transactions where user_id = :L), '36000');
select t.eq('legacy currency', (select currency from public.transactions where user_id = :L), 'UGX');
select t.expect_fail($q$insert into auth.users (email, raw_user_meta_data) values ('z@x.com','{"country":"ZZ"}')$q$, 'Unsupported country');

-- As user A (Kenya)
set role authenticated; set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000001';
select public.test_deposit(10);
select t.eq('deposit credited', (select balance_usd::text from public.wallets), '10.00');
update public.wallets set balance_usd = 99999;
select t.eq('cannot edit own balance', (select balance_usd::text from public.wallets), '10.00');
update public.profiles set kyc_tier = 1;
select t.eq('cannot raise own tier', (select kyc_tier::text from public.profiles), '0');
select t.expect_fail($q$insert into public.transactions (user_id, kind, amount_usd) values ('aaaaaaaa-0000-0000-0000-000000000001','deposit',1)$q$, 'row-level security');

select public.pay_service('ke-safaricom', '0712345678', 650, '11111111-1111-1111-1111-111111111111');
select t.eq('650 KES = $5.00 + 1% fee', (select balance_usd::text from public.wallets), '4.95');
select public.pay_service('ke-safaricom', '0712345678', 650, '11111111-1111-1111-1111-111111111111');
select t.eq('retry does not double charge', (select balance_usd::text from public.wallets), '4.95');
select t.eq('one payment recorded', (select count(*) from public.transactions where kind = 'payment')::text, '1');

select t.expect_fail($q$select public.pay_service('ke-safaricom','0712345678',1300)$q$, 'Not enough balance');
select t.expect_fail($q$select public.pay_service('ug-mtn','0712345678',650)$q$, 'not available in your country');
select t.expect_fail($q$select public.pay_service('ke-safaricom','0712345678',10)$q$, 'too small');
select t.expect_fail($q$select public.pay_service('ke-safaricom','123',650)$q$, 'valid phone');

select public.test_deposit(100);
select t.expect_fail($q$select public.test_deposit(100)$q$, 'Balance cap');
select public.pay_service('ke-safaricom', '0712345678', 12000);
select t.eq('spent in 24h tracked', (public.my_limits()->>'spent_24h_usd'), '98.28');
select t.expect_fail($q$select public.pay_service('ke-safaricom','0712345678',1300)$q$, 'Daily limit');

-- As user B (Uganda): isolation
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000002';
select t.eq('B sees no one else''s transactions', (select count(*) from public.transactions where user_id <> auth.uid())::text, '0');
select t.eq('B sees no one else''s wallet', (select count(*) from public.wallets where user_id <> auth.uid())::text, '0');
select public.test_deposit(10);
select public.pay_service('ug-mtn', '0771234567', 3600);
select t.eq('3600 UGX = $1.00 + fee', (select balance_usd::text from public.wallets), '8.99');

-- Rates: only the service role, and never a wild jump
select t.expect_fail($q$select public.set_rate('KES',131,'test')$q$, 'permission denied');
reset role; set role service_role;
select public.set_rate('KES', 131, 'test');
reset role;
select t.eq('rate applied', (select per_usd::text from public.currencies where code = 'KES'), '131');
set role service_role;
select t.expect_fail($q$select public.set_rate('KES',200,'test')$q$, 'too large');
reset role;
select t.eq('history kept (seed + 1)', (select count(*) from public.rate_history where currency = 'KES')::text, '2');
