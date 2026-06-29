-- Allow longer admin news messages and remove the old dedicated-post tagging
-- configuration from existing Estrazione rows.

do $$
declare
  v_constraint text;
begin
  for v_constraint in
    select conname
    from pg_constraint
    where conrelid = 'public.broadcasts'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%message%'
      and pg_get_constraintdef(oid) ilike '%char_length%'
  loop
    execute format('alter table public.broadcasts drop constraint %I', v_constraint);
  end loop;
end;
$$;

alter table public.broadcasts
  add constraint broadcasts_message_check
  check (char_length(trim(message)) between 1 and 3500);

create or replace function public.admin_create_broadcast(
  p_title text,
  p_message text,
  p_publish boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_title text := trim(coalesce(p_title, ''));
  v_message text := trim(coalesce(p_message, ''));
begin
  if not public.is_admin() then
    raise exception 'ADMIN_MFA_REQUIRED';
  end if;

  if char_length(v_message) not between 1 and 3500 then
    raise exception 'BROADCAST_MESSAGE_INVALID';
  end if;

  if char_length(v_title) = 0 then
    v_title := left(regexp_replace(split_part(v_message, E'\n', 1), '[[:space:]]+', ' ', 'g'), 120);
  end if;

  v_title := coalesce(nullif(left(v_title, 120), ''), 'Notizia');

  insert into public.broadcasts (
    kind,
    title,
    message,
    status,
    published_at,
    created_by
  ) values (
    'announcement',
    v_title,
    v_message,
    case when p_publish then 'published'::public.broadcast_status else 'draft'::public.broadcast_status end,
    case when p_publish then now() else null end,
    auth.uid()
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.admin_create_broadcast(text, text, boolean) from public, anon;
grant execute on function public.admin_create_broadcast(text, text, boolean) to authenticated;

update public.estrazioni
set instagram_verification_url = '',
    instagram_tag_friends_count = 1
where coalesce(instagram_verification_url, '') <> ''
   or instagram_tag_friends_count <> 1;
