-- Add paid game tickets for Ruota/Scratch and cap order gettoni usage at 5%.

update public.game_configs
set cost = 20
where game_type in ('spin', 'scratch');

create or replace function public.buy_game_ticket(p_game_type public.game_type)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_config public.game_configs%rowtype;
  v_wallet public.wallet_balances%rowtype;
  v_price integer;
begin
  perform public.assert_allowed();
  if p_game_type not in ('spin', 'scratch') then raise exception 'TICKET_PURCHASE_UNAVAILABLE'; end if;

  select * into v_config
  from public.game_configs
  where game_type = p_game_type and active;
  if not found then raise exception 'GAME_NOT_AVAILABLE'; end if;

  v_price := greatest(coalesce(v_config.cost, 20), 1);
  select * into v_wallet
  from public.wallet_balances
  where user_id = auth.uid()
  for update;
  if not found or v_wallet.points < v_price then raise exception 'TICKET_BALANCE_REQUIRED'; end if;

  update public.wallet_balances
  set points = points - v_price,
    spin_tickets = spin_tickets + case when p_game_type = 'spin' then 1 else 0 end,
    scratch_tickets = scratch_tickets + case when p_game_type = 'scratch' then 1 else 0 end,
    updated_at = now()
  where user_id = auth.uid()
  returning * into v_wallet;

  insert into public.loyalty_ledger (user_id, reason, points_delta, xp_delta, reference_type)
  values (
    auth.uid(),
    case when p_game_type = 'spin' then 'Biglietto ruota acquistato' else 'Biglietto Scratch acquistato' end,
    -v_price,
    0,
    'ticket_purchase'
  );

  return jsonb_build_object(
    'game_type', p_game_type,
    'ticket_price', v_price,
    'balance', v_wallet.points,
    'spin_tickets', v_wallet.spin_tickets,
    'scratch_tickets', v_wallet.scratch_tickets,
    'box_tickets', v_wallet.box_tickets
  );
end $$;

create or replace function public.admin_set_game_ticket_price(p_price integer)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Non sei autorizzato a modificare i giochi.'; end if;
  if p_price is null or p_price not between 1 and 100 then raise exception 'TICKET_PRICE_INVALID'; end if;
  update public.game_configs set cost = p_price where game_type in ('spin', 'scratch');
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
  v_tokens_to_reserve integer := coalesce(p_tokens_to_reserve, 0);
  v_token_limit integer;
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
  if v_units > 5000 then raise exception 'MAXIMUM_UNITS_SUPPORTED:5000'; end if;

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
  if not found then raise exception 'TOKEN_RESERVE_INVALID'; end if;
  v_token_limit := floor((v_subtotal + v_surcharge) * 0.05);
  if v_tokens_to_reserve < 0
    or v_tokens_to_reserve > v_wallet.points
    or v_tokens_to_reserve > v_token_limit
  then raise exception 'TOKEN_RESERVE_INVALID'; end if;

  v_total := greatest(v_subtotal + v_surcharge - v_tokens_to_reserve, 0);
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
    v_tokens_to_reserve, v_total, v_subtotal, v_surcharge, v_tokens_to_reserve, v_total, v_expected_tokens, v_expected_xp
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
  if v_tokens_to_reserve > 0 then
    update public.wallet_balances set points = points - v_tokens_to_reserve, updated_at = now()
      where user_id = p_user_id returning * into v_wallet;
    insert into public.loyalty_ledger (user_id, reason, points_delta, xp_delta, reference_type, reference_id)
    values (p_user_id, 'Gettoni riservati ' || v_display, -v_tokens_to_reserve, 0, 'order_reserve', v_order);
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
    'simulated_surcharge', v_surcharge, 'simulated_token_credit', v_tokens_to_reserve,
    'simulated_total', v_total, 'total_units', v_units, 'tokens_reserved', v_tokens_to_reserve,
    'tokens_on_complete', v_expected_tokens, 'xp_on_complete', v_expected_xp,
    'first_order_gift', v_first_order_gift, 'balance', v_wallet.points, 'disclaimer', ''
  );
end $$;

grant execute on function public.buy_game_ticket(public.game_type) to authenticated;
grant execute on function public.admin_set_game_ticket_price(integer) to authenticated;
grant execute on function public.submit_test_order_internal(uuid, jsonb, text, text, text, integer) to service_role;
revoke execute on function public.buy_game_ticket(public.game_type) from public, anon;
revoke execute on function public.admin_set_game_ticket_price(integer) from public, anon;
revoke execute on function public.submit_test_order_internal(uuid, jsonb, text, text, text, integer) from authenticated, public, anon;
