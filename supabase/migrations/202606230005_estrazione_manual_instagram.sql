-- Manual Instagram collection for Estrazione: the buyer stores an Instagram
-- username directly on the ticket, and admins check it manually.

alter table public.estrazioni
  add column if not exists instagram_required boolean not null default false,
  add column if not exists instagram_target_username text not null default '',
  add column if not exists instagram_verification_url text not null default '';

alter table public.estrazione_tickets
  add column if not exists instagram_username text not null default '';

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
        'selected_number', t.selected_number,
        'instagram_username', t.instagram_username,
        'username', p.username,
        'telegram_subject', p.telegram_subject
      ) order by w.place)
      from public.estrazione_winners w
      join public.estrazione_tickets t on t.id = w.ticket_id
      join public.profiles p on p.id = t.user_id
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
      join public.profiles p on p.id = t.user_id
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
drop function if exists public.admin_upsert_estrazione(uuid, text, integer, integer, integer, integer, boolean, text, text);
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
begin
  if not public.is_admin() then raise exception 'Non sei autorizzato a modificare le estrazioni.'; end if;
  if char_length(trim(coalesce(p_title, ''))) not between 1 and 90 then raise exception 'ESTR_TITLE_INVALID'; end if;
  if p_ticket_price not between 1 and 100 then raise exception 'ESTR_PRICE_INVALID'; end if;
  if p_min_completed_orders not between 0 and 1000 then raise exception 'ESTR_MIN_ORDERS_INVALID'; end if;
  if p_max_tickets not between 1 and 99 then raise exception 'ESTR_MAX_TICKETS_INVALID'; end if;
  if p_winners_count not between 1 and p_max_tickets then raise exception 'ESTR_WINNERS_INVALID'; end if;

  v_instagram_target := public.normalize_instagram_username(p_instagram_target_username);
  if v_instagram_target <> '' and v_instagram_target !~ '^[a-z0-9._]{1,30}$' then
    raise exception 'ESTR_INSTAGRAM_TARGET_REQUIRED';
  end if;

  if p_id is null then
    insert into public.estrazioni (
      title, ticket_price, min_completed_orders, max_tickets, winners_count,
      instagram_required, instagram_target_username, instagram_verification_url, created_by, updated_by
    ) values (
      trim(p_title), p_ticket_price, p_min_completed_orders, p_max_tickets, p_winners_count,
      coalesce(p_instagram_required, false), v_instagram_target, trim(coalesce(p_instagram_verification_url, '')), auth.uid(), auth.uid()
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
      instagram_verification_url = trim(coalesce(p_instagram_verification_url, '')),
      updated_by = auth.uid()
    where id = p_id
    returning id into v_id;
  end if;

  return public.admin_list_estrazioni();
end $$;

grant execute on function public.get_current_estrazione(text) to authenticated;
grant execute on function public.buy_estrazione_ticket(uuid, integer, text) to authenticated;
grant execute on function public.admin_list_estrazioni() to authenticated;
grant execute on function public.admin_upsert_estrazione(uuid, text, integer, integer, integer, integer, boolean, text, text) to authenticated;

revoke execute on function public.get_current_estrazione(text) from public, anon;
revoke execute on function public.buy_estrazione_ticket(uuid, integer, text) from public, anon;
revoke execute on function public.admin_list_estrazioni() from public, anon;
revoke execute on function public.admin_upsert_estrazione(uuid, text, integer, integer, integer, integer, boolean, text, text) from public, anon;

drop table if exists public.estrazione_instagram_verifications cascade;
drop function if exists public.ensure_estrazione_instagram_verification(uuid, text);
drop function if exists public.manychat_verify_estrazione_instagram(text, text, jsonb);
