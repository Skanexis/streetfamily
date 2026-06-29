-- Public reviews wall: order-linked feedback plus admin-curated chat screenshots.

insert into public.app_settings (key, value)
values ('community_links', '{"instagram":"","telegram":null,"viber":"","signal":null}'::jsonb)
on conflict (key) do update
set value = jsonb_build_object(
  'instagram', coalesce(public.app_settings.value ->> 'instagram', ''),
  'telegram', coalesce(public.app_settings.value -> 'telegram', 'null'::jsonb),
  'viber', coalesce(public.app_settings.value ->> 'viber', ''),
  'signal', coalesce(public.app_settings.value -> 'signal', 'null'::jsonb)
);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('review-screenshots', 'review-screenshots', false, 10485760, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create table if not exists public.feedback_chat_screenshots (
  id uuid primary key default gen_random_uuid(),
  product_id uuid references public.products(id) on delete set null,
  customer_label text not null default '',
  order_label text not null default '',
  message text not null default '',
  storage_path text not null unique,
  status public.feedback_status not null default 'published',
  created_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (char_length(trim(customer_label)) <= 80),
  check (char_length(trim(order_label)) <= 120),
  check (char_length(trim(message)) <= 240)
);

drop trigger if exists feedback_chat_screenshots_touch on public.feedback_chat_screenshots;
create trigger feedback_chat_screenshots_touch
  before update on public.feedback_chat_screenshots
  for each row execute function public.touch_updated_at();

alter table public.feedback_chat_screenshots enable row level security;

grant select, insert, update, delete on public.feedback_chat_screenshots to authenticated;

drop policy if exists feedback_chat_screenshots_member_read on public.feedback_chat_screenshots;
create policy feedback_chat_screenshots_member_read
  on public.feedback_chat_screenshots for select
  using ((public.is_allowed() and status = 'published') or public.is_admin());

drop policy if exists feedback_chat_screenshots_admin_all on public.feedback_chat_screenshots;
create policy feedback_chat_screenshots_admin_all
  on public.feedback_chat_screenshots for all
  using (public.is_admin())
  with check (public.is_admin());

drop trigger if exists audit_feedback_chat_screenshots on public.feedback_chat_screenshots;
create trigger audit_feedback_chat_screenshots
  after insert or update or delete on public.feedback_chat_screenshots
  for each row execute function public.audit_admin_change();

drop policy if exists review_screenshots_member_objects on storage.objects;
create policy review_screenshots_member_objects on storage.objects for select
  using (bucket_id = 'review-screenshots' and public.is_allowed());

drop policy if exists review_screenshots_admin_objects on storage.objects;
create policy review_screenshots_admin_objects on storage.objects for all
  using (bucket_id = 'review-screenshots' and public.is_admin())
  with check (bucket_id = 'review-screenshots' and public.is_admin());

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
                pr.name,
                c.name as category,
                to_jsonb(array_agg(distinct oi.variant_label order by oi.variant_label)) as variant_labels
              from public.order_items oi
              join public.product_variants pv on pv.id = oi.variant_id
              join public.products pr on pr.id = pv.product_id
              left join public.categories c on c.id = pr.category_id
              where oi.order_id = o.id
              group by pr.id, pr.name, c.name
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
