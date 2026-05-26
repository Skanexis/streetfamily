-- Remove staging terminology from user-facing stored content and newly created records.
update public.products
set
  name = replace(replace(name, 'Articolo dimostrativo', 'Prodotto'), 'Demo Item', 'Prodotto'),
  description = case
    when description ilike '%dimostrativ%' or description ilike '%demo%' or description ilike '%nessuna vendita%'
      then 'Prodotto disponibile in catalogo.'
    else description
  end
where name ilike '%dimostrativ%' or name ilike '%demo item%'
  or description ilike '%dimostrativ%' or description ilike '%demo%' or description ilike '%nessuna vendita%';

update public.order_items
set name_snapshot = replace(replace(name_snapshot, 'Articolo dimostrativo', 'Prodotto'), 'Demo Item', 'Prodotto')
where name_snapshot ilike '%dimostrativ%' or name_snapshot ilike '%demo item%';

update public.orders
set display_id = replace(display_id, '#DEMO-', '#ORD-')
where display_id like '#DEMO-%';

update public.reward_definitions
set label = case code
  when 'free_delivery' then 'Credito delivery'
  when 'discount_5' then 'Credito 5%'
  when 'discount_10' then 'Credito 10%'
  else label
end
where label ilike '%demo%' or label ilike '%dimostrativ%';

update public.game_reward_options
set label = replace(replace(replace(label, 'Credito per scenario dimostrativo', 'Credito delivery'), 'Credito dimostrativo', 'Credito'), 'Credito scenario demo', 'Credito delivery')
where label ilike '%demo%' or label ilike '%dimostrativ%';

update public.loyalty_ledger
set reason = replace(reason, 'Richiesta di prova ', 'Ordine ')
where reason like 'Richiesta di prova %';

update public.broadcasts
set
  title = replace(replace(title, 'Nuovo articolo dimostrativo:', 'Nuovo prodotto:'), 'Nuova demo item:', 'Nuovo prodotto:'),
  message = replace(replace(message, 'Nuova voce aggiunta al catalogo dimostrativo.', 'Nuovo prodotto aggiunto al catalogo.'), 'Nuova voce aggiunta al catalogo demo.', 'Nuovo prodotto aggiunto al catalogo.')
where title ilike '%demo%' or title ilike '%dimostrativ%'
  or message ilike '%demo%' or message ilike '%dimostrativ%';

update public.app_settings
set value = jsonb_set(value, '{disclaimer}', to_jsonb(''::text), true)
where key = 'demo_rules';

do $$
declare
  v_definition text;
begin
  select pg_get_functiondef('public.submit_test_order_internal(uuid,jsonb,text,text,text,integer)'::regprocedure)
  into v_definition;
  v_definition := replace(v_definition, '#DEMO-', '#ORD-');
  v_definition := replace(v_definition, 'Ambiente dimostrativo: nessun pagamento, scambio o gestione reale degli ordini.', '');
  v_definition := replace(v_definition, 'Ambiente demo: nessun pagamento, scambio o fulfillment reale.', '');
  execute v_definition;

  select pg_get_functiondef('public.admin_create_demo_product(text,uuid,jsonb,boolean)'::regprocedure)
  into v_definition;
  v_definition := replace(v_definition, '''demo-'' ||', '''product-'' ||');
  v_definition := replace(v_definition, 'Articolo dimostrativo. Nessuna vendita o consegna reale.', 'Prodotto disponibile in catalogo.');
  v_definition := replace(v_definition, 'Nuovo articolo dimostrativo: ', 'Nuovo prodotto: ');
  v_definition := replace(v_definition, 'Nuova demo item: ', 'Nuovo prodotto: ');
  v_definition := replace(v_definition, 'Nuova voce aggiunta al catalogo dimostrativo.', 'Nuovo prodotto aggiunto al catalogo.');
  v_definition := replace(v_definition, 'Nuova voce aggiunta al catalogo demo.', 'Nuovo prodotto aggiunto al catalogo.');
  execute v_definition;
end;
$$;
