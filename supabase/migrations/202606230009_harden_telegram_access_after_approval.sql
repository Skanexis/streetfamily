-- Make access approval immediately effective for already logged-in Telegram users.
-- This migration also fixes stale duplicate allowlist rows for the same numeric
-- Telegram ID, which can otherwise keep showing "Account in attesa".

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
  access_decided_at = coalesce(public.staging_allowlist.access_decided_at, now()),
  note = 'production admin access repair';

update public.profiles
set role = 'admin',
  blocked = false,
  updated_at = now()
where public.normalize_telegram_subject(telegram_subject) = '8523253126';

insert into public.staging_allowlist (
  telegram_subject,
  role,
  enabled,
  access_status,
  access_requested_at,
  access_decided_at,
  access_username,
  note
)
select
  public.normalize_telegram_subject(profile.telegram_subject),
  'admin',
  true,
  'approved',
  coalesce(profile.created_at, now()),
  now(),
  profile.username,
  'admin profile access repair'
from public.profiles profile
where profile.role = 'admin'
  and public.normalize_telegram_subject(profile.telegram_subject) is not null
on conflict (telegram_subject) do update
set role = 'admin',
  enabled = true,
  access_status = 'approved',
  access_decided_at = coalesce(public.staging_allowlist.access_decided_at, now()),
  access_username = coalesce(public.staging_allowlist.access_username, excluded.access_username),
  note = 'admin profile access repair';

with approved_subjects as (
  select
    public.normalize_telegram_subject(telegram_subject) as subject,
    bool_or(role = 'admin') as has_admin,
    max(access_decided_at) as decided_at
  from public.staging_allowlist
  where enabled
    and access_status = 'approved'
    and public.normalize_telegram_subject(telegram_subject) is not null
  group by public.normalize_telegram_subject(telegram_subject)
)
update public.staging_allowlist target
set enabled = true,
  access_status = 'approved',
  role = case when approved_subjects.has_admin then 'admin'::public.app_role else target.role end,
  access_decided_at = coalesce(target.access_decided_at, approved_subjects.decided_at, now()),
  note = coalesce(target.note, 'stale duplicate pending row normalized to approved')
from approved_subjects
where public.normalize_telegram_subject(target.telegram_subject) = approved_subjects.subject
  and target.access_status = 'pending';

update public.profiles profile
set blocked = false,
  role = case
    when exists (
      select 1
      from public.staging_allowlist allowed
      where public.normalize_telegram_subject(allowed.telegram_subject) = public.normalize_telegram_subject(profile.telegram_subject)
        and allowed.enabled
        and allowed.access_status = 'approved'
        and allowed.role = 'admin'
    ) then 'admin'::public.app_role
    else profile.role
  end,
  updated_at = now()
where public.normalize_telegram_subject(profile.telegram_subject) is not null
  and exists (
    select 1
    from public.staging_allowlist allowed
    where public.normalize_telegram_subject(allowed.telegram_subject) = public.normalize_telegram_subject(profile.telegram_subject)
      and allowed.enabled
      and allowed.access_status = 'approved'
  );

create or replace function public.sync_allowlist_role()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.profiles
  set role = case
        when new.enabled and new.access_status = 'approved' then new.role
        else role
      end,
      blocked = case
        when new.access_status = 'rejected' then true
        when new.enabled and new.access_status = 'approved' then false
        else blocked
      end,
      updated_at = now()
  where public.normalize_telegram_subject(telegram_subject) = public.normalize_telegram_subject(new.telegram_subject)
    and (new.enabled and new.access_status = 'approved' or new.access_status = 'rejected');
  return new;
end $$;

drop trigger if exists allowlist_role_sync on public.staging_allowlist;
create trigger allowlist_role_sync
  after insert or update of role, enabled, access_status on public.staging_allowlist
  for each row execute function public.sync_allowlist_role();

create or replace function public.admin_review_access_request(
  p_actor_id uuid, p_telegram_subject text, p_decision text
)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare
  v_subject text := public.normalize_telegram_subject(p_telegram_subject);
  v_role public.app_role := 'user';
  v_user auth.users%rowtype;
begin
  if p_decision not in ('approved', 'rejected') then
    raise exception 'Decisione accesso non valida.';
  end if;
  if v_subject is null then
    raise exception 'Telegram ID non valido.';
  end if;

  if not exists (
    select 1
    from public.profiles profile
    join lateral public.effective_access_row(profile.telegram_subject) allowed on true
    where profile.id = p_actor_id
      and profile.role = 'admin'
      and allowed.enabled
      and allowed.access_status = 'approved'
      and not profile.blocked
  ) then
    raise exception 'Amministratore Telegram non autorizzato.';
  end if;

  select coalesce(
    (
      select 'admin'::public.app_role
      from public.profiles profile
      where public.normalize_telegram_subject(profile.telegram_subject) = v_subject
        and profile.role = 'admin'
      limit 1
    ),
    (
      select access.role
      from public.effective_access_row(v_subject) access
      where access.role = 'admin'
      limit 1
    ),
    'user'::public.app_role
  )
  into v_role;

  update public.staging_allowlist
  set access_status = p_decision,
    enabled = p_decision = 'approved',
    role = case when p_decision = 'approved' then v_role else role end,
    access_decided_at = now(),
    access_decided_by = p_actor_id,
    note = case when p_decision = 'approved' then 'Approvato da Telegram' else 'Rifiutato da Telegram' end
  where public.normalize_telegram_subject(telegram_subject) = v_subject;

  if not found then
    insert into public.staging_allowlist (
      telegram_subject,
      role,
      enabled,
      access_status,
      access_requested_at,
      access_decided_at,
      access_decided_by,
      note
    )
    values (
      v_subject,
      v_role,
      p_decision = 'approved',
      p_decision,
      now(),
      now(),
      p_actor_id,
      case when p_decision = 'approved' then 'Approvato da Telegram' else 'Rifiutato da Telegram' end
    );
  end if;

  insert into public.staging_allowlist (
    telegram_subject,
    role,
    enabled,
    access_status,
    access_requested_at,
    access_decided_at,
    access_decided_by,
    note
  )
  values (
    v_subject,
    v_role,
    p_decision = 'approved',
    p_decision,
    now(),
    now(),
    p_actor_id,
    case when p_decision = 'approved' then 'Approvato da Telegram' else 'Rifiutato da Telegram' end
  )
  on conflict (telegram_subject) do update
  set role = case when excluded.access_status = 'approved' then excluded.role else public.staging_allowlist.role end,
    enabled = excluded.enabled,
    access_status = excluded.access_status,
    access_decided_at = excluded.access_decided_at,
    access_decided_by = excluded.access_decided_by,
    note = excluded.note;

  update public.profiles
  set role = case when p_decision = 'approved' then v_role else role end,
    blocked = p_decision = 'rejected',
    updated_at = now()
  where public.normalize_telegram_subject(telegram_subject) = v_subject;

  for v_user in
    select *
    from auth.users
    where public.auth_telegram_subject(id) = v_subject
  loop
    perform public.repair_auth_profile(
      v_user.id,
      v_subject,
      coalesce(v_user.raw_user_meta_data ->> 'username', v_user.raw_user_meta_data ->> 'preferred_username', v_user.raw_user_meta_data ->> 'first_name', 'member'),
      coalesce(v_user.raw_user_meta_data ->> 'avatar_url', v_user.raw_user_meta_data ->> 'photo_url', v_user.raw_user_meta_data ->> 'picture'),
      case when p_decision = 'approved' then v_role else 'user'::public.app_role end
    );

    if p_decision = 'approved' then
      update public.profiles
      set blocked = false,
        role = v_role,
        updated_at = now()
      where id = v_user.id;
    elsif p_decision = 'rejected' then
      update public.profiles
      set blocked = true,
        updated_at = now()
      where id = v_user.id;
    end if;
  end loop;

  insert into public.admin_audit_log (actor_id, action, entity_type, entity_id, details)
  values (
    p_actor_id,
    'access.' || p_decision,
    'staging_allowlist',
    v_subject,
    jsonb_build_object('telegram_subject', v_subject, 'decision', p_decision)
  );

  return jsonb_build_object('status', p_decision, 'telegram_subject', v_subject);
end $$;

grant execute on function public.admin_review_access_request(uuid, text, text) to service_role;
revoke execute on function public.admin_review_access_request(uuid, text, text) from authenticated, public, anon;

notify pgrst, 'reload schema';
