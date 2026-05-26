-- Keep historical order snapshots while allowing administrators to remove catalog products.
alter table public.order_items
  alter column variant_id drop not null;

alter table public.order_items
  drop constraint if exists order_items_variant_id_fkey;

alter table public.order_items
  add constraint order_items_variant_id_fkey
  foreign key (variant_id) references public.product_variants(id) on delete set null;

create or replace function public.admin_delete_product(p_product_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Accesso amministratore richiesto.';
  end if;

  delete from public.products
  where id = p_product_id;

  if not found then
    raise exception 'Prodotto non trovato.';
  end if;
end;
$$;

create or replace function public.admin_delete_category(p_category_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Accesso amministratore richiesto.';
  end if;

  if exists (
    select 1
    from public.products
    where category_id = p_category_id
  ) then
    raise exception 'La categoria contiene prodotti. Elimina prima i prodotti associati.';
  end if;

  delete from public.categories
  where id = p_category_id;

  if not found then
    raise exception 'Categoria non trovata.';
  end if;
end;
$$;

revoke all on function public.admin_delete_product(uuid) from public, anon;
revoke all on function public.admin_delete_category(uuid) from public, anon;
grant execute on function public.admin_delete_product(uuid) to authenticated;
grant execute on function public.admin_delete_category(uuid) to authenticated;
