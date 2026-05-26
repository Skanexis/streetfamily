-- Gram-based catalog pricing with a custom weight selectable in 25 g increments.
alter table public.order_items
  add column if not exists gram_amount integer check (gram_amount is null or gram_amount > 0);

update public.product_variants
set
  label = unit_amount || ' g',
  price = round(price / 5) * 5
where unit_amount is not null;

alter table public.product_variants
  drop constraint if exists product_variants_gram_rounded_price;
alter table public.product_variants
  add constraint product_variants_gram_rounded_price
  check (unit_amount is null or mod(price, 5) = 0);

update public.order_items item
set
  gram_amount = coalesce(item.gram_amount, variant.unit_amount),
  variant_label = variant.unit_amount || ' g'
from public.product_variants variant
where item.variant_id = variant.id
  and variant.unit_amount is not null;

-- Existing products did not ask admins for a 25 g reference price. Initialize it
-- from half of the 50 g price; it remains editable from the administration panel.
insert into public.product_variants (product_id, label, price, sort_order, unit_amount, token_award)
select product.id, '25 g', round((base.price / 2) / 5) * 5, 25, 25, 0
from public.products product
join public.product_variants base on base.product_id = product.id and base.unit_amount = 50
where not exists (
  select 1 from public.product_variants existing
  where existing.product_id = product.id and existing.unit_amount = 25
);

insert into public.inventory_status (variant_id)
select id from public.product_variants where unit_amount = 25
on conflict (variant_id) do update set available = true, updated_at = now();

create or replace function public.calculate_product_gram_price(p_product_id uuid, p_grams integer)
returns numeric language plpgsql security definer set search_path = public as $$
declare
  v_lower public.product_variants%rowtype;
  v_upper public.product_variants%rowtype;
begin
  if p_grams < 50 or p_grams % 25 <> 0 then raise exception 'GRAM_AMOUNT_INVALID'; end if;

  select variant.* into v_lower
  from public.product_variants variant
  join public.inventory_status stock on stock.variant_id = variant.id and stock.available
  join public.products product on product.id = variant.product_id and product.published
  where variant.product_id = p_product_id and variant.unit_amount <= p_grams and variant.unit_amount >= 50
  order by variant.unit_amount desc
  limit 1;

  select variant.* into v_upper
  from public.product_variants variant
  join public.inventory_status stock on stock.variant_id = variant.id and stock.available
  join public.products product on product.id = variant.product_id and product.published
  where variant.product_id = p_product_id and variant.unit_amount >= p_grams
  order by variant.unit_amount
  limit 1;

  if v_lower.id is null or v_upper.id is null then raise exception 'ITEM_UNAVAILABLE'; end if;
  if v_lower.unit_amount = v_upper.unit_amount then return round(v_lower.price / 5) * 5; end if;

  return round((
    v_lower.price + (p_grams - v_lower.unit_amount)::numeric /
      (v_upper.unit_amount - v_lower.unit_amount) * (v_upper.price - v_lower.price)
  ) / 5) * 5;
end $$;

create or replace function public.submit_test_order_internal(
  p_user_id uuid, p_items jsonb, p_scenario_type text, p_city text default '',
  p_street text default '', p_tokens_to_reserve integer default 0
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_order uuid := gen_random_uuid();
  v_display text := '#DEMO-' || upper(substr(replace(v_order::text, '-', ''), 1, 8));
  v_subtotal numeric(10,2);
  v_surcharge numeric(10,2) := 0;
  v_total numeric(10,2);
  v_units integer;
  v_expected_tokens integer;
  v_expected_xp integer;
  v_wallet public.wallet_balances%rowtype;
  v_valid_count integer;
  v_area public.service_areas%rowtype;
  v_xp_multiplier numeric := coalesce((select (value ->> 'xp_multiplier')::numeric from public.app_settings where key = 'order_rewards'), 0.5);
begin
  if not exists (
    select 1 from public.profiles p join public.staging_allowlist a on a.telegram_subject = p.telegram_subject
    where p.id = p_user_id and a.enabled and not p.blocked
  ) then raise exception 'Staging access denied'; end if;
  if not exists (select 1 from public.orders where user_id = p_user_id) and not exists (
    select 1 from public.kyc_cases where user_id = p_user_id and status = 'approved'
  ) then raise exception 'KYC_REQUIRED_FIRST_ORDER'; end if;
  if p_scenario_type not in ('meetup', 'delivery_zone', 'delivery_italia') then raise exception 'SCENARIO_INVALID'; end if;
  if jsonb_array_length(p_items) = 0 then raise exception 'CART_EMPTY'; end if;
  if exists (
    select 1 from jsonb_array_elements(p_items) item
    where (item ->> 'grams') is null
      or (item ->> 'grams')::integer < 50
      or (item ->> 'grams')::integer % 25 <> 0
  ) then raise exception 'GRAM_AMOUNT_INVALID'; end if;

  select count(*), sum(public.calculate_product_gram_price(product.id, (item ->> 'grams')::integer)),
    sum((item ->> 'grams')::integer)
  into v_valid_count, v_subtotal, v_units
  from jsonb_array_elements(p_items) item
  join public.products product on product.id = (item ->> 'product_id')::uuid and product.published;
  if v_valid_count <> jsonb_array_length(p_items) or v_subtotal is null then raise exception 'ITEM_UNAVAILABLE'; end if;
  if v_units > 1000 then raise exception 'MAXIMUM_UNITS_SUPPORTED:1000'; end if;

  if p_scenario_type = 'delivery_italia' then
    select * into v_area from public.service_areas where scenario_type = 'delivery_italia' and active limit 1;
    if length(trim(p_city)) < 2 or length(trim(p_street)) < 2 then raise exception 'CITY_STREET_REQUIRED'; end if;
  else
    select * into v_area from public.service_areas
    where scenario_type = p_scenario_type and lower(city) = lower(trim(p_city)) and active;
    if not found then raise exception 'CITY_NOT_AVAILABLE'; end if;
    if v_area.requires_street and length(trim(p_street)) < 2 then raise exception 'STREET_REQUIRED'; end if;
  end if;
  if v_units < v_area.minimum_units then raise exception 'MINIMUM_UNITS_REQUIRED:%', v_area.minimum_units; end if;
  if p_scenario_type = 'delivery_zone' then v_surcharge := floor(v_units / 100.0) * 10; end if;

  select * into v_wallet from public.wallet_balances where user_id = p_user_id for update;
  if p_tokens_to_reserve < 0 or p_tokens_to_reserve > v_wallet.points or p_tokens_to_reserve > floor(v_subtotal + v_surcharge)
    then raise exception 'TOKEN_RESERVE_INVALID'; end if;
  if v_wallet.points >= 100 and p_tokens_to_reserve = 0 then raise exception 'TOKEN_SPEND_REQUIRED'; end if;

  v_total := greatest(v_subtotal + v_surcharge - p_tokens_to_reserve, 0);
  select tokens_awarded into v_expected_tokens from public.token_reward_tiers
  where minimum_units <= v_units order by minimum_units desc limit 1;
  if v_expected_tokens is null then raise exception 'MINIMUM_UNITS_REQUIRED:50'; end if;
  v_expected_xp := floor(v_subtotal * v_xp_multiplier);
  insert into public.orders (
    id, display_id, user_id, fulfillment_method, scenario_type, scenario_city, scenario_street,
    location_note, total_units, tokens_reserved, total, simulated_subtotal, simulated_surcharge,
    simulated_token_credit, simulated_total, points_awarded, xp_awarded
  ) values (
    v_order, v_display, p_user_id, case when p_scenario_type = 'meetup' then 'meetup' else 'delivery' end,
    p_scenario_type, trim(p_city), trim(p_street), 'submitted', v_units,
    p_tokens_to_reserve, v_total, v_subtotal, v_surcharge, p_tokens_to_reserve, v_total, v_expected_tokens, v_expected_xp
  );
  insert into public.order_items (order_id, variant_id, name_snapshot, variant_label, unit_price, quantity, gram_amount)
  select v_order, anchor.id, product.name, (item ->> 'grams') || ' g',
    public.calculate_product_gram_price(product.id, (item ->> 'grams')::integer), 1, (item ->> 'grams')::integer
  from jsonb_array_elements(p_items) item
  join public.products product on product.id = (item ->> 'product_id')::uuid
  join lateral (
    select variant.id
    from public.product_variants variant
    join public.inventory_status stock on stock.variant_id = variant.id and stock.available
    where variant.product_id = product.id
      and variant.unit_amount <= (item ->> 'grams')::integer
      and variant.unit_amount >= 50
    order by variant.unit_amount desc
    limit 1
  ) anchor on true;
  insert into public.order_status_history (order_id, status, changed_by, note)
  values (v_order, 'submitted', p_user_id, 'submitted');
  if p_tokens_to_reserve > 0 then
    update public.wallet_balances set points = points - p_tokens_to_reserve, updated_at = now()
      where user_id = p_user_id returning * into v_wallet;
    insert into public.loyalty_ledger (user_id, reason, points_delta, xp_delta, reference_type, reference_id)
    values (p_user_id, 'Gettoni riservati ' || v_display, -p_tokens_to_reserve, 0, 'order_reserve', v_order);
  end if;
  return jsonb_build_object(
    'order_id', v_order, 'display_id', v_display, 'simulated_subtotal', v_subtotal,
    'simulated_surcharge', v_surcharge, 'simulated_token_credit', p_tokens_to_reserve,
    'simulated_total', v_total, 'total_units', v_units, 'tokens_reserved', p_tokens_to_reserve,
    'tokens_on_complete', v_expected_tokens, 'xp_on_complete', v_expected_xp,
    'balance', v_wallet.points,
    'disclaimer', 'Ambiente dimostrativo: nessun pagamento, scambio o gestione reale degli ordini.'
  );
end $$;

create or replace function public.admin_create_demo_product(
  p_name text, p_category_id uuid, p_prices jsonb, p_announce boolean default false
)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_product_id uuid;
  v_slug text;
  v_name text := trim(p_name);
  v_required integer[] := array[25,50,100,300,500,1000];
  v_unit integer;
  v_price numeric;
begin
  if not public.is_admin() then raise exception 'Accesso amministratore richiesto'; end if;
  if char_length(v_name) = 0 then raise exception 'Prodotto non valido'; end if;
  foreach v_unit in array v_required loop
    v_price := (p_prices ->> v_unit::text)::numeric;
    if v_price is null or v_price < 0 or mod(v_price, 5) <> 0 then raise exception 'Prezzo pacchetto non valido: %', v_unit; end if;
  end loop;
  v_slug := 'demo-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  insert into public.products (category_id, slug, name, description, badge, featured, published, rating)
  values (p_category_id, v_slug, v_name, 'Articolo dimostrativo. Nessuna vendita o consegna reale.', 'NEW', false, false, 0)
  returning id into v_product_id;
  foreach v_unit in array v_required loop
    insert into public.product_variants (product_id, label, price, sort_order, unit_amount, token_award)
    values (
      v_product_id, v_unit || ' g', (p_prices ->> v_unit::text)::numeric, v_unit, v_unit,
      coalesce((select tokens_awarded from public.token_reward_tiers where minimum_units <= v_unit order by minimum_units desc limit 1), 0)
    );
  end loop;
  insert into public.inventory_status (variant_id)
  select id from public.product_variants where product_id = v_product_id;
  if p_announce then
    insert into public.broadcasts (kind, title, message, product_id, status, created_by)
    values ('product_new', 'Nuovo articolo dimostrativo: ' || v_name, 'Nuova voce aggiunta al catalogo dimostrativo.', v_product_id, 'draft', auth.uid());
  end if;
  return v_product_id;
end $$;

grant execute on function public.submit_test_order_internal(uuid, jsonb, text, text, text, integer) to service_role;
revoke execute on function public.submit_test_order_internal(uuid, jsonb, text, text, text, integer) from authenticated, public, anon;
revoke execute on function public.calculate_product_gram_price(uuid, integer) from authenticated, public, anon;
