-- Support game prizes that grant a one-use item/product reward for the next order.

alter type public.reward_kind add value if not exists 'item';

create or replace function public.admin_save_game_options(p_game_type public.game_type, p_options jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_active_count integer;
  v_total integer;
  v_option record;
  v_reward_id uuid;
  v_reward_kind text;
  v_item_label text;
begin
  if not public.is_admin() then raise exception 'Non sei autorizzato a modificare i giochi.'; end if;
  if p_game_type not in ('spin', 'scratch', 'box') or jsonb_typeof(p_options) <> 'array' then
    raise exception 'Configurazione premi non valida.';
  end if;
  if exists (
    select 1
    from jsonb_to_recordset(p_options) as x(
      code text, label text, points_awarded integer, xp_awarded integer, weight integer,
      color text, active boolean, reward_kind text, item_label text
    )
    where trim(coalesce(x.code, '')) = ''
      or trim(coalesce(x.label, '')) = ''
      or coalesce(x.points_awarded, -1) < 0
      or coalesce(x.xp_awarded, -1) < 0
      or coalesce(x.weight, 0) < 1
      or trim(coalesce(x.color, '')) = ''
      or coalesce(nullif(x.reward_kind, ''), 'wallet') not in ('wallet', 'item')
      or (
        coalesce(nullif(x.reward_kind, ''), 'wallet') = 'item'
        and (
          trim(coalesce(x.item_label, '')) = ''
          or coalesce(x.points_awarded, 0) <> 0
          or coalesce(x.xp_awarded, 0) <> 0
        )
      )
  ) then raise exception 'Configurazione premi non valida.'; end if;
  if (select count(*) from jsonb_to_recordset(p_options) as x(code text))
    <> (select count(distinct trim(x.code)) from jsonb_to_recordset(p_options) as x(code text)) then
    raise exception 'Codici premio duplicati.';
  end if;
  select count(*) filter (where x.active), coalesce(sum(x.weight) filter (where x.active), 0)
  into v_active_count, v_total
  from jsonb_to_recordset(p_options) as x(weight integer, active boolean);
  if v_active_count > 0 and v_total <> 100 then raise exception 'REWARD_DISTRIBUTION_INVALID'; end if;
  if exists (select 1 from public.game_configs where game_type = p_game_type and active)
    and (v_active_count = 0 or v_total <> 100) then raise exception 'REWARD_DISTRIBUTION_INVALID'; end if;

  update public.game_reward_options set active = false where game_type = p_game_type;

  for v_option in
    select *
    from jsonb_to_recordset(p_options) as x(
      code text, label text, points_awarded integer, xp_awarded integer,
      reward_definition_id uuid, weight integer, color text, active boolean,
      reward_kind text, item_label text
    )
  loop
    v_reward_kind := coalesce(nullif(v_option.reward_kind, ''), 'wallet');
    v_reward_id := v_option.reward_definition_id;
    if v_reward_kind = 'item' then
      v_item_label := trim(v_option.item_label);
      execute '
        insert into public.reward_definitions (code, label, kind, value, active)
        values ($1, $2, $3::public.reward_kind, null, true)
        on conflict (code) do update
        set label = excluded.label,
          kind = excluded.kind,
          value = null,
          active = true
        returning id'
      into v_reward_id
      using 'game_item_' || p_game_type::text || '_' || trim(v_option.code), v_item_label, 'item';
    elsif v_reward_id is not null and not exists (
      select 1 from public.reward_definitions definition
      where definition.id = v_reward_id and definition.kind::text <> 'item'
    ) then
      v_reward_id := null;
    end if;

    insert into public.game_reward_options (
      game_type, code, label, points_awarded, xp_awarded, reward_definition_id, weight, color, active
    ) values (
      p_game_type, trim(v_option.code), trim(v_option.label),
      case when v_reward_kind = 'item' then 0 else v_option.points_awarded end,
      case when v_reward_kind = 'item' then 0 else v_option.xp_awarded end,
      v_reward_id,
      v_option.weight,
      v_option.color,
      v_option.active
    )
    on conflict (game_type, code) do update set label = excluded.label,
      points_awarded = excluded.points_awarded, xp_awarded = excluded.xp_awarded,
      reward_definition_id = excluded.reward_definition_id, weight = excluded.weight,
      color = excluded.color, active = excluded.active;
  end loop;
end $$;

create or replace function public.admin_delete_game_option(p_option_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_game_type public.game_type;
  v_total integer;
  v_count integer;
begin
  if not public.is_admin() then raise exception 'Non sei autorizzato a modificare i giochi.'; end if;
  select game_type into v_game_type from public.game_reward_options where id = p_option_id;
  if not found then return; end if;

  if exists (select 1 from public.game_plays where reward_option_id = p_option_id) then
    update public.game_reward_options set active = false where id = p_option_id;
  else
    delete from public.game_reward_options where id = p_option_id;
  end if;

  select coalesce(sum(weight) filter (where active), 0), count(*) filter (where active)
  into v_total, v_count
  from public.game_reward_options
  where game_type = v_game_type;

  if exists (select 1 from public.game_configs where game_type = v_game_type and active)
    and (v_count = 0 or v_total <> 100) then
    update public.game_configs set active = false where game_type = v_game_type;
  end if;
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
  v_item_rewards jsonb := '[]'::jsonb;
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

  with redeemed as (
    update public.user_rewards reward
    set state = 'redeemed',
      redeemed_order_id = v_order
    from public.reward_definitions definition
    where reward.user_id = p_user_id
      and reward.state = 'available'
      and reward.reward_definition_id = definition.id
      and definition.kind::text = 'item'
    returning reward.id, definition.label
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'label', label)), '[]'::jsonb)
  into v_item_rewards
  from redeemed;

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
    'first_order_gift', v_first_order_gift, 'balance', v_wallet.points, 'item_rewards', v_item_rewards,
    'disclaimer', ''
  );
end $$;

grant execute on function public.admin_save_game_options(public.game_type, jsonb) to authenticated;
grant execute on function public.admin_delete_game_option(uuid) to authenticated;
grant execute on function public.submit_test_order_internal(uuid, jsonb, text, text, text, integer) to service_role;
revoke execute on function public.admin_save_game_options(public.game_type, jsonb) from public, anon;
revoke execute on function public.admin_delete_game_option(uuid) from public, anon;
revoke execute on function public.submit_test_order_internal(uuid, jsonb, text, text, text, integer) from authenticated, public, anon;
