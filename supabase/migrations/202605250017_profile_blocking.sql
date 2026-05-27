-- Account blocking is controlled by admins and remains visible to the blocked account.

create or replace function public.get_my_access_state()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'blocked', coalesce((select blocked from public.profiles where id = auth.uid()), false)
  )
$$;

create or replace function public.admin_set_profile_blocked(p_user_id uuid, p_blocked boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Non sei autorizzato a bloccare utenti.'; end if;
  if p_user_id = auth.uid() then raise exception 'Non puoi bloccare il tuo account.'; end if;

  update public.profiles
  set blocked = p_blocked
  where id = p_user_id and role <> 'admin';

  if not found then raise exception 'Utente non trovato o amministratore non bloccabile.'; end if;

  insert into public.admin_audit_log (actor_id, action, entity_type, entity_id, details)
  values (
    auth.uid(),
    case when p_blocked then 'profile.block' else 'profile.unblock' end,
    'profile',
    p_user_id::text,
    jsonb_build_object('blocked', p_blocked)
  );
end $$;

grant execute on function public.get_my_access_state() to authenticated;
revoke execute on function public.get_my_access_state() from public, anon;
grant execute on function public.admin_set_profile_blocked(uuid, boolean) to authenticated;
revoke execute on function public.admin_set_profile_blocked(uuid, boolean) from public, anon;
