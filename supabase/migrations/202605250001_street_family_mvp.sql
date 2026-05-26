create extension if not exists pgcrypto;

create type public.app_role as enum ('user', 'admin');
create type public.order_mode as enum ('test');
create type public.order_status as enum ('submitted', 'processing', 'completed', 'cancelled');
create type public.reward_kind as enum ('discount', 'free_delivery', 'xp_boost');
create type public.reward_state as enum ('available', 'redeemed', 'expired');
create type public.game_type as enum ('scratch', 'spin', 'box', 'daily');

create table public.staging_allowlist (
  telegram_subject text primary key,
  role public.app_role not null default 'user',
  enabled boolean not null default true,
  note text,
  created_at timestamptz not null default now()
);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  telegram_subject text unique,
  username text not null default 'member',
  avatar_url text,
  role public.app_role not null default 'user',
  blocked boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  slug text not null unique,
  sort_order integer not null default 0,
  published boolean not null default true
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  category_id uuid not null references public.categories(id),
  name text not null,
  slug text not null unique,
  description text not null default '',
  badge text check (badge in ('HOT', 'NEW') or badge is null),
  rating numeric(2,1) not null default 0 check (rating between 0 and 5),
  review_count integer not null default 0,
  featured boolean not null default false,
  published boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.product_variants (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  label text not null,
  price numeric(10,2) not null check (price >= 0),
  sort_order integer not null default 0,
  unique (product_id, label)
);

create table public.product_media (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  url text not null,
  media_type text not null default 'image' check (media_type in ('image', 'video')),
  alt text,
  sort_order integer not null default 0,
  published boolean not null default true
);

create table public.inventory_status (
  variant_id uuid primary key references public.product_variants(id) on delete cascade,
  available boolean not null default true,
  display_label text not null default 'Disponibile',
  updated_at timestamptz not null default now()
);

create table public.meetup_locations (
  id uuid primary key default gen_random_uuid(),
  city text not null,
  label text not null,
  active boolean not null default true,
  test_only boolean not null default true
);

create table public.app_settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);

create table public.levels (
  id uuid primary key default gen_random_uuid(),
  level_number integer not null unique,
  name text not null,
  xp_min integer not null check (xp_min >= 0),
  xp_max integer,
  color text not null,
  icon text not null
);

create table public.wallet_balances (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  points integer not null default 0 check (points >= 0),
  xp integer not null default 0 check (xp >= 0),
  streak integer not null default 0 check (streak >= 0),
  last_daily_claim date,
  updated_at timestamptz not null default now()
);

create table public.loyalty_ledger (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  reason text not null,
  points_delta integer not null default 0,
  xp_delta integer not null default 0,
  reference_type text,
  reference_id uuid,
  mode public.order_mode not null default 'test',
  created_at timestamptz not null default now()
);

create table public.reward_definitions (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  label text not null,
  kind public.reward_kind not null,
  value numeric(10,2),
  active boolean not null default true
);

create table public.user_rewards (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  reward_definition_id uuid not null references public.reward_definitions(id),
  state public.reward_state not null default 'available',
  source_play_id uuid,
  redeemed_order_id uuid,
  created_at timestamptz not null default now()
);

create table public.game_configs (
  game_type public.game_type primary key,
  title text not null,
  cost integer not null default 0 check (cost >= 0),
  active boolean not null default true,
  xp_on_points_win integer not null default 0 check (xp_on_points_win >= 0)
);

create table public.game_reward_options (
  id uuid primary key default gen_random_uuid(),
  game_type public.game_type not null references public.game_configs(game_type) on delete cascade,
  code text not null,
  label text not null,
  points_awarded integer not null default 0 check (points_awarded >= 0),
  xp_awarded integer not null default 0 check (xp_awarded >= 0),
  reward_definition_id uuid references public.reward_definitions(id),
  weight integer not null check (weight > 0),
  color text not null default '#A3FF12',
  active boolean not null default true,
  unique (game_type, code)
);

create table public.game_plays (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  game_type public.game_type not null,
  cost integer not null,
  reward_option_id uuid not null references public.game_reward_options(id),
  points_awarded integer not null default 0,
  xp_awarded integer not null default 0,
  mode public.order_mode not null default 'test',
  created_at timestamptz not null default now()
);

create table public.daily_claims (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  claimed_on date not null default current_date,
  streak integer not null,
  points_awarded integer not null,
  xp_awarded integer not null,
  mode public.order_mode not null default 'test',
  unique (user_id, claimed_on)
);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  display_id text not null unique,
  user_id uuid not null references public.profiles(id),
  mode public.order_mode not null default 'test',
  status public.order_status not null default 'submitted',
  fulfillment_method text not null check (fulfillment_method in ('meetup', 'delivery')),
  location_note text not null default '',
  total numeric(10,2) not null,
  points_awarded integer not null default 0,
  xp_awarded integer not null default 0,
  operator_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  variant_id uuid not null references public.product_variants(id),
  name_snapshot text not null,
  variant_label text not null,
  unit_price numeric(10,2) not null,
  quantity integer not null default 1 check (quantity > 0)
);

create table public.order_status_history (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  status public.order_status not null,
  changed_by uuid references public.profiles(id),
  note text,
  created_at timestamptz not null default now()
);

alter table public.user_rewards
  add constraint user_rewards_order_fk foreign key (redeemed_order_id) references public.orders(id);
alter table public.user_rewards
  add constraint user_rewards_play_fk foreign key (source_play_id) references public.game_plays(id);

create table public.admin_audit_log (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid not null references public.profiles(id),
  action text not null,
  entity_type text not null,
  entity_id text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create or replace function public.touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
create trigger products_touch before update on public.products for each row execute function public.touch_updated_at();
create trigger profiles_touch before update on public.profiles for each row execute function public.touch_updated_at();
create trigger orders_touch before update on public.orders for each row execute function public.touch_updated_at();

insert into storage.buckets (id, name, public)
values ('product-media', 'product-media', false)
on conflict (id) do nothing;

create or replace function public.telegram_subject()
returns text language sql stable as $$
  select coalesce(
    auth.jwt() -> 'user_metadata' ->> 'sub',
    auth.jwt() -> 'user_metadata' ->> 'id',
    auth.jwt() ->> 'sub'
  )
$$;

create or replace function public.is_allowed()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles p
    join public.staging_allowlist a on a.telegram_subject = p.telegram_subject
    where p.id = auth.uid() and a.enabled and not p.blocked
  )
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_allowed()
    and exists (select 1 from public.profiles where id = auth.uid() and role = 'admin')
    and coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2'
$$;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_subject text := coalesce(new.raw_user_meta_data ->> 'sub', new.raw_user_meta_data ->> 'id', new.id::text);
  v_role public.app_role;
begin
  select role into v_role from public.staging_allowlist where telegram_subject = v_subject and enabled;
  insert into public.profiles (id, telegram_subject, username, avatar_url, role)
  values (
    new.id,
    v_subject,
    coalesce(new.raw_user_meta_data ->> 'preferred_username', new.raw_user_meta_data ->> 'username', 'member'),
    coalesce(new.raw_user_meta_data ->> 'picture', new.raw_user_meta_data ->> 'photo_url'),
    coalesce(v_role, 'user')
  );
  insert into public.wallet_balances (user_id, points) values (new.id, 450);
  return new;
end $$;
create trigger auth_user_profile after insert on auth.users for each row execute function public.handle_new_user();

create or replace function public.sync_allowlist_role()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.profiles set role = new.role where telegram_subject = new.telegram_subject;
  return new;
end $$;
create trigger allowlist_role_sync after insert or update of role on public.staging_allowlist
  for each row execute function public.sync_allowlist_role();

alter table public.staging_allowlist enable row level security;
alter table public.profiles enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.product_variants enable row level security;
alter table public.product_media enable row level security;
alter table public.inventory_status enable row level security;
alter table public.meetup_locations enable row level security;
alter table public.app_settings enable row level security;
alter table public.levels enable row level security;
alter table public.wallet_balances enable row level security;
alter table public.loyalty_ledger enable row level security;
alter table public.reward_definitions enable row level security;
alter table public.user_rewards enable row level security;
alter table public.game_configs enable row level security;
alter table public.game_reward_options enable row level security;
alter table public.game_plays enable row level security;
alter table public.daily_claims enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.order_status_history enable row level security;
alter table public.admin_audit_log enable row level security;

create policy admin_all_allowlist on public.staging_allowlist for all using (public.is_admin()) with check (public.is_admin());
create policy own_profile_read on public.profiles for select using (public.is_allowed() and id = auth.uid() or public.is_admin());
create policy admin_profiles on public.profiles for update using (public.is_admin()) with check (public.is_admin());

create policy member_categories_read on public.categories for select using (public.is_allowed() and published or public.is_admin());
create policy member_products_read on public.products for select using (public.is_allowed() and published or public.is_admin());
create policy member_variants_read on public.product_variants for select using (public.is_allowed() or public.is_admin());
create policy member_media_read on public.product_media for select using (public.is_allowed() and published or public.is_admin());
create policy member_inventory_read on public.inventory_status for select using (public.is_allowed() or public.is_admin());
create policy member_meetups_read on public.meetup_locations for select using (public.is_allowed() and active or public.is_admin());
create policy member_levels_read on public.levels for select using (public.is_allowed() or public.is_admin());
create policy member_games_read on public.game_configs for select using (public.is_allowed() and active or public.is_admin());
create policy member_game_options_read on public.game_reward_options for select using (public.is_allowed() and active or public.is_admin());

create policy own_wallet_read on public.wallet_balances for select using (public.is_allowed() and user_id = auth.uid() or public.is_admin());
create policy own_ledger_read on public.loyalty_ledger for select using (public.is_allowed() and user_id = auth.uid() or public.is_admin());
create policy own_rewards_read on public.user_rewards for select using (public.is_allowed() and user_id = auth.uid() or public.is_admin());
create policy own_plays_read on public.game_plays for select using (public.is_allowed() and user_id = auth.uid() or public.is_admin());
create policy own_daily_read on public.daily_claims for select using (public.is_allowed() and user_id = auth.uid() or public.is_admin());
create policy own_orders_read on public.orders for select using (public.is_allowed() and user_id = auth.uid() or public.is_admin());
create policy own_order_items_read on public.order_items for select using (
  exists (select 1 from public.orders o where o.id = order_id and ((public.is_allowed() and o.user_id = auth.uid()) or public.is_admin()))
);
create policy own_order_history_read on public.order_status_history for select using (
  exists (select 1 from public.orders o where o.id = order_id and ((public.is_allowed() and o.user_id = auth.uid()) or public.is_admin()))
);
create policy admin_audit_read on public.admin_audit_log for select using (public.is_admin());

create policy admin_categories_write on public.categories for all using (public.is_admin()) with check (public.is_admin());
create policy admin_products_write on public.products for all using (public.is_admin()) with check (public.is_admin());
create policy admin_variants_write on public.product_variants for all using (public.is_admin()) with check (public.is_admin());
create policy admin_media_write on public.product_media for all using (public.is_admin()) with check (public.is_admin());
create policy admin_inventory_write on public.inventory_status for all using (public.is_admin()) with check (public.is_admin());
create policy admin_meetups_write on public.meetup_locations for all using (public.is_admin()) with check (public.is_admin());
create policy admin_settings_write on public.app_settings for all using (public.is_admin()) with check (public.is_admin());
create policy admin_levels_write on public.levels for all using (public.is_admin()) with check (public.is_admin());
create policy admin_games_write on public.game_configs for all using (public.is_admin()) with check (public.is_admin());
create policy admin_options_write on public.game_reward_options for all using (public.is_admin()) with check (public.is_admin());
create policy admin_rewards_def_write on public.reward_definitions for all using (public.is_admin()) with check (public.is_admin());
create policy admin_orders_write on public.orders for update using (public.is_admin()) with check (public.is_admin());
create policy member_reward_defs_read on public.reward_definitions for select using (public.is_allowed() or public.is_admin());

create policy product_media_member_objects on storage.objects for select
  using (bucket_id = 'product-media' and public.is_allowed());
create policy product_media_admin_objects on storage.objects for all
  using (bucket_id = 'product-media' and public.is_admin())
  with check (bucket_id = 'product-media' and public.is_admin());

create or replace function public.audit_admin_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_row jsonb;
begin
  if auth.uid() is not null and public.is_admin() then
    v_row := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
    insert into public.admin_audit_log (actor_id, action, entity_type, entity_id, details)
    values (
      auth.uid(), lower(tg_op), tg_table_name,
      coalesce(v_row ->> 'id', v_row ->> 'telegram_subject', ''),
      jsonb_build_object('operation', tg_op)
    );
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;

create trigger audit_categories after insert or update or delete on public.categories for each row execute function public.audit_admin_change();
create trigger audit_products after insert or update or delete on public.products for each row execute function public.audit_admin_change();
create trigger audit_product_variants after insert or update or delete on public.product_variants for each row execute function public.audit_admin_change();
create trigger audit_product_media after insert or update or delete on public.product_media for each row execute function public.audit_admin_change();
create trigger audit_inventory after insert or update or delete on public.inventory_status for each row execute function public.audit_admin_change();
create trigger audit_locations after insert or update or delete on public.meetup_locations for each row execute function public.audit_admin_change();
create trigger audit_levels after insert or update or delete on public.levels for each row execute function public.audit_admin_change();
create trigger audit_games after insert or update or delete on public.game_configs for each row execute function public.audit_admin_change();
create trigger audit_reward_options after insert or update or delete on public.game_reward_options for each row execute function public.audit_admin_change();
create trigger audit_allowlist after insert or update or delete on public.staging_allowlist for each row execute function public.audit_admin_change();

create or replace function public.assert_allowed() returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_allowed() then raise exception 'Staging access denied: allowlist required'; end if;
end $$;

create or replace function public.get_my_profile()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  perform public.assert_allowed();
  select jsonb_build_object(
    'id', p.id, 'username', p.username, 'avatar_url', p.avatar_url, 'role', p.role,
    'points', w.points, 'xp', w.xp, 'streak', w.streak,
    'level_number', coalesce(l.level_number, 1),
    'next_level_xp', (select min(xp_min) from public.levels where xp_min > w.xp),
    'total_orders', (select count(*) from public.orders where user_id = p.id)
  ) into v from public.profiles p
  join public.wallet_balances w on w.user_id = p.id
  left join lateral (
    select * from public.levels where xp_min <= w.xp order by xp_min desc limit 1
  ) l on true where p.id = auth.uid();
  return v;
end $$;

create or replace function public.get_catalog()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_allowed();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id, 'name', p.name, 'category', c.name, 'description', p.description,
      'badge', p.badge, 'rating', p.rating, 'review_count', p.review_count,
      'variants', (select jsonb_agg(jsonb_build_object('id', v.id, 'label', v.label, 'price', v.price, 'available', i.available) order by v.sort_order)
        from public.product_variants v join public.inventory_status i on i.variant_id = v.id where v.product_id = p.id),
      'media', (select jsonb_agg(jsonb_build_object('id', m.id, 'url', m.url, 'type', m.media_type, 'alt', m.alt, 'sort_order', m.sort_order) order by m.sort_order)
        from public.product_media m where m.product_id = p.id and m.published)
    ) order by p.featured desc, p.name)
    from public.products p join public.categories c on c.id = p.category_id
    where p.published and c.published
  ), '[]'::jsonb);
end $$;

create or replace function public.play_game(p_game_type public.game_type)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_wallet public.wallet_balances%rowtype;
  v_config public.game_configs%rowtype;
  v_option public.game_reward_options%rowtype;
  v_total integer;
  v_pick integer;
  v_play uuid := gen_random_uuid();
  v_reward_kind public.reward_kind;
begin
  perform public.assert_allowed();
  if p_game_type = 'daily' then raise exception 'Use claim_daily_bonus'; end if;
  select * into v_config from public.game_configs where game_type = p_game_type and active for update;
  if not found then raise exception 'Game unavailable'; end if;
  select * into v_wallet from public.wallet_balances where user_id = auth.uid() for update;
  if v_wallet.points < v_config.cost then raise exception 'Punti insufficienti'; end if;
  select sum(weight) into v_total from public.game_reward_options where game_type = p_game_type and active;
  if coalesce(v_total, 0) <= 0 then raise exception 'Reward configuration invalid'; end if;
  v_pick := floor(random() * v_total)::integer + 1;
  select option_row.* into v_option from (
    select o.*, sum(o.weight) over (order by o.id) running_weight
    from public.game_reward_options o where o.game_type = p_game_type and o.active
  ) option_row where option_row.running_weight >= v_pick order by option_row.running_weight limit 1;
  update public.wallet_balances set
    points = points - v_config.cost + v_option.points_awarded,
    xp = xp + v_option.xp_awarded,
    updated_at = now()
  where user_id = auth.uid() returning * into v_wallet;
  insert into public.game_plays (id, user_id, game_type, cost, reward_option_id, points_awarded, xp_awarded)
  values (v_play, auth.uid(), p_game_type, v_config.cost, v_option.id, v_option.points_awarded, v_option.xp_awarded);
  insert into public.loyalty_ledger (user_id, reason, points_delta, xp_delta, reference_type, reference_id)
  values (auth.uid(), 'Game: ' || v_config.title, v_option.points_awarded - v_config.cost, v_option.xp_awarded, 'game_play', v_play);
  if v_option.reward_definition_id is not null then
    insert into public.user_rewards (user_id, reward_definition_id, source_play_id)
    values (auth.uid(), v_option.reward_definition_id, v_play);
    select kind into v_reward_kind from public.reward_definitions where id = v_option.reward_definition_id;
  end if;
  return jsonb_build_object('play_id', v_play, 'reward_code', v_option.code, 'reward_label', v_option.label,
    'points_awarded', v_option.points_awarded, 'xp_awarded', v_option.xp_awarded, 'reward_kind', v_reward_kind,
    'balance', v_wallet.points, 'xp', v_wallet.xp);
end $$;

create or replace function public.claim_daily_bonus()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_wallet public.wallet_balances%rowtype;
  v_streak integer;
  v_points integer;
  v_xp integer;
  v_claim uuid := gen_random_uuid();
begin
  perform public.assert_allowed();
  select * into v_wallet from public.wallet_balances where user_id = auth.uid() for update;
  if v_wallet.last_daily_claim = current_date then raise exception 'Bonus giornaliero gia riscosso'; end if;
  v_streak := case when v_wallet.last_daily_claim = current_date - 1 then v_wallet.streak + 1 else 1 end;
  v_points := (array[10,15,20,25,30,40,50])[least(v_streak, 7)];
  v_xp := floor(v_points / 2);
  update public.wallet_balances set points = points + v_points, xp = xp + v_xp, streak = v_streak,
    last_daily_claim = current_date, updated_at = now() where user_id = auth.uid() returning * into v_wallet;
  insert into public.daily_claims (id, user_id, streak, points_awarded, xp_awarded)
    values (v_claim, auth.uid(), v_streak, v_points, v_xp);
  insert into public.loyalty_ledger (user_id, reason, points_delta, xp_delta, reference_type, reference_id)
    values (auth.uid(), 'Daily Bonus', v_points, v_xp, 'daily_claim', v_claim);
  return jsonb_build_object('claim_id', v_claim, 'reward_label', '+' || v_points || ' Punti',
    'points_awarded', v_points, 'xp_awarded', v_xp, 'balance', v_wallet.points, 'xp', v_wallet.xp);
end $$;

create or replace function public.submit_test_order(p_items jsonb, p_method text, p_location_note text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_order uuid := gen_random_uuid();
  v_display text := '#TEST-' || upper(substr(replace(v_order::text, '-', ''), 1, 8));
  v_total numeric(10,2);
  v_points integer;
  v_xp integer;
  v_wallet public.wallet_balances%rowtype;
  v_valid_count integer;
  v_points_multiplier numeric := coalesce((select (value ->> 'points_multiplier')::numeric from public.app_settings where key = 'order_rewards'), 0.5);
  v_xp_multiplier numeric := coalesce((select (value ->> 'xp_multiplier')::numeric from public.app_settings where key = 'order_rewards'), 0.5);
begin
  perform public.assert_allowed();
  if p_method not in ('meetup', 'delivery') then raise exception 'Metodo non valido'; end if;
  if jsonb_array_length(p_items) = 0 then raise exception 'Carrello vuoto'; end if;
  if exists (
    select 1 from jsonb_array_elements(p_items) item
    where coalesce((item ->> 'quantity')::integer, 1) <> 1
  ) then raise exception 'Quantita test non valida'; end if;
  select count(*) into v_valid_count
  from jsonb_array_elements(p_items) item
  join public.product_variants v on v.id = (item ->> 'variant_id')::uuid
  join public.products p on p.id = v.product_id and p.published
  join public.inventory_status i on i.variant_id = v.id and i.available;
  if v_valid_count <> jsonb_array_length(p_items) then raise exception 'Prodotto non disponibile'; end if;
  select sum(v.price * greatest(coalesce((item ->> 'quantity')::integer, 1), 1)) into v_total
  from jsonb_array_elements(p_items) item
  join public.product_variants v on v.id = (item ->> 'variant_id')::uuid
  join public.products p on p.id = v.product_id and p.published
  join public.inventory_status i on i.variant_id = v.id and i.available;
  if v_total is null then raise exception 'Prodotto non disponibile'; end if;
  v_points := floor(v_total * v_points_multiplier);
  v_xp := floor(v_total * v_xp_multiplier);
  insert into public.orders (id, display_id, user_id, fulfillment_method, location_note, total, points_awarded, xp_awarded)
  values (v_order, v_display, auth.uid(), p_method, left(coalesce(p_location_note, ''), 160), v_total, v_points, v_xp);
  insert into public.order_items (order_id, variant_id, name_snapshot, variant_label, unit_price, quantity)
  select v_order, v.id, p.name, v.label, v.price, greatest(coalesce((item ->> 'quantity')::integer, 1), 1)
  from jsonb_array_elements(p_items) item join public.product_variants v on v.id = (item ->> 'variant_id')::uuid
  join public.products p on p.id = v.product_id;
  insert into public.order_status_history (order_id, status, changed_by, note)
    values (v_order, 'submitted', auth.uid(), 'TEST MODE - no payment or fulfillment');
  update public.wallet_balances set points = points + v_points, xp = xp + v_xp, updated_at = now()
    where user_id = auth.uid() returning * into v_wallet;
  insert into public.loyalty_ledger (user_id, reason, points_delta, xp_delta, reference_type, reference_id)
    values (auth.uid(), 'Test order ' || v_display, v_points, v_xp, 'order', v_order);
  return jsonb_build_object('order_id', v_order, 'display_id', v_display, 'total', v_total,
    'points_awarded', v_points, 'xp_awarded', v_xp, 'balance', v_wallet.points, 'xp', v_wallet.xp);
end $$;

create or replace function public.admin_update_order_status(p_order_id uuid, p_status public.order_status, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admin MFA required'; end if;
  update public.orders set status = p_status, operator_note = nullif(trim(p_note), '') where id = p_order_id;
  if not found then raise exception 'Richiesta non trovata'; end if;
  insert into public.order_status_history (order_id, status, changed_by, note)
    values (p_order_id, p_status, auth.uid(), nullif(trim(p_note), ''));
  insert into public.admin_audit_log (actor_id, action, entity_type, entity_id, details)
    values (auth.uid(), 'order.status', 'order', p_order_id::text, jsonb_build_object('status', p_status, 'note', p_note));
end $$;

create or replace function public.redeem_reward(p_order_id uuid, p_reward_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_allowed();
  update public.user_rewards set state = 'redeemed', redeemed_order_id = p_order_id
  where id = p_reward_id and user_id = auth.uid() and state = 'available'
    and exists (select 1 from public.orders where id = p_order_id and user_id = auth.uid() and mode = 'test');
  if not found then raise exception 'Premio non applicabile'; end if;
end $$;

create or replace function public.admin_adjust_wallet(p_user_id uuid, p_points_delta integer, p_xp_delta integer, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admin MFA required'; end if;
  if length(trim(coalesce(p_reason, ''))) < 4 then raise exception 'Motivo richiesto'; end if;
  update public.wallet_balances set points = points + p_points_delta, xp = xp + p_xp_delta, updated_at = now()
    where user_id = p_user_id and points + p_points_delta >= 0 and xp + p_xp_delta >= 0;
  if not found then raise exception 'Saldo non valido'; end if;
  insert into public.loyalty_ledger (user_id, reason, points_delta, xp_delta, reference_type)
    values (p_user_id, 'Admin: ' || p_reason, p_points_delta, p_xp_delta, 'admin_adjustment');
  insert into public.admin_audit_log (actor_id, action, entity_type, entity_id, details)
    values (auth.uid(), 'wallet.adjust', 'profile', p_user_id::text,
      jsonb_build_object('reason', p_reason, 'points', p_points_delta, 'xp', p_xp_delta));
end $$;

create or replace function public.admin_dashboard()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admin MFA required'; end if;
  return jsonb_build_object(
    'allowlisted_users', (select count(*) from public.staging_allowlist where enabled),
    'submitted_orders', (select count(*) from public.orders where status = 'submitted'),
    'game_plays', (select count(*) from public.game_plays),
    'issued_points', (select coalesce(sum(points_delta), 0) from public.loyalty_ledger where points_delta > 0)
  );
end $$;

grant execute on function public.get_my_profile() to authenticated;
grant execute on function public.get_catalog() to authenticated;
grant execute on function public.play_game(public.game_type) to authenticated;
grant execute on function public.claim_daily_bonus() to authenticated;
grant execute on function public.submit_test_order(jsonb, text, text) to authenticated;
grant execute on function public.redeem_reward(uuid, uuid) to authenticated;
grant execute on function public.admin_adjust_wallet(uuid, integer, integer, text) to authenticated;
grant execute on function public.admin_dashboard() to authenticated;
grant execute on function public.admin_update_order_status(uuid, public.order_status, text) to authenticated;
revoke execute on function public.get_my_profile() from public, anon;
revoke execute on function public.get_catalog() from public, anon;
revoke execute on function public.play_game(public.game_type) from public, anon;
revoke execute on function public.claim_daily_bonus() from public, anon;
revoke execute on function public.submit_test_order(jsonb, text, text) from public, anon;
revoke execute on function public.redeem_reward(uuid, uuid) from public, anon;
revoke execute on function public.admin_adjust_wallet(uuid, integer, integer, text) from public, anon;
revoke execute on function public.admin_dashboard() from public, anon;
revoke execute on function public.admin_update_order_status(uuid, public.order_status, text) from public, anon;

insert into public.categories (id, name, slug, sort_order) values
('10000000-0000-0000-0000-000000000001', 'Flower', 'flower', 1),
('10000000-0000-0000-0000-000000000002', 'Sativa', 'sativa', 2),
('10000000-0000-0000-0000-000000000003', 'Indica', 'indica', 3),
('10000000-0000-0000-0000-000000000004', 'Hybrid', 'hybrid', 4),
('10000000-0000-0000-0000-000000000005', 'Hash', 'hash', 5);

insert into public.products (id, category_id, name, slug, description, badge, rating, review_count, featured, published) values
('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','OG Kush','og-kush','Test catalogue item only. No sale or fulfillment.','HOT',4.8,142,true,true),
('20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000002','Purple Haze','purple-haze','Test catalogue item only. No sale or fulfillment.','HOT',4.9,98,true,true),
('20000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000003','Gorilla Glue','gorilla-glue','Test catalogue item only. No sale or fulfillment.','NEW',4.7,54,false,true),
('20000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000004','Gelato #33','gelato-33','Test catalogue item only. No sale or fulfillment.',null,5.0,203,true,true),
('20000000-0000-0000-0000-000000000005','10000000-0000-0000-0000-000000000002','Amnesia Haze','amnesia-haze','Test catalogue item only. No sale or fulfillment.','HOT',4.6,87,false,true),
('20000000-0000-0000-0000-000000000006','10000000-0000-0000-0000-000000000003','Northern Lights','northern-lights','Test catalogue item only. No sale or fulfillment.',null,4.8,165,false,true),
('20000000-0000-0000-0000-000000000007','10000000-0000-0000-0000-000000000005','Moroccan Hash','moroccan-hash','Test catalogue item only. No sale or fulfillment.','NEW',4.5,33,false,true),
('20000000-0000-0000-0000-000000000008','10000000-0000-0000-0000-000000000004','Blue Dream','blue-dream','Test catalogue item only. No sale or fulfillment.',null,4.7,119,false,true);

insert into public.product_variants (id, product_id, label, price, sort_order)
select ('30000000-0000-0000-0000-' || lpad(((n * 2) - 1)::text, 12, '0'))::uuid, p.id, '1g',
  case n when 2 then 35 when 4 then 40 when 5 then 35 when 7 then 20 when 8 then 35 else 30 end, 1
from (select id, row_number() over (order by id)::integer n from public.products) p
union all
select ('30000000-0000-0000-0000-' || lpad((n * 2)::text, 12, '0'))::uuid, p.id, '2g',
  case n when 2 then 60 when 4 then 70 when 5 then 60 when 7 then 35 when 8 then 60 else 50 end, 2
from (select id, row_number() over (order by id)::integer n from public.products) p;
insert into public.inventory_status (variant_id) select id from public.product_variants;

insert into public.product_media (product_id, url, alt) values
('20000000-0000-0000-0000-000000000001','https://images.unsplash.com/photo-1759315878838-f96e975812c8?w=600&q=80','OG Kush test'),
('20000000-0000-0000-0000-000000000002','https://images.unsplash.com/photo-1760078328371-2ed51cd13307?w=600&q=80','Purple Haze test'),
('20000000-0000-0000-0000-000000000003','https://images.unsplash.com/photo-1596129050968-24ea0d26f0ce?w=600&q=80','Gorilla Glue test'),
('20000000-0000-0000-0000-000000000004','https://images.unsplash.com/photo-1763750581767-b367bcd6c117?w=600&q=80','Gelato test'),
('20000000-0000-0000-0000-000000000005','https://images.unsplash.com/photo-1767036841733-cf7f5c40c18d?w=600&q=80','Amnesia test'),
('20000000-0000-0000-0000-000000000006','https://images.unsplash.com/photo-1765300013271-ab0bbbecdaa1?w=600&q=80','Northern Lights test'),
('20000000-0000-0000-0000-000000000007','https://images.unsplash.com/photo-1777447458426-43f11f1f7667?w=600&q=80','Moroccan Hash test'),
('20000000-0000-0000-0000-000000000008','https://images.unsplash.com/photo-1585232004423-244e0e6904e3?w=600&q=80','Blue Dream test');

insert into public.levels (level_number, name, xp_min, xp_max, color, icon) values
(1,'Rookie',0,100,'#6B7280','START'), (2,'Hustler',100,300,'#3B82F6','XP'),
(3,'Street OG',300,600,'#8B5CF6','OG'), (4,'Legend',600,1000,'#F59E0B','PRO'),
(5,'Don',1000,null,'#EF4444','MAX');

insert into public.reward_definitions (id, code, label, kind, value) values
('40000000-0000-0000-0000-000000000001','discount_5','Sconto 5%','discount',5),
('40000000-0000-0000-0000-000000000002','discount_10','Sconto 10%','discount',10),
('40000000-0000-0000-0000-000000000003','free_delivery','Free Delivery','free_delivery',null),
('40000000-0000-0000-0000-000000000004','xp_boost','2x XP','xp_boost',2);
insert into public.game_configs (game_type, title, cost) values
('scratch','Scratch Card',10), ('spin','Spin Wheel',20), ('box','Mystery Box',30), ('daily','Daily Bonus',0);
insert into public.game_reward_options (game_type, code, label, points_awarded, xp_awarded, reward_definition_id, weight, color) values
('scratch','points_20','+20 Punti',20,10,null,38,'#A3FF12'), ('scratch','nothing','Niente',0,0,null,30,'#6B7280'),
('scratch','discount_5','Sconto 5%',0,0,'40000000-0000-0000-0000-000000000001',20,'#F59E0B'), ('scratch','free_delivery','Free Delivery',0,0,'40000000-0000-0000-0000-000000000003',12,'#3B82F6'),
('spin','points_50','+50 Punti',50,15,null,13,'#3B82F6'), ('spin','nothing','Niente',0,0,null,12,'#374151'),
('spin','points_20','+20 Punti',20,15,null,13,'#8B5CF6'), ('spin','discount_5','Sconto 5%',0,0,'40000000-0000-0000-0000-000000000001',12,'#A3FF12'),
('spin','points_10','+10 Punti',10,15,null,13,'#EF4444'), ('spin','free_delivery','Free Delivery',0,0,'40000000-0000-0000-0000-000000000003',12,'#10B981'),
('spin','points_30','+30 Punti',30,15,null,13,'#F97316'), ('spin','xp_boost','2x XP',0,50,'40000000-0000-0000-0000-000000000004',12,'#EC4899'),
('box','points_100','+100 Punti',100,20,null,8,'#EC4899'), ('box','points_50','+50 Punti',50,20,null,17,'#F59E0B'),
('box','points_30','+30 Punti',30,20,null,25,'#8B5CF6'), ('box','points_15','+15 Punti',15,20,null,30,'#3B82F6'),
('box','discount_10','Sconto 10%',0,0,'40000000-0000-0000-0000-000000000002',10,'#10B981'), ('box','nothing','Niente',0,0,null,10,'#6B7280');
insert into public.app_settings (key, value) values
('staging_banner', '{"text":"TEST MODE - no payment / no fulfillment"}'),
('order_rewards', '{"points_multiplier":0.5,"xp_multiplier":0.5}');
