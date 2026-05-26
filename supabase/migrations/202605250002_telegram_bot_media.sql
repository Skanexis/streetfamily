create type public.media_upload_status as enum ('uploading', 'ready', 'failed');

alter table public.product_media
  add column storage_path text,
  add column upload_status public.media_upload_status not null default 'ready',
  alter column url drop not null;

create table public.telegram_login_challenges (
  id uuid primary key default gen_random_uuid(),
  token_hash text not null unique,
  telegram_id text,
  state text not null default 'pending' check (state in ('pending', 'confirmed', 'consumed', 'expired', 'denied')),
  auth_token_hash text,
  expires_at timestamptz not null default now() + interval '10 minutes',
  created_at timestamptz not null default now(),
  confirmed_at timestamptz,
  consumed_at timestamptz
);
alter table public.telegram_login_challenges enable row level security;

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
    new.id,
    v_subject,
    coalesce(new.raw_user_meta_data ->> 'username', new.raw_user_meta_data ->> 'first_name', 'member'),
    new.raw_user_meta_data ->> 'avatar_url',
    coalesce(v_role, 'user')
  )
  on conflict (id) do update set
    telegram_subject = excluded.telegram_subject,
    username = excluded.username,
    avatar_url = excluded.avatar_url,
    role = excluded.role,
    updated_at = now();
  insert into public.wallet_balances (user_id, points) values (new.id, 450)
  on conflict (user_id) do nothing;
  return new;
end $$;

create or replace function public.validate_product_media_limit()
returns trigger language plpgsql set search_path = public as $$
declare
  v_images integer;
  v_videos integer;
begin
  select count(*) filter (where media_type = 'image'), count(*) filter (where media_type = 'video')
    into v_images, v_videos
  from public.product_media
  where product_id = new.product_id
    and upload_status <> 'failed'
    and id <> coalesce(new.id, gen_random_uuid());
  if new.media_type = 'image' and v_images >= 5 then
    raise exception 'Massimo 5 foto per prodotto';
  end if;
  if new.media_type = 'video' and v_videos >= 3 then
    raise exception 'Massimo 3 video per prodotto';
  end if;
  return new;
end $$;
create trigger product_media_limit before insert or update of product_id, media_type, upload_status on public.product_media
for each row execute function public.validate_product_media_limit();

drop policy if exists product_media_member_objects on storage.objects;
create policy product_media_member_objects on storage.objects for select
  using (bucket_id = 'product-media' and public.is_allowed());

create or replace function public.submit_test_order_internal(
  p_user_id uuid, p_items jsonb, p_method text, p_location_note text default ''
)
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
  if not exists (
    select 1 from public.profiles p join public.staging_allowlist a on a.telegram_subject = p.telegram_subject
    where p.id = p_user_id and a.enabled and not p.blocked
  ) then raise exception 'Staging access denied'; end if;
  if p_method not in ('meetup', 'delivery') then raise exception 'Metodo non valido'; end if;
  if jsonb_array_length(p_items) = 0 then raise exception 'Carrello vuoto'; end if;
  if exists (select 1 from jsonb_array_elements(p_items) item where coalesce((item ->> 'quantity')::integer, 1) <> 1)
    then raise exception 'Quantita test non valida'; end if;
  select count(*), sum(v.price) into v_valid_count, v_total
  from jsonb_array_elements(p_items) item
  join public.product_variants v on v.id = (item ->> 'variant_id')::uuid
  join public.products p on p.id = v.product_id and p.published
  join public.inventory_status i on i.variant_id = v.id and i.available;
  if v_valid_count <> jsonb_array_length(p_items) or v_total is null then raise exception 'Prodotto non disponibile'; end if;
  v_points := floor(v_total * v_points_multiplier);
  v_xp := floor(v_total * v_xp_multiplier);
  insert into public.orders (id, display_id, user_id, fulfillment_method, location_note, total, points_awarded, xp_awarded)
  values (v_order, v_display, p_user_id, p_method, left(coalesce(p_location_note, ''), 160), v_total, v_points, v_xp);
  insert into public.order_items (order_id, variant_id, name_snapshot, variant_label, unit_price, quantity)
  select v_order, v.id, p.name, v.label, v.price, 1
  from jsonb_array_elements(p_items) item join public.product_variants v on v.id = (item ->> 'variant_id')::uuid
  join public.products p on p.id = v.product_id;
  insert into public.order_status_history (order_id, status, changed_by, note)
  values (v_order, 'submitted', p_user_id, 'submitted');
  update public.wallet_balances set points = points + v_points, xp = xp + v_xp, updated_at = now()
  where user_id = p_user_id returning * into v_wallet;
  insert into public.loyalty_ledger (user_id, reason, points_delta, xp_delta, reference_type, reference_id)
  values (p_user_id, 'Test order ' || v_display, v_points, v_xp, 'order', v_order);
  return jsonb_build_object('order_id', v_order, 'display_id', v_display, 'total', v_total,
    'points_awarded', v_points, 'xp_awarded', v_xp, 'balance', v_wallet.points, 'xp', v_wallet.xp);
end $$;

revoke execute on function public.submit_test_order(jsonb, text, text) from authenticated, public, anon;
revoke execute on function public.submit_test_order_internal(uuid, jsonb, text, text) from public, anon, authenticated;
grant execute on function public.submit_test_order_internal(uuid, jsonb, text, text) to service_role;

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
      'media', (select jsonb_agg(jsonb_build_object('id', m.id, 'url', m.url, 'storage_path', m.storage_path,
        'upload_status', m.upload_status, 'type', m.media_type, 'alt', m.alt, 'sort_order', m.sort_order) order by m.sort_order)
        from public.product_media m where m.product_id = p.id and m.published and m.upload_status = 'ready')
    ) order by p.featured desc, p.name)
    from public.products p join public.categories c on c.id = p.category_id
    where p.published and c.published
  ), '[]'::jsonb);
end $$;
