create type public.kyc_status as enum ('not_started', 'collecting', 'submitted', 'approved', 'rejected');
create type public.kyc_document_type as enum ('document_front', 'document_back', 'selfie_with_document');

create table public.kyc_cases (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  status public.kyc_status not null default 'not_started',
  submitted_at timestamptz,
  reviewed_at timestamptz,
  reviewed_by uuid references public.profiles(id),
  rejection_reason text,
  updated_at timestamptz not null default now()
);

create table public.kyc_documents (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  document_type public.kyc_document_type not null,
  storage_path text not null unique,
  content_type text not null check (content_type in ('image/jpeg', 'image/png', 'image/webp')),
  byte_size bigint not null check (byte_size > 0 and byte_size <= 10485760),
  captured_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (user_id, document_type)
);

create trigger kyc_cases_touch before update on public.kyc_cases
for each row execute function public.touch_updated_at();

alter table public.kyc_cases enable row level security;
alter table public.kyc_documents enable row level security;

create policy admin_kyc_cases_read on public.kyc_cases for select using (public.is_admin());

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('kyc-documents', 'kyc-documents', false, 10485760, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

-- KYC documents intentionally have no client Storage policies. Edge Functions
-- using service_role are the only upload/read path.

create or replace function public.get_my_kyc_status()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_case public.kyc_cases%rowtype;
  v_docs jsonb;
begin
  perform public.assert_allowed();
  select * into v_case from public.kyc_cases where user_id = auth.uid();
  select coalesce(jsonb_agg(document_type), '[]'::jsonb) into v_docs
  from public.kyc_documents where user_id = auth.uid();
  return jsonb_build_object(
    'status', coalesce(v_case.status, 'not_started'::public.kyc_status),
    'documents', v_docs,
    'submitted_at', v_case.submitted_at,
    'rejection_reason', v_case.rejection_reason
  );
end $$;

create or replace function public.admin_log_kyc_view(p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admin MFA required'; end if;
  insert into public.admin_audit_log (actor_id, action, entity_type, entity_id, details)
  values (auth.uid(), 'kyc.documents.view', 'profile', p_user_id::text, jsonb_build_object('ttl_seconds', 60));
end $$;

create or replace function public.admin_review_kyc(p_user_id uuid, p_decision text, p_reason text default '')
returns void language plpgsql security definer set search_path = public as $$
declare
  v_status public.kyc_status;
begin
  if not public.is_admin() then raise exception 'Admin MFA required'; end if;
  if p_decision not in ('approved', 'rejected') then raise exception 'Decisione non valida'; end if;
  if p_decision = 'rejected' and length(trim(coalesce(p_reason, ''))) < 4 then
    raise exception 'Motivo rifiuto richiesto';
  end if;
  if p_decision = 'approved' and (
    select count(distinct document_type) from public.kyc_documents where user_id = p_user_id
  ) <> 3 then raise exception 'Documenti KYC incompleti'; end if;
  v_status := p_decision::public.kyc_status;
  update public.kyc_cases set
    status = v_status,
    reviewed_at = now(),
    reviewed_by = auth.uid(),
    rejection_reason = case when v_status = 'rejected' then trim(p_reason) else null end
  where user_id = p_user_id and status = 'submitted';
  if not found then raise exception 'Caso KYC non revisionabile'; end if;
  insert into public.admin_audit_log (actor_id, action, entity_type, entity_id, details)
  values (auth.uid(), 'kyc.' || p_decision, 'profile', p_user_id::text, jsonb_build_object('reason', p_reason));
end $$;

create or replace function public.submit_test_order_internal(
  p_user_id uuid, p_items jsonb, p_method text, p_location_note text default ''
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_order uuid := gen_random_uuid();
  v_display text := '#TEST-' || upper(substr(replace(v_order::text, '-', ''), 1, 8));
  v_total numeric(10,2);
  v_points integer;
  v_xp integer;
  v_wallet public.wallet_balances%rowtype;
  v_valid_count integer;
  v_points_multiplier numeric := coalesce((select (value ->> 'points_multiplier')::numeric from public.app_settings where key = 'order_rewards'), 0.5);
  v_xp_multiplier numeric := coalesce((select (value ->> 'xp_multiplier')::numeric from public.app_settings where key = 'order_rewards'), 0.5);
begin
  if not exists (
    select 1 from public.profiles p join public.staging_allowlist a on a.telegram_subject = p.telegram_subject
    where p.id = p_user_id and a.enabled and not p.blocked
  ) then raise exception 'Staging access denied'; end if;
  if not exists (select 1 from public.orders where user_id = p_user_id) and not exists (
    select 1 from public.kyc_cases where user_id = p_user_id and status = 'approved'
  ) then raise exception 'KYC_REQUIRED_FIRST_ORDER'; end if;
  if p_method not in ('meetup', 'delivery') then raise exception 'Metodo non valido'; end if;
  if jsonb_array_length(p_items) = 0 then raise exception 'Carrello vuoto'; end if;
  if exists (select 1 from jsonb_array_elements(p_items) item where coalesce((item ->> 'quantity')::integer, 1) <> 1)
    then raise exception 'Quantita test non valida'; end if;
  select count(*), sum(v.price) into v_valid_count, v_total
  from jsonb_array_elements(p_items) item
  join public.product_variants v on v.id = (item ->> 'variant_id')::uuid
  join public.products p on p.id = v.product_id and p.published
  join public.inventory_status i on i.variant_id = v.id and i.available;
  if v_valid_count <> jsonb_array_length(p_items) or v_total is null then raise exception 'Prodotto non disponibile'; end if;
  v_points := floor(v_total * v_points_multiplier);
  v_xp := floor(v_total * v_xp_multiplier);
  insert into public.orders (id, display_id, user_id, fulfillment_method, location_note, total, points_awarded, xp_awarded)
  values (v_order, v_display, p_user_id, p_method, left(coalesce(p_location_note, ''), 160), v_total, v_points, v_xp);
  insert into public.order_items (order_id, variant_id, name_snapshot, variant_label, unit_price, quantity)
  select v_order, v.id, p.name, v.label, v.price, 1
  from jsonb_array_elements(p_items) item join public.product_variants v on v.id = (item ->> 'variant_id')::uuid
  join public.products p on p.id = v.product_id;
  insert into public.order_status_history (order_id, status, changed_by, note)
  values (v_order, 'submitted', p_user_id, 'submitted');
  update public.wallet_balances set points = points + v_points, xp = xp + v_xp, updated_at = now()
  where user_id = p_user_id returning * into v_wallet;
  insert into public.loyalty_ledger (user_id, reason, points_delta, xp_delta, reference_type, reference_id)
  values (p_user_id, 'Test order ' || v_display, v_points, v_xp, 'order', v_order);
  return jsonb_build_object('order_id', v_order, 'display_id', v_display, 'total', v_total,
    'points_awarded', v_points, 'xp_awarded', v_xp, 'balance', v_wallet.points, 'xp', v_wallet.xp);
end $$;

grant execute on function public.get_my_kyc_status() to authenticated;
grant execute on function public.admin_log_kyc_view(uuid) to authenticated;
grant execute on function public.admin_review_kyc(uuid, text, text) to authenticated;
revoke execute on function public.get_my_kyc_status() from public, anon;
revoke execute on function public.admin_log_kyc_view(uuid) from public, anon;
revoke execute on function public.admin_review_kyc(uuid, text, text) from public, anon;
