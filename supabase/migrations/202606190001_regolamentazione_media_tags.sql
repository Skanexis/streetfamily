-- Regolamentazione minima ordini, promo tag prodotto e realtime service areas.

alter table public.products
  add column if not exists promo_tag text not null default '';

insert into public.service_areas (scenario_type, city, minimum_units, requires_street, sort_order, active)
values
  ('meetup', 'Spoleto', 25, false, 1, true),
  ('meetup', 'Foligno', 25, false, 2, true),
  ('meetup', 'Gualdo', 50, false, 3, true),
  ('meetup', 'Bastia', 50, false, 4, true),
  ('meetup', 'Perugia', 100, false, 5, true),
  ('meetup', 'Gubbio', 100, false, 6, true),
  ('meetup', 'Terni', 100, false, 7, true),
  ('delivery_zone', 'Umbertide', 200, true, 10, true),
  ('delivery_zone', 'CDC', 200, true, 11, true),
  ('delivery_zone', 'Fabriano', 200, true, 12, true),
  ('delivery_zone', 'Cerreto Desi', 200, true, 13, true),
  ('delivery_zone', 'Matelica', 300, true, 14, true),
  ('delivery_zone', 'Cagli', 300, true, 15, true)
on conflict (scenario_type, city) do update set
  minimum_units = excluded.minimum_units,
  requires_street = excluded.requires_street,
  sort_order = excluded.sort_order,
  active = true;

do $$
begin
  alter publication supabase_realtime add table public.service_areas;
exception
  when duplicate_object then null;
  when undefined_object then null;
end $$;

create or replace function public.get_catalog()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public.assert_allowed();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id, 'name', p.name, 'category', c.name, 'description', p.description, 'badge', p.badge,
      'promo_tag', p.promo_tag,
      'rating', coalesce(stats.rating, 0), 'review_count', coalesce(stats.review_count, 0),
      'variants', (select jsonb_agg(jsonb_build_object(
          'id', v.id, 'label', v.label, 'price', v.price, 'unit_amount', v.unit_amount,
          'token_award', v.token_award, 'available', i.available
        ) order by v.sort_order)
        from public.product_variants v join public.inventory_status i on i.variant_id = v.id
        where v.product_id = p.id and v.unit_amount is not null),
      'media', (select jsonb_agg(jsonb_build_object('id', m.id, 'url', m.url, 'storage_path', m.storage_path,
        'upload_status', m.upload_status, 'type', m.media_type, 'alt', m.alt, 'sort_order', m.sort_order)
        order by case when m.media_type = 'video' then 0 else 1 end, m.sort_order, m.id)
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

drop function if exists public.admin_create_demo_product(text, uuid, jsonb, boolean);

create or replace function public.admin_create_demo_product(
  p_name text, p_category_id uuid, p_prices jsonb, p_announce boolean default false, p_promo_tag text default ''
)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_product_id uuid;
  v_slug text;
  v_name text := trim(p_name);
  v_required integer[] := array[25,50,100,300,500,1000,2000,3000,4000,5000];
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
  insert into public.products (category_id, slug, name, description, badge, promo_tag, featured, published, rating)
  values (p_category_id, v_slug, v_name, 'Prodotto disponibile in catalogo.', 'NEW', left(trim(coalesce(p_promo_tag, '')), 40), false, true, 0)
  returning id into v_product_id;
  foreach v_unit in array v_required loop
    insert into public.product_variants (product_id, label, price, sort_order, unit_amount, token_award)
    values (
      v_product_id,
      v_unit || ' g',
      (p_prices ->> v_unit::text)::numeric,
      v_unit,
      v_unit,
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

grant execute on function public.admin_create_demo_product(text, uuid, jsonb, boolean, text) to authenticated;
revoke execute on function public.admin_create_demo_product(text, uuid, jsonb, boolean, text) from public, anon;
