-- Italian user-facing content for existing records and future catalog items.
update public.categories
set name = 'Collezione'
where name = 'Collection';

update public.products
set name = replace(name, 'Demo Item', 'Articolo dimostrativo')
where name like 'Demo Item %';

update public.product_variants
set label = replace(label, ' units', ' unità')
where label like '% units';

update public.order_items
set
  name_snapshot = replace(name_snapshot, 'Demo Item', 'Articolo dimostrativo'),
  variant_label = replace(variant_label, ' units', ' unità')
where name_snapshot like 'Demo Item %' or variant_label like '% units';

update public.levels
set name = case name
  when 'Rookie' then 'Principiante'
  when 'Hustler' then 'Esperto'
  when 'Street OG' then 'Veterano'
  when 'Legend' then 'Leggenda'
  when 'Don' then 'Capo'
  else name
end
where name in ('Rookie', 'Hustler', 'Street OG', 'Legend', 'Don');

update public.reward_definitions
set label = case code
  when 'free_delivery' then 'Credito per scenario dimostrativo'
  when 'discount_5' then 'Credito dimostrativo 5%'
  when 'discount_10' then 'Credito dimostrativo 10%'
  else label
end
where code in ('free_delivery', 'discount_5', 'discount_10');

update public.game_reward_options
set label = replace(replace(label, 'Free Delivery', 'Credito per scenario dimostrativo'), 'Punti', 'Gettoni');

update public.game_configs
set title = case game_type
  when 'scratch' then 'Gratta e vinci'
  when 'spin' then 'Ruota dei premi'
  when 'box' then 'Scatola misteriosa'
  when 'daily' then 'Bonus giornaliero'
  else title
end;

update public.loyalty_ledger
set reason = case
  when reason like 'Test order %' then replace(reason, 'Test order ', 'Richiesta di prova ')
  when reason = 'Daily Bonus' then 'Bonus giornaliero'
  when reason like 'Game: %' then replace(reason, 'Game: ', 'Gioco: ')
  when reason like 'Admin gettoni:%' then replace(reason, 'Admin gettoni:', 'Amministrazione gettoni:')
  when reason = 'Ticket ruota guadagnato' then 'Biglietto ruota guadagnato'
  else reason
end
where reason like 'Test order %' or reason = 'Daily Bonus' or reason like 'Game: %' or reason like 'Admin gettoni:%' or reason = 'Ticket ruota guadagnato';

update public.broadcasts
set
  title = replace(title, 'Nuova demo item:', 'Nuovo articolo dimostrativo:'),
  message = replace(message, 'Nuova voce aggiunta al catalogo demo.', 'Nuova voce aggiunta al catalogo dimostrativo.')
where title like 'Nuova demo item:%' or message = 'Nuova voce aggiunta al catalogo demo.';

update public.app_settings
set value = jsonb_set(
  value,
  '{disclaimer}',
  to_jsonb('Ambiente dimostrativo: nessun pagamento, scambio o gestione reale degli ordini.'::text),
  true
)
where key = 'demo_rules';

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
  if not public.is_admin() then raise exception 'Accesso amministratore richiesto'; end if;
  if char_length(v_name) = 0 then raise exception 'Prodotto non valido'; end if;
  foreach v_unit in array v_required loop
    v_price := (p_prices ->> v_unit::text)::numeric;
    if v_price is null or v_price < 0 then raise exception 'Prezzo pacchetto non valido: %', v_unit; end if;
  end loop;
  v_slug := 'demo-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  insert into public.products (category_id, slug, name, description, badge, featured, published, rating)
  values (p_category_id, v_slug, v_name, 'Articolo dimostrativo. Nessuna vendita o consegna reale.', 'NEW', false, false, 0)
  returning id into v_product_id;
  foreach v_unit in array v_required loop
    insert into public.product_variants (product_id, label, price, sort_order, unit_amount, token_award)
    select v_product_id, v_unit || ' unità', (p_prices ->> v_unit::text)::numeric, v_unit, v_unit, tokens_awarded
    from public.token_reward_tiers where minimum_units = v_unit;
  end loop;
  insert into public.inventory_status (variant_id)
  select id from public.product_variants where product_id = v_product_id;
  if p_announce then
    insert into public.broadcasts (kind, title, message, product_id, status, created_by)
    values ('product_new', 'Nuovo articolo dimostrativo: ' || v_name, 'Nuova voce aggiunta al catalogo dimostrativo.', v_product_id, 'draft', auth.uid());
  end if;
  return v_product_id;
end $$;
