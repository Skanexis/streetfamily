-- Keep Telegram access state deterministic after Cloud -> self-host imports.
-- The allowlist is the source of truth; explicit pending/rejected rows always win.

alter table public.staging_allowlist
  add column if not exists access_status text not null default 'approved'
    check (access_status in ('pending', 'approved', 'rejected')),
  add column if not exists access_requested_at timestamptz,
  add column if not exists access_username text,
  add column if not exists access_notified_at timestamptz,
  add column if not exists access_decided_at timestamptz,
  add column if not exists access_decided_by uuid references public.profiles(id);

create or replace function public.normalize_telegram_subject(p_value text)
returns text language sql immutable as $$
  select case
    when nullif(trim(p_value), '') ~ '^[0-9]+$'
      then trim(p_value)
    when nullif(trim(p_value), '') ~ '^telegram_[0-9]+@street-family\.invalid$'
      then substring(trim(p_value) from '^telegram_([0-9]+)@street-family\.invalid$')
    when nullif(trim(p_value), '') ~ '^telegram_[0-9]+$'
      then substring(trim(p_value) from '^telegram_([0-9]+)$')
    else null
  end
$$;

create or replace function public.auth_telegram_subject(p_user_id uuid default auth.uid())
returns text language sql stable security definer set search_path = public, auth as $$
  select coalesce(
    public.normalize_telegram_subject(u.raw_user_meta_data ->> 'telegram_id'),
    public.normalize_telegram_subject(u.raw_user_meta_data ->> 'telegram_subject'),
    public.normalize_telegram_subject(u.raw_user_meta_data ->> 'id'),
    public.normalize_telegram_subject(u.raw_user_meta_data ->> 'sub'),
    public.normalize_telegram_subject(u.email)
  )
  from auth.users u
  where u.id = p_user_id
$$;

create or replace function public.effective_access_row(p_telegram_subject text)
returns table (
  telegram_subject text,
  role public.app_role,
  enabled boolean,
  access_status text
) language sql stable security definer set search_path = public as $$
  select
    allowed.telegram_subject,
    allowed.role,
    allowed.enabled,
    allowed.access_status
  from public.staging_allowlist allowed
  where public.normalize_telegram_subject(allowed.telegram_subject) = public.normalize_telegram_subject(p_telegram_subject)
  order by
    case when allowed.telegram_subject = public.normalize_telegram_subject(p_telegram_subject) then 0 else 1 end,
    case allowed.access_status when 'rejected' then 0 when 'pending' then 1 when 'approved' then 2 else 3 end,
    allowed.created_at desc nulls last
  limit 1
$$;

-- If imported rows used an email-like Telegram subject, preserve their access
-- state under the numeric subject without overwriting explicit numeric rows.
insert into public.staging_allowlist (
  telegram_subject,
  role,
  enabled,
  note,
  created_at,
  access_status,
  access_requested_at,
  access_username,
  access_notified_at,
  access_decided_at,
  access_decided_by
)
select
  source.normalized_subject,
  source.role,
  source.enabled,
  coalesce(source.note, 'normalized Telegram ID after self-host migration'),
  source.created_at,
  source.access_status,
  source.access_requested_at,
  source.access_username,
  source.access_notified_at,
  source.access_decided_at,
  source.access_decided_by
from (
  select distinct on (public.normalize_telegram_subject(allowed.telegram_subject))
    public.normalize_telegram_subject(allowed.telegram_subject) as normalized_subject,
    allowed.*
  from public.staging_allowlist allowed
  where public.normalize_telegram_subject(allowed.telegram_subject) is not null
    and allowed.telegram_subject <> public.normalize_telegram_subject(allowed.telegram_subject)
  order by
    public.normalize_telegram_subject(allowed.telegram_subject),
    case allowed.access_status when 'rejected' then 0 when 'pending' then 1 when 'approved' then 2 else 3 end,
    allowed.created_at desc nulls last
) source
where source.normalized_subject is not null
  and not exists (
    select 1
    from public.staging_allowlist existing
    where existing.telegram_subject = source.normalized_subject
  );

update public.profiles profile
set telegram_subject = public.normalize_telegram_subject(profile.telegram_subject),
  updated_at = now()
where public.normalize_telegram_subject(profile.telegram_subject) is not null
  and profile.telegram_subject <> public.normalize_telegram_subject(profile.telegram_subject)
  and not exists (
    select 1
    from public.profiles existing
    where existing.id <> profile.id
      and existing.telegram_subject = public.normalize_telegram_subject(profile.telegram_subject)
  );

-- Imported non-blocked profiles without any allowlist row were approved members
-- in the old dataset. Restore only when no explicit pending/rejected/approved
-- allowlist row exists for that Telegram ID.
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
  candidates.normalized_subject,
  candidates.role,
  true,
  'approved',
  coalesce(candidates.created_at, now()),
  now(),
  candidates.username,
  'approved profile restored after self-host migration'
from (
  select distinct on (public.normalize_telegram_subject(profile.telegram_subject))
    public.normalize_telegram_subject(profile.telegram_subject) as normalized_subject,
    profile.*
  from public.profiles profile
  where public.normalize_telegram_subject(profile.telegram_subject) is not null
    and not profile.blocked
  order by
    public.normalize_telegram_subject(profile.telegram_subject),
    case when profile.role = 'admin' then 0 else 1 end,
    profile.created_at asc nulls last
) candidates
where candidates.normalized_subject is not null
  and not exists (
    select 1
    from public.staging_allowlist allowed
    where public.normalize_telegram_subject(allowed.telegram_subject) = candidates.normalized_subject
  );

update public.staging_allowlist
set enabled = true,
  access_decided_at = coalesce(access_decided_at, now()),
  note = coalesce(note, 'approved allowlist normalized after self-host migration')
where access_status = 'approved'
  and enabled is not true;

update public.profiles profile
set blocked = false,
  role = case
    when (
      select access.role
      from public.effective_access_row(profile.telegram_subject) access
      where access.enabled
        and access.access_status = 'approved'
      limit 1
    ) = 'admin' then 'admin'::public.app_role
    else profile.role
  end,
  updated_at = now()
where exists (
    select 1
    from public.effective_access_row(profile.telegram_subject) access
    where access.enabled
      and access.access_status = 'approved'
  )
  and (
    profile.blocked
    or (
      profile.role <> 'admin'
      and (
        select access.role
        from public.effective_access_row(profile.telegram_subject) access
        where access.enabled
          and access.access_status = 'approved'
        limit 1
      ) = 'admin'
    )
  );

create or replace function public.repair_my_profile()
returns uuid language plpgsql security definer set search_path = public, auth as $$
declare
  v_user auth.users%rowtype;
  v_subject text;
  v_access_status text;
  v_access_enabled boolean;
  v_access_role public.app_role;
begin
  if auth.uid() is null then
    return null;
  end if;

  select * into v_user from auth.users where id = auth.uid();
  v_subject := public.auth_telegram_subject(auth.uid());

  if v_subject is null then
    return auth.uid();
  end if;

  select access_status, enabled, role
  into v_access_status, v_access_enabled, v_access_role
  from public.effective_access_row(v_subject);

  perform public.repair_auth_profile(
    auth.uid(),
    v_subject,
    coalesce(v_user.raw_user_meta_data ->> 'username', v_user.raw_user_meta_data ->> 'preferred_username', v_user.raw_user_meta_data ->> 'first_name', 'member'),
    coalesce(v_user.raw_user_meta_data ->> 'avatar_url', v_user.raw_user_meta_data ->> 'photo_url', v_user.raw_user_meta_data ->> 'picture'),
    case
      when v_access_status = 'approved' and coalesce(v_access_enabled, false) then coalesce(v_access_role, 'user'::public.app_role)
      else 'user'::public.app_role
    end
  );

  return auth.uid();
end $$;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public, auth as $$
declare
  v_subject text := coalesce(
    public.normalize_telegram_subject(new.raw_user_meta_data ->> 'telegram_id'),
    public.normalize_telegram_subject(new.raw_user_meta_data ->> 'telegram_subject'),
    public.normalize_telegram_subject(new.raw_user_meta_data ->> 'id'),
    public.normalize_telegram_subject(new.raw_user_meta_data ->> 'sub'),
    public.normalize_telegram_subject(new.email)
  );
  v_access_status text;
  v_access_enabled boolean;
  v_access_role public.app_role;
begin
  select access_status, enabled, role
  into v_access_status, v_access_enabled, v_access_role
  from public.effective_access_row(v_subject);

  perform public.repair_auth_profile(
    new.id,
    v_subject,
    coalesce(new.raw_user_meta_data ->> 'preferred_username', new.raw_user_meta_data ->> 'username', new.raw_user_meta_data ->> 'first_name', 'member'),
    coalesce(new.raw_user_meta_data ->> 'picture', new.raw_user_meta_data ->> 'photo_url', new.raw_user_meta_data ->> 'avatar_url'),
    case
      when v_access_status = 'approved' and coalesce(v_access_enabled, false) then coalesce(v_access_role, 'user'::public.app_role)
      else 'user'::public.app_role
    end
  );

  return new;
end $$;

create or replace function public.get_my_access_state()
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare
  v_subject text;
  v_access_subject text;
  v_access_status text;
  v_access_enabled boolean;
  v_access_role public.app_role;
begin
  perform public.repair_my_profile();

  select coalesce(public.normalize_telegram_subject(profile.telegram_subject), public.auth_telegram_subject(auth.uid()))
  into v_subject
  from public.profiles profile
  where profile.id = auth.uid();

  v_subject := coalesce(v_subject, public.auth_telegram_subject(auth.uid()));

  select telegram_subject, access_status, enabled, role
  into v_access_subject, v_access_status, v_access_enabled, v_access_role
  from public.effective_access_row(v_subject);

  if v_access_status = 'approved' then
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
      v_subject,
      coalesce(v_access_role, 'user'::public.app_role),
      true,
      'approved',
      now(),
      now(),
      'approved access normalized during access check'
    )
    on conflict (telegram_subject) do update
    set role = excluded.role,
      enabled = true,
      access_status = 'approved',
      access_decided_at = coalesce(public.staging_allowlist.access_decided_at, now());

    update public.profiles
    set telegram_subject = v_subject,
      blocked = false,
      role = case when v_access_role = 'admin' then 'admin'::public.app_role else role end,
      updated_at = now()
    where id = auth.uid();

    return jsonb_build_object('blocked', false, 'access_status', 'approved');
  end if;

  return jsonb_build_object(
    'blocked', coalesce((select blocked from public.profiles where id = auth.uid()), false),
    'access_status', coalesce(v_access_status, 'pending')
  );
end $$;

create or replace function public.is_allowed()
returns boolean language sql stable security definer set search_path = public, auth as $$
  with current_identity as (
    select
      auth.uid() as user_id,
      coalesce(
        public.normalize_telegram_subject((select p.telegram_subject from public.profiles p where p.id = auth.uid())),
        public.auth_telegram_subject(auth.uid())
      ) as telegram_subject,
      coalesce((select p.blocked from public.profiles p where p.id = auth.uid()), false) as blocked
  )
  select exists (
    select 1
    from current_identity identity
    join lateral public.effective_access_row(identity.telegram_subject) access on true
    where identity.user_id is not null
      and identity.telegram_subject is not null
      and access.enabled
      and access.access_status = 'approved'
      and not identity.blocked
  )
$$;

create or replace function public.get_my_profile()
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare
  v jsonb;
  v_subject text;
  v_access_status text;
  v_access_enabled boolean;
  v_access_role public.app_role;
begin
  perform public.repair_my_profile();

  select coalesce(public.normalize_telegram_subject(profile.telegram_subject), public.auth_telegram_subject(auth.uid()))
  into v_subject
  from public.profiles profile
  where profile.id = auth.uid();

  v_subject := coalesce(v_subject, public.auth_telegram_subject(auth.uid()));

  select access_status, enabled, role
  into v_access_status, v_access_enabled, v_access_role
  from public.effective_access_row(v_subject);

  if v_access_status = 'approved' then
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
      v_subject,
      coalesce(v_access_role, 'user'::public.app_role),
      true,
      'approved',
      now(),
      now(),
      'approved access normalized during profile read'
    )
    on conflict (telegram_subject) do update
    set role = excluded.role,
      enabled = true,
      access_status = 'approved',
      access_decided_at = coalesce(public.staging_allowlist.access_decided_at, now());

    update public.profiles
    set telegram_subject = v_subject,
      blocked = false,
      role = case when v_access_role = 'admin' then 'admin'::public.app_role else role end,
      updated_at = now()
    where id = auth.uid();
  end if;

  perform public.assert_allowed();

  select jsonb_build_object(
    'id', p.id, 'username', p.username, 'avatar_url', p.avatar_url, 'role', p.role,
    'tokens', w.points, 'points', w.points, 'xp', w.xp, 'streak', w.streak,
    'spin_tickets', w.spin_tickets, 'scratch_tickets', w.scratch_tickets, 'box_tickets', w.box_tickets,
    'level_number', coalesce(l.level_number, 1),
    'next_level_xp', (select min(xp_min) from public.levels where xp_min > w.xp),
    'total_orders', (select count(*) from public.orders where user_id = p.id),
    'completed_orders', (select count(*) from public.orders where user_id = p.id and status = 'completed')
  ) into v
  from public.profiles p
  join public.wallet_balances w on w.user_id = p.id
  left join lateral (
    select * from public.levels where xp_min <= w.xp order by xp_min desc limit 1
  ) l on true
  where p.id = auth.uid();

  return v;
end $$;

create or replace function public.admin_dashboard()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Non sei autorizzato.'; end if;
  return jsonb_build_object(
    'allowlisted_users', (
      select count(distinct public.normalize_telegram_subject(telegram_subject))
      from public.staging_allowlist
      where enabled
        and access_status = 'approved'
        and public.normalize_telegram_subject(telegram_subject) is not null
    ),
    'submitted_orders', (select count(*) from public.orders where status = 'submitted'),
    'game_plays', (select count(*) from public.game_plays),
    'issued_points', (select coalesce(sum(points_delta), 0) from public.loyalty_ledger where points_delta > 0)
  );
end $$;

grant execute on function public.normalize_telegram_subject(text) to authenticated, service_role;
grant execute on function public.auth_telegram_subject(uuid) to authenticated, service_role;
grant execute on function public.effective_access_row(text) to authenticated, service_role;
grant execute on function public.repair_my_profile() to authenticated, service_role;
grant execute on function public.get_my_access_state() to authenticated;
grant execute on function public.get_my_profile() to authenticated;
grant execute on function public.is_allowed() to authenticated;
grant execute on function public.admin_dashboard() to authenticated;
revoke execute on function public.normalize_telegram_subject(text) from public, anon;
revoke execute on function public.auth_telegram_subject(uuid) from public, anon;
revoke execute on function public.effective_access_row(text) from public, anon;
revoke execute on function public.get_my_access_state() from public, anon;
revoke execute on function public.get_my_profile() from public, anon;
revoke execute on function public.admin_dashboard() from public, anon;

notify pgrst, 'reload schema';
