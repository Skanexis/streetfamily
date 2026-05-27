-- Admin balance adjustments support gettoni, XP and wheel tickets.

drop function if exists public.admin_adjust_wallet(uuid, integer, integer, text);

create or replace function public.admin_adjust_wallet(
  p_user_id uuid,
  p_points_delta integer,
  p_xp_delta integer,
  p_tickets_delta integer,
  p_reason text
)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Non sei autorizzato a modificare il saldo.'; end if;
  if length(trim(coalesce(p_reason, ''))) < 4 then raise exception 'Motivo richiesto.'; end if;
  if coalesce(p_points_delta, 0) = 0 and coalesce(p_xp_delta, 0) = 0 and coalesce(p_tickets_delta, 0) = 0 then
    raise exception 'Inserisci almeno una modifica al saldo.';
  end if;

  update public.wallet_balances
  set points = points + coalesce(p_points_delta, 0),
    xp = xp + coalesce(p_xp_delta, 0),
    spin_tickets = spin_tickets + coalesce(p_tickets_delta, 0),
    updated_at = now()
  where user_id = p_user_id
    and points + coalesce(p_points_delta, 0) between 0 and 100
    and xp + coalesce(p_xp_delta, 0) >= 0
    and spin_tickets + coalesce(p_tickets_delta, 0) >= 0;

  if not found then raise exception 'Saldo non valido: controlla gettoni, XP e biglietti.'; end if;

  insert into public.loyalty_ledger (user_id, reason, points_delta, xp_delta, reference_type)
  values (
    p_user_id,
    'Amministrazione saldo: ' || trim(p_reason) || case
      when coalesce(p_tickets_delta, 0) <> 0 then ' / biglietti ' || case when p_tickets_delta > 0 then '+' else '' end || p_tickets_delta
      else ''
    end,
    coalesce(p_points_delta, 0),
    coalesce(p_xp_delta, 0),
    'admin_adjustment'
  );

  insert into public.admin_audit_log (actor_id, action, entity_type, entity_id, details)
  values (
    auth.uid(),
    'wallet.adjust',
    'profile',
    p_user_id::text,
    jsonb_build_object(
      'reason', trim(p_reason),
      'gettoni', coalesce(p_points_delta, 0),
      'xp', coalesce(p_xp_delta, 0),
      'biglietti', coalesce(p_tickets_delta, 0)
    )
  );
end $$;

grant execute on function public.admin_adjust_wallet(uuid, integer, integer, integer, text) to authenticated;
revoke execute on function public.admin_adjust_wallet(uuid, integer, integer, integer, text) from public, anon;
