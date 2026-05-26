-- Admin access is restricted by the Telegram-derived admin role and allowlist.
-- TOTP/MFA is intentionally not required for this staging environment.

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_allowed()
    and exists (
      select 1 from public.profiles
      where id = auth.uid() and role = 'admin'
    )
$$;
