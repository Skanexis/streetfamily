-- Keep review product names visible even when the catalog product is archived
-- or no longer joinable. Order snapshots are the source of truth for old orders.

create or replace function public.get_reviews_wall()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.assert_allowed();

  return jsonb_build_object(
    'feedback',
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', review_row.id,
        'rating', review_row.rating,
        'message', review_row.message,
        'created_at', review_row.created_at,
        'username', review_row.username,
        'avatar_url', review_row.avatar_url,
        'order', review_row.order_payload,
        'products', review_row.products_payload
      ) order by review_row.created_at desc)
      from (
        select
          f.id,
          f.rating,
          f.message,
          f.created_at,
          p.username,
          p.avatar_url,
          jsonb_build_object(
            'id', o.id,
            'display_id', o.display_id,
            'created_at', o.created_at,
            'total', o.total,
            'total_units', o.total_units
          ) as order_payload,
          coalesce((
            select jsonb_agg(jsonb_build_object(
              'id', product_row.id,
              'name', product_row.name,
              'category', product_row.category,
              'variant_labels', product_row.variant_labels
            ) order by product_row.name)
            from (
              select
                pr.id,
                coalesce(pr.name, oi.name_snapshot, 'Prodotto ordinato') as name,
                coalesce(c.name, 'Archivio') as category,
                to_jsonb(array_agg(distinct oi.variant_label order by oi.variant_label)) as variant_labels
              from public.order_items oi
              left join public.product_variants pv on pv.id = oi.variant_id
              left join public.products pr on pr.id = pv.product_id
              left join public.categories c on c.id = pr.category_id
              where oi.order_id = o.id
              group by pr.id, coalesce(pr.name, oi.name_snapshot, 'Prodotto ordinato'), coalesce(c.name, 'Archivio')
            ) product_row
          ), '[]'::jsonb) as products_payload
        from public.feedback f
        join public.profiles p on p.id = f.user_id
        join public.orders o on o.id = f.order_id
        where f.status = 'published'
        order by f.created_at desc
        limit 80
      ) review_row
    ), '[]'::jsonb),
    'screenshots',
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', s.id,
        'storage_path', s.storage_path,
        'image_url', '',
        'customer_label', s.customer_label,
        'order_label', s.order_label,
        'message', s.message,
        'created_at', s.created_at,
        'product', case when pr.id is null then null else jsonb_build_object(
          'id', pr.id,
          'name', pr.name,
          'category', c.name,
          'variant_labels', '[]'::jsonb
        ) end
      ) order by s.created_at desc)
      from public.feedback_chat_screenshots s
      left join public.products pr on pr.id = s.product_id
      left join public.categories c on c.id = pr.category_id
      where s.status = 'published'
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_reviews_wall() from public, anon;
grant execute on function public.get_reviews_wall() to authenticated;
