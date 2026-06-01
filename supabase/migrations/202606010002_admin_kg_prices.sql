-- Allow administrators to set explicit 1-5 kg prices on catalog products.

do $$
declare
  v_product public.products%rowtype;
  v_lower public.product_variants%rowtype;
  v_upper public.product_variants%rowtype;
  v_previous public.product_variants%rowtype;
  v_unit integer;
  v_price numeric;
  v_units integer[] := array[1000,2000,3000,4000,5000];
begin
  for v_product in select * from public.products loop
    foreach v_unit in array v_units loop
      if not exists (
        select 1
        from public.product_variants variant
        where variant.product_id = v_product.id
          and variant.unit_amount = v_unit
      ) then
        v_price := null;
        v_lower := null;
        v_upper := null;
        v_previous := null;

        select variant.* into v_lower
        from public.product_variants variant
        where variant.product_id = v_product.id
          and variant.unit_amount >= 25
          and variant.unit_amount <= v_unit
        order by variant.unit_amount desc
        limit 1;

        select variant.* into v_upper
        from public.product_variants variant
        where variant.product_id = v_product.id
          and variant.unit_amount >= v_unit
        order by variant.unit_amount
        limit 1;

        if v_lower.id is not null and v_upper.id is not null then
          if v_lower.unit_amount = v_upper.unit_amount then
            v_price := round(v_lower.price / 5) * 5;
          else
            v_price := round((
              v_lower.price + (v_unit - v_lower.unit_amount)::numeric /
                (v_upper.unit_amount - v_lower.unit_amount) * (v_upper.price - v_lower.price)
            ) / 5) * 5;
          end if;
        elsif v_lower.id is not null then
          select variant.* into v_previous
          from public.product_variants variant
          where variant.product_id = v_product.id
            and variant.unit_amount >= 25
            and variant.unit_amount < v_lower.unit_amount
          order by variant.unit_amount desc
          limit 1;

          if v_previous.id is null then
            v_price := round(((v_lower.price / v_lower.unit_amount) * v_unit) / 5) * 5;
          else
            v_price := round((
              v_lower.price + ((v_unit - v_lower.unit_amount) *
                ((v_lower.price - v_previous.price) / (v_lower.unit_amount - v_previous.unit_amount)))
            ) / 5) * 5;
          end if;
        end if;

        if v_price is not null then
          insert into public.product_variants (product_id, label, price, sort_order, unit_amount, token_award)
          values (
            v_product.id,
            v_unit || ' g',
            v_price,
            v_unit,
            v_unit,
            coalesce((
              select tokens_awarded
              from public.token_reward_tiers
              where minimum_units <= v_unit
              order by minimum_units desc
              limit 1
            ), 0)
          );
        end if;
      end if;
    end loop;
  end loop;

  insert into public.inventory_status (variant_id)
  select variant.id
  from public.product_variants variant
  left join public.inventory_status status on status.variant_id = variant.id
  where status.variant_id is null;
end;
$$;

create or replace function public.admin_create_demo_product(
  p_name text, p_category_id uuid, p_prices jsonb, p_announce boolean default false
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
  insert into public.products (category_id, slug, name, description, badge, featured, published, rating)
  values (p_category_id, v_slug, v_name, 'Prodotto disponibile in catalogo.', 'NEW', false, true, 0)
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

grant execute on function public.admin_create_demo_product(text, uuid, jsonb, boolean) to authenticated;
revoke execute on function public.admin_create_demo_product(text, uuid, jsonb, boolean) from public, anon;
