-- Server-authoritative Estrazione raffle. Mystery Box stays in historical data,
-- but the public app will use this separate module.

do $$
begin
  if not exists (select 1 from pg_type where typname = 'estrazione_status' and typnamespace = 'public'::regnamespace) then
    create type public.estrazione_status as enum ('draft', 'open', 'sold_out', 'scheduled', 'running', 'completed', 'cancelled');
  end if;
  if not exists (select 1 from pg_type where typname = 'estrazione_ticket_status' and typnamespace = 'public'::regnamespace) then
    create type public.estrazione_ticket_status as enum ('active', 'cancelled');
  end if;
end $$;

update public.game_configs
set active = false
where game_type = 'box';

create table if not exists public.estrazioni (
  id uuid primary key default gen_random_uuid(),
  title text not null default 'Estrazione' check (char_length(trim(title)) between 1 and 90),
  status public.estrazione_status not null default 'draft',
  ticket_price integer not null default 20 check (ticket_price between 1 and 100),
  min_completed_orders integer not null default 0 check (min_completed_orders between 0 and 1000),
  max_tickets integer not null default 99 check (max_tickets between 1 and 99),
  winners_count integer not null default 1 check (winners_count between 1 and 99),
  scheduled_at timestamptz,
  public_token text not null unique default encode(gen_random_bytes(18), 'hex'),
  admin_notified_at timestamptz,
  reminder_sent_at timestamptz,
  draw_started_at timestamptz,
  completed_at timestamptz,
  cancelled_at timestamptz,
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (winners_count <= max_tickets),
  check (status <> 'scheduled' or scheduled_at is not null),
  check (status <> 'completed' or completed_at is not null),
  check (status <> 'cancelled' or cancelled_at is not null)
);

create unique index if not exists estrazioni_one_active_idx
  on public.estrazioni ((true))
  where status in ('draft', 'open', 'sold_out', 'scheduled', 'running');

create table if not exists public.estrazione_tickets (
  id uuid primary key default gen_random_uuid(),
  estrazione_id uuid not null references public.estrazioni(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  selected_number integer not null check (selected_number between 1 and 99),
  paid_points integer not null check (paid_points > 0),
  status public.estrazione_ticket_status not null default 'active',
  purchased_at timestamptz not null default now()
);

create unique index if not exists estrazione_tickets_one_user_idx
  on public.estrazione_tickets (estrazione_id, user_id)
  where status = 'active';

create unique index if not exists estrazione_tickets_one_number_idx
  on public.estrazione_tickets (estrazione_id, selected_number)
  where status = 'active';

create table if not exists public.estrazione_winners (
  id uuid primary key default gen_random_uuid(),
  estrazione_id uuid not null references public.estrazioni(id) on delete cascade,
  ticket_id uuid not null references public.estrazione_tickets(id) on delete restrict,
  place integer not null check (place between 1 and 99),
  created_at timestamptz not null default now(),
  unique (estrazione_id, place),
  unique (estrazione_id, ticket_id)
);

create table if not exists public.estrazione_telegram_messages (
  id uuid primary key default gen_random_uuid(),
  estrazione_id uuid not null references public.estrazioni(id) on delete cascade,
  telegram_subject text not null,
  kind text not null check (kind in ('admin_sold_out', 'reminder')),
  message_id integer,
  error text,
  sent_at timestamptz not null default now(),
  unique (estrazione_id, telegram_subject, kind)
);

drop trigger if exists touch_estrazioni_updated_at on public.estrazioni;
create trigger touch_estrazioni_updated_at
  before update on public.estrazioni
  for each row execute procedure public.touch_updated_at();

alter table public.estrazioni enable row level security;
alter table public.estrazione_tickets enable row level security;
alter table public.estrazione_winners enable row level security;
alter table public.estrazione_telegram_messages enable row level security;

grant select on public.estrazioni, public.estrazione_tickets, public.estrazione_winners, public.estrazione_telegram_messages to authenticated;
grant insert, update, delete on public.estrazioni, public.estrazione_tickets, public.estrazione_winners, public.estrazione_telegram_messages to authenticated;

drop policy if exists member_estrazioni_read on public.estrazioni;
create policy member_estrazioni_read
  on public.estrazioni for select
  using ((public.is_allowed() and status in ('open', 'sold_out', 'scheduled', 'running', 'completed')) or public.is_admin());

drop policy if exists admin_estrazioni_all on public.estrazioni;
create policy admin_estrazioni_all
  on public.estrazioni for all
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists own_estrazione_tickets_read on public.estrazione_tickets;
create policy own_estrazione_tickets_read
  on public.estrazione_tickets for select
  using ((public.is_allowed() and user_id = auth.uid()) or public.is_admin());

drop policy if exists admin_estrazione_tickets_all on public.estrazione_tickets;
create policy admin_estrazione_tickets_all
  on public.estrazione_tickets for all
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists member_estrazione_winners_read on public.estrazione_winners;
create policy member_estrazione_winners_read
  on public.estrazione_winners for select
  using (
    public.is_admin()
    or (
      public.is_allowed()
      and exists (
        select 1 from public.estrazioni draw
        where draw.id = estrazione_id
          and draw.status in ('running', 'completed')
      )
    )
  );

drop policy if exists admin_estrazione_winners_all on public.estrazione_winners;
create policy admin_estrazione_winners_all
  on public.estrazione_winners for all
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists admin_estrazione_telegram_messages_all on public.estrazione_telegram_messages;
create policy admin_estrazione_telegram_messages_all
  on public.estrazione_telegram_messages for all
  using (public.is_admin())
  with check (public.is_admin());

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
    'user_completed_orders', draw.user_completed_orders,
    'user_eligible', draw.user_completed_orders >= draw.min_completed_orders,
    'user_balance', draw.user_balance
  )
  from draw
$$;

revoke execute on function public.estrazione_payload(uuid) from public, anon;
grant execute on function public.estrazione_payload(uuid) to authenticated, service_role;

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

create or replace function public.admin_upsert_estrazione(
  p_id uuid,
  p_title text,
  p_ticket_price integer,
  p_min_completed_orders integer,
  p_max_tickets integer,
  p_winners_count integer
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_status public.estrazione_status;
  v_sold_count integer := 0;
begin
  if not public.is_admin() then raise exception 'Non sei autorizzato a modificare le estrazioni.'; end if;
  if char_length(trim(coalesce(p_title, ''))) not between 1 and 90 then raise exception 'ESTR_TITLE_INVALID'; end if;
  if p_ticket_price not between 1 and 100 then raise exception 'ESTR_PRICE_INVALID'; end if;
  if p_min_completed_orders not between 0 and 1000 then raise exception 'ESTR_MIN_ORDERS_INVALID'; end if;
  if p_max_tickets not between 1 and 99 then raise exception 'ESTR_MAX_TICKETS_INVALID'; end if;
  if p_winners_count not between 1 and p_max_tickets then raise exception 'ESTR_WINNERS_INVALID'; end if;

  if p_id is null then
    insert into public.estrazioni (
      title, ticket_price, min_completed_orders, max_tickets, winners_count, created_by, updated_by
    ) values (
      trim(p_title), p_ticket_price, p_min_completed_orders, p_max_tickets, p_winners_count, auth.uid(), auth.uid()
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
      updated_by = auth.uid()
    where id = p_id
    returning id into v_id;
  end if;

  return public.admin_list_estrazioni();
end $$;

create or replace function public.admin_open_estrazione(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_status public.estrazione_status;
begin
  if not public.is_admin() then raise exception 'Non sei autorizzato ad aprire le estrazioni.'; end if;
  select status into v_status from public.estrazioni where id = p_id for update;
  if not found then raise exception 'ESTR_NOT_FOUND'; end if;
  if v_status <> 'draft' then raise exception 'ESTR_OPEN_INVALID_STATUS'; end if;
  update public.estrazioni set status = 'open', updated_by = auth.uid() where id = p_id;
  return public.admin_list_estrazioni();
end $$;

create or replace function public.admin_schedule_estrazione(p_id uuid, p_scheduled_at timestamptz)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_status public.estrazione_status;
  v_sold_count integer;
  v_winners_count integer;
begin
  if not public.is_admin() then raise exception 'Non sei autorizzato a programmare le estrazioni.'; end if;
  if p_scheduled_at is null or p_scheduled_at <= now() + interval '75 seconds' then raise exception 'ESTR_SCHEDULE_TOO_SOON'; end if;
  select status, winners_count into v_status, v_winners_count from public.estrazioni where id = p_id for update;
  if not found then raise exception 'ESTR_NOT_FOUND'; end if;
  if v_status <> 'sold_out' then raise exception 'ESTR_SCHEDULE_INVALID_STATUS'; end if;
  select count(*) into v_sold_count from public.estrazione_tickets where estrazione_id = p_id and status = 'active';
  if v_sold_count < v_winners_count then raise exception 'ESTR_NOT_ENOUGH_TICKETS'; end if;
  update public.estrazioni
  set status = 'scheduled',
    scheduled_at = p_scheduled_at,
    reminder_sent_at = null,
    draw_started_at = null,
    completed_at = null,
    updated_by = auth.uid()
  where id = p_id;
  return public.admin_list_estrazioni();
end $$;

create or replace function public.admin_cancel_estrazione(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_draw public.estrazioni%rowtype;
  v_ticket record;
begin
  if not public.is_admin() then raise exception 'Non sei autorizzato ad annullare le estrazioni.'; end if;
  select * into v_draw from public.estrazioni where id = p_id for update;
  if not found then raise exception 'ESTR_NOT_FOUND'; end if;
  if v_draw.status in ('completed', 'cancelled') then raise exception 'ESTR_LOCKED'; end if;

  for v_ticket in
    update public.estrazione_tickets
    set status = 'cancelled'
    where estrazione_id = p_id
      and status = 'active'
    returning *
  loop
    update public.wallet_balances
    set points = points + v_ticket.paid_points,
      updated_at = now()
    where user_id = v_ticket.user_id;
    insert into public.loyalty_ledger (user_id, reason, points_delta, xp_delta, reference_type, reference_id)
    values (v_ticket.user_id, 'Rimborso Estrazione', v_ticket.paid_points, 0, 'estrazione_refund', v_ticket.id);
  end loop;

  update public.estrazioni
  set status = 'cancelled',
    cancelled_at = now(),
    updated_by = auth.uid()
  where id = p_id;

  return public.admin_list_estrazioni();
end $$;

create or replace function public.run_estrazione_internal(p_id uuid, p_force boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_draw public.estrazioni%rowtype;
  v_ticket record;
  v_place integer := 1;
  v_ticket_count integer;
begin
  select * into v_draw
  from public.estrazioni
  where id = p_id
  for update;
  if not found then raise exception 'ESTR_NOT_FOUND'; end if;

  if v_draw.status = 'completed' then
    return public.estrazione_payload(p_id);
  end if;
  if v_draw.status not in ('sold_out', 'scheduled', 'running') then raise exception 'ESTR_RUN_INVALID_STATUS'; end if;
  if not p_force and v_draw.status = 'scheduled' and v_draw.scheduled_at > now() then raise exception 'ESTR_NOT_DUE'; end if;

  select count(*) into v_ticket_count
  from public.estrazione_tickets
  where estrazione_id = p_id
    and status = 'active';
  if v_ticket_count < v_draw.winners_count then raise exception 'ESTR_NOT_ENOUGH_TICKETS'; end if;

  update public.estrazioni
  set status = 'running',
    draw_started_at = coalesce(draw_started_at, now())
  where id = p_id;

  for v_ticket in
    select t.id
    from public.estrazione_tickets t
    where t.estrazione_id = p_id
      and t.status = 'active'
    order by random()
    limit v_draw.winners_count
  loop
    insert into public.estrazione_winners (estrazione_id, ticket_id, place)
    values (p_id, v_ticket.id, v_place)
    on conflict do nothing;
    v_place := v_place + 1;
  end loop;

  update public.estrazioni
  set status = 'completed',
    completed_at = now()
  where id = p_id;

  return public.estrazione_payload(p_id);
end $$;

create or replace function public.admin_run_estrazione(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Non sei autorizzato ad avviare le estrazioni.'; end if;
  return public.run_estrazione_internal(p_id, true);
end $$;

grant execute on function public.get_current_estrazione(text) to authenticated;
grant execute on function public.buy_estrazione_ticket(uuid, integer) to authenticated;
grant execute on function public.admin_list_estrazioni() to authenticated;
grant execute on function public.admin_upsert_estrazione(uuid, text, integer, integer, integer, integer) to authenticated;
grant execute on function public.admin_open_estrazione(uuid) to authenticated;
grant execute on function public.admin_schedule_estrazione(uuid, timestamptz) to authenticated;
grant execute on function public.admin_cancel_estrazione(uuid) to authenticated;
grant execute on function public.admin_run_estrazione(uuid) to authenticated;
grant execute on function public.run_estrazione_internal(uuid, boolean) to service_role;

revoke execute on function public.get_current_estrazione(text) from public, anon;
revoke execute on function public.buy_estrazione_ticket(uuid, integer) from public, anon;
revoke execute on function public.admin_list_estrazioni() from public, anon;
revoke execute on function public.admin_upsert_estrazione(uuid, text, integer, integer, integer, integer) from public, anon;
revoke execute on function public.admin_open_estrazione(uuid) from public, anon;
revoke execute on function public.admin_schedule_estrazione(uuid, timestamptz) from public, anon;
revoke execute on function public.admin_cancel_estrazione(uuid) from public, anon;
revoke execute on function public.admin_run_estrazione(uuid) from public, anon;
revoke execute on function public.run_estrazione_internal(uuid, boolean) from authenticated, public, anon;
