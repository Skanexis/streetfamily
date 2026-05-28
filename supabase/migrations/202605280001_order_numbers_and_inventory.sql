-- Use compact sequential order numbers and add product-level warehouse stock.
create sequence if not exists public.order_display_seq;

do $$
declare
  v_max integer;
begin
  select coalesce(max(display_id::integer), 0)
  into v_max
  from public.orders
  where display_id ~ '^[0-9]+$';

  perform setval('public.order_display_seq', greatest(v_max, 1), v_max > 0);
end;
$$;

create table if not exists public.product_inventory (
  product_id uuid primary key references public.products(id) on delete cascade,
  stock_quantity integer check (stock_quantity is null or stock_quantity >= 0),
  notify_threshold_quantity integer not null default 500 check (notify_threshold_quantity >= 0),
  low_stock_alerted_at timestamptz,
  updated_at timestamptz not null default now()
);

alter table public.orders
  add column if not exists stock_deducted boolean not null default false;

alter table public.product_inventory
  add column if not exists notify_threshold_quantity integer not null default 500 check (notify_threshold_quantity >= 0),
  add column if not exists low_stock_alerted_at timestamptz;

create table if not exists public.low_stock_notifications (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  stock_quantity integer not null check (stock_quantity >= 0),
  threshold_quantity integer not null check (threshold_quantity >= 0),
  status text not null default 'pending' check (status in ('pending', 'processing', 'sent', 'failed')),
  telegram_sent integer not null default 0 check (telegram_sent >= 0),
  telegram_failed integer not null default 0 check (telegram_failed >= 0),
  error text,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);

insert into public.product_inventory (product_id, stock_quantity)
select id, null
from public.products
on conflict (product_id) do nothing;

alter table public.product_inventory enable row level security;
alter table public.low_stock_notifications enable row level security;

drop policy if exists member_product_inventory_read on public.product_inventory;
create policy member_product_inventory_read on public.product_inventory
  for select using (public.is_allowed() or public.is_admin());

drop policy if exists admin_product_inventory_write on public.product_inventory;
create policy admin_product_inventory_write on public.product_inventory
  for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists admin_low_stock_notifications_read on public.low_stock_notifications;
create policy admin_low_stock_notifications_read on public.low_stock_notifications
  for select using (public.is_admin());

drop trigger if exists product_inventory_touch on public.product_inventory;
create trigger product_inventory_touch
  before update on public.product_inventory
  for each row execute function public.touch_updated_at();

drop trigger if exists audit_product_inventory on public.product_inventory;
create trigger audit_product_inventory
  after insert or update or delete on public.product_inventory
  for each row execute function public.audit_admin_change();

drop trigger if exists audit_low_stock_notifications on public.low_stock_notifications;
create trigger audit_low_stock_notifications
  after insert or update or delete on public.low_stock_notifications
  for each row execute function public.audit_admin_change();

create or replace function public.next_order_display_id()
returns text language sql security definer set search_path = public as $$
  select lpad(nextval('public.order_display_seq')::text, 3, '0')
$$;

create or replace function public.calculate_product_gram_price(p_product_id uuid, p_grams integer)
returns numeric language plpgsql security definer set search_path = public as $$
declare
  v_lower public.product_variants%rowtype;
  v_upper public.product_variants%rowtype;
begin
  if p_grams < 25 or p_grams % 25 <> 0 then raise exception 'GRAM_AMOUNT_INVALID'; end if;
  if exists (
    select 1
    from public.product_inventory inventory
    where inventory.product_id = p_product_id
      and inventory.stock_quantity is not null
      and inventory.stock_quantity < p_grams
  ) then raise exception 'ITEM_UNAVAILABLE'; end if;

  select variant.* into v_lower
  from public.product_variants variant
  join public.inventory_status stock on stock.variant_id = variant.id and stock.available
  join public.products product on product.id = variant.product_id and product.published
  where variant.product_id = p_product_id and variant.unit_amount <= p_grams and variant.unit_amount >= 25
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
  v_display text := public.next_order_display_id();
  v_subtotal numeric(10,2);
  v_surcharge numeric(10,2) := 0;
  v_total numeric(10,2);
  v_units integer;
  v_expected_tokens integer;
  v_expected_xp integer;
  v_wallet public.wallet_balances%rowtype;
  v_valid_count integer;
  v_is_first_order boolean;
  v_first_order_gift integer := 0;
  v_area public.service_areas%rowtype;
  v_xp_multiplier numeric := coalesce((select (value ->> 'xp_multiplier')::numeric from public.app_settings where key = 'order_rewards'), 0.5);
begin
  if not exists (
    select 1 from public.profiles p join public.staging_allowlist a on a.telegram_subject = p.telegram_subject
    where p.id = p_user_id and a.enabled and not p.blocked
  ) then raise exception 'Staging access denied'; end if;
  v_is_first_order := not exists (select 1 from public.orders where user_id = p_user_id);
  if v_is_first_order and not exists (
    select 1 from public.profiles where id = p_user_id and role = 'admin'
  ) and not exists (
    select 1 from public.kyc_cases where user_id = p_user_id and status = 'approved'
  ) then raise exception 'KYC_REQUIRED_FIRST_ORDER'; end if;
  if p_scenario_type not in ('meetup', 'delivery_zone', 'delivery_italia') then raise exception 'SCENARIO_INVALID'; end if;
  if jsonb_array_length(p_items) = 0 then raise exception 'CART_EMPTY'; end if;
  if exists (
    select 1 from jsonb_array_elements(p_items) item
    where (item ->> 'grams') is null
      or (item ->> 'grams')::integer < 25
      or (item ->> 'grams')::integer % 25 <> 0
  ) then raise exception 'GRAM_AMOUNT_INVALID'; end if;

  select count(*), sum(public.calculate_product_gram_price(product.id, (item ->> 'grams')::integer)),
    sum((item ->> 'grams')::integer)
  into v_valid_count, v_subtotal, v_units
  from jsonb_array_elements(p_items) item
  join public.products product on product.id = (item ->> 'product_id')::uuid and product.published;
  if v_valid_count <> jsonb_array_length(p_items) or v_subtotal is null then raise exception 'ITEM_UNAVAILABLE'; end if;
  if v_units > 10000 then raise exception 'MAXIMUM_UNITS_SUPPORTED:10000'; end if;

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
    left join public.product_inventory inventory on inventory.product_id = product.id
    where variant.product_id = product.id
      and variant.unit_amount <= (item ->> 'grams')::integer
      and variant.unit_amount >= 25
      and (inventory.stock_quantity is null or inventory.stock_quantity >= (item ->> 'grams')::integer)
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
  if v_is_first_order
    and exists (select 1 from public.kyc_cases where user_id = p_user_id and status = 'approved')
    and not exists (
      select 1 from public.loyalty_ledger
      where user_id = p_user_id and reference_type = 'first_order_gift'
    )
  then
    select least(5, 100 - points) into v_first_order_gift
    from public.wallet_balances
    where user_id = p_user_id
    for update;
    if coalesce(v_first_order_gift, 0) > 0 then
      update public.wallet_balances
      set points = points + v_first_order_gift, updated_at = now()
      where user_id = p_user_id
      returning * into v_wallet;
      insert into public.loyalty_ledger (user_id, reason, points_delta, xp_delta, reference_type, reference_id)
      values (p_user_id, 'Regalo primo ordine', v_first_order_gift, 0, 'first_order_gift', v_order);
    end if;
  end if;
  return jsonb_build_object(
    'order_id', v_order, 'display_id', v_display, 'simulated_subtotal', v_subtotal,
    'simulated_surcharge', v_surcharge, 'simulated_token_credit', p_tokens_to_reserve,
    'simulated_total', v_total, 'total_units', v_units, 'tokens_reserved', p_tokens_to_reserve,
    'tokens_on_complete', v_expected_tokens, 'xp_on_complete', v_expected_xp,
    'first_order_gift', v_first_order_gift, 'balance', v_wallet.points, 'disclaimer', ''
  );
end $$;

create or replace function public.deduct_order_stock(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_short text;
begin
  perform 1
  from public.product_inventory inventory
  join (
    select variant.product_id
    from public.order_items item
    join public.product_variants variant on variant.id = item.variant_id
    where item.order_id = p_order_id
    group by variant.product_id
  ) needed on needed.product_id = inventory.product_id
  for update of inventory;

  select string_agg(product.name || ' (' || inventory.stock_quantity || ' g)', ', ')
  into v_short
  from (
    select variant.product_id, sum(coalesce(item.gram_amount, variant.unit_amount, 0) * item.quantity)::integer grams
    from public.order_items item
    join public.product_variants variant on variant.id = item.variant_id
    where item.order_id = p_order_id
    group by variant.product_id
  ) needed
  join public.product_inventory inventory on inventory.product_id = needed.product_id
  join public.products product on product.id = needed.product_id
  where inventory.stock_quantity is not null
    and inventory.stock_quantity < needed.grams;

  if v_short is not null then
    raise exception 'STOCK_NOT_ENOUGH:%', v_short;
  end if;

  update public.product_inventory inventory
  set stock_quantity = inventory.stock_quantity - needed.grams,
      updated_at = now()
  from (
    select variant.product_id, sum(coalesce(item.gram_amount, variant.unit_amount, 0) * item.quantity)::integer grams
    from public.order_items item
    join public.product_variants variant on variant.id = item.variant_id
    where item.order_id = p_order_id
    group by variant.product_id
  ) needed
  where inventory.product_id = needed.product_id
    and inventory.stock_quantity is not null;

  insert into public.low_stock_notifications (product_id, stock_quantity, threshold_quantity)
  select inventory.product_id, inventory.stock_quantity, inventory.notify_threshold_quantity
  from public.product_inventory inventory
  join (
    select variant.product_id
    from public.order_items item
    join public.product_variants variant on variant.id = item.variant_id
    where item.order_id = p_order_id
    group by variant.product_id
  ) needed on needed.product_id = inventory.product_id
  where inventory.stock_quantity is not null
    and inventory.notify_threshold_quantity > 0
    and inventory.stock_quantity <= inventory.notify_threshold_quantity
    and inventory.low_stock_alerted_at is null;

  update public.product_inventory
  set low_stock_alerted_at = now()
  from (
    select variant.product_id
    from public.order_items item
    join public.product_variants variant on variant.id = item.variant_id
    where item.order_id = p_order_id
    group by variant.product_id
  ) needed
  where stock_quantity is not null
    and public.product_inventory.product_id = needed.product_id
    and notify_threshold_quantity > 0
    and stock_quantity <= notify_threshold_quantity
    and low_stock_alerted_at is null;
end $$;

create or replace function public.restore_order_stock(p_order_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.product_inventory inventory
  set stock_quantity = inventory.stock_quantity + needed.grams,
      updated_at = now()
  from (
    select variant.product_id, sum(coalesce(item.gram_amount, variant.unit_amount, 0) * item.quantity)::integer grams
    from public.order_items item
    join public.product_variants variant on variant.id = item.variant_id
    where item.order_id = p_order_id
    group by variant.product_id
  ) needed
  where inventory.product_id = needed.product_id
    and inventory.stock_quantity is not null;

  update public.product_inventory
  set low_stock_alerted_at = null
  from (
    select variant.product_id
    from public.order_items item
    join public.product_variants variant on variant.id = item.variant_id
    where item.order_id = p_order_id
    group by variant.product_id
  ) needed
  where stock_quantity is not null
    and public.product_inventory.product_id = needed.product_id
    and stock_quantity > notify_threshold_quantity;
end $$;

create or replace function public.admin_update_order_status(p_order_id uuid, p_status public.order_status, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
declare
  v_order public.orders%rowtype;
  v_wallet public.wallet_balances%rowtype;
  v_awarded integer;
  v_completed_count integer;
begin
  if not public.is_admin() then raise exception 'Non sei autorizzato a modificare l''ordine.'; end if;
  select * into v_order from public.orders where id = p_order_id for update;
  if not found then raise exception 'Ordine non trovato.'; end if;
  if v_order.status = p_status then return; end if;
  if v_order.status in ('completed', 'cancelled') then raise exception 'L''ordine è già concluso.'; end if;
  if p_status = 'processing' and v_order.status <> 'submitted' then raise exception 'Transizione ordine non valida.'; end if;
  if p_status = 'completed' and v_order.status <> 'processing' then raise exception 'Accetta prima l''ordine.'; end if;
  if p_status = 'cancelled' and v_order.status not in ('submitted', 'processing') then raise exception 'Transizione ordine non valida.'; end if;
  if p_status not in ('processing', 'completed', 'cancelled') then raise exception 'Transizione ordine non valida.'; end if;

  if p_status = 'processing' and not v_order.stock_deducted then
    perform public.deduct_order_stock(p_order_id);
  end if;
  if p_status = 'cancelled' and v_order.stock_deducted then
    perform public.restore_order_stock(p_order_id);
  end if;

  update public.orders
  set status = p_status,
      operator_note = nullif(trim(p_note), ''),
      stock_deducted = case
        when p_status = 'processing' then true
        when p_status = 'cancelled' then false
        else stock_deducted
      end
  where id = p_order_id;

  if p_status = 'cancelled' and v_order.tokens_reserved > 0 and not v_order.tokens_returned and not v_order.rewards_applied then
    update public.wallet_balances set points = least(points + v_order.tokens_reserved, 100), updated_at = now()
      where user_id = v_order.user_id;
    update public.orders set tokens_returned = true where id = p_order_id;
    insert into public.loyalty_ledger (user_id, reason, points_delta, xp_delta, reference_type, reference_id)
    values (v_order.user_id, 'Gettoni restituiti ' || v_order.display_id, v_order.tokens_reserved, 0, 'order_cancel', p_order_id);
  elsif p_status = 'completed' and not v_order.rewards_applied then
    select * into v_wallet from public.wallet_balances where user_id = v_order.user_id for update;
    v_awarded := least(v_order.points_awarded, 100 - v_wallet.points);
    update public.wallet_balances set points = points + v_awarded, xp = xp + v_order.xp_awarded, updated_at = now()
      where user_id = v_order.user_id;
    update public.orders set points_awarded = v_awarded, rewards_applied = true where id = p_order_id;
    insert into public.loyalty_ledger (user_id, reason, points_delta, xp_delta, reference_type, reference_id)
    values (v_order.user_id, 'Ordine completato ' || v_order.display_id, v_awarded, v_order.xp_awarded, 'order_complete', p_order_id);
    select count(*) into v_completed_count from public.orders
    where user_id = v_order.user_id and status = 'completed' and scenario_type <> 'legacy';
    if v_completed_count % 5 = 0 then
      update public.wallet_balances set spin_tickets = spin_tickets + 1 where user_id = v_order.user_id;
      insert into public.loyalty_ledger (user_id, reason, points_delta, xp_delta, reference_type, reference_id)
      values (v_order.user_id, 'Ticket ruota guadagnato', 0, 0, 'spin_ticket', p_order_id);
    end if;
  end if;
  insert into public.order_status_history (order_id, status, changed_by, note)
    values (p_order_id, p_status, auth.uid(), nullif(trim(p_note), ''));
  insert into public.admin_audit_log (actor_id, action, entity_type, entity_id, details)
    values (auth.uid(), 'order.status', 'order', p_order_id::text, jsonb_build_object('status', p_status, 'note', p_note));
end $$;

create or replace function public.telegram_admin_order_action(p_actor_id uuid, p_order_id uuid, p_action text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_order public.orders%rowtype;
  v_status public.order_status;
begin
  if not exists (
    select 1
    from public.profiles profile
    join public.staging_allowlist allowed on allowed.telegram_subject = profile.telegram_subject
    where profile.id = p_actor_id and profile.role = 'admin' and allowed.enabled and not profile.blocked
  ) then raise exception 'Amministratore Telegram non autorizzato.'; end if;
  if p_action not in ('accept', 'reject') then raise exception 'Azione ordine non valida.'; end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if not found then raise exception 'Ordine non trovato.'; end if;
  if v_order.status in ('completed', 'cancelled') then raise exception 'L''ordine è già concluso.'; end if;

  if p_action = 'accept' then
    if v_order.status = 'processing' then
      return jsonb_build_object('status', v_order.status, 'display_id', v_order.display_id);
    end if;
    if not v_order.stock_deducted then
      perform public.deduct_order_stock(p_order_id);
    end if;
    v_status := 'processing';
  else
    if v_order.stock_deducted then
      perform public.restore_order_stock(p_order_id);
    end if;
    v_status := 'cancelled';
  end if;

  update public.orders
    set status = v_status,
      stock_deducted = case when v_status = 'processing' then true else false end,
      operator_note = case when p_action = 'accept' then 'Accettato da Telegram' else 'Rifiutato da Telegram' end
    where id = p_order_id;

  if v_status = 'cancelled' and v_order.tokens_reserved > 0 and not v_order.tokens_returned and not v_order.rewards_applied then
    update public.wallet_balances set points = least(points + v_order.tokens_reserved, 100), updated_at = now()
      where user_id = v_order.user_id;
    update public.orders set tokens_returned = true where id = p_order_id;
    insert into public.loyalty_ledger (user_id, reason, points_delta, xp_delta, reference_type, reference_id)
    values (v_order.user_id, 'Gettoni restituiti ' || v_order.display_id, v_order.tokens_reserved, 0, 'order_cancel', p_order_id);
  end if;

  insert into public.order_status_history (order_id, status, changed_by, note)
    values (p_order_id, v_status, p_actor_id, case when p_action = 'accept' then 'Accettato da Telegram' else 'Rifiutato da Telegram' end);
  insert into public.admin_audit_log (actor_id, action, entity_type, entity_id, details)
    values (p_actor_id, 'order.telegram_action', 'order', p_order_id::text, jsonb_build_object('action', p_action, 'status', v_status));
  return jsonb_build_object('status', v_status, 'display_id', v_order.display_id);
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
  v_slug := 'product-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  insert into public.products (category_id, slug, name, description, badge, featured, published, rating)
  values (p_category_id, v_slug, v_name, 'Prodotto disponibile in catalogo.', 'NEW', false, true, 0)
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
  insert into public.product_inventory (product_id, stock_quantity)
  values (v_product_id, null);
  if p_announce then
    insert into public.broadcasts (kind, title, message, product_id, status, created_by)
    values ('product_new', 'Nuovo prodotto: ' || v_name, 'Nuovo prodotto aggiunto al catalogo.', v_product_id, 'draft', auth.uid());
  end if;
  return v_product_id;
end $$;

grant execute on function public.next_order_display_id() to service_role;
grant execute on function public.submit_test_order_internal(uuid, jsonb, text, text, text, integer) to service_role;
grant execute on function public.admin_update_order_status(uuid, public.order_status, text) to authenticated;
grant execute on function public.telegram_admin_order_action(uuid, uuid, text) to service_role;
grant execute on function public.admin_create_demo_product(text, uuid, jsonb, boolean) to authenticated;
revoke execute on function public.next_order_display_id() from authenticated, public, anon;
revoke execute on function public.submit_test_order_internal(uuid, jsonb, text, text, text, integer) from authenticated, public, anon;
revoke execute on function public.calculate_product_gram_price(uuid, integer) from authenticated, public, anon;
