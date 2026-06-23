-- Repair Telegram access after Cloud -> self-host imports where auth.users.id
-- can differ from the imported public.profiles.id for the same Telegram ID.

create or replace function public.auth_telegram_subject(p_user_id uuid default auth.uid())
returns text language sql stable security definer set search_path = public, auth as $$
  select coalesce(
    case when nullif(trim(u.raw_user_meta_data ->> 'telegram_id'), '') ~ '^[0-9]+$' then trim(u.raw_user_meta_data ->> 'telegram_id') end,
    case when nullif(trim(u.raw_user_meta_data ->> 'telegram_subject'), '') ~ '^[0-9]+$' then trim(u.raw_user_meta_data ->> 'telegram_subject') end,
    case when nullif(trim(u.raw_user_meta_data ->> 'id'), '') ~ '^[0-9]+$' then trim(u.raw_user_meta_data ->> 'id') end,
    case when nullif(trim(u.email), '') ~ '^telegram_[0-9]+@street-family\.invalid$' then substring(trim(u.email) from '^telegram_([0-9]+)@street-family\.invalid$') end,
    case when nullif(trim(u.raw_user_meta_data ->> 'sub'), '') ~ '^[0-9]+$' then trim(u.raw_user_meta_data ->> 'sub') end
  )
  from auth.users u
  where u.id = p_user_id
$$;

create or replace function public.repair_auth_profile(
  p_user_id uuid,
  p_telegram_subject text,
  p_username text default null,
  p_avatar_url text default null,
  p_role public.app_role default 'user'
)
returns uuid language plpgsql security definer set search_path = public, auth as $$
declare
  v_subject text := nullif(regexp_replace(coalesce(p_telegram_subject, ''), '[^0-9]', '', 'g'), '');
  v_old public.profiles%rowtype;
  v_current public.profiles%rowtype;
  v_username text := nullif(trim(coalesce(p_username, '')), '');
  v_avatar text := nullif(trim(coalesce(p_avatar_url, '')), '');
  v_role public.app_role := coalesce(p_role, 'user');
begin
  if p_user_id is null or v_subject is null then
    return p_user_id;
  end if;

  select * into v_old
  from public.profiles
  where telegram_subject = v_subject
  for update;

  select * into v_current
  from public.profiles
  where id = p_user_id
  for update;

  if found and v_current.telegram_subject = v_subject then
    update public.profiles
    set username = coalesce(v_username, username, 'member'),
        avatar_url = coalesce(v_avatar, avatar_url),
        role = case when v_role = 'admin' then 'admin' else role end,
        updated_at = now()
    where id = p_user_id;

    insert into public.wallet_balances (user_id, points)
    values (p_user_id, 0)
    on conflict (user_id) do nothing;

    return p_user_id;
  end if;

  if v_old.id is not null and v_old.id <> p_user_id then
    update public.profiles
    set telegram_subject = '__merged__:' || v_subject || ':' || v_old.id::text,
        updated_at = now()
    where id = v_old.id;
  end if;

  if v_current.id is null then
    insert into public.profiles (id, telegram_subject, username, avatar_url, role, blocked, created_at, updated_at)
    values (
      p_user_id,
      v_subject,
      coalesce(v_username, v_old.username, 'member'),
      coalesce(v_avatar, v_old.avatar_url),
      case when v_role = 'admin' then 'admin' else coalesce(v_old.role, 'user') end,
      coalesce(v_old.blocked, false),
      coalesce(v_old.created_at, now()),
      now()
    );
  else
    update public.profiles
    set telegram_subject = v_subject,
        username = coalesce(v_username, v_current.username, v_old.username, 'member'),
        avatar_url = coalesce(v_avatar, v_current.avatar_url, v_old.avatar_url),
        role = case when v_role = 'admin' then 'admin' else coalesce(v_current.role, v_old.role, 'user') end,
        blocked = coalesce(v_current.blocked, false) or coalesce(v_old.blocked, false),
        updated_at = now()
    where id = p_user_id;
  end if;

  if v_old.id is not null and v_old.id <> p_user_id then
    insert into public.wallet_balances (
      user_id,
      points,
      xp,
      streak,
      last_daily_claim,
      updated_at,
      spin_tickets,
      scratch_tickets,
      box_tickets
    )
    select
      p_user_id,
      points,
      xp,
      streak,
      last_daily_claim,
      now(),
      spin_tickets,
      scratch_tickets,
      box_tickets
    from public.wallet_balances
    where user_id = v_old.id
    on conflict (user_id) do update set
      points = greatest(public.wallet_balances.points, excluded.points),
      xp = greatest(public.wallet_balances.xp, excluded.xp),
      streak = greatest(public.wallet_balances.streak, excluded.streak),
      last_daily_claim = greatest(public.wallet_balances.last_daily_claim, excluded.last_daily_claim),
      updated_at = now(),
      spin_tickets = greatest(public.wallet_balances.spin_tickets, excluded.spin_tickets),
      scratch_tickets = greatest(public.wallet_balances.scratch_tickets, excluded.scratch_tickets),
      box_tickets = greatest(public.wallet_balances.box_tickets, excluded.box_tickets);

    delete from public.wallet_balances where user_id = v_old.id;

    update public.loyalty_ledger set user_id = p_user_id where user_id = v_old.id;
    update public.user_rewards set user_id = p_user_id where user_id = v_old.id;
    update public.game_plays set user_id = p_user_id where user_id = v_old.id;

    delete from public.daily_claims current_claim
    using public.daily_claims old_claim
    where current_claim.user_id = p_user_id
      and old_claim.user_id = v_old.id
      and current_claim.claimed_on = old_claim.claimed_on;
    update public.daily_claims set user_id = p_user_id where user_id = v_old.id;

    update public.orders set user_id = p_user_id where user_id = v_old.id;
    update public.order_status_history set changed_by = p_user_id where changed_by = v_old.id;
    update public.admin_audit_log set actor_id = p_user_id where actor_id = v_old.id;

    delete from public.kyc_cases current_case
    using public.kyc_cases old_case
    where current_case.user_id = p_user_id
      and old_case.user_id = v_old.id;
    update public.kyc_cases set user_id = p_user_id where user_id = v_old.id;
    update public.kyc_cases set reviewed_by = p_user_id where reviewed_by = v_old.id;
    update public.kyc_documents set user_id = p_user_id where user_id = v_old.id;

    update public.feedback set user_id = p_user_id where user_id = v_old.id;
    update public.feedback set moderated_by = p_user_id where moderated_by = v_old.id;
    update public.broadcasts set created_by = p_user_id where created_by = v_old.id;
    update public.staging_allowlist set access_decided_by = p_user_id where access_decided_by = v_old.id;

    update public.estrazioni set created_by = p_user_id where created_by = v_old.id;
    update public.estrazioni set updated_by = p_user_id where updated_by = v_old.id;
    delete from public.estrazione_tickets current_ticket
    using public.estrazione_tickets old_ticket
    where current_ticket.user_id = p_user_id
      and old_ticket.user_id = v_old.id
      and current_ticket.estrazione_id = old_ticket.estrazione_id;
    update public.estrazione_tickets set user_id = p_user_id where user_id = v_old.id;

    delete from public.profiles where id = v_old.id;
  end if;

  insert into public.wallet_balances (user_id, points)
  values (p_user_id, 0)
  on conflict (user_id) do nothing;

  return p_user_id;
end $$;

create or replace function public.repair_my_profile()
returns uuid language plpgsql security definer set search_path = public, auth as $$
declare
  v_user auth.users%rowtype;
  v_subject text;
  v_role public.app_role := 'user';
begin
  if auth.uid() is null then
    return null;
  end if;

  select * into v_user from auth.users where id = auth.uid();
  v_subject := public.auth_telegram_subject(auth.uid());

  if v_subject is null then
    return auth.uid();
  end if;

  select coalesce(role, 'user') into v_role
  from public.staging_allowlist
  where telegram_subject = v_subject
    and enabled
    and access_status = 'approved';

  perform public.repair_auth_profile(
    auth.uid(),
    v_subject,
    coalesce(v_user.raw_user_meta_data ->> 'username', v_user.raw_user_meta_data ->> 'preferred_username', v_user.raw_user_meta_data ->> 'first_name', 'member'),
    coalesce(v_user.raw_user_meta_data ->> 'avatar_url', v_user.raw_user_meta_data ->> 'photo_url', v_user.raw_user_meta_data ->> 'picture'),
    coalesce(v_role, 'user')
  );

  return auth.uid();
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
    from current_identity i
    join public.staging_allowlist a on a.telegram_subject = i.telegram_subject
    where i.user_id is not null
      and a.enabled
      and a.access_status = 'approved'
      and not i.blocked
  )
$$;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public, auth as $$
declare
  v_subject text := coalesce(
    case when nullif(trim(new.raw_user_meta_data ->> 'telegram_id'), '') ~ '^[0-9]+$' then trim(new.raw_user_meta_data ->> 'telegram_id') end,
    case when nullif(trim(new.raw_user_meta_data ->> 'telegram_subject'), '') ~ '^[0-9]+$' then trim(new.raw_user_meta_data ->> 'telegram_subject') end,
    case when nullif(trim(new.raw_user_meta_data ->> 'id'), '') ~ '^[0-9]+$' then trim(new.raw_user_meta_data ->> 'id') end,
    case when nullif(trim(new.email), '') ~ '^telegram_[0-9]+@street-family\.invalid$' then substring(trim(new.email) from '^telegram_([0-9]+)@street-family\.invalid$') end,
    case when nullif(trim(new.raw_user_meta_data ->> 'sub'), '') ~ '^[0-9]+$' then trim(new.raw_user_meta_data ->> 'sub') end
  );
  v_role public.app_role := 'user';
begin
  select role into v_role
  from public.staging_allowlist
  where telegram_subject = v_subject
    and enabled
    and access_status = 'approved';

  perform public.repair_auth_profile(
    new.id,
    v_subject,
    coalesce(new.raw_user_meta_data ->> 'preferred_username', new.raw_user_meta_data ->> 'username', new.raw_user_meta_data ->> 'first_name', 'member'),
    coalesce(new.raw_user_meta_data ->> 'picture', new.raw_user_meta_data ->> 'photo_url', new.raw_user_meta_data ->> 'avatar_url'),
    coalesce(v_role, 'user')
  );

  return new;
end $$;

create or replace function public.get_my_access_state()
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare
  v_subject text;
begin
  perform public.repair_my_profile();
  v_subject := coalesce(
    (select telegram_subject from public.profiles where id = auth.uid()),
    public.auth_telegram_subject(auth.uid())
  );

  return jsonb_build_object(
    'blocked', coalesce((select blocked from public.profiles where id = auth.uid()), false),
    'access_status', coalesce((
      select a.access_status
      from public.staging_allowlist a
      where a.telegram_subject = v_subject
    ), 'pending')
  );
end $$;

create or replace function public.get_my_profile()
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare
  v jsonb;
begin
  perform public.repair_my_profile();
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

grant execute on function public.auth_telegram_subject(uuid) to authenticated, service_role;
grant execute on function public.repair_my_profile() to authenticated, service_role;
grant execute on function public.get_my_access_state() to authenticated;
grant execute on function public.get_my_profile() to authenticated;
grant execute on function public.repair_auth_profile(uuid, text, text, text, public.app_role) to service_role;
revoke execute on function public.repair_auth_profile(uuid, text, text, text, public.app_role) from authenticated, public, anon;
