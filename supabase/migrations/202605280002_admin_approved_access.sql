-- New Telegram accounts must be approved by an administrator before seeing the app.
alter table public.staging_allowlist
  add column if not exists access_status text not null default 'approved'
    check (access_status in ('pending', 'approved', 'rejected')),
  add column if not exists access_requested_at timestamptz,
  add column if not exists access_username text,
  add column if not exists access_notified_at timestamptz,
  add column if not exists access_decided_at timestamptz,
  add column if not exists access_decided_by uuid references public.profiles(id);

update public.staging_allowlist
set access_status = case when enabled then 'approved' else 'rejected' end,
    access_requested_at = coalesce(access_requested_at, created_at),
    access_decided_at = case when enabled then coalesce(access_decided_at, created_at) else access_decided_at end
where access_status = 'approved' or not enabled;

create or replace function public.is_allowed()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from public.profiles p
    join public.staging_allowlist a on a.telegram_subject = p.telegram_subject
    where p.id = auth.uid()
      and a.enabled
      and a.access_status = 'approved'
      and not p.blocked
  )
$$;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_subject text := coalesce(new.raw_user_meta_data ->> 'sub', new.raw_user_meta_data ->> 'telegram_id', new.raw_user_meta_data ->> 'id', new.id::text);
  v_role public.app_role;
begin
  select role into v_role
  from public.staging_allowlist
  where telegram_subject = v_subject
    and enabled
    and access_status = 'approved';
  insert into public.profiles (id, telegram_subject, username, avatar_url, role)
  values (
    new.id,
    v_subject,
    coalesce(new.raw_user_meta_data ->> 'preferred_username', new.raw_user_meta_data ->> 'username', 'member'),
    coalesce(new.raw_user_meta_data ->> 'picture', new.raw_user_meta_data ->> 'photo_url', new.raw_user_meta_data ->> 'avatar_url'),
    coalesce(v_role, 'user')
  );
  insert into public.wallet_balances (user_id, points) values (new.id, 0);
  return new;
end $$;

create or replace function public.sync_allowlist_role()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.profiles
  set role = new.role,
      blocked = case when new.access_status = 'rejected' then true else blocked end
  where telegram_subject = new.telegram_subject
    and (new.enabled and new.access_status = 'approved' or new.access_status = 'rejected');
  return new;
end $$;

drop trigger if exists allowlist_role_sync on public.staging_allowlist;
create trigger allowlist_role_sync
  after insert or update of role, enabled, access_status on public.staging_allowlist
  for each row execute function public.sync_allowlist_role();

create or replace function public.get_my_access_state()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'blocked', coalesce((select blocked from public.profiles where id = auth.uid()), false),
    'access_status', coalesce((
      select a.access_status
      from public.profiles p
      join public.staging_allowlist a on a.telegram_subject = p.telegram_subject
      where p.id = auth.uid()
    ), 'pending')
  )
$$;

create or replace function public.admin_review_access_request(
  p_actor_id uuid, p_telegram_subject text, p_decision text
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_status text;
  v_profile public.profiles%rowtype;
begin
  if p_decision not in ('approved', 'rejected') then raise exception 'Decisione accesso non valida.'; end if;
  if not exists (
    select 1
    from public.profiles profile
    join public.staging_allowlist allowed on allowed.telegram_subject = profile.telegram_subject
    where profile.id = p_actor_id
      and profile.role = 'admin'
      and allowed.enabled
      and allowed.access_status = 'approved'
      and not profile.blocked
  ) then raise exception 'Amministratore Telegram non autorizzato.'; end if;

  update public.staging_allowlist
  set access_status = p_decision,
      enabled = p_decision = 'approved',
      access_decided_at = now(),
      access_decided_by = p_actor_id,
      note = case when p_decision = 'approved' then 'Approvato da Telegram' else 'Rifiutato da Telegram' end
  where telegram_subject = p_telegram_subject
    and access_status = 'pending'
  returning access_status into v_status;
  if not found then raise exception 'Richiesta di accesso non trovata.'; end if;

  select * into v_profile from public.profiles where telegram_subject = p_telegram_subject;
  if found then
    update public.profiles
    set role = 'user',
        blocked = p_decision = 'rejected'
    where id = v_profile.id;
  end if;

  insert into public.admin_audit_log (actor_id, action, entity_type, entity_id, details)
  values (
    p_actor_id,
    'access.' || p_decision,
    'staging_allowlist',
    p_telegram_subject,
    jsonb_build_object('telegram_subject', p_telegram_subject, 'decision', p_decision)
  );

  return jsonb_build_object('status', v_status, 'telegram_subject', p_telegram_subject);
end $$;

grant execute on function public.get_my_access_state() to authenticated;
grant execute on function public.admin_review_access_request(uuid, text, text) to service_role;
revoke execute on function public.admin_review_access_request(uuid, text, text) from authenticated, public, anon;
