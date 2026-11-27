# Imara

A dollar wallet for East Africa: hold a stable balance in USD, pay everyday bills in local currency.
**Status: working prototype (test mode). All money is fake and nothing reaches real providers.
Imara is not a licensed payment service.**

## Structure
```
supabase/migrations/   0001_init, 0002_multicurrency, 0003_rates_and_limits, 0004_service_categories   (run in order)
supabase/functions/    update-rates (daily FX job)
supabase/tests/        database integration tests (run.sh)
web/                   static front end, no build step
  index.html  css/styles.css
  js/config.js         Supabase URL + publishable key
  js/api.js            all backend calls
  js/format.js         pure helpers (unit tested)
  js/main.js           UI controller
  tests/               node --test
  _headers             security headers (Netlify)
```

## Run it
1. Supabase > SQL Editor: run `0001_init.sql`, `0002_multicurrency.sql`, `0003_rates_and_limits.sql`, then `0004_service_categories.sql`.
2. Authentication > Providers > Email: turn "Confirm email" off for development only.
3. Test: `npm test` (unit tests). `npm run test:db` applies all migrations to a scratch Postgres and runs 32 checks
   (needs psql access through PG* variables). CI runs both on every push.
4. Local preview: `npx serve web`, or drag the `web` folder onto app.netlify.com/drop.

## Design decisions
- **Security boundary is the database.** Row Level Security lets users read only their own rows.
  Nobody can write balances from the browser; money moves only through `security definer`
  functions (`test_deposit`, `pay_service`) that set prices server-side.
- **Idempotent payments.** The client sends a UUID per attempt; a retry returns the original
  result instead of charging twice.
- **Balances are USD; payments are local.** Each user's currency comes from their country at
  sign-up and cannot be edited from the client.
- **Publishable key in the client is intended.** The secret/service-role key must never be committed.

## Limits and tiers
Each user has a KYC tier (`profiles.kyc_tier`). Tier 0 (Basic): $100 spent per rolling 24 hours, $200 balance cap.
Tier 1 (Verified): $1,000 and $5,000. Edit `kyc_tiers` to change them. For a demo, lift one account:
`update profiles set kyc_tier = 1 where user_id = '<id>';` (users cannot change their own tier).

## Live exchange rates
Rates come from the free ExchangeRate-API open endpoint (once a day, attribution required: it is credited in the app).
`set_rate()` is callable only by the service role and rejects moves larger than `settings.max_rate_move` (5%),
so a bad feed cannot reprice payments. Every change is kept in `rate_history`.
1. Edge Functions > create `update-rates`, paste `supabase/functions/update-rates/index.ts`, and turn **off** "Verify JWT".
2. Project Settings > Edge Functions > Secrets: add `CRON_SECRET` (a long random string).
3. Try it once: `curl -X POST https://<ref>.supabase.co/functions/v1/update-rates -H "x-cron-secret: <secret>"`
4. Enable the `pg_cron` and `pg_net` extensions, then schedule it:
```sql
select cron.schedule('update-rates-daily', '0 6 * * *', $$
  select net.http_post(url := 'https://<ref>.supabase.co/functions/v1/update-rates',
                       headers := jsonb_build_object('x-cron-secret', '<secret>')); $$);
```
(In production keep the secret in Supabase Vault, not in the job text.) If the demo seed rate is more than 5% from
the live rate, the first sync is refused on purpose: correct it once with `update currencies set per_usd = <rate> where code = '<code>';`.

## Services and categories
Four categories: Airtime & data, Bills, Send money, Online & subscriptions (Netflix, Spotify, YouTube Premium,
Google Play, Apple). Each service has an input type (phone, email, or account number) that the server validates.
**These are catalogue entries in test mode.** Real fulfilment needs a partner per category: an airtime and bill
aggregator, mobile-money payout rails, and a gift-card or top-up provider for online services. Check coverage,
fees and licensing for Kenya and Uganda before promising any service to users.

## Add a country
```sql
insert into currencies (code,name,symbol,decimals,per_usd) values ('TZS','Tanzanian shilling','TSh',0,2500);
insert into countries (code,name,currency,dial) values ('TZ','Tanzania','TZS','+255');
insert into services (id,country,name,short,field_label,color,badge,sort)
values ('tz-vodacom','TZ','Vodacom airtime','Vodacom','Phone number','#E60000','Vo',1);
```
Rates in `currencies.per_usd` are demo values: update them before presenting
(Kenya: CBK publishes the daily rate).

## Before real money (not built yet)
Licensing (Kenya: CBK/CMA VASP licence, or a licensed partner), KYC, wallet/custody provider,
double-entry ledger with daily reconciliation, limits and fraud checks, audit logging, monitoring,
live FX feed, terms and privacy policy, independent security review.
