-- Start with a fully empty catalogue. Future categories and products are created from admin UI.
delete from public.broadcasts
where kind = 'product_new';

delete from public.products;

delete from public.categories;
