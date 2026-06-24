-- Final hardening for Telegram access conflicts:
-- if the same numeric Telegram ID has stale duplicate allowlist rows, an
-- enabled approved row wins unless a rejected decision is newer.

create or replace function public.effective_access_row(p_telegram_subject text)
returns table (
  telegram_subject text,
  role public.app_role,
  enabled boolean,
  access_status text
) language sql stable security definer set search_path = public as $$
  with input as (
    select public.normalize_telegram_subject(p_telegram_subject) as subject
  ),
  candidates as (
    select
      allowed.telegram_subject,
      allowed.role,
      allowed.enabled,
      allowed.access_status,
      coalesce(allowed.access_decided_at, allowed.access_requested_at, allowed.created_at) as row_time,
      max(coalesce(allowed.access_decided_at, allowed.access_requested_at, allowed.created_at)) filter (
        where allowed.enabled and allowed.access_status = 'approved'
      ) over () as latest_approved_time,
      input.subject
    from input
    join public.staging_allowlist allowed
      on public.normalize_telegram_subject(allowed.telegram_subject) = input.subject
    where input.subject is not null
  )
  select
    candidates.telegram_subject,
    candidates.role,
    candidates.enabled,
    candidates.access_status
  from candidates
  order by
    case
      when candidates.access_status = 'rejected'
        and candidates.row_time > coalesce(candidates.latest_approved_time, '-infinity'::timestamptz) then 0
      when candidates.enabled and candidates.access_status = 'approved' then 1
      when candidates.access_status = 'rejected' then 2
      when candidates.access_status = 'pending' then 3
      else 4
    end,
    case when candidates.telegram_subject = candidates.subject then 0 else 1 end,
    candidates.row_time desc nulls last
  limit 1
$$;

insert into public.staging_allowlist (
  telegram_subject,
  role,
  enabled,
  access_status,
  access_requested_at,
  access_decided_at,
  note
)
values (
  '8523253126',
  'admin',
  true,
  'approved',
  now(),
  now(),
  'production admin access repair'
)
on conflict (telegram_subject) do update
set role = 'admin',
  enabled = true,
  access_status = 'approved',
  access_decided_at = now(),
  note = 'production admin access repair';

with approved as (
  select
    public.normalize_telegram_subject(telegram_subject) as subject,
    bool_or(role = 'admin') as has_admin,
    max(coalesce(access_decided_at, access_requested_at, created_at)) as approved_at
  from public.staging_allowlist
  where enabled
    and access_status = 'approved'
    and public.normalize_telegram_subject(telegram_subject) is not null
  group by public.normalize_telegram_subject(telegram_subject)
)
update public.staging_allowlist target
set enabled = true,
  access_status = 'approved',
  role = case when approved.has_admin then 'admin'::public.app_role else target.role end,
  access_decided_at = coalesce(target.access_decided_at, approved.approved_at, now()),
  note = coalesce(target.note, 'duplicate Telegram access normalized to approved')
from approved
where public.normalize_telegram_subject(target.telegram_subject) = approved.subject
  and (
    target.access_status = 'pending'
    or (
      target.access_status = 'rejected'
      and coalesce(target.access_decided_at, target.access_requested_at, target.created_at) <= approved.approved_at
    )
  );

update auth.users auth_user
set raw_user_meta_data = coalesce(auth_user.raw_user_meta_data, '{}'::jsonb)
  || jsonb_build_object('telegram_id', subjects.subject, 'telegram_subject', subjects.subject)
from (
  select id, public.auth_telegram_subject(id) as subject
  from auth.users
) subjects
where auth_user.id = subjects.id
  and subjects.subject is not null
  and (
    public.normalize_telegram_subject(auth_user.raw_user_meta_data ->> 'telegram_id') is distinct from subjects.subject
    or public.normalize_telegram_subject(auth_user.raw_user_meta_data ->> 'telegram_subject') is distinct from subjects.subject
  );

do $$
declare
  v_user auth.users%rowtype;
  v_subject text;
  v_access_status text;
  v_access_enabled boolean;
  v_access_role public.app_role;
begin
  for v_user in
    select *
    from auth.users
  loop
    v_subject := public.auth_telegram_subject(v_user.id);
    if v_subject is null then
      continue;
    end if;

    v_access_status := null;
    v_access_enabled := null;
    v_access_role := null;

    select access_status, enabled, role
    into v_access_status, v_access_enabled, v_access_role
    from public.effective_access_row(v_subject);

    if v_access_status = 'approved' and v_access_enabled then
      perform public.repair_auth_profile(
        v_user.id,
        v_subject,
        coalesce(v_user.raw_user_meta_data ->> 'username', v_user.raw_user_meta_data ->> 'preferred_username', v_user.raw_user_meta_data ->> 'first_name', 'member'),
        coalesce(v_user.raw_user_meta_data ->> 'avatar_url', v_user.raw_user_meta_data ->> 'photo_url', v_user.raw_user_meta_data ->> 'picture'),
        coalesce(v_access_role, 'user'::public.app_role)
      );

      update public.profiles
      set blocked = false,
        role = case when v_access_role = 'admin' then 'admin'::public.app_role else role end,
        updated_at = now()
      where id = v_user.id;
    elsif v_access_status = 'rejected' then
      update public.profiles
      set blocked = true,
        updated_at = now()
      where id = v_user.id;
    end if;
  end loop;
end $$;

update public.profiles
set role = 'admin',
  blocked = false,
  updated_at = now()
where public.normalize_telegram_subject(telegram_subject) = '8523253126';

grant execute on function public.effective_access_row(text) to authenticated, service_role;
revoke execute on function public.effective_access_row(text) from public, anon;

notify pgrst, 'reload schema';
