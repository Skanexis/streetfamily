-- Replace existing catalogue products with the initial editable collection.
-- Existing order snapshots remain available because order item variants use ON DELETE SET NULL.
delete from public.products;

insert into public.products (
  id, category_id, name, slug, description, badge, rating, review_count, featured, published
) values
  (
    '21000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000005',
    'Filtrato mfl formato 50g',
    'filtrato-mfl-formato-50g',
    'Disponibile in formati selezionabili.',
    null, 0, 0, true, true
  ),
  (
    '21000000-0000-0000-0000-000000000002',
    '10000000-0000-0000-0000-000000000005',
    'Real cali usa vari strain',
    'real-cali-usa-vari-strain',
    'Disponibile in formati selezionabili.',
    null, 0, 0, true, true
  ),
  (
    '21000000-0000-0000-0000-000000000003',
    '10000000-0000-0000-0000-000000000005',
    'Frozen sift mountain brothers',
    'frozen-sift-mountain-brothers',
    'Disponibile in formati selezionabili.',
    null, 0, 0, true, true
  );

insert into public.product_variants (
  product_id, label, price, sort_order, unit_amount, token_award
)
select product_id, grams || ' g', price, grams, grams,
  coalesce((
    select tier.tokens_awarded
    from public.token_reward_tiers tier
    where tier.minimum_units <= grams
    order by tier.minimum_units desc
    limit 1
  ), 0)
from (
  values
    ('21000000-0000-0000-0000-000000000001'::uuid, 25, 95::numeric),
    ('21000000-0000-0000-0000-000000000001'::uuid, 50, 190::numeric),
    ('21000000-0000-0000-0000-000000000001'::uuid, 100, 370::numeric),
    ('21000000-0000-0000-0000-000000000001'::uuid, 300, 1020::numeric),
    ('21000000-0000-0000-0000-000000000001'::uuid, 500, 1550::numeric),
    ('21000000-0000-0000-0000-000000000001'::uuid, 1000, 2800::numeric),
    ('21000000-0000-0000-0000-000000000001'::uuid, 3000, 7950::numeric),
    ('21000000-0000-0000-0000-000000000001'::uuid, 5000, 12750::numeric),
    ('21000000-0000-0000-0000-000000000001'::uuid, 10000, 24500::numeric),
    ('21000000-0000-0000-0000-000000000002'::uuid, 25, 175::numeric),
    ('21000000-0000-0000-0000-000000000002'::uuid, 50, 350::numeric),
    ('21000000-0000-0000-0000-000000000002'::uuid, 100, 650::numeric),
    ('21000000-0000-0000-0000-000000000002'::uuid, 300, 1800::numeric),
    ('21000000-0000-0000-0000-000000000002'::uuid, 500, 2850::numeric),
    ('21000000-0000-0000-0000-000000000002'::uuid, 1000, 5600::numeric),
    ('21000000-0000-0000-0000-000000000003'::uuid, 25, 140::numeric),
    ('21000000-0000-0000-0000-000000000003'::uuid, 50, 280::numeric),
    ('21000000-0000-0000-0000-000000000003'::uuid, 100, 550::numeric),
    ('21000000-0000-0000-0000-000000000003'::uuid, 300, 1600::numeric),
    ('21000000-0000-0000-0000-000000000003'::uuid, 500, 2550::numeric),
    ('21000000-0000-0000-0000-000000000003'::uuid, 1000, 5000::numeric)
) variants(product_id, grams, price);

insert into public.inventory_status (variant_id)
select id from public.product_variants
where product_id in (
  '21000000-0000-0000-0000-000000000001',
  '21000000-0000-0000-0000-000000000002',
  '21000000-0000-0000-0000-000000000003'
);

-- Permit checkout for displayed bulk tiers through 10 kg.
do $$
declare
  v_definition text;
begin
  select pg_get_functiondef('public.submit_test_order_internal(uuid,jsonb,text,text,text,integer)'::regprocedure)
  into v_definition;
  v_definition := replace(v_definition, 'v_units > 1000', 'v_units > 10000');
  v_definition := replace(v_definition, 'MAXIMUM_UNITS_SUPPORTED:1000', 'MAXIMUM_UNITS_SUPPORTED:10000');
  execute v_definition;
end;
$$;
