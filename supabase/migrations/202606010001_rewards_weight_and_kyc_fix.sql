-- Rewards and order limits update:
-- - feedback grants 5 gettoni once per completed-order review
-- - custom gram orders are capped at 5 kg
-- - token rewards include 3 kg and 5 kg tiers
-- - gram pricing can extrapolate up to 5 kg from the largest configured tiers

insert into public.token_reward_tiers (minimum_units, tokens_awarded)
values (3000, 70), (5000, 100)
on conflict (minimum_units) do update
set tokens_awarded = excluded.tokens_awarded,
    updated_at = now();

update public.product_variants variant
set token_award = tier.tokens_awarded
from public.token_reward_tiers tier
where variant.unit_amount = tier.minimum_units
  and tier.minimum_units in (3000, 5000);

do $$
declare
  v_definition text;
begin
  select pg_get_functiondef('public.submit_test_order_internal(uuid,jsonb,text,text,text,integer)'::regprocedure)
  into v_definition;

  v_definition := replace(v_definition, 'if v_units > 10000 then raise exception ''MAXIMUM_UNITS_SUPPORTED:10000'';', 'if v_units > 5000 then raise exception ''MAXIMUM_UNITS_SUPPORTED:5000'';');
  v_definition := replace(v_definition, 'if v_units > 10000 then', 'if v_units > 5000 then');
  v_definition := replace(v_definition, 'MAXIMUM_UNITS_SUPPORTED:10000', 'MAXIMUM_UNITS_SUPPORTED:5000');
  execute v_definition;
end;
$$;

create or replace function public.calculate_product_gram_price(p_product_id uuid, p_grams integer)
returns numeric language plpgsql security definer set search_path = public as $$
declare
  v_lower public.product_variants%rowtype;
  v_upper public.product_variants%rowtype;
  v_previous public.product_variants%rowtype;
  v_per_gram numeric;
begin
  if p_grams < 25 or p_grams > 5000 or p_grams % 25 <> 0 then
    raise exception 'GRAM_AMOUNT_INVALID';
  end if;
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

  if v_lower.id is null then raise exception 'ITEM_UNAVAILABLE'; end if;
  if v_upper.id is not null then
    if v_lower.unit_amount = v_upper.unit_amount then return round(v_lower.price / 5) * 5; end if;
    return round((
      v_lower.price + (p_grams - v_lower.unit_amount)::numeric /
        (v_upper.unit_amount - v_lower.unit_amount) * (v_upper.price - v_lower.price)
    ) / 5) * 5;
  end if;

  select variant.* into v_previous
  from public.product_variants variant
  join public.inventory_status stock on stock.variant_id = variant.id and stock.available
  where variant.product_id = p_product_id
    and variant.unit_amount >= 25
    and variant.unit_amount < v_lower.unit_amount
  order by variant.unit_amount desc
  limit 1;

  if v_previous.id is null then
    return round(((v_lower.price / v_lower.unit_amount) * p_grams) / 5) * 5;
  end if;

  v_per_gram := (v_lower.price - v_previous.price) / (v_lower.unit_amount - v_previous.unit_amount);
  return round((v_lower.price + ((p_grams - v_lower.unit_amount) * v_per_gram)) / 5) * 5;
end $$;

create or replace function public.submit_feedback(p_order_id uuid, p_rating integer, p_message text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_points integer := 0;
begin
  perform public.assert_allowed();
  if p_rating not between 1 and 5 or char_length(trim(coalesce(p_message, ''))) not between 3 and 500 then
    raise exception 'FEEDBACK_INVALID';
  end if;
  if not exists (select 1 from public.orders where id = p_order_id and user_id = auth.uid() and status = 'completed') then
    raise exception 'COMPLETED_ORDER_REQUIRED';
  end if;

  insert into public.feedback (order_id, user_id, rating, message)
  values (p_order_id, auth.uid(), p_rating, trim(p_message))
  returning id into v_id;

  select least(5, 100 - points) into v_points
  from public.wallet_balances
  where user_id = auth.uid()
  for update;

  if coalesce(v_points, 0) > 0 then
    update public.wallet_balances
    set points = points + v_points,
        updated_at = now()
    where user_id = auth.uid();

    insert into public.loyalty_ledger (user_id, reason, points_delta, xp_delta, reference_type, reference_id)
    values (auth.uid(), 'Recensione ordine', v_points, 0, 'feedback', v_id);
  end if;

  return v_id;
end $$;

create or replace function public.admin_set_token_tier(p_minimum_units integer, p_tokens_awarded integer)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'ADMIN_MFA_REQUIRED'; end if;
  if p_minimum_units not in (50,100,300,500,1000,3000,5000) or p_tokens_awarded not between 0 and 100 then
    raise exception 'TIER_INVALID';
  end if;
  insert into public.token_reward_tiers (minimum_units, tokens_awarded)
  values (p_minimum_units, p_tokens_awarded)
  on conflict (minimum_units) do update
  set tokens_awarded = excluded.tokens_awarded,
      updated_at = now();
  update public.product_variants set token_award = p_tokens_awarded where unit_amount = p_minimum_units;
end $$;

grant execute on function public.submit_feedback(uuid, integer, text) to authenticated;
grant execute on function public.admin_set_token_tier(integer, integer) to authenticated;
revoke execute on function public.submit_feedback(uuid, integer, text) from public, anon;
revoke execute on function public.admin_set_token_tier(integer, integer) from public, anon;
