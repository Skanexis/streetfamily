-- Fix products inserted into the hidden legacy category by the initial catalogue replacement.
update public.categories
set published = true
where id = '10000000-0000-0000-0000-000000000001';

update public.products
set category_id = '10000000-0000-0000-0000-000000000001',
    published = true
where id in (
  '21000000-0000-0000-0000-000000000001',
  '21000000-0000-0000-0000-000000000002',
  '21000000-0000-0000-0000-000000000003'
);
