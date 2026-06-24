-- Keep Telegram access and Estrazione RPCs deterministic after migration repairs.

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
      coalesce(allowed.access_decided_at, allowed.access_requested_at, allowed.created_at, '-infinity'::timestamptz) as row_time,
      max(coalesce(allowed.access_decided_at, allowed.access_requested_at, allowed.created_at, '-infinity'::timestamptz)) filter (
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

with subjects as (
  select distinct public.normalize_telegram_subject(telegram_subject) as subject
  from public.staging_allowlist
  where public.normalize_telegram_subject(telegram_subject) is not null
),
effective as (
  select subject, access.role, access.enabled, access.access_status
  from subjects
  join lateral public.effective_access_row(subject) access on true
)
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
  subject,
  coalesce(role, 'user'::public.app_role),
  coalesce(enabled, false),
  coalesce(access_status, 'pending'),
  now(),
  case when access_status in ('approved', 'rejected') then now() else null end,
  'canonical Telegram access row'
from effective
on conflict (telegram_subject) do update
set role = case
      when excluded.access_status = 'approved' then excluded.role
      when public.staging_allowlist.role = 'admin' then 'admin'::public.app_role
      else public.staging_allowlist.role
    end,
    enabled = excluded.enabled,
    access_status = excluded.access_status,
    access_decided_at = case
      when excluded.access_status in ('approved', 'rejected') then coalesce(public.staging_allowlist.access_decided_at, excluded.access_decided_at, now())
      else public.staging_allowlist.access_decided_at
    end,
    note = coalesce(public.staging_allowlist.note, excluded.note);

with subjects as (
  select distinct public.normalize_telegram_subject(telegram_subject) as subject
  from public.staging_allowlist
  where public.normalize_telegram_subject(telegram_subject) is not null
),
effective as (
  select subject, access.role, access.enabled, access.access_status
  from subjects
  join lateral public.effective_access_row(subject) access on true
)
update public.staging_allowlist target
set enabled = effective.enabled,
  access_status = effective.access_status,
  role = case
    when effective.access_status = 'approved' then effective.role
    when target.role = 'admin' then 'admin'::public.app_role
    else target.role
  end,
  access_decided_at = case
    when effective.access_status in ('approved', 'rejected') then coalesce(target.access_decided_at, now())
    else target.access_decided_at
  end,
  note = coalesce(target.note, 'duplicate Telegram access normalized to effective state')
from effective
where public.normalize_telegram_subject(target.telegram_subject) = effective.subject
  and (
    target.enabled is distinct from effective.enabled
    or target.access_status is distinct from effective.access_status
    or (effective.access_status = 'approved' and target.role is distinct from effective.role)
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

  update public.staging_allowlist
  set access_status = p_decision,
    enabled = p_decision = 'approved',
    role = case when p_decision = 'approved' then v_role else role end,
    access_decided_at = now(),
    access_decided_by = p_actor_id,
    note = case when p_decision = 'approved' then 'Approvato da Telegram' else 'Rifiutato da Telegram' end
  where public.normalize_telegram_subject(telegram_subject) = v_subject;

  update public.profiles
  set role = case when p_decision = 'approved' then v_role else role end,
    blocked = p_decision = 'rejected',
    telegram_subject = v_subject,
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
        telegram_subject = v_subject,
        updated_at = now()
      where id = v_user.id;
    elsif p_decision = 'rejected' then
      update public.profiles
      set blocked = true,
        telegram_subject = v_subject,
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

do $$
declare
  v_user auth.users%rowtype;
  v_subject text;
  v_access_status text;
  v_access_enabled boolean;
  v_access_role public.app_role;
begin
  for v_user in select * from auth.users loop
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
        telegram_subject = v_subject,
        updated_at = now()
      where id = v_user.id;
    elsif v_access_status = 'rejected' then
      update public.profiles
      set blocked = true,
        telegram_subject = v_subject,
        updated_at = now()
      where id = v_user.id;
    end if;
  end loop;
end $$;

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
    from public.effective_access_row(profile.telegram_subject) access
    where access.enabled
      and access.access_status = 'approved'
  );

create or replace function public.admin_access_overview()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_result jsonb;
begin
  if not public.is_admin() then raise exception 'Non sei autorizzato.'; end if;

  with access_subjects as (
    select distinct public.normalize_telegram_subject(telegram_subject) as subject
    from public.staging_allowlist
    where public.normalize_telegram_subject(telegram_subject) is not null
  ),
  profile_subjects as (
    select distinct public.normalize_telegram_subject(telegram_subject) as subject
    from public.profiles
    where public.normalize_telegram_subject(telegram_subject) is not null
  ),
  subjects as (
    select subject from access_subjects
    union
    select subject from profile_subjects
  ),
  profile_candidates as (
    select
      public.normalize_telegram_subject(profile.telegram_subject) as subject,
      profile.*
    from public.profiles profile
    where public.normalize_telegram_subject(profile.telegram_subject) is not null
  ),
  profile_pick as (
    select distinct on (subject)
      subject,
      id,
      username,
      role,
      blocked,
      telegram_subject,
      created_at,
      updated_at
    from profile_candidates
    order by subject,
      case when telegram_subject = subject then 0 else 1 end,
      updated_at desc nulls last,
      created_at desc nulls last
  ),
  access_meta as (
    select distinct on (public.normalize_telegram_subject(allowed.telegram_subject))
      public.normalize_telegram_subject(allowed.telegram_subject) as subject,
      allowed.access_username,
      allowed.access_requested_at,
      allowed.access_decided_at,
      allowed.access_notified_at,
      allowed.note
    from public.staging_allowlist allowed
    where public.normalize_telegram_subject(allowed.telegram_subject) is not null
    order by public.normalize_telegram_subject(allowed.telegram_subject),
      case when allowed.telegram_subject = public.normalize_telegram_subject(allowed.telegram_subject) then 0 else 1 end,
      coalesce(allowed.access_decided_at, allowed.access_requested_at, allowed.created_at) desc nulls last
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'telegram_subject', subjects.subject,
    'access_status', coalesce(access.access_status, case when profile.id is not null and profile.blocked then 'rejected' else 'pending' end),
    'enabled', coalesce(access.enabled, false),
    'role', coalesce(access.role, profile.role, 'user'::public.app_role),
    'profile_id', profile.id,
    'username', coalesce(profile.username, access_meta.access_username),
    'blocked', coalesce(profile.blocked, false),
    'has_profile', profile.id is not null,
    'access_username', access_meta.access_username,
    'access_requested_at', access_meta.access_requested_at,
    'access_decided_at', access_meta.access_decided_at,
    'access_notified_at', access_meta.access_notified_at,
    'note', access_meta.note
  ) order by
    case coalesce(access.access_status, case when profile.id is not null and profile.blocked then 'rejected' else 'pending' end)
      when 'approved' then 1
      when 'pending' then 2
      when 'rejected' then 3
      else 4
    end,
    coalesce(profile.username, access_meta.access_username, subjects.subject)
  ), '[]'::jsonb)
  into v_result
  from subjects
  left join lateral public.effective_access_row(subjects.subject) access on true
  left join profile_pick profile on profile.subject = subjects.subject
  left join access_meta on access_meta.subject = subjects.subject;

  return v_result;
end $$;

create or replace function public.admin_dashboard()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Non sei autorizzato.'; end if;
  return jsonb_build_object(
    'allowlisted_users', (
      with subjects as (
        select distinct public.normalize_telegram_subject(telegram_subject) as subject
        from public.staging_allowlist
        where public.normalize_telegram_subject(telegram_subject) is not null
      )
      select count(*)
      from subjects
      join lateral public.effective_access_row(subjects.subject) access on true
      where access.enabled
        and access.access_status = 'approved'
    ),
    'submitted_orders', (select count(*) from public.orders where status = 'submitted'),
    'game_plays', (select count(*) from public.game_plays),
    'issued_points', (select coalesce(sum(points_delta), 0) from public.loyalty_ledger where points_delta > 0)
  );
end $$;

alter table public.estrazioni
  add column if not exists instagram_required boolean not null default false,
  add column if not exists instagram_target_username text not null default '',
  add column if not exists instagram_verification_url text not null default '',
  add column if not exists instagram_tag_friends_count integer not null default 1,
  add column if not exists prize_first_value integer not null default 600,
  add column if not exists prize_second_value integer not null default 300,
  add column if not exists prize_third_value integer not null default 100;

alter table public.estrazione_tickets
  add column if not exists instagram_username text not null default '';

update public.estrazioni
set instagram_tag_friends_count = 1
where instagram_tag_friends_count is null
  or instagram_tag_friends_count not between 1 and 99;

update public.estrazioni
set prize_first_value = 600
where prize_first_value is null
  or prize_first_value not between 1 and 100000;

update public.estrazioni
set prize_second_value = 300
where prize_second_value is null
  or prize_second_value not between 1 and 100000;

update public.estrazioni
set prize_third_value = 100
where prize_third_value is null
  or prize_third_value not between 1 and 100000;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'estrazioni_instagram_tag_friends_count_check'
      and conrelid = 'public.estrazioni'::regclass
  ) then
    alter table public.estrazioni
      add constraint estrazioni_instagram_tag_friends_count_check
      check (instagram_tag_friends_count between 1 and 99);
  end if;
end $$;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'estrazioni_prize_first_value_check'
      and conrelid = 'public.estrazioni'::regclass
  ) then
    alter table public.estrazioni
      add constraint estrazioni_prize_first_value_check
      check (prize_first_value between 1 and 100000);
  end if;
end $$;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'estrazioni_prize_second_value_check'
      and conrelid = 'public.estrazioni'::regclass
  ) then
    alter table public.estrazioni
      add constraint estrazioni_prize_second_value_check
      check (prize_second_value between 1 and 100000);
  end if;
end $$;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'estrazioni_prize_third_value_check'
      and conrelid = 'public.estrazioni'::regclass
  ) then
    alter table public.estrazioni
      add constraint estrazioni_prize_third_value_check
      check (prize_third_value between 1 and 100000);
  end if;
end $$;

create or replace function public.normalize_instagram_username(p_username text)
returns text language sql immutable as $$
  select lower(regexp_replace(regexp_replace(trim(coalesce(p_username, '')), '^@+', ''), '\s+', '', 'g'))
$$;

create or replace function public.estrazione_payload(p_estrazione_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  with draw as (
    select e.*,
      (select count(*) from public.estrazione_tickets t where t.estrazione_id = e.id and t.status = 'active')::integer as sold_count,
      (select count(*) from public.orders o where o.user_id = auth.uid() and o.status = 'completed')::integer as user_completed_orders,
      coalesce((select points from public.wallet_balances where user_id = auth.uid()), 0)::integer as user_balance
    from public.estrazioni e
    where e.id = p_estrazione_id
  )
  select jsonb_build_object(
    'estrazione', jsonb_build_object(
      'id', draw.id,
      'title', draw.title,
      'status', draw.status,
      'ticket_price', draw.ticket_price,
      'min_completed_orders', draw.min_completed_orders,
      'max_tickets', draw.max_tickets,
      'winners_count', draw.winners_count,
      'instagram_required', draw.instagram_required,
      'instagram_target_username', draw.instagram_target_username,
      'instagram_verification_url', draw.instagram_verification_url,
      'instagram_tag_friends_count', draw.instagram_tag_friends_count,
      'prize_first_value', draw.prize_first_value,
      'prize_second_value', draw.prize_second_value,
      'prize_third_value', draw.prize_third_value,
      'scheduled_at', draw.scheduled_at,
      'public_token', draw.public_token,
      'admin_notified_at', draw.admin_notified_at,
      'reminder_sent_at', draw.reminder_sent_at,
      'draw_started_at', draw.draw_started_at,
      'completed_at', draw.completed_at,
      'cancelled_at', draw.cancelled_at,
      'created_at', draw.created_at,
      'updated_at', draw.updated_at,
      'sold_count', draw.sold_count,
      'remaining_count', greatest(draw.max_tickets - draw.sold_count, 0)
    ),
    'sold_numbers', coalesce((
      select jsonb_agg(t.selected_number order by t.selected_number)
      from public.estrazione_tickets t
      where t.estrazione_id = draw.id and t.status = 'active'
    ), '[]'::jsonb),
    'user_ticket', (
      select jsonb_build_object(
        'id', t.id,
        'selected_number', t.selected_number,
        'paid_points', t.paid_points,
        'instagram_username', t.instagram_username,
        'purchased_at', t.purchased_at
      )
      from public.estrazione_tickets t
      where t.estrazione_id = draw.id
        and t.user_id = auth.uid()
        and t.status = 'active'
      limit 1
    ),
    'winners', coalesce((
      select jsonb_agg(jsonb_build_object(
        'place', w.place,
        'ticket_id', w.ticket_id,
        'selected_number', t.selected_number,
        'instagram_username', t.instagram_username,
        'username', p.username,
        'telegram_subject', p.telegram_subject
      ) order by w.place)
      from public.estrazione_winners w
      join public.estrazione_tickets t on t.id = w.ticket_id
      left join public.profiles p on p.id = t.user_id
      where w.estrazione_id = draw.id
    ), '[]'::jsonb),
    'user_completed_orders', draw.user_completed_orders,
    'user_eligible', draw.user_completed_orders >= draw.min_completed_orders,
    'user_balance', draw.user_balance
  )
  from draw
$$;

create or replace function public.get_current_estrazione(p_public_token text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  perform public.assert_allowed();

  if nullif(trim(coalesce(p_public_token, '')), '') is not null then
    select id into v_id
    from public.estrazioni
    where public_token = trim(p_public_token)
      and status <> 'cancelled';
  else
    select id into v_id
    from public.estrazioni
    where status in ('open', 'sold_out', 'scheduled', 'running', 'completed')
    order by case status
      when 'open' then 1
      when 'sold_out' then 2
      when 'scheduled' then 3
      when 'running' then 4
      when 'completed' then 5
      else 9
    end, created_at desc
    limit 1;
  end if;

  if v_id is null then
    return jsonb_build_object(
      'estrazione', null,
      'sold_numbers', '[]'::jsonb,
      'user_ticket', null,
      'winners', '[]'::jsonb,
      'user_completed_orders', (select count(*) from public.orders where user_id = auth.uid() and status = 'completed'),
      'user_eligible', false,
      'user_balance', coalesce((select points from public.wallet_balances where user_id = auth.uid()), 0)
    );
  end if;

  return public.estrazione_payload(v_id);
end $$;

drop function if exists public.buy_estrazione_ticket(uuid, integer);
drop function if exists public.buy_estrazione_ticket(uuid, integer, text);
create or replace function public.buy_estrazione_ticket(
  p_estrazione_id uuid,
  p_selected_number integer,
  p_instagram_username text default ''
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_draw public.estrazioni%rowtype;
  v_wallet public.wallet_balances%rowtype;
  v_sold_count integer;
  v_completed_orders integer;
  v_ticket_id uuid;
  v_instagram_username text;
begin
  perform public.assert_allowed();

  if p_selected_number not between 1 and 99 then raise exception 'ESTR_NUMBER_INVALID'; end if;

  select * into v_draw
  from public.estrazioni
  where id = p_estrazione_id
  for update;
  if not found or v_draw.status <> 'open' then raise exception 'ESTR_NOT_OPEN'; end if;

  v_instagram_username := public.normalize_instagram_username(p_instagram_username);
  if v_draw.instagram_required and v_instagram_username !~ '^[a-z0-9._]{1,30}$' then
    raise exception 'ESTR_INSTAGRAM_USERNAME_INVALID';
  end if;
  if v_instagram_username <> '' and v_instagram_username !~ '^[a-z0-9._]{1,30}$' then
    raise exception 'ESTR_INSTAGRAM_USERNAME_INVALID';
  end if;

  select count(*) into v_completed_orders
  from public.orders
  where user_id = auth.uid()
    and status = 'completed';
  if v_completed_orders < v_draw.min_completed_orders then
    raise exception 'ESTR_COMPLETED_ORDERS_REQUIRED:%', v_draw.min_completed_orders;
  end if;

  if exists (
    select 1 from public.estrazione_tickets
    where estrazione_id = v_draw.id
      and user_id = auth.uid()
      and status = 'active'
  ) then raise exception 'ESTR_TICKET_ALREADY_BOUGHT'; end if;

  if exists (
    select 1 from public.estrazione_tickets
    where estrazione_id = v_draw.id
      and selected_number = p_selected_number
      and status = 'active'
  ) then raise exception 'ESTR_NUMBER_TAKEN'; end if;

  select count(*) into v_sold_count
  from public.estrazione_tickets
  where estrazione_id = v_draw.id
    and status = 'active';
  if v_sold_count >= v_draw.max_tickets then raise exception 'ESTR_SOLD_OUT'; end if;

  select * into v_wallet
  from public.wallet_balances
  where user_id = auth.uid()
  for update;
  if not found or v_wallet.points < v_draw.ticket_price then raise exception 'ESTR_TICKET_BALANCE_REQUIRED'; end if;

  update public.wallet_balances
  set points = points - v_draw.ticket_price,
    updated_at = now()
  where user_id = auth.uid()
  returning * into v_wallet;

  insert into public.estrazione_tickets (estrazione_id, user_id, selected_number, paid_points, instagram_username)
  values (v_draw.id, auth.uid(), p_selected_number, v_draw.ticket_price, v_instagram_username)
  returning id into v_ticket_id;

  insert into public.loyalty_ledger (user_id, reason, points_delta, xp_delta, reference_type, reference_id)
  values (
    auth.uid(),
    'Biglietto Estrazione #' || lpad(p_selected_number::text, 2, '0'),
    -v_draw.ticket_price,
    0,
    'estrazione_ticket',
    v_ticket_id
  );

  select count(*) into v_sold_count
  from public.estrazione_tickets
  where estrazione_id = v_draw.id
    and status = 'active';
  if v_sold_count >= v_draw.max_tickets then
    update public.estrazioni
    set status = 'sold_out',
      updated_by = auth.uid()
    where id = v_draw.id;
  end if;

  return public.estrazione_payload(v_draw.id);
end $$;

create or replace function public.admin_list_estrazioni()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_result jsonb;
begin
  if not public.is_admin() then raise exception 'Non sei autorizzato a leggere le estrazioni.'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', e.id,
    'title', e.title,
    'status', e.status,
    'ticket_price', e.ticket_price,
    'min_completed_orders', e.min_completed_orders,
    'max_tickets', e.max_tickets,
    'winners_count', e.winners_count,
    'instagram_required', e.instagram_required,
    'instagram_target_username', e.instagram_target_username,
    'instagram_verification_url', e.instagram_verification_url,
    'instagram_tag_friends_count', e.instagram_tag_friends_count,
    'prize_first_value', e.prize_first_value,
    'prize_second_value', e.prize_second_value,
    'prize_third_value', e.prize_third_value,
    'instagram_count', (select count(*) from public.estrazione_tickets t where t.estrazione_id = e.id and t.status = 'active' and nullif(t.instagram_username, '') is not null),
    'scheduled_at', e.scheduled_at,
    'public_token', e.public_token,
    'admin_notified_at', e.admin_notified_at,
    'reminder_sent_at', e.reminder_sent_at,
    'draw_started_at', e.draw_started_at,
    'completed_at', e.completed_at,
    'cancelled_at', e.cancelled_at,
    'created_at', e.created_at,
    'updated_at', e.updated_at,
    'sold_count', (select count(*) from public.estrazione_tickets t where t.estrazione_id = e.id and t.status = 'active'),
    'tickets', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', t.id,
        'user_id', t.user_id,
        'username', p.username,
        'telegram_subject', p.telegram_subject,
        'instagram_username', t.instagram_username,
        'selected_number', t.selected_number,
        'paid_points', t.paid_points,
        'status', t.status,
        'purchased_at', t.purchased_at
      ) order by t.selected_number)
      from public.estrazione_tickets t
      left join public.profiles p on p.id = t.user_id
      where t.estrazione_id = e.id
    ), '[]'::jsonb),
    'winners', coalesce((
      select jsonb_agg(jsonb_build_object(
        'place', w.place,
        'ticket_id', w.ticket_id,
        'selected_number', t.selected_number,
        'instagram_username', t.instagram_username,
        'username', p.username,
        'telegram_subject', p.telegram_subject
      ) order by w.place)
      from public.estrazione_winners w
      join public.estrazione_tickets t on t.id = w.ticket_id
      left join public.profiles p on p.id = t.user_id
      where w.estrazione_id = e.id
    ), '[]'::jsonb),
    'message_counts', jsonb_build_object(
      'admin_sold_out', (select count(*) from public.estrazione_telegram_messages m where m.estrazione_id = e.id and m.kind = 'admin_sold_out' and m.message_id is not null),
      'reminder', (select count(*) from public.estrazione_telegram_messages m where m.estrazione_id = e.id and m.kind = 'reminder' and m.message_id is not null),
      'errors', (select count(*) from public.estrazione_telegram_messages m where m.estrazione_id = e.id and m.error is not null)
    )
  ) order by e.created_at desc), '[]'::jsonb)
  into v_result
  from public.estrazioni e;

  return v_result;
end $$;

drop function if exists public.admin_upsert_estrazione(uuid, text, integer, integer, integer, integer);
drop function if exists public.admin_upsert_estrazione(uuid, text, integer, integer, integer, integer, boolean, text, text);
drop function if exists public.admin_upsert_estrazione(uuid, text, integer, integer, integer, integer, boolean, text, text, integer);
drop function if exists public.admin_upsert_estrazione(uuid, text, integer, integer, integer, integer, boolean, text, text, integer, integer, integer, integer);
create or replace function public.admin_upsert_estrazione(
  p_id uuid,
  p_title text,
  p_ticket_price integer,
  p_min_completed_orders integer,
  p_max_tickets integer,
  p_winners_count integer,
  p_instagram_required boolean default false,
  p_instagram_target_username text default '',
  p_instagram_verification_url text default '',
  p_instagram_tag_friends_count integer default 1,
  p_prize_first_value integer default 600,
  p_prize_second_value integer default 300,
  p_prize_third_value integer default 100
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_status public.estrazione_status;
  v_sold_count integer := 0;
  v_instagram_target text;
  v_instagram_url text;
  v_instagram_tag_friends_count integer;
  v_prize_first_value integer;
  v_prize_second_value integer;
  v_prize_third_value integer;
begin
  if not public.is_admin() then raise exception 'Non sei autorizzato a modificare le estrazioni.'; end if;
  if char_length(trim(coalesce(p_title, ''))) not between 1 and 90 then raise exception 'ESTR_TITLE_INVALID'; end if;
  if p_ticket_price not between 1 and 100 then raise exception 'ESTR_PRICE_INVALID'; end if;
  if p_min_completed_orders not between 0 and 1000 then raise exception 'ESTR_MIN_ORDERS_INVALID'; end if;
  if p_max_tickets not between 1 and 99 then raise exception 'ESTR_MAX_TICKETS_INVALID'; end if;
  if p_winners_count not between 1 and p_max_tickets then raise exception 'ESTR_WINNERS_INVALID'; end if;

  v_instagram_target := public.normalize_instagram_username(p_instagram_target_username);
  v_instagram_url := trim(coalesce(p_instagram_verification_url, ''));
  v_instagram_tag_friends_count := coalesce(p_instagram_tag_friends_count, 1);
  v_prize_first_value := coalesce(p_prize_first_value, 600);
  v_prize_second_value := coalesce(p_prize_second_value, 300);
  v_prize_third_value := coalesce(p_prize_third_value, 100);

  if v_instagram_target <> '' and v_instagram_target !~ '^[a-z0-9._]{1,30}$' then
    raise exception 'ESTR_INSTAGRAM_TARGET_REQUIRED';
  end if;
  if v_instagram_url <> '' and v_instagram_url !~* '^https?://' then
    raise exception 'ESTR_INSTAGRAM_URL_INVALID';
  end if;
  if v_instagram_tag_friends_count not between 1 and 99 then
    raise exception 'ESTR_INSTAGRAM_TAGS_INVALID';
  end if;
  if v_prize_first_value not between 1 and 100000
    or v_prize_second_value not between 1 and 100000
    or v_prize_third_value not between 1 and 100000 then
    raise exception 'ESTR_PRIZE_VALUE_INVALID';
  end if;

  if p_id is null then
    insert into public.estrazioni (
      title, ticket_price, min_completed_orders, max_tickets, winners_count,
      instagram_required, instagram_target_username, instagram_verification_url,
      instagram_tag_friends_count, prize_first_value, prize_second_value, prize_third_value,
      created_by, updated_by
    ) values (
      trim(p_title), p_ticket_price, p_min_completed_orders, p_max_tickets, p_winners_count,
      coalesce(p_instagram_required, false), v_instagram_target, v_instagram_url,
      v_instagram_tag_friends_count, v_prize_first_value, v_prize_second_value, v_prize_third_value,
      auth.uid(), auth.uid()
    )
    returning id into v_id;
  else
    select status into v_status from public.estrazioni where id = p_id for update;
    if not found then raise exception 'ESTR_NOT_FOUND'; end if;
    if v_status in ('running', 'completed', 'cancelled') then raise exception 'ESTR_LOCKED'; end if;
    select count(*) into v_sold_count
    from public.estrazione_tickets
    where estrazione_id = p_id and status = 'active';
    if p_max_tickets < v_sold_count then raise exception 'ESTR_MAX_TICKETS_BELOW_SOLD'; end if;
    if p_winners_count > greatest(p_max_tickets, v_sold_count) then raise exception 'ESTR_WINNERS_INVALID'; end if;

    update public.estrazioni
    set title = trim(p_title),
      ticket_price = p_ticket_price,
      min_completed_orders = p_min_completed_orders,
      max_tickets = p_max_tickets,
      winners_count = p_winners_count,
      instagram_required = coalesce(p_instagram_required, false),
      instagram_target_username = v_instagram_target,
      instagram_verification_url = v_instagram_url,
      instagram_tag_friends_count = v_instagram_tag_friends_count,
      prize_first_value = v_prize_first_value,
      prize_second_value = v_prize_second_value,
      prize_third_value = v_prize_third_value,
      updated_by = auth.uid()
    where id = p_id
    returning id into v_id;
  end if;

  return public.admin_list_estrazioni();
end $$;

grant execute on function public.effective_access_row(text) to authenticated, service_role;
grant execute on function public.admin_review_access_request(uuid, text, text) to service_role;
grant execute on function public.admin_access_overview() to authenticated;
grant execute on function public.admin_dashboard() to authenticated;
grant execute on function public.get_current_estrazione(text) to authenticated;
grant execute on function public.buy_estrazione_ticket(uuid, integer, text) to authenticated;
grant execute on function public.admin_list_estrazioni() to authenticated;
grant execute on function public.admin_upsert_estrazione(uuid, text, integer, integer, integer, integer, boolean, text, text, integer, integer, integer, integer) to authenticated;

revoke execute on function public.effective_access_row(text) from public, anon;
revoke execute on function public.admin_review_access_request(uuid, text, text) from authenticated, public, anon;
revoke execute on function public.admin_access_overview() from public, anon;
revoke execute on function public.admin_dashboard() from public, anon;
revoke execute on function public.get_current_estrazione(text) from public, anon;
revoke execute on function public.buy_estrazione_ticket(uuid, integer, text) from public, anon;
revoke execute on function public.admin_list_estrazioni() from public, anon;
revoke execute on function public.admin_upsert_estrazione(uuid, text, integer, integer, integer, integer, boolean, text, text, integer, integer, integer, integer) from public, anon;

notify pgrst, 'reload schema';
