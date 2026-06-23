-- Final hardening for imported approved Telegram users.
-- Some imported users had profiles but missing/disabled allowlist rows, which
-- made the app show "Account in attesa" even though admins saw them as approved.

insert into public.staging_allowlist (
  telegram_subject,
  role,
  enabled,
  access_status,
  access_requested_at,
  access_decided_at,
  note
)
select
  profile.telegram_subject,
  profile.role,
  true,
  'approved',
  now(),
  now(),
  'approved profile restored after self-host migration'
from public.profiles profile
where profile.telegram_subject ~ '^[0-9]+$'
  and not exists (
    select 1
    from public.staging_allowlist allowed
    where allowed.telegram_subject = profile.telegram_subject
  );

update public.staging_allowlist
set enabled = true,
  access_decided_at = coalesce(access_decided_at, now()),
  note = coalesce(note, 'approved allowlist normalized after self-host migration')
where access_status = 'approved'
  and not enabled;

update public.profiles profile
set blocked = false,
  role = case when allowed.role = 'admin' then 'admin' else profile.role end,
  updated_at = now()
from public.staging_allowlist allowed
where allowed.telegram_subject = profile.telegram_subject
  and allowed.access_status = 'approved'
  and allowed.enabled
  and (profile.blocked or (allowed.role = 'admin' and profile.role <> 'admin'));

create or replace function public.get_my_access_state()
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare
  v_subject text;
  v_status text;
  v_enabled boolean;
  v_role public.app_role;
begin
  perform public.repair_my_profile();

  v_subject := coalesce(
    (select telegram_subject from public.profiles where id = auth.uid()),
    public.auth_telegram_subject(auth.uid())
  );

  select a.access_status, a.enabled, a.role
  into v_status, v_enabled, v_role
  from public.staging_allowlist a
  where a.telegram_subject = v_subject
  limit 1;

  if v_status = 'approved' then
    if not coalesce(v_enabled, false) then
      update public.staging_allowlist
      set enabled = true,
        access_decided_at = coalesce(access_decided_at, now())
      where telegram_subject = v_subject;
    end if;

    update public.profiles
    set blocked = false,
      role = case when v_role = 'admin' then 'admin'::public.app_role else role end,
      updated_at = now()
    where id = auth.uid();

    return jsonb_build_object('blocked', false, 'access_status', 'approved');
  end if;

  return jsonb_build_object(
    'blocked', coalesce((select blocked from public.profiles where id = auth.uid()), false),
    'access_status', coalesce(v_status, 'pending')
  );
end $$;

create or replace function public.is_allowed()
returns boolean language sql stable security definer set search_path = public, auth as $$
  with current_identity as (
    select
      auth.uid() as user_id,
      coalesce(
        (select p.telegram_subject from public.profiles p where p.id = auth.uid()),
        public.auth_telegram_subject(auth.uid())
      ) as telegram_subject,
      coalesce((select p.blocked from public.profiles p where p.id = auth.uid()), false) as blocked
  )
  select exists (
    select 1
    from current_identity identity
    join public.staging_allowlist allowed on allowed.telegram_subject = identity.telegram_subject
    where identity.user_id is not null
      and allowed.enabled
      and allowed.access_status = 'approved'
      and not identity.blocked
  )
$$;

create or replace function public.get_my_profile()
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare
  v jsonb;
  v_subject text;
  v_role public.app_role;
begin
  perform public.repair_my_profile();

  v_subject := coalesce(
    (select telegram_subject from public.profiles where id = auth.uid()),
    public.auth_telegram_subject(auth.uid())
  );

  select role into v_role
  from public.staging_allowlist
  where telegram_subject = v_subject
    and access_status = 'approved'
  limit 1;

  if v_role is not null then
    update public.staging_allowlist
    set enabled = true,
      access_decided_at = coalesce(access_decided_at, now())
    where telegram_subject = v_subject
      and access_status = 'approved';

    update public.profiles
    set blocked = false,
      role = case when v_role = 'admin' then 'admin'::public.app_role else role end,
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

grant execute on function public.get_my_access_state() to authenticated;
grant execute on function public.get_my_profile() to authenticated;
grant execute on function public.is_allowed() to authenticated;
revoke execute on function public.get_my_access_state() from public, anon;
revoke execute on function public.get_my_profile() from public, anon;
