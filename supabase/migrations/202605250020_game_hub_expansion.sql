-- Three server-authoritative ticket games with admin-managed reward configurations.

alter table public.wallet_balances
  add column if not exists scratch_tickets integer not null default 0 check (scratch_tickets >= 0),
  add column if not exists box_tickets integer not null default 0 check (box_tickets >= 0);

update public.game_configs
set active = false, cost = 0,
  title = case game_type when 'scratch' then 'Scratch' when 'box' then 'Mystery Box' else title end
where game_type in ('scratch', 'box');

-- These options were inaccessible seed content. New games begin empty for admin setup.
delete from public.game_reward_options option_row
where option_row.game_type in ('scratch', 'box')
  and not exists (select 1 from public.game_plays play where play.reward_option_id = option_row.id);
update public.game_reward_options set active = false where game_type in ('scratch', 'box');

create or replace function public.get_my_profile()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  perform public.assert_allowed();
  select jsonb_build_object(
    'id', p.id, 'username', p.username, 'avatar_url', p.avatar_url, 'role', p.role,
    'tokens', w.points, 'points', w.points, 'xp', w.xp, 'streak', w.streak,
    'spin_tickets', w.spin_tickets, 'scratch_tickets', w.scratch_tickets, 'box_tickets', w.box_tickets,
    'level_number', coalesce(l.level_number, 1),
    'next_level_xp', (select min(xp_min) from public.levels where xp_min > w.xp),
    'total_orders', (select count(*) from public.orders where user_id = p.id),
    'completed_orders', (select count(*) from public.orders where user_id = p.id and status = 'completed')
  ) into v from public.profiles p
  join public.wallet_balances w on w.user_id = p.id
  left join lateral (
    select * from public.levels where xp_min <= w.xp order by xp_min desc limit 1
  ) l on true where p.id = auth.uid();
  return v;
end $$;

create or replace function public.play_game(p_game_type public.game_type)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_wallet public.wallet_balances%rowtype;
  v_config public.game_configs%rowtype;
  v_option public.game_reward_options%rowtype;
  v_total integer;
  v_pick integer;
  v_play uuid := gen_random_uuid();
  v_reward_kind public.reward_kind;
  v_tokens integer;
  v_option_id uuid;
  v_segment integer;
  v_segments integer;
  v_angle integer;
begin
  perform public.assert_allowed();
  if p_game_type not in ('spin', 'scratch', 'box') then raise exception 'GAME_NOT_AVAILABLE'; end if;
  select * into v_config from public.game_configs where game_type = p_game_type and active;
  if not found then raise exception 'GAME_NOT_AVAILABLE'; end if;
  select * into v_wallet from public.wallet_balances where user_id = auth.uid() for update;
  if p_game_type = 'spin' and v_wallet.spin_tickets < 1 then raise exception 'SPIN_TICKET_REQUIRED'; end if;
  if p_game_type = 'scratch' and v_wallet.scratch_tickets < 1 then raise exception 'SCRATCH_TICKET_REQUIRED'; end if;
  if p_game_type = 'box' and v_wallet.box_tickets < 1 then raise exception 'BOX_TICKET_REQUIRED'; end if;

  select sum(weight), count(*) into v_total, v_segments
  from public.game_reward_options where game_type = p_game_type and active;
  if coalesce(v_total, 0) <> 100 or v_segments < 1 then raise exception 'REWARD_DISTRIBUTION_INVALID'; end if;
  v_pick := floor(random() * v_total)::integer + 1;
  select chosen.id, chosen.segment into v_option_id, v_segment
  from (
    select o.*, row_number() over (order by o.id)::integer segment,
      sum(o.weight) over (order by o.id) running_weight
    from public.game_reward_options o where o.game_type = p_game_type and o.active
  ) chosen
  where chosen.running_weight >= v_pick order by chosen.running_weight limit 1;
  select * into v_option from public.game_reward_options where id = v_option_id;

  v_tokens := least(v_option.points_awarded, 100 - v_wallet.points);
  update public.wallet_balances set points = points + v_tokens, xp = xp + v_option.xp_awarded,
    spin_tickets = spin_tickets - case when p_game_type = 'spin' then 1 else 0 end,
    scratch_tickets = scratch_tickets - case when p_game_type = 'scratch' then 1 else 0 end,
    box_tickets = box_tickets - case when p_game_type = 'box' then 1 else 0 end,
    updated_at = now()
  where user_id = auth.uid() returning * into v_wallet;
  insert into public.game_plays (id, user_id, game_type, cost, reward_option_id, points_awarded, xp_awarded)
  values (v_play, auth.uid(), p_game_type, 0, v_option.id, v_tokens, v_option.xp_awarded);
  insert into public.loyalty_ledger (user_id, reason, points_delta, xp_delta, reference_type, reference_id)
  values (auth.uid(), 'Gioco: ' || v_config.title, v_tokens, v_option.xp_awarded, 'game_play', v_play);
  if v_option.reward_definition_id is not null then
    insert into public.user_rewards (user_id, reward_definition_id, source_play_id)
    values (auth.uid(), v_option.reward_definition_id, v_play);
    select kind into v_reward_kind from public.reward_definitions where id = v_option.reward_definition_id;
  end if;
  v_angle := mod(round(360 - ((v_segment - 0.5) * 360 / v_segments))::integer + 360, 360);
  return jsonb_build_object('play_id', v_play, 'game_type', p_game_type, 'reward_code', v_option.code,
    'reward_label', v_option.label, 'reward_color', v_option.color, 'points_awarded', v_tokens,
    'xp_awarded', v_option.xp_awarded, 'reward_kind', v_reward_kind, 'balance', v_wallet.points,
    'xp', v_wallet.xp, 'spin_tickets', v_wallet.spin_tickets, 'scratch_tickets', v_wallet.scratch_tickets,
    'box_tickets', v_wallet.box_tickets, 'segment_index', v_segment - 1, 'segment_count', v_segments,
    'angle', v_angle, 'box_stop_index', 91);
end $$;

drop function if exists public.admin_adjust_wallet(uuid, integer, integer, integer, text);
create or replace function public.admin_adjust_wallet(
  p_user_id uuid,
  p_points_delta integer,
  p_xp_delta integer,
  p_spin_tickets_delta integer,
  p_scratch_tickets_delta integer,
  p_box_tickets_delta integer,
  p_reason text
)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Non sei autorizzato a modificare il saldo.'; end if;
  if length(trim(coalesce(p_reason, ''))) < 4 then raise exception 'Motivo richiesto.'; end if;
  if coalesce(p_points_delta, 0) = 0 and coalesce(p_xp_delta, 0) = 0
    and coalesce(p_spin_tickets_delta, 0) = 0 and coalesce(p_scratch_tickets_delta, 0) = 0
    and coalesce(p_box_tickets_delta, 0) = 0 then
    raise exception 'Inserisci almeno una modifica al saldo.';
  end if;
  update public.wallet_balances
  set points = points + coalesce(p_points_delta, 0),
    xp = xp + coalesce(p_xp_delta, 0),
    spin_tickets = spin_tickets + coalesce(p_spin_tickets_delta, 0),
    scratch_tickets = scratch_tickets + coalesce(p_scratch_tickets_delta, 0),
    box_tickets = box_tickets + coalesce(p_box_tickets_delta, 0),
    updated_at = now()
  where user_id = p_user_id
    and points + coalesce(p_points_delta, 0) between 0 and 100
    and xp + coalesce(p_xp_delta, 0) >= 0
    and spin_tickets + coalesce(p_spin_tickets_delta, 0) >= 0
    and scratch_tickets + coalesce(p_scratch_tickets_delta, 0) >= 0
    and box_tickets + coalesce(p_box_tickets_delta, 0) >= 0;
  if not found then raise exception 'Saldo non valido: controlla gettoni, XP e biglietti.'; end if;
  insert into public.loyalty_ledger (user_id, reason, points_delta, xp_delta, reference_type)
  values (p_user_id, 'Amministrazione saldo: ' || trim(p_reason), coalesce(p_points_delta, 0),
    coalesce(p_xp_delta, 0), 'admin_adjustment');
  insert into public.admin_audit_log (actor_id, action, entity_type, entity_id, details)
  values (auth.uid(), 'wallet.adjust', 'profile', p_user_id::text, jsonb_build_object(
    'reason', trim(p_reason), 'gettoni', coalesce(p_points_delta, 0), 'xp', coalesce(p_xp_delta, 0),
    'biglietti_ruota', coalesce(p_spin_tickets_delta, 0),
    'biglietti_scratch', coalesce(p_scratch_tickets_delta, 0),
    'biglietti_box', coalesce(p_box_tickets_delta, 0)));
end $$;

create or replace function public.validate_game_activation()
returns trigger language plpgsql set search_path = public as $$
declare v_total integer; v_count integer;
begin
  if new.active and new.game_type in ('spin', 'scratch', 'box') then
    select sum(weight), count(*) into v_total, v_count
    from public.game_reward_options where game_type = new.game_type and active;
    if coalesce(v_total, 0) <> 100 or v_count < 1 then raise exception 'REWARD_DISTRIBUTION_INVALID'; end if;
  end if;
  return new;
end $$;
drop trigger if exists validate_game_activation_trigger on public.game_configs;
create trigger validate_game_activation_trigger before insert or update of active on public.game_configs
for each row execute function public.validate_game_activation();

drop policy if exists admin_options_write on public.game_reward_options;

create or replace function public.admin_set_game_active(p_game_type public.game_type, p_active boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Non sei autorizzato a modificare i giochi.'; end if;
  if p_game_type not in ('spin', 'scratch', 'box') then raise exception 'GAME_NOT_AVAILABLE'; end if;
  update public.game_configs set active = p_active where game_type = p_game_type;
end $$;

create or replace function public.admin_save_game_options(p_game_type public.game_type, p_options jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare v_active_count integer; v_total integer;
begin
  if not public.is_admin() then raise exception 'Non sei autorizzato a modificare i giochi.'; end if;
  if p_game_type not in ('spin', 'scratch', 'box') or jsonb_typeof(p_options) <> 'array' then
    raise exception 'Configurazione premi non valida.';
  end if;
  if exists (
    select 1 from jsonb_to_recordset(p_options) as x(code text, label text, points_awarded integer, xp_awarded integer, weight integer, color text, active boolean)
    where trim(coalesce(x.code, '')) = '' or trim(coalesce(x.label, '')) = ''
      or coalesce(x.points_awarded, -1) < 0 or coalesce(x.xp_awarded, -1) < 0
      or coalesce(x.weight, 0) < 1 or trim(coalesce(x.color, '')) = ''
  ) then raise exception 'Configurazione premi non valida.'; end if;
  if (select count(*) from jsonb_to_recordset(p_options) as x(code text))
    <> (select count(distinct trim(x.code)) from jsonb_to_recordset(p_options) as x(code text)) then
    raise exception 'Codici premio duplicati.';
  end if;
  select count(*) filter (where x.active), coalesce(sum(x.weight) filter (where x.active), 0)
  into v_active_count, v_total
  from jsonb_to_recordset(p_options) as x(weight integer, active boolean);
  if v_active_count > 0 and v_total <> 100 then raise exception 'REWARD_DISTRIBUTION_INVALID'; end if;
  if exists (select 1 from public.game_configs where game_type = p_game_type and active)
    and (v_active_count = 0 or v_total <> 100) then raise exception 'REWARD_DISTRIBUTION_INVALID'; end if;

  update public.game_reward_options set active = false where game_type = p_game_type;
  insert into public.game_reward_options (
    game_type, code, label, points_awarded, xp_awarded, reward_definition_id, weight, color, active
  )
  select p_game_type, trim(x.code), trim(x.label), x.points_awarded, x.xp_awarded,
    x.reward_definition_id, x.weight, x.color, x.active
  from jsonb_to_recordset(p_options) as x(
    code text, label text, points_awarded integer, xp_awarded integer,
    reward_definition_id uuid, weight integer, color text, active boolean
  )
  on conflict (game_type, code) do update set label = excluded.label,
    points_awarded = excluded.points_awarded, xp_awarded = excluded.xp_awarded,
    reward_definition_id = excluded.reward_definition_id, weight = excluded.weight,
    color = excluded.color, active = excluded.active;
end $$;

create or replace function public.admin_delete_game_option(p_option_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_game_type public.game_type; v_active boolean;
begin
  if not public.is_admin() then raise exception 'Non sei autorizzato a modificare i giochi.'; end if;
  select game_type, active into v_game_type, v_active from public.game_reward_options where id = p_option_id;
  if not found then return; end if;
  if v_active and exists (select 1 from public.game_configs where game_type = v_game_type and active) then
    raise exception 'Disattiva il gioco prima di eliminare un premio attivo.';
  end if;
  if exists (select 1 from public.game_plays where reward_option_id = p_option_id) then
    update public.game_reward_options set active = false where id = p_option_id;
  else
    delete from public.game_reward_options where id = p_option_id;
  end if;
end $$;

create or replace function public.admin_simulate_game(p_game_type public.game_type, p_attempts integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_total integer; v_pick integer; v_code text; v_results jsonb := '{}'::jsonb; i integer;
begin
  if not public.is_admin() then raise exception 'Non sei autorizzato a simulare i giochi.'; end if;
  if p_attempts not between 1 and 100000 then raise exception 'Numero simulazioni non valido.'; end if;
  select sum(weight) into v_total from public.game_reward_options where game_type = p_game_type and active;
  if coalesce(v_total, 0) <> 100 then raise exception 'REWARD_DISTRIBUTION_INVALID'; end if;
  for i in 1..p_attempts loop
    v_pick := floor(random() * v_total)::integer + 1;
    select option_row.code into v_code from (
      select code, sum(weight) over (order by id) running_weight
      from public.game_reward_options where game_type = p_game_type and active
    ) option_row where option_row.running_weight >= v_pick order by option_row.running_weight limit 1;
    v_results := jsonb_set(v_results, array[v_code], to_jsonb(coalesce((v_results ->> v_code)::integer, 0) + 1), true);
  end loop;
  return v_results;
end $$;

grant execute on function public.get_my_profile() to authenticated;
grant execute on function public.play_game(public.game_type) to authenticated;
grant execute on function public.admin_adjust_wallet(uuid, integer, integer, integer, integer, integer, text) to authenticated;
grant execute on function public.admin_set_game_active(public.game_type, boolean) to authenticated;
grant execute on function public.admin_save_game_options(public.game_type, jsonb) to authenticated;
grant execute on function public.admin_delete_game_option(uuid) to authenticated;
grant execute on function public.admin_simulate_game(public.game_type, integer) to authenticated;
revoke execute on function public.admin_adjust_wallet(uuid, integer, integer, integer, integer, integer, text) from public, anon;
revoke execute on function public.admin_set_game_active(public.game_type, boolean) from public, anon;
revoke execute on function public.admin_save_game_options(public.game_type, jsonb) from public, anon;
revoke execute on function public.admin_delete_game_option(uuid) from public, anon;
revoke execute on function public.admin_simulate_game(public.game_type, integer) from public, anon;
