create type public.broadcast_kind as enum ('announcement', 'product_new');
create type public.broadcast_status as enum ('draft', 'published', 'archived');

create table public.broadcasts (
  id uuid primary key default gen_random_uuid(),
  kind public.broadcast_kind not null default 'announcement',
  title text not null check (char_length(trim(title)) between 1 and 120),
  message text not null check (char_length(trim(message)) between 1 and 500),
  product_id uuid references public.products(id) on delete set null,
  status public.broadcast_status not null default 'draft',
  published_at timestamptz,
  expires_at timestamptz,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (status <> 'published' or published_at is not null),
  check (expires_at is null or published_at is null or expires_at > published_at)
);

create index broadcasts_public_feed_idx
  on public.broadcasts(status, published_at desc)
  where status = 'published';

create trigger touch_broadcasts_updated_at
  before update on public.broadcasts
  for each row execute procedure public.touch_updated_at();

alter table public.broadcasts enable row level security;

grant select, insert, update, delete on public.broadcasts to authenticated;

create policy member_broadcasts_read
  on public.broadcasts for select
  using (
    public.is_allowed()
    and status = 'published'
    and (expires_at is null or expires_at > now())
  );

create policy admin_broadcasts_all
  on public.broadcasts for all
  using (public.is_admin())
  with check (public.is_admin());

create trigger audit_broadcasts
  after insert or update or delete on public.broadcasts
  for each row execute procedure public.audit_admin_change();

create or replace function public.admin_create_broadcast(
  p_title text,
  p_message text,
  p_publish boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if not public.is_admin() then
    raise exception 'ADMIN_MFA_REQUIRED';
  end if;

  insert into public.broadcasts (
    kind,
    title,
    message,
    status,
    published_at,
    created_by
  ) values (
    'announcement',
    trim(p_title),
    trim(p_message),
    case when p_publish then 'published'::public.broadcast_status else 'draft'::public.broadcast_status end,
    case when p_publish then now() else null end,
    auth.uid()
  )
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.admin_create_product(
  p_name text,
  p_category_id uuid,
  p_price1 numeric,
  p_price2 numeric,
  p_announce boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_product_id uuid;
  v_slug text;
  v_name text := trim(p_name);
begin
  if not public.is_admin() then
    raise exception 'ADMIN_MFA_REQUIRED';
  end if;

  if char_length(v_name) = 0 or p_price1 < 0 or p_price2 < 0 then
    raise exception 'INVALID_PRODUCT';
  end if;

  v_slug := nullif(
    trim(both '-' from regexp_replace(lower(v_name), '[^a-z0-9]+', '-', 'g')),
    ''
  );
  v_slug := coalesce(v_slug, 'product') || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);

  insert into public.products (
    category_id,
    slug,
    name,
    description,
    badge,
    featured,
    published,
    rating
  ) values (
    p_category_id,
    v_slug,
    v_name,
    'Premium quality product.',
    'NEW',
    false,
    false,
    5
  )
  returning id into v_product_id;

  insert into public.product_variants (product_id, label, price, sort_order)
  values
    (v_product_id, '1g', p_price1, 0),
    (v_product_id, '2g', p_price2, 1);

  insert into public.inventory_status (variant_id)
  select id
  from public.product_variants
  where product_id = v_product_id;

  if p_announce then
    insert into public.broadcasts (
      kind,
      title,
      message,
      product_id,
      status,
      created_by
    ) values (
      'product_new',
      'Nuovo prodotto: ' || v_name,
      'Nuovo prodotto aggiunto al catalogo test.',
      v_product_id,
      'draft',
      auth.uid()
    );
  end if;

  return v_product_id;
end;
$$;

revoke all on function public.admin_create_broadcast(text, text, boolean) from public, anon;
revoke all on function public.admin_create_product(text, uuid, numeric, numeric, boolean) from public, anon;
grant execute on function public.admin_create_broadcast(text, text, boolean) to authenticated;
grant execute on function public.admin_create_product(text, uuid, numeric, numeric, boolean) to authenticated;
