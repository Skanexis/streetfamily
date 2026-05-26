-- Apply corrected 25 g prices for the initial collection.
update public.product_variants
set price = 100
where product_id = '21000000-0000-0000-0000-000000000001'
  and unit_amount = 25;

update public.product_variants
set price = 150
where product_id = '21000000-0000-0000-0000-000000000003'
  and unit_amount = 25;
