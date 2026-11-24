-- An account that existed BEFORE migration 0002 (upgrade-path test).
insert into auth.users (id, email) values ('aaaaaaaa-0000-0000-0000-000000000009', 'legacy@x.com');
insert into public.transactions (user_id, kind, service, recipient, amount_ugx, amount_usd, fee_usd, rate)
values ('aaaaaaaa-0000-0000-0000-000000000009', 'payment', 'MTN airtime', '0771234567', 36000, 10.10, 0.10, 3600);
