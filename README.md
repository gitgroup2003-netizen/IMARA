# Imara

A dollar wallet for East Africa: hold a stable balance in USD, pay everyday bills in local currency.
**Status: working prototype (test mode). All money is fake and nothing reaches real providers.
Imara is not a licensed payment service.**

## Structure
```
supabase/migrations/   0001_init.sql, 0002_multicurrency.sql   (run in order)
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
1. Supabase > SQL Editor: run `0001_init.sql`, then `0002_multicurrency.sql`.
2. Authentication > Providers > Email: turn "Confirm email" off for development only.
3. Test: `npm test` (Node 18+).
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
