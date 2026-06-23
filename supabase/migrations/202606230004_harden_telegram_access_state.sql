-- Make Telegram access repair deterministic after imported Cloud data.
-- Approved allowlist wins over stale profile.blocked/profile.id mismatches.

update public.profiles profile
set blocked = false,
  role = case when allowed.role = 'admin' then 'admin' else profile.role end,
  updated_at = now()
from public.staging_allowlist allowed
where allowed.telegram_subject = profile.telegram_subject
  and allowed.enabled
  and allowed.access_status = 'approved'
  and (profile.blocked or (allowed.role = 'admin' and profile.role <> 'admin'));

create or replace function public.get_my_access_state()
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare
  v_subject text;
  v_status text;
begin
  perform public.repair_my_profile();

  v_subject := coalesce(
    (select telegram_subject from public.profiles where id = auth.uid()),
    public.auth_telegram_subject(auth.uid())
  );

  select a.access_status into v_status
  from public.staging_allowlist a
  where a.telegram_subject = v_subject
    and a.enabled
  limit 1;

  if v_status = 'approved' then
    update public.profiles
    set blocked = false,
      role = case
        when exists (
          select 1
          from public.staging_allowlist a
          where a.telegram_subject = v_subject
            and a.enabled
            and a.access_status = 'approved'
            and a.role = 'admin'
        ) then 'admin'::public.app_role
        else role
      end,
      updated_at = now()
    where id = auth.uid();
  end if;

  return jsonb_build_object(
    'blocked', case when v_status = 'approved' then false else coalesce((select blocked from public.profiles where id = auth.uid()), false) end,
    'access_status', coalesce(v_status, 'pending')
  );
end $$;

create or replace function public.get_my_profile()
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare
  v jsonb;
  v_subject text;
begin
  perform public.repair_my_profile();

  v_subject := coalesce(
    (select telegram_subject from public.profiles where id = auth.uid()),
    public.auth_telegram_subject(auth.uid())
  );

  if exists (
    select 1
    from public.staging_allowlist a
    where a.telegram_subject = v_subject
      and a.enabled
      and a.access_status = 'approved'
  ) then
    update public.profiles
    set blocked = false,
      role = case
        when exists (
          select 1
          from public.staging_allowlist a
          where a.telegram_subject = v_subject
            and a.enabled
            and a.access_status = 'approved'
            and a.role = 'admin'
        ) then 'admin'::public.app_role
        else role
      end,
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
revoke execute on function public.get_my_access_state() from public, anon;
revoke execute on function public.get_my_profile() from public, anon;
