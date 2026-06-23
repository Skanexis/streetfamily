-- Optional ManyChat Instagram follow verification for Estrazione tickets.

alter table public.estrazioni
  add column if not exists instagram_required boolean not null default false,
  add column if not exists instagram_target_username text not null default '',
  add column if not exists instagram_verification_url text not null default '';

create table if not exists public.estrazione_instagram_verifications (
  id uuid primary key default gen_random_uuid(),
  estrazione_id uuid not null references public.estrazioni(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  telegram_subject text,
  instagram_username text not null default '',
  verification_code text not null unique,
  verified_at timestamptz,
  verified_by text,
  manychat_payload jsonb not null default '{}'::jsonb,
  expires_at timestamptz not null default now() + interval '30 minutes',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (estrazione_id, user_id)
);

drop trigger if exists touch_estrazione_instagram_verifications_updated_at on public.estrazione_instagram_verifications;
create trigger touch_estrazione_instagram_verifications_updated_at
  before update on public.estrazione_instagram_verifications
  for each row execute procedure public.touch_updated_at();

alter table public.estrazione_instagram_verifications enable row level security;

drop policy if exists own_estrazione_instagram_verifications_read on public.estrazione_instagram_verifications;
create policy own_estrazione_instagram_verifications_read
  on public.estrazione_instagram_verifications for select
  using (user_id = auth.uid() or public.is_admin());

drop policy if exists admin_estrazione_instagram_verifications_all on public.estrazione_instagram_verifications;
create policy admin_estrazione_instagram_verifications_all
  on public.estrazione_instagram_verifications for all
  using (public.is_admin())
  with check (public.is_admin());

grant select on public.estrazione_instagram_verifications to authenticated;
grant select, insert, update, delete on public.estrazione_instagram_verifications to service_role;

create or replace function public.normalize_instagram_username(p_username text)
returns text language sql immutable as $$
  select lower(regexp_replace(regexp_replace(trim(coalesce(p_username, '')), '^@+', ''), '\s+', '', 'g'))
$$;

create or replace function public.estrazione_instagram_verification_payload(
  p_verification public.estrazione_instagram_verifications,
  p_instagram_required boolean,
  p_instagram_target_username text,
  p_instagram_verification_url text
)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'required', coalesce(p_instagram_required, false),
    'target_username', coalesce(p_instagram_target_username, ''),
    'verification_url', coalesce(nullif(p_instagram_verification_url, ''), case when coalesce(p_instagram_target_username, '') <> '' then 'https://ig.me/m/' || p_instagram_target_username else '' end),
    'instagram_username', coalesce(p_verification.instagram_username, ''),
    'verification_code', coalesce(p_verification.verification_code, ''),
    'verified_at', p_verification.verified_at,
    'expires_at', p_verification.expires_at,
    'verified', p_verification.verified_at is not null
  )
$$;

create or replace function public.ensure_estrazione_instagram_verification(
  p_estrazione_id uuid,
  p_instagram_username text default ''
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_draw public.estrazioni%rowtype;
  v_existing public.estrazione_instagram_verifications%rowtype;
  v_username text;
  v_code text;
begin
  perform public.assert_allowed();

  select * into v_draw
  from public.estrazioni
  where id = p_estrazione_id
    and status not in ('completed', 'cancelled');
  if not found then raise exception 'ESTR_NOT_FOUND'; end if;

  if not v_draw.instagram_required then
    return jsonb_build_object(
      'required', false,
      'target_username', '',
      'verification_url', '',
      'instagram_username', '',
      'verification_code', '',
      'verified_at', null,
      'expires_at', null,
      'verified', true
    );
  end if;

  select * into v_existing
  from public.estrazione_instagram_verifications
  where estrazione_id = v_draw.id
    and user_id = auth.uid()
  for update;

  v_username := public.normalize_instagram_username(p_instagram_username);
  if v_username = '' and found then
    v_username := public.normalize_instagram_username(v_existing.instagram_username);
  end if;
  if v_username !~ '^[a-z0-9._]{1,30}$' then
    raise exception 'ESTR_INSTAGRAM_USERNAME_INVALID';
  end if;

  if found and v_existing.verified_at is not null then
    if v_existing.instagram_username <> v_username then
      update public.estrazione_instagram_verifications
      set instagram_username = v_username
      where id = v_existing.id
      returning * into v_existing;
    end if;
    return public.estrazione_instagram_verification_payload(
      v_existing,
      v_draw.instagram_required,
      v_draw.instagram_target_username,
      v_draw.instagram_verification_url
    );
  end if;

  if found and v_existing.expires_at > now() then
    update public.estrazione_instagram_verifications
    set instagram_username = v_username,
      telegram_subject = (select telegram_subject from public.profiles where id = auth.uid())
    where id = v_existing.id
    returning * into v_existing;
    return public.estrazione_instagram_verification_payload(
      v_existing,
      v_draw.instagram_required,
      v_draw.instagram_target_username,
      v_draw.instagram_verification_url
    );
  end if;

  loop
    v_code := upper(substr(encode(gen_random_bytes(6), 'hex'), 1, 10));
    exit when not exists (
      select 1 from public.estrazione_instagram_verifications
      where verification_code = v_code
    );
  end loop;

  insert into public.estrazione_instagram_verifications (
    estrazione_id,
    user_id,
    telegram_subject,
    instagram_username,
    verification_code,
    expires_at
  ) values (
    v_draw.id,
    auth.uid(),
    (select telegram_subject from public.profiles where id = auth.uid()),
    v_username,
    v_code,
    now() + interval '30 minutes'
  )
  on conflict (estrazione_id, user_id) do update
  set telegram_subject = excluded.telegram_subject,
    instagram_username = excluded.instagram_username,
    verification_code = excluded.verification_code,
    verified_at = null,
    verified_by = null,
    manychat_payload = '{}'::jsonb,
    expires_at = excluded.expires_at
  returning * into v_existing;

  return public.estrazione_instagram_verification_payload(
    v_existing,
    v_draw.instagram_required,
    v_draw.instagram_target_username,
    v_draw.instagram_verification_url
  );
end $$;

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
      'instagram_verification_url', coalesce(nullif(draw.instagram_verification_url, ''), case when draw.instagram_target_username <> '' then 'https://ig.me/m/' || draw.instagram_target_username else '' end),
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
        'selected_number', t.selected_number,
        'username', p.username,
        'telegram_subject', p.telegram_subject
      ) order by w.place)
      from public.estrazione_winners w
      join public.estrazione_tickets t on t.id = w.ticket_id
      join public.profiles p on p.id = t.user_id
      where w.estrazione_id = draw.id
    ), '[]'::jsonb),
    'instagram_verification', case
      when draw.instagram_required then coalesce((
        select public.estrazione_instagram_verification_payload(
          v,
          draw.instagram_required,
          draw.instagram_target_username,
          draw.instagram_verification_url
        )
        from public.estrazione_instagram_verifications v
        where v.estrazione_id = draw.id
          and v.user_id = auth.uid()
        limit 1
      ), jsonb_build_object(
        'required', true,
        'target_username', draw.instagram_target_username,
        'verification_url', coalesce(nullif(draw.instagram_verification_url, ''), case when draw.instagram_target_username <> '' then 'https://ig.me/m/' || draw.instagram_target_username else '' end),
        'instagram_username', '',
        'verification_code', '',
        'verified_at', null,
        'expires_at', null,
        'verified', false
      ))
      else jsonb_build_object(
        'required', false,
        'target_username', '',
        'verification_url', '',
        'instagram_username', '',
        'verification_code', '',
        'verified_at', null,
        'expires_at', null,
        'verified', true
      )
    end,
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
      'instagram_verification', null,
      'user_completed_orders', (select count(*) from public.orders where user_id = auth.uid() and status = 'completed'),
      'user_eligible', false,
      'user_balance', coalesce((select points from public.wallet_balances where user_id = auth.uid()), 0)
    );
  end if;

  return public.estrazione_payload(v_id);
end $$;

create or replace function public.buy_estrazione_ticket(p_estrazione_id uuid, p_selected_number integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_draw public.estrazioni%rowtype;
  v_wallet public.wallet_balances%rowtype;
  v_sold_count integer;
  v_completed_orders integer;
  v_ticket_id uuid;
begin
  perform public.assert_allowed();

  if p_selected_number not between 1 and 99 then raise exception 'ESTR_NUMBER_INVALID'; end if;

  select * into v_draw
  from public.estrazioni
  where id = p_estrazione_id
  for update;
  if not found or v_draw.status <> 'open' then raise exception 'ESTR_NOT_OPEN'; end if;

  select count(*) into v_completed_orders
  from public.orders
  where user_id = auth.uid()
    and status = 'completed';
  if v_completed_orders < v_draw.min_completed_orders then
    raise exception 'ESTR_COMPLETED_ORDERS_REQUIRED:%', v_draw.min_completed_orders;
  end if;

  if v_draw.instagram_required and not exists (
    select 1
    from public.estrazione_instagram_verifications verification
    where verification.estrazione_id = v_draw.id
      and verification.user_id = auth.uid()
      and verification.verified_at is not null
  ) then
    raise exception 'ESTR_INSTAGRAM_REQUIRED';
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

  insert into public.estrazione_tickets (estrazione_id, user_id, selected_number, paid_points)
  values (v_draw.id, auth.uid(), p_selected_number, v_draw.ticket_price)
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
    'instagram_verification_url', coalesce(nullif(e.instagram_verification_url, ''), case when e.instagram_target_username <> '' then 'https://ig.me/m/' || e.instagram_target_username else '' end),
    'instagram_verified_count', (select count(*) from public.estrazione_instagram_verifications v where v.estrazione_id = e.id and v.verified_at is not null),
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
        'instagram_username', v.instagram_username,
        'instagram_verified_at', v.verified_at,
        'selected_number', t.selected_number,
        'paid_points', t.paid_points,
        'status', t.status,
        'purchased_at', t.purchased_at
      ) order by t.selected_number)
      from public.estrazione_tickets t
      join public.profiles p on p.id = t.user_id
      left join public.estrazione_instagram_verifications v on v.estrazione_id = e.id and v.user_id = t.user_id
      where t.estrazione_id = e.id
    ), '[]'::jsonb),
    'winners', coalesce((
      select jsonb_agg(jsonb_build_object(
        'place', w.place,
        'ticket_id', w.ticket_id,
        'selected_number', t.selected_number,
        'username', p.username,
        'telegram_subject', p.telegram_subject
      ) order by w.place)
      from public.estrazione_winners w
      join public.estrazione_tickets t on t.id = w.ticket_id
      join public.profiles p on p.id = t.user_id
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
create or replace function public.admin_upsert_estrazione(
  p_id uuid,
  p_title text,
  p_ticket_price integer,
  p_min_completed_orders integer,
  p_max_tickets integer,
  p_winners_count integer,
  p_instagram_required boolean default false,
  p_instagram_target_username text default '',
  p_instagram_verification_url text default ''
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_status public.estrazione_status;
  v_sold_count integer := 0;
  v_instagram_target text;
  v_instagram_url text;
begin
  if not public.is_admin() then raise exception 'Non sei autorizzato a modificare le estrazioni.'; end if;
  if char_length(trim(coalesce(p_title, ''))) not between 1 and 90 then raise exception 'ESTR_TITLE_INVALID'; end if;
  if p_ticket_price not between 1 and 100 then raise exception 'ESTR_PRICE_INVALID'; end if;
  if p_min_completed_orders not between 0 and 1000 then raise exception 'ESTR_MIN_ORDERS_INVALID'; end if;
  if p_max_tickets not between 1 and 99 then raise exception 'ESTR_MAX_TICKETS_INVALID'; end if;
  if p_winners_count not between 1 and p_max_tickets then raise exception 'ESTR_WINNERS_INVALID'; end if;

  v_instagram_target := public.normalize_instagram_username(p_instagram_target_username);
  v_instagram_url := trim(coalesce(p_instagram_verification_url, ''));
  if coalesce(p_instagram_required, false) and v_instagram_target !~ '^[a-z0-9._]{1,30}$' then
    raise exception 'ESTR_INSTAGRAM_TARGET_REQUIRED';
  end if;
  if v_instagram_url <> '' and v_instagram_url !~* '^https://.+$' then
    raise exception 'ESTR_INSTAGRAM_URL_INVALID';
  end if;

  if p_id is null then
    insert into public.estrazioni (
      title,
      ticket_price,
      min_completed_orders,
      max_tickets,
      winners_count,
      instagram_required,
      instagram_target_username,
      instagram_verification_url,
      created_by,
      updated_by
    ) values (
      trim(p_title),
      p_ticket_price,
      p_min_completed_orders,
      p_max_tickets,
      p_winners_count,
      coalesce(p_instagram_required, false),
      v_instagram_target,
      v_instagram_url,
      auth.uid(),
      auth.uid()
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
      updated_by = auth.uid()
    where id = p_id
    returning id into v_id;
  end if;

  return public.admin_list_estrazioni();
end $$;

create or replace function public.manychat_verify_estrazione_instagram(
  p_verification_code text,
  p_instagram_username text default '',
  p_payload jsonb default '{}'::jsonb
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_code text;
  v_username text;
  v_verification public.estrazione_instagram_verifications%rowtype;
  v_draw public.estrazioni%rowtype;
begin
  v_code := upper(coalesce(substring(trim(coalesce(p_verification_code, '')) from '([A-Fa-f0-9]{10})'), ''));
  if v_code = '' then raise exception 'ESTR_INSTAGRAM_CODE_NOT_FOUND'; end if;

  v_username := public.normalize_instagram_username(p_instagram_username);
  if v_username <> '' and v_username !~ '^[a-z0-9._]{1,30}$' then
    raise exception 'ESTR_INSTAGRAM_USERNAME_INVALID';
  end if;

  select * into v_verification
  from public.estrazione_instagram_verifications
  where verification_code = v_code
  for update;
  if not found then raise exception 'ESTR_INSTAGRAM_CODE_NOT_FOUND'; end if;

  select * into v_draw
  from public.estrazioni
  where id = v_verification.estrazione_id
    and status not in ('completed', 'cancelled');
  if not found then raise exception 'ESTR_NOT_FOUND'; end if;

  if v_verification.verified_at is null and v_verification.expires_at < now() then
    raise exception 'ESTR_INSTAGRAM_CODE_EXPIRED';
  end if;

  if v_username = '' then
    v_username := v_verification.instagram_username;
  end if;

  update public.estrazione_instagram_verifications
  set instagram_username = v_username,
    verified_at = coalesce(verified_at, now()),
    verified_by = 'manychat',
    manychat_payload = coalesce(p_payload, '{}'::jsonb)
  where id = v_verification.id
  returning * into v_verification;

  return jsonb_build_object(
    'verified', true,
    'estrazione_id', v_verification.estrazione_id,
    'user_id', v_verification.user_id,
    'telegram_subject', v_verification.telegram_subject,
    'instagram_username', v_verification.instagram_username,
    'target_username', v_draw.instagram_target_username,
    'draw_title', v_draw.title,
    'verified_at', v_verification.verified_at
  );
end $$;

grant execute on function public.ensure_estrazione_instagram_verification(uuid, text) to authenticated;
grant execute on function public.admin_upsert_estrazione(uuid, text, integer, integer, integer, integer, boolean, text, text) to authenticated;
grant execute on function public.manychat_verify_estrazione_instagram(text, text, jsonb) to service_role;

revoke execute on function public.ensure_estrazione_instagram_verification(uuid, text) from public, anon;
revoke execute on function public.admin_upsert_estrazione(uuid, text, integer, integer, integer, integer, boolean, text, text) from public, anon;
revoke execute on function public.manychat_verify_estrazione_instagram(text, text, jsonb) from public, anon, authenticated;
