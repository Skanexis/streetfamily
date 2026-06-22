\pset format unaligned
\pset fieldsep '\t'
\pset tuples_only on
select 'auth.users', count(*) from auth.users;
select 'public.profiles', count(*) from public.profiles;
select 'public.staging_allowlist', count(*) from public.staging_allowlist;
select 'public.products', count(*) from public.products;
select 'public.product_media', count(*) from public.product_media;
select 'public.orders', count(*) from public.orders;
select 'public.order_items', count(*) from public.order_items;
select 'public.wallet_balances', count(*) from public.wallet_balances;
select 'public.kyc_cases', count(*) from public.kyc_cases;
select 'public.kyc_documents', count(*) from public.kyc_documents;
select 'storage.buckets', count(*) from storage.buckets;
select 'storage.objects', count(*) from storage.objects;
