-- Categories are public catalogue navigation, and products created in the admin form are visible immediately.
update public.products
set published = true
where not published
  and (slug like 'demo-%' or slug like 'product-%');

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
  if p_announce then
    insert into public.broadcasts (kind, title, message, product_id, status, created_by)
    values ('product_new', 'Nuovo prodotto: ' || v_name, 'Nuovo prodotto aggiunto al catalogo.', v_product_id, 'draft', auth.uid());
  end if;
  return v_product_id;
end $$;
