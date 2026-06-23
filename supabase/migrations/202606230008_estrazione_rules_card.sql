alter table public.estrazioni
  add column if not exists instagram_tag_friends_count integer not null default 1,
  add column if not exists prize_first_value integer not null default 600,
  add column if not exists prize_second_value integer not null default 300,
  add column if not exists prize_third_value integer not null default 100;

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
  alter table public.estrazioni
    add constraint estrazioni_instagram_tag_friends_count_check
    check (instagram_tag_friends_count between 1 and 99);
exception
  when duplicate_object then null;
end $$;

do $$
begin
  alter table public.estrazioni
    add constraint estrazioni_prize_first_value_check
    check (prize_first_value between 1 and 100000);
exception
  when duplicate_object then null;
end $$;

do $$
begin
  alter table public.estrazioni
    add constraint estrazioni_prize_second_value_check
    check (prize_second_value between 1 and 100000);
exception
  when duplicate_object then null;
end $$;

do $$
begin
  alter table public.estrazioni
    add constraint estrazioni_prize_third_value_check
    check (prize_third_value between 1 and 100000);
exception
  when duplicate_object then null;
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

grant execute on function public.admin_upsert_estrazione(uuid, text, integer, integer, integer, integer, boolean, text, text, integer, integer, integer, integer) to authenticated;
revoke execute on function public.admin_upsert_estrazione(uuid, text, integer, integer, integer, integer, boolean, text, text, integer, integer, integer, integer) from public, anon;
