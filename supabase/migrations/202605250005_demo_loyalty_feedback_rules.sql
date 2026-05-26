-- Closed staging expansion: demo scenarios, tokens, earned wheel, feedback and KYC retention.
-- All order figures are simulated only. No payment, exchange or fulfillment is performed.

alter table public.product_variants
  add column unit_amount integer,
  add column token_award integer not null default 0 check (token_award >= 0);

alter table public.wallet_balances
  add column spin_tickets integer not null default 0 check (spin_tickets >= 0);

alter table public.orders
  add column scenario_type text not null default 'legacy' check (scenario_type in ('legacy', 'meetup', 'delivery_zone', 'delivery_italia')),
  add column scenario_city text not null default '',
  add column scenario_street text not null default '',
  add column total_units integer not null default 0 check (total_units >= 0),
  add column tokens_reserved integer not null default 0 check (tokens_reserved >= 0),
  add column simulated_subtotal numeric(10,2) not null default 0 check (simulated_subtotal >= 0),
  add column simulated_surcharge numeric(10,2) not null default 0 check (simulated_surcharge >= 0),
  add column simulated_token_credit numeric(10,2) not null default 0 check (simulated_token_credit >= 0),
  add column simulated_total numeric(10,2) not null default 0 check (simulated_total >= 0),
  add column rewards_applied boolean not null default false,
  add column tokens_returned boolean not null default false;

alter table public.kyc_cases
  add column retain_until timestamptz,
  add column documents_purged_at timestamptz;

update public.orders set
  rewards_applied = true,
  simulated_subtotal = total,
  simulated_total = total
where scenario_type = 'legacy';

create table public.service_areas (
  id uuid primary key default gen_random_uuid(),
  scenario_type text not null check (scenario_type in ('meetup', 'delivery_zone', 'delivery_italia')),
  city text not null,
  minimum_units integer not null check (minimum_units > 0),
  requires_street boolean not null default false,
  active boolean not null default true,
  sort_order integer not null default 0,
  unique (scenario_type, city)
);

create table public.token_reward_tiers (
  minimum_units integer primary key check (minimum_units > 0),
  tokens_awarded integer not null check (tokens_awarded between 0 and 100),
  updated_at timestamptz not null default now()
);

create type public.feedback_status as enum ('pending', 'published', 'hidden');

create table public.feedback (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references public.orders(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  rating integer not null check (rating between 1 and 5),
  message text not null check (char_length(trim(message)) between 3 and 500),
  status public.feedback_status not null default 'pending',
  moderated_by uuid references public.profiles(id),
  moderated_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger feedback_touch before update on public.feedback
for each row execute function public.touch_updated_at();

alter table public.service_areas enable row level security;
alter table public.token_reward_tiers enable row level security;
alter table public.feedback enable row level security;

grant select, insert, update, delete on public.service_areas to authenticated;
grant select, insert, update, delete on public.token_reward_tiers to authenticated;
grant select, insert, update on public.feedback to authenticated;

create policy member_service_areas_read on public.service_areas for select
  using (public.is_allowed() and active or public.is_admin());
create policy admin_service_areas_write on public.service_areas for all
  using (public.is_admin()) with check (public.is_admin());
create policy member_token_tiers_read on public.token_reward_tiers for select
  using (public.is_allowed() or public.is_admin());
create policy admin_token_tiers_write on public.token_reward_tiers for all
  using (public.is_admin()) with check (public.is_admin());
create policy feedback_member_read on public.feedback for select
  using (public.is_allowed() and (status = 'published' or user_id = auth.uid()) or public.is_admin());
create policy feedback_admin_update on public.feedback for update
  using (public.is_admin()) with check (public.is_admin());

create trigger audit_service_areas after insert or update or delete on public.service_areas
for each row execute function public.audit_admin_change();
create trigger audit_token_tiers after insert or update or delete on public.token_reward_tiers
for each row execute function public.audit_admin_change();
create trigger audit_feedback after update or delete on public.feedback
for each row execute function public.audit_admin_change();

insert into public.service_areas (scenario_type, city, minimum_units, requires_street, sort_order) values
  ('meetup', 'Spoleto', 50, false, 1),
  ('meetup', 'Foligno', 50, false, 2),
  ('meetup', 'Gualdo', 50, false, 3),
  ('meetup', 'Bastia', 50, false, 4),
  ('meetup', 'Perugia', 100, false, 5),
  ('meetup', 'Gubbio', 100, false, 6),
  ('meetup', 'Terni', 100, false, 7),
  ('delivery_zone', 'Umbertide', 300, true, 10),
  ('delivery_zone', 'CDC', 300, true, 11),
  ('delivery_zone', 'Matelica', 300, true, 12),
  ('delivery_zone', 'Fabriano', 300, true, 13),
  ('delivery_zone', 'Cagli', 300, true, 14),
  ('delivery_zone', 'Cerreto Desi', 300, true, 15),
  ('delivery_italia', 'Italia', 500, true, 20);

insert into public.token_reward_tiers (minimum_units, tokens_awarded) values
  (50, 5), (100, 10), (300, 20), (500, 30), (1000, 50);

insert into public.app_settings (key, value) values
  ('demo_rules', '{"disclaimer":"Ambiente demo: nessun pagamento, scambio o fulfillment reale.","delivery_zone_surcharge_per_100_units":10,"italia_note":"Tariffa demo da definire nel solo scenario simulato."}'),
  ('community_links', '{"instagram":"https://www.instagram.com/street_family_420?igsh=anE0NXl2bHc1bWUy","viber":"https://invite.viber.com/?g2=AQBPMWNo9WD3f1ZpxQmFGMw45rNNTiciLs1ftxm3cHeo6mCJD9EvQHNnNxSt%2BlNe","signal":null}'),
  ('kyc_retention', '{"approved_days":365}')
on conflict (key) do update set value = excluded.value, updated_at = now();

-- Replace the initial showcase with neutral demo terminology and package tiers.
update public.categories set name = 'Demo Collection', slug = 'demo-collection', published = true
where id = '10000000-0000-0000-0000-000000000001';
update public.categories set published = false
where id <> '10000000-0000-0000-0000-000000000001';
update public.products set
  category_id = '10000000-0000-0000-0000-000000000001',
  name = 'Demo Item ' || lpad(numbered.seq::text, 2, '0'),
  description = 'Articolo dimostrativo in un catalogo chiuso. Nessuna vendita o consegna reale.',
  rating = 0,
  review_count = 0
from (
  select id, row_number() over (order by created_at, id) as seq from public.products
) numbered
where public.products.id = numbered.id;

update public.product_media set published = false where storage_path is null;

update public.inventory_status set available = false
where variant_id in (select id from public.product_variants where unit_amount is null);

insert into public.product_variants (product_id, label, price, sort_order, unit_amount, token_award)
select p.id, tier.label, tier.price, tier.sort_order, tier.unit_amount, tier.token_award
from public.products p
cross join (values
  ('50 units', 50::numeric, 10, 50, 5),
  ('100 units', 95::numeric, 11, 100, 10),
  ('300 units', 270::numeric, 12, 300, 20),
  ('500 units', 425::numeric, 13, 500, 30),
  ('1000 units', 800::numeric, 14, 1000, 50)
) as tier(label, price, sort_order, unit_amount, token_award);

insert into public.inventory_status (variant_id)
select id from public.product_variants where unit_amount is not null
on conflict (variant_id) do update set available = true, updated_at = now();

update public.game_configs set active = (game_type = 'spin'), cost = 0,
  title = case when game_type = 'spin' then 'Ruota dei premi' else title end;
update public.game_reward_options
set label = replace(label, 'Punti', 'Gettoni')
where game_type = 'spin';
update public.reward_definitions
set label = case code
  when 'free_delivery' then 'Credito scenario demo'
  when 'discount_5' then 'Credito demo 5%'
  when 'discount_10' then 'Credito demo 10%'
  else label
end
where code in ('free_delivery', 'discount_5', 'discount_10');
update public.wallet_balances set points = least(points, 100);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_subject text := coalesce(
    new.raw_user_meta_data ->> 'telegram_id',
    new.raw_user_meta_data ->> 'telegram_subject',
    new.raw_user_meta_data ->> 'sub',
    new.id::text
  );
  v_role public.app_role;
begin
  select role into v_role from public.staging_allowlist where telegram_subject = v_subject and enabled;
  insert into public.profiles (id, telegram_subject, username, avatar_url, role)
  values (
    new.id, v_subject,
    coalesce(new.raw_user_meta_data ->> 'username', new.raw_user_meta_data ->> 'first_name', 'member'),
    new.raw_user_meta_data ->> 'avatar_url', coalesce(v_role, 'user')
  )
  on conflict (id) do update set
    telegram_subject = excluded.telegram_subject, username = excluded.username,
    avatar_url = excluded.avatar_url, role = excluded.role, updated_at = now();
  insert into public.wallet_balances (user_id, points) values (new.id, 0)
  on conflict (user_id) do nothing;
  return new;
end $$;

create or replace function public.get_my_profile()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  perform public.assert_allowed();
  select jsonb_build_object(
    'id', p.id, 'username', p.username, 'avatar_url', p.avatar_url, 'role', p.role,
    'tokens', w.points, 'points', w.points, 'xp', w.xp, 'streak', w.streak,
    'spin_tickets', w.spin_tickets,
    'level_number', coalesce(l.level_number, 1),
    'next_level_xp', (select min(xp_min) from public.levels where xp_min > w.xp),
    'total_orders', (select count(*) from public.orders where user_id = p.id),
    'completed_orders', (select count(*) from public.orders where user_id = p.id and status = 'completed')
  ) into v from public.profiles p
  join public.wallet_balances w on w.user_id = p.id
  left join lateral (
    select * from public.levels where xp_min <= w.xp order by xp_min desc limit 1
  ) l on true where p.id = auth.uid();
  return v;
end $$;

create or replace function public.get_demo_info()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_allowed();
  return jsonb_build_object(
    'rules', (select value from public.app_settings where key = 'demo_rules'),
    'links', (select value from public.app_settings where key = 'community_links')
  );
end $$;

create or replace function public.get_catalog()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_allowed();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id, 'name', p.name, 'category', c.name, 'description', p.description, 'badge', p.badge,
      'rating', coalesce(stats.rating, 0), 'review_count', coalesce(stats.review_count, 0),
      'variants', (select jsonb_agg(jsonb_build_object(
          'id', v.id, 'label', v.label, 'price', v.price, 'unit_amount', v.unit_amount,
          'token_award', v.token_award, 'available', i.available
        ) order by v.sort_order)
        from public.product_variants v join public.inventory_status i on i.variant_id = v.id
        where v.product_id = p.id and v.unit_amount is not null),
      'media', (select jsonb_agg(jsonb_build_object('id', m.id, 'url', m.url, 'storage_path', m.storage_path,
        'upload_status', m.upload_status, 'type', m.media_type, 'alt', m.alt, 'sort_order', m.sort_order) order by m.sort_order)
        from public.product_media m where m.product_id = p.id and m.published and m.upload_status = 'ready')
    ) order by p.featured desc, p.name)
    from public.products p join public.categories c on c.id = p.category_id
    left join lateral (
      select round(avg(f.rating)::numeric, 1) as rating, count(*)::integer as review_count
      from public.feedback f join public.order_items oi on oi.order_id = f.order_id
      join public.product_variants reviewed_variant on reviewed_variant.id = oi.variant_id
      where f.status = 'published' and reviewed_variant.product_id = p.id
    ) stats on true
    where p.published and c.published
  ), '[]'::jsonb);
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
  select count(*), sum(v.price), sum(v.unit_amount)
  into v_valid_count, v_subtotal, v_units
  from jsonb_array_elements(p_items) item
  join public.product_variants v on v.id = (item ->> 'variant_id')::uuid and v.unit_amount is not null
  join public.products p on p.id = v.product_id and p.published
  join public.inventory_status i on i.variant_id = v.id and i.available;
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
    p_scenario_type, trim(p_city), trim(p_street), 'DEMO ONLY - no fulfillment', v_units,
    p_tokens_to_reserve, v_total, v_subtotal, v_surcharge, p_tokens_to_reserve, v_total, v_expected_tokens, v_expected_xp
  );
  insert into public.order_items (order_id, variant_id, name_snapshot, variant_label, unit_price, quantity)
  select v_order, v.id, p.name, v.label, v.price, 1
  from jsonb_array_elements(p_items) item join public.product_variants v on v.id = (item ->> 'variant_id')::uuid
  join public.products p on p.id = v.product_id;
  insert into public.order_status_history (order_id, status, changed_by, note)
  values (v_order, 'submitted', p_user_id, 'DEMO ONLY - no payment or fulfillment');
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
    'balance', case when p_tokens_to_reserve > 0 then v_wallet.points else v_wallet.points end,
    'disclaimer', 'Ambiente demo: nessun pagamento, scambio o fulfillment reale.'
  );
end $$;

create or replace function public.admin_update_order_status(p_order_id uuid, p_status public.order_status, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
declare
  v_order public.orders%rowtype;
  v_wallet public.wallet_balances%rowtype;
  v_awarded integer;
  v_completed_count integer;
begin
  if not public.is_admin() then raise exception 'Admin MFA required'; end if;
  select * into v_order from public.orders where id = p_order_id for update;
  if not found then raise exception 'Richiesta non trovata'; end if;
  if v_order.status in ('completed', 'cancelled') and v_order.status <> p_status then raise exception 'ORDER_FINALIZED'; end if;
  update public.orders set status = p_status, operator_note = nullif(trim(p_note), '') where id = p_order_id;

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
    values (v_order.user_id, 'Scenario completato ' || v_order.display_id, v_awarded, v_order.xp_awarded, 'order_complete', p_order_id);
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

create or replace function public.play_game(p_game_type public.game_type)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_wallet public.wallet_balances%rowtype;
  v_option public.game_reward_options%rowtype;
  v_total integer; v_pick integer; v_play uuid := gen_random_uuid(); v_reward_kind public.reward_kind; v_tokens integer;
begin
  perform public.assert_allowed();
  if p_game_type <> 'spin' then raise exception 'ONLY_EARNED_WHEEL_AVAILABLE'; end if;
  select * into v_wallet from public.wallet_balances where user_id = auth.uid() for update;
  if v_wallet.spin_tickets < 1 then raise exception 'SPIN_TICKET_REQUIRED'; end if;
  select sum(weight) into v_total from public.game_reward_options where game_type = 'spin' and active;
  if coalesce(v_total, 0) <= 0 then raise exception 'Reward configuration invalid'; end if;
  v_pick := floor(random() * v_total)::integer + 1;
  select option_row.* into v_option from (
    select o.*, sum(o.weight) over (order by o.id) running_weight
    from public.game_reward_options o where o.game_type = 'spin' and o.active
  ) option_row where option_row.running_weight >= v_pick order by option_row.running_weight limit 1;
  v_tokens := least(v_option.points_awarded, 100 - v_wallet.points);
  update public.wallet_balances set points = points + v_tokens, xp = xp + v_option.xp_awarded,
    spin_tickets = spin_tickets - 1, updated_at = now()
  where user_id = auth.uid() returning * into v_wallet;
  insert into public.game_plays (id, user_id, game_type, cost, reward_option_id, points_awarded, xp_awarded)
  values (v_play, auth.uid(), 'spin', 0, v_option.id, v_tokens, v_option.xp_awarded);
  insert into public.loyalty_ledger (user_id, reason, points_delta, xp_delta, reference_type, reference_id)
  values (auth.uid(), 'Ruota dei premi', v_tokens, v_option.xp_awarded, 'game_play', v_play);
  if v_option.reward_definition_id is not null then
    insert into public.user_rewards (user_id, reward_definition_id, source_play_id)
    values (auth.uid(), v_option.reward_definition_id, v_play);
    select kind into v_reward_kind from public.reward_definitions where id = v_option.reward_definition_id;
  end if;
  return jsonb_build_object('play_id', v_play, 'reward_code', v_option.code, 'reward_label', v_option.label,
    'points_awarded', v_tokens, 'xp_awarded', v_option.xp_awarded, 'reward_kind', v_reward_kind,
    'balance', v_wallet.points, 'xp', v_wallet.xp, 'spin_tickets', v_wallet.spin_tickets);
end $$;

create or replace function public.submit_feedback(p_order_id uuid, p_rating integer, p_message text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform public.assert_allowed();
  if p_rating not between 1 and 5 or char_length(trim(coalesce(p_message, ''))) not between 3 and 500 then
    raise exception 'FEEDBACK_INVALID';
  end if;
  if not exists (select 1 from public.orders where id = p_order_id and user_id = auth.uid() and status = 'completed') then
    raise exception 'COMPLETED_ORDER_REQUIRED';
  end if;
  insert into public.feedback (order_id, user_id, rating, message)
  values (p_order_id, auth.uid(), p_rating, trim(p_message)) returning id into v_id;
  return v_id;
end $$;

create or replace function public.admin_moderate_feedback(p_feedback_id uuid, p_status public.feedback_status)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'ADMIN_MFA_REQUIRED'; end if;
  if p_status not in ('published', 'hidden') then raise exception 'FEEDBACK_STATUS_INVALID'; end if;
  update public.feedback set status = p_status, moderated_by = auth.uid(), moderated_at = now()
    where id = p_feedback_id;
  if not found then raise exception 'FEEDBACK_NOT_FOUND'; end if;
end $$;

create or replace function public.admin_set_token_tier(p_minimum_units integer, p_tokens_awarded integer)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'ADMIN_MFA_REQUIRED'; end if;
  if p_minimum_units not in (50,100,300,500,1000) or p_tokens_awarded not between 0 and 100 then
    raise exception 'TIER_INVALID';
  end if;
  update public.token_reward_tiers set tokens_awarded = p_tokens_awarded, updated_at = now()
    where minimum_units = p_minimum_units;
  update public.product_variants set token_award = p_tokens_awarded where unit_amount = p_minimum_units;
end $$;

create or replace function public.admin_adjust_wallet(p_user_id uuid, p_points_delta integer, p_xp_delta integer, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admin MFA required'; end if;
  if length(trim(coalesce(p_reason, ''))) < 4 then raise exception 'Motivo richiesto'; end if;
  update public.wallet_balances
  set points = points + p_points_delta, xp = xp + p_xp_delta, updated_at = now()
  where user_id = p_user_id
    and points + p_points_delta between 0 and 100
    and xp + p_xp_delta >= 0;
  if not found then raise exception 'Saldo gettoni non valido: il limite e 100'; end if;
  insert into public.loyalty_ledger (user_id, reason, points_delta, xp_delta, reference_type)
  values (p_user_id, 'Admin gettoni: ' || p_reason, p_points_delta, p_xp_delta, 'admin_adjustment');
  insert into public.admin_audit_log (actor_id, action, entity_type, entity_id, details)
  values (auth.uid(), 'wallet.adjust', 'profile', p_user_id::text,
    jsonb_build_object('reason', p_reason, 'tokens', p_points_delta, 'xp', p_xp_delta));
end $$;

create or replace function public.admin_create_demo_product(
  p_name text, p_category_id uuid, p_prices jsonb, p_announce boolean default false
)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_product_id uuid;
  v_slug text;
  v_name text := trim(p_name);
  v_required integer[] := array[50,100,300,500,1000];
  v_unit integer;
  v_price numeric;
begin
  if not public.is_admin() then raise exception 'ADMIN_MFA_REQUIRED'; end if;
  if char_length(v_name) = 0 then raise exception 'INVALID_PRODUCT'; end if;
  foreach v_unit in array v_required loop
    v_price := (p_prices ->> v_unit::text)::numeric;
    if v_price is null or v_price < 0 then raise exception 'INVALID_PACKAGE_PRICE:%', v_unit; end if;
  end loop;
  v_slug := 'demo-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  insert into public.products (category_id, slug, name, description, badge, featured, published, rating)
  values (p_category_id, v_slug, v_name, 'Articolo dimostrativo. Nessuna vendita o consegna reale.', 'NEW', false, false, 0)
  returning id into v_product_id;
  foreach v_unit in array v_required loop
    insert into public.product_variants (product_id, label, price, sort_order, unit_amount, token_award)
    select v_product_id, v_unit || ' units', (p_prices ->> v_unit::text)::numeric, v_unit, v_unit, tokens_awarded
    from public.token_reward_tiers where minimum_units = v_unit;
  end loop;
  insert into public.inventory_status (variant_id)
  select id from public.product_variants where product_id = v_product_id;
  if p_announce then
    insert into public.broadcasts (kind, title, message, product_id, status, created_by)
    values ('product_new', 'Nuova demo item: ' || v_name, 'Nuova voce aggiunta al catalogo demo.', v_product_id, 'draft', auth.uid());
  end if;
  return v_product_id;
end $$;

grant execute on function public.submit_test_order_internal(uuid, jsonb, text, text, text, integer) to service_role;
revoke execute on function public.submit_test_order_internal(uuid, jsonb, text, text, text, integer) from authenticated, public, anon;
revoke execute on function public.submit_test_order_internal(uuid, jsonb, text, text) from service_role;
revoke execute on function public.claim_daily_bonus() from authenticated;
revoke execute on function public.admin_create_product(text, uuid, numeric, numeric, boolean) from authenticated;
grant execute on function public.submit_feedback(uuid, integer, text) to authenticated;
revoke execute on function public.submit_feedback(uuid, integer, text) from public, anon;
grant execute on function public.admin_moderate_feedback(uuid, public.feedback_status) to authenticated;
revoke execute on function public.admin_moderate_feedback(uuid, public.feedback_status) from public, anon;
grant execute on function public.admin_set_token_tier(integer, integer) to authenticated;
revoke execute on function public.admin_set_token_tier(integer, integer) from public, anon;
grant execute on function public.admin_create_demo_product(text, uuid, jsonb, boolean) to authenticated;
revoke execute on function public.admin_create_demo_product(text, uuid, jsonb, boolean) from public, anon;
grant execute on function public.get_demo_info() to authenticated;
revoke execute on function public.get_demo_info() from public, anon;
