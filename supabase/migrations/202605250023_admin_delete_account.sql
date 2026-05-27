-- Prepare a non-admin account for Auth deletion while preserving the acting admin for audit triggers.
create or replace function public.admin_prepare_account_deletion(p_user_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_telegram_subject text;
  v_username text;
  v_role public.app_role;
begin
  if not public.is_admin() then raise exception 'Non sei autorizzato a eliminare utenti.'; end if;
  if p_user_id = auth.uid() then raise exception 'Non puoi eliminare il tuo account.'; end if;

  select telegram_subject, username, role
  into v_telegram_subject, v_username, v_role
  from public.profiles
  where id = p_user_id;

  if not found then raise exception 'Utente non trovato.'; end if;
  if v_role = 'admin' then raise exception 'Un amministratore non puo essere eliminato.'; end if;

  update public.profiles set blocked = true where id = p_user_id;
  delete from public.staging_allowlist where telegram_subject = v_telegram_subject;

  update public.kyc_cases set reviewed_by = null
  where reviewed_by = p_user_id and user_id <> p_user_id;
  update public.feedback set moderated_by = null
  where moderated_by = p_user_id and user_id <> p_user_id;
  update public.order_status_history set changed_by = null
  where changed_by = p_user_id
    and order_id not in (select id from public.orders where user_id = p_user_id);

  delete from public.broadcasts where created_by = p_user_id;
  update public.user_rewards set redeemed_order_id = null
  where redeemed_order_id in (select id from public.orders where user_id = p_user_id)
    and user_id <> p_user_id;
  delete from public.user_rewards where user_id = p_user_id;
  delete from public.orders where user_id = p_user_id;
  delete from public.admin_audit_log where actor_id = p_user_id;

  insert into public.admin_audit_log (actor_id, action, entity_type, entity_id, details)
  values (auth.uid(), 'profile.delete', 'profile', p_user_id::text, jsonb_build_object(
    'username', v_username,
    'telegram_subject', v_telegram_subject
  ));

  return v_telegram_subject;
end $$;

grant execute on function public.admin_prepare_account_deletion(uuid) to authenticated;
revoke execute on function public.admin_prepare_account_deletion(uuid) from public, anon;
