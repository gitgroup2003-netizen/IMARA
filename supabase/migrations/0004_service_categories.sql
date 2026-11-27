-- 0004: service categories (airtime and data, bills, send money, online and subscriptions),
-- more services per country, and recipient validation by type. Run AFTER 0003. TEST MODE.

alter table public.services add column if not exists category text not null default 'bills'
  check (category in ('airtime','bills','send','online'));
alter table public.services add column if not exists input_kind text not null default 'number'
  check (input_kind in ('phone','number','email'));

update public.services set category = 'airtime', input_kind = 'phone' where id in ('ug-mtn','ug-airtel','ke-safaricom','ke-airtel');
update public.services set category = 'bills',   input_kind = 'number' where id in ('ug-umeme','ug-nwsc','ke-kplc','ke-water');
update public.services set category = 'send',    input_kind = 'phone' where id in ('ug-momo','ke-mpesa');

-- Operator-specific services.
insert into public.services (id, country, name, short, field_label, color, text_color, badge, sort, category, input_kind) values
  ('ug-mtn-data','UG','MTN data bundle','MTN data','Phone number','#F2C230','#2B2300','MD',7,'airtime','phone'),
  ('ug-airtel-data','UG','Airtel data bundle','Airtel data','Phone number','#D62F2F','#ffffff','AD',8,'airtime','phone'),
  ('ug-airtelmoney','UG','Send to Airtel Money','Airtel Money','Phone number','#D62F2F','#ffffff','AM',9,'send','phone'),
  ('ke-safaricom-data','KE','Safaricom data bundle','Safaricom data','Phone number','#3FA535','#ffffff','SD',7,'airtime','phone'),
  ('ke-airtel-data','KE','Airtel data bundle','Airtel data','Phone number','#D62F2F','#ffffff','AD',8,'airtime','phone'),
  ('ke-airtelmoney','KE','Send to Airtel Money','Airtel Money','Phone number','#D62F2F','#ffffff','AM',9,'send','phone')
on conflict (id) do nothing;

-- Brands offered in every country.
insert into public.services (id, country, name, short, field_label, color, text_color, badge, sort, category, input_kind)
select lower(c.code) || '-' || s.slug, c.code, s.name, s.short, s.label, s.color, s.tc, s.badge, s.sort, s.cat, s.kind
from public.countries c cross join (values
  ('dstv','DStv','DStv','Smartcard number','#0072CE','#ffffff','DS',10,'bills','number'),
  ('gotv','GOtv','GOtv','IUC number','#7AC143','#0B1F10','GO',11,'bills','number'),
  ('netflix','Netflix','Netflix','Netflix account email','#E50914','#ffffff','N',12,'online','email'),
  ('spotify','Spotify','Spotify','Spotify account email','#1DB954','#06240F','Sp',13,'online','email'),
  ('youtube','YouTube Premium','YouTube','Google account email','#FF0000','#ffffff','YT',14,'online','email'),
  ('googleplay','Google Play credit','Google Play','Google account email','#2F80ED','#ffffff','GP',15,'online','email'),
  ('apple','Apple gift card','Apple','Apple ID email','#1D1D1F','#ffffff','Ap',16,'online','email')
) as s(slug, name, short, label, color, tc, badge, sort, cat, kind)
on conflict (id) do nothing;

-- Payments now validate the recipient by service type (phone, email, or account number).
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
  if v_s.input_kind = 'phone' then
    if length(regexp_replace(coalesce(p_recipient, ''), '[^0-9]', '', 'g')) not between 9 and 15 then
      raise exception 'Enter a valid phone number'; end if;
  elsif v_s.input_kind = 'email' then
    if coalesce(p_recipient, '') !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
      raise exception 'Enter a valid email address'; end if;
  elsif coalesce(length(trim(p_recipient)), 0) < 6 then
    raise exception 'Enter a valid meter or account number';
  end if;

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
