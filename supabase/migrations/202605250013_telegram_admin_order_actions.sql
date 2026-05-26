-- Telegram admins may accept or reject orders; rewards are credited only by completing accepted orders in admin UI.
create or replace function public.admin_update_order_status(p_order_id uuid, p_status public.order_status, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
declare
  v_order public.orders%rowtype;
  v_wallet public.wallet_balances%rowtype;
  v_awarded integer;
  v_completed_count integer;
begin
  if not public.is_admin() then raise exception 'Non sei autorizzato a modificare l''ordine.'; end if;
  select * into v_order from public.orders where id = p_order_id for update;
  if not found then raise exception 'Ordine non trovato.'; end if;
  if v_order.status = p_status then return; end if;
  if v_order.status in ('completed', 'cancelled') then raise exception 'L''ordine è già concluso.'; end if;
  if p_status = 'processing' and v_order.status <> 'submitted' then raise exception 'Transizione ordine non valida.'; end if;
  if p_status = 'completed' and v_order.status <> 'processing' then raise exception 'Accetta prima l''ordine.'; end if;
  if p_status = 'cancelled' and v_order.status not in ('submitted', 'processing') then raise exception 'Transizione ordine non valida.'; end if;
  if p_status not in ('processing', 'completed', 'cancelled') then raise exception 'Transizione ordine non valida.'; end if;

  update public.orders set status = p_status, operator_note = nullif(trim(p_note), '') where id = p_order_id;

  if p_status = 'cancelled' and v_order.tokens_reserved > 0 and not v_order.tokens_returned and not v_order.rewards_applied then
    update public.wallet_balances set points = least(points + v_order.tokens_reserved, 100), updated_at = now()
      where user_id = v_order.user_id;
    update public.orders set tokens_returned = true where id = p_order_id;
    insert into public.loyalty_ledger (user_id, reason, points_delta, xp_delta, reference_type, reference_id)
    values (v_order.user_id, 'Gettoni restituiti ' || v_order.display_id, v_order.tokens_reserved, 0, 'order_cancel', p_order_id);
  elsif p_status = 'completed' and not v_order.rewards_applied then
    select * into v_wallet from public.wallet_balances where user_id = v_order.user_id for update;
    v_awarded := least(v_order.points_awarded, 100 - v_wallet.points);
    update public.wallet_balances set points = points + v_awarded, xp = xp + v_order.xp_awarded, updated_at = now()
      where user_id = v_order.user_id;
    update public.orders set points_awarded = v_awarded, rewards_applied = true where id = p_order_id;
    insert into public.loyalty_ledger (user_id, reason, points_delta, xp_delta, reference_type, reference_id)
    values (v_order.user_id, 'Ordine completato ' || v_order.display_id, v_awarded, v_order.xp_awarded, 'order_complete', p_order_id);
    select count(*) into v_completed_count from public.orders
    where user_id = v_order.user_id and status = 'completed' and scenario_type <> 'legacy';
    if v_completed_count % 5 = 0 then
      update public.wallet_balances set spin_tickets = spin_tickets + 1 where user_id = v_order.user_id;
      insert into public.loyalty_ledger (user_id, reason, points_delta, xp_delta, reference_type, reference_id)
      values (v_order.user_id, 'Ticket ruota guadagnato', 0, 0, 'spin_ticket', p_order_id);
    end if;
  end if;
  insert into public.order_status_history (order_id, status, changed_by, note)
    values (p_order_id, p_status, auth.uid(), nullif(trim(p_note), ''));
  insert into public.admin_audit_log (actor_id, action, entity_type, entity_id, details)
    values (auth.uid(), 'order.status', 'order', p_order_id::text, jsonb_build_object('status', p_status, 'note', p_note));
end $$;

create or replace function public.telegram_admin_order_action(p_actor_id uuid, p_order_id uuid, p_action text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_order public.orders%rowtype;
  v_status public.order_status;
begin
  if not exists (
    select 1
    from public.profiles profile
    join public.staging_allowlist allowed on allowed.telegram_subject = profile.telegram_subject
    where profile.id = p_actor_id and profile.role = 'admin' and allowed.enabled and not profile.blocked
  ) then raise exception 'Amministratore Telegram non autorizzato.'; end if;
  if p_action not in ('accept', 'reject') then raise exception 'Azione ordine non valida.'; end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if not found then raise exception 'Ordine non trovato.'; end if;
  if v_order.status in ('completed', 'cancelled') then raise exception 'L''ordine è già concluso.'; end if;

  if p_action = 'accept' then
    if v_order.status = 'processing' then
      return jsonb_build_object('status', v_order.status, 'display_id', v_order.display_id);
    end if;
    v_status := 'processing';
  else
    v_status := 'cancelled';
  end if;

  update public.orders
    set status = v_status,
      operator_note = case when p_action = 'accept' then 'Accettato da Telegram' else 'Rifiutato da Telegram' end
    where id = p_order_id;

  if v_status = 'cancelled' and v_order.tokens_reserved > 0 and not v_order.tokens_returned and not v_order.rewards_applied then
    update public.wallet_balances set points = least(points + v_order.tokens_reserved, 100), updated_at = now()
      where user_id = v_order.user_id;
    update public.orders set tokens_returned = true where id = p_order_id;
    insert into public.loyalty_ledger (user_id, reason, points_delta, xp_delta, reference_type, reference_id)
    values (v_order.user_id, 'Gettoni restituiti ' || v_order.display_id, v_order.tokens_reserved, 0, 'order_cancel', p_order_id);
  end if;

  insert into public.order_status_history (order_id, status, changed_by, note)
    values (p_order_id, v_status, p_actor_id, case when p_action = 'accept' then 'Accettato da Telegram' else 'Rifiutato da Telegram' end);
  insert into public.admin_audit_log (actor_id, action, entity_type, entity_id, details)
    values (p_actor_id, 'order.telegram_action', 'order', p_order_id::text, jsonb_build_object('action', p_action, 'status', v_status));
  return jsonb_build_object('status', v_status, 'display_id', v_order.display_id);
end $$;

grant execute on function public.telegram_admin_order_action(uuid, uuid, text) to service_role;
revoke execute on function public.telegram_admin_order_action(uuid, uuid, text) from authenticated, public, anon;
