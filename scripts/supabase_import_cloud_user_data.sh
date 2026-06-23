#!/usr/bin/env bash
set -euo pipefail

IMPORT_JSON="${1:-/opt/apps/streetfamily/import/cloud_user_data.json}"
SELFHOST_SUPABASE_DIR="${SELFHOST_SUPABASE_DIR:-/opt/supabase-project}"
ENV_DEPLOY_FILE="${ENV_DEPLOY_FILE:-/opt/apps/streetfamily/.env.deploy}"
BACKUP_DIR="${BACKUP_DIR:-/opt/apps/streetfamily/backups/cloud-user-data-import-$(date -u +%Y%m%dT%H%M%SZ)}"

if [[ "${CONFIRM_IMPORT_CLOUD_USER_DATA:-}" != "yes" ]]; then
  cat >&2 <<EOF
Refusing to import without confirmation.

This imports Cloud profiles, wallets, orders, order items, KYC metadata and history
into the current self-host database. Existing data for those Telegram users is replaced.

Run:
  CONFIRM_IMPORT_CLOUD_USER_DATA=yes $0 "$IMPORT_JSON"
EOF
  exit 1
fi

if [[ ! -f "$IMPORT_JSON" ]]; then
  echo "Import JSON not found: $IMPORT_JSON" >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"
NORMALIZED_JSON="$BACKUP_DIR/cloud_user_data_inner.json"

echo "Normalizing Cloud JSON..."
python3 - "$IMPORT_JSON" "$NORMALIZED_JSON" <<'PY'
import json
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
raw = json.loads(src.read_text(encoding="utf-8-sig"))

if isinstance(raw, list) and len(raw) == 1 and isinstance(raw[0], dict) and "backup_json" in raw[0]:
    data = json.loads(raw[0]["backup_json"])
elif isinstance(raw, dict) and "backup_json" in raw:
    data = json.loads(raw["backup_json"])
elif isinstance(raw, dict):
    data = raw
else:
    raise SystemExit("Unsupported JSON format. Expected backup_json or object with table arrays.")

required = ["profiles", "wallet_balances", "orders", "order_items", "order_status_history"]
missing = [key for key in required if key not in data]
if missing:
    raise SystemExit(f"Missing keys in JSON: {', '.join(missing)}")

dst.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
for key in sorted(data):
    value = data[key]
    print(f"{key}: {len(value) if isinstance(value, list) else type(value).__name__}")
PY

cd "$SELFHOST_SUPABASE_DIR"
docker compose up -d db auth rest >/dev/null

echo "Waiting for self-host database..."
for _ in $(seq 1 60); do
  if docker exec supabase-db pg_isready -U postgres -d postgres >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
docker exec supabase-db pg_isready -U postgres -d postgres >/dev/null

echo "Saving current self-host user data backup..."
docker exec supabase-db pg_dump -U postgres -d postgres \
  --data-only --no-owner --no-privileges \
  -t auth.users \
  -t public.staging_allowlist \
  -t public.profiles \
  -t public.wallet_balances \
  -t public.orders \
  -t public.order_items \
  -t public.order_status_history \
  -t public.feedback \
  -t public.kyc_cases \
  -t public.kyc_documents \
  -t public.loyalty_ledger \
  -t public.daily_claims \
  -t public.game_plays \
  -t public.user_rewards \
  > "$BACKUP_DIR/selfhost-user-data-before.sql"

SERVICE_ROLE_KEY="$(
  { grep -hE '^(SERVICE_ROLE_KEY|SUPABASE_SERVICE_ROLE_KEY)=' "$SELFHOST_SUPABASE_DIR/.env" "$SELFHOST_SUPABASE_DIR/.env.functions" 2>/dev/null || true; } \
    | tail -n1 \
    | cut -d= -f2- \
    | tr -d '\r'
)"

if [[ -z "$SERVICE_ROLE_KEY" ]]; then
  echo "Could not find SERVICE_ROLE_KEY in $SELFHOST_SUPABASE_DIR/.env or .env.functions" >&2
  exit 1
fi

echo "Creating missing Auth users through self-host Auth API..."
python3 - "$NORMALIZED_JSON" "$SERVICE_ROLE_KEY" <<'PY'
import json
import sys
import urllib.error
import urllib.request

path, service_key = sys.argv[1], sys.argv[2]
data = json.load(open(path, encoding="utf-8"))
profiles = data.get("profiles", [])
url = "http://127.0.0.1:8000/auth/v1/admin/users"
headers = {
    "apikey": service_key,
    "authorization": f"Bearer {service_key}",
    "content-type": "application/json",
}

created = 0
skipped = 0
failed = []

for profile in profiles:
    telegram_subject = str(profile.get("telegram_subject") or "").strip()
    if not telegram_subject:
        continue
    username = str(profile.get("username") or "member")
    payload = {
        "email": f"telegram_{telegram_subject}@street-family.invalid",
        "email_confirm": True,
        "user_metadata": {
            "telegram_id": telegram_subject,
            "telegram_subject": telegram_subject,
            "username": username,
            "preferred_username": username,
            "avatar_url": profile.get("avatar_url"),
        },
    }
    request = urllib.request.Request(url, data=json.dumps(payload).encode(), headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            response.read()
        created += 1
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        if exc.code in (400, 409, 422) and any(token in body.lower() for token in ("already", "exists", "registered")):
            skipped += 1
            continue
        failed.append((telegram_subject, exc.code, body[:300]))

print(f"auth users created: {created}")
print(f"auth users already existed: {skipped}")
if failed:
    for item in failed[:10]:
        print("AUTH_CREATE_FAILED", item)
    raise SystemExit(f"Failed to create {len(failed)} auth users")
PY

docker cp "$NORMALIZED_JSON" supabase-db:/tmp/cloud_user_data_inner.json

ADMIN_IDS=""
if [[ -f "$ENV_DEPLOY_FILE" ]]; then
  ADMIN_IDS="$(grep '^TELEGRAM_ADMIN_IDS=' "$ENV_DEPLOY_FILE" | tail -n1 | cut -d= -f2- | tr -d ' \r' || true)"
fi

echo "Importing profiles, orders, KYC and history into Postgres..."
docker exec -i supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 -v admin_ids="$ADMIN_IDS" <<'SQL'
begin;

create temp table import_payload(data jsonb) on commit drop;
\copy import_payload(data) from '/tmp/cloud_user_data_inner.json'

alter table public.staging_allowlist
  add column if not exists access_status text not null default 'approved'
    check (access_status in ('pending', 'approved', 'rejected')),
  add column if not exists access_requested_at timestamptz,
  add column if not exists access_username text,
  add column if not exists access_notified_at timestamptz,
  add column if not exists access_decided_at timestamptz,
  add column if not exists access_decided_by uuid references public.profiles(id);

create temp table old_profiles on commit drop as
select
  id::uuid as old_id,
  nullif(telegram_subject, '') as telegram_subject,
  coalesce(nullif(username, ''), 'member') as username,
  avatar_url,
  coalesce(nullif(role, ''), 'user')::public.app_role as role,
  coalesce(blocked, false) as blocked,
  coalesce(created_at, now())::timestamptz as created_at,
  coalesce(updated_at, now())::timestamptz as updated_at
from jsonb_to_recordset((select data->'profiles' from import_payload)) as row(
  id text,
  role text,
  blocked boolean,
  username text,
  avatar_url text,
  created_at timestamptz,
  updated_at timestamptz,
  telegram_subject text
)
where nullif(telegram_subject, '') is not null;

insert into public.staging_allowlist (
  telegram_subject,
  role,
  enabled,
  note,
  access_status,
  access_username,
  access_decided_at
)
select
  telegram_subject,
  role,
  true,
  'restored from Supabase Cloud user data import',
  'approved',
  username,
  now()
from old_profiles
on conflict (telegram_subject) do update set
  role = excluded.role,
  enabled = true,
  note = excluded.note,
  access_status = 'approved',
  access_username = excluded.access_username,
  access_decided_at = now();

create temp table auth_map on commit drop as
select
  old_profiles.old_id,
  coalesce(existing_profiles.id, auth_users.id) as new_id,
  old_profiles.telegram_subject
from old_profiles
left join public.profiles existing_profiles
  on existing_profiles.telegram_subject = old_profiles.telegram_subject
left join auth.users auth_users
  on auth_users.email = 'telegram_' || old_profiles.telegram_subject || '@street-family.invalid'
where coalesce(existing_profiles.id, auth_users.id) is not null;

do $$
declare
  missing_count integer;
begin
  select count(*)
  into missing_count
  from old_profiles
  left join auth_map using (old_id, telegram_subject)
  where auth_map.new_id is null;

  if missing_count > 0 then
    raise exception 'Missing Auth users after creation: %', missing_count;
  end if;
end $$;

create temp table affected_profile_ids on commit drop as
select new_id as id from auth_map
union
select profiles.id
from public.profiles profiles
join old_profiles on old_profiles.telegram_subject = profiles.telegram_subject;

create temp table old_orders on commit drop as
select *
from jsonb_to_recordset((select data->'orders' from import_payload)) as row(
  id uuid,
  mode text,
  total numeric,
  status text,
  user_id uuid,
  created_at timestamptz,
  display_id text,
  updated_at timestamptz,
  xp_awarded integer,
  total_units integer,
  location_note text,
  operator_note text,
  scenario_city text,
  scenario_type text,
  points_awarded integer,
  stock_deducted boolean,
  rewards_applied boolean,
  scenario_street text,
  simulated_total numeric,
  tokens_reserved integer,
  tokens_returned boolean,
  fulfillment_method text,
  simulated_subtotal numeric,
  simulated_surcharge numeric,
  simulated_token_credit numeric
);

create temp table import_order_ids on commit drop as
select orders.id
from public.orders orders
where orders.user_id in (select id from affected_profile_ids)
   or orders.id in (select id from old_orders)
   or orders.display_id in (select display_id from old_orders);

delete from public.feedback where user_id in (select id from affected_profile_ids) or order_id in (select id from import_order_ids);
delete from public.order_status_history where order_id in (select id from import_order_ids) or changed_by in (select id from affected_profile_ids);
delete from public.order_items where order_id in (select id from import_order_ids);
delete from public.orders where id in (select id from import_order_ids);
delete from public.user_rewards where user_id in (select id from affected_profile_ids);
delete from public.game_plays where user_id in (select id from affected_profile_ids);
delete from public.daily_claims where user_id in (select id from affected_profile_ids);
delete from public.loyalty_ledger where user_id in (select id from affected_profile_ids);
delete from public.kyc_documents where user_id in (select id from affected_profile_ids);
delete from public.kyc_cases where user_id in (select id from affected_profile_ids);
delete from public.wallet_balances where user_id in (select id from affected_profile_ids);

insert into public.profiles (
  id,
  telegram_subject,
  username,
  avatar_url,
  role,
  blocked,
  created_at,
  updated_at
)
select
  auth_map.new_id,
  old_profiles.telegram_subject,
  old_profiles.username,
  old_profiles.avatar_url,
  old_profiles.role,
  old_profiles.blocked,
  old_profiles.created_at,
  old_profiles.updated_at
from old_profiles
join auth_map using (old_id, telegram_subject)
on conflict (id) do update set
  telegram_subject = excluded.telegram_subject,
  username = excluded.username,
  avatar_url = excluded.avatar_url,
  role = excluded.role,
  blocked = excluded.blocked,
  created_at = excluded.created_at,
  updated_at = excluded.updated_at;

insert into public.wallet_balances (
  user_id,
  points,
  xp,
  streak,
  last_daily_claim,
  updated_at,
  spin_tickets,
  scratch_tickets,
  box_tickets
)
select
  auth_map.new_id,
  coalesce(row.points, 0),
  coalesce(row.xp, 0),
  coalesce(row.streak, 0),
  row.last_daily_claim,
  coalesce(row.updated_at, now()),
  coalesce(row.spin_tickets, 0),
  coalesce(row.scratch_tickets, 0),
  coalesce(row.box_tickets, 0)
from jsonb_to_recordset((select data->'wallet_balances' from import_payload)) as row(
  user_id uuid,
  points integer,
  xp integer,
  streak integer,
  last_daily_claim date,
  updated_at timestamptz,
  spin_tickets integer,
  scratch_tickets integer,
  box_tickets integer
)
join auth_map on auth_map.old_id = row.user_id
on conflict (user_id) do update set
  points = excluded.points,
  xp = excluded.xp,
  streak = excluded.streak,
  last_daily_claim = excluded.last_daily_claim,
  updated_at = excluded.updated_at,
  spin_tickets = excluded.spin_tickets,
  scratch_tickets = excluded.scratch_tickets,
  box_tickets = excluded.box_tickets;

insert into public.kyc_cases (
  user_id,
  status,
  submitted_at,
  reviewed_at,
  reviewed_by,
  rejection_reason,
  updated_at,
  retain_until,
  documents_purged_at
)
select
  user_map.new_id,
  coalesce(row.status, 'not_started')::public.kyc_status,
  row.submitted_at,
  row.reviewed_at,
  reviewer_map.new_id,
  row.rejection_reason,
  coalesce(row.updated_at, now()),
  row.retain_until,
  row.documents_purged_at
from jsonb_to_recordset((select data->'kyc_cases' from import_payload)) as row(
  user_id uuid,
  status text,
  submitted_at timestamptz,
  reviewed_at timestamptz,
  reviewed_by uuid,
  rejection_reason text,
  updated_at timestamptz,
  retain_until timestamptz,
  documents_purged_at timestamptz
)
join auth_map user_map on user_map.old_id = row.user_id
left join auth_map reviewer_map on reviewer_map.old_id = row.reviewed_by
on conflict (user_id) do update set
  status = excluded.status,
  submitted_at = excluded.submitted_at,
  reviewed_at = excluded.reviewed_at,
  reviewed_by = excluded.reviewed_by,
  rejection_reason = excluded.rejection_reason,
  updated_at = excluded.updated_at,
  retain_until = excluded.retain_until,
  documents_purged_at = excluded.documents_purged_at;

insert into public.kyc_documents (
  id,
  user_id,
  document_type,
  storage_path,
  content_type,
  byte_size,
  captured_at,
  created_at
)
select
  row.id,
  auth_map.new_id,
  row.document_type::public.kyc_document_type,
  row.storage_path,
  row.content_type,
  row.byte_size,
  coalesce(row.captured_at, now()),
  coalesce(row.created_at, now())
from jsonb_to_recordset((select data->'kyc_documents' from import_payload)) as row(
  id uuid,
  user_id uuid,
  document_type text,
  storage_path text,
  content_type text,
  byte_size bigint,
  captured_at timestamptz,
  created_at timestamptz
)
join auth_map on auth_map.old_id = row.user_id
on conflict (id) do update set
  user_id = excluded.user_id,
  document_type = excluded.document_type,
  storage_path = excluded.storage_path,
  content_type = excluded.content_type,
  byte_size = excluded.byte_size,
  captured_at = excluded.captured_at,
  created_at = excluded.created_at;

insert into public.orders (
  id,
  display_id,
  user_id,
  mode,
  status,
  fulfillment_method,
  location_note,
  total,
  points_awarded,
  xp_awarded,
  operator_note,
  created_at,
  updated_at,
  scenario_type,
  scenario_city,
  scenario_street,
  total_units,
  tokens_reserved,
  simulated_subtotal,
  simulated_surcharge,
  simulated_token_credit,
  simulated_total,
  rewards_applied,
  tokens_returned,
  stock_deducted
)
select
  old_orders.id,
  old_orders.display_id,
  auth_map.new_id,
  coalesce(old_orders.mode, 'test')::public.order_mode,
  coalesce(old_orders.status, 'submitted')::public.order_status,
  old_orders.fulfillment_method,
  coalesce(old_orders.location_note, ''),
  coalesce(old_orders.total, 0),
  coalesce(old_orders.points_awarded, 0),
  coalesce(old_orders.xp_awarded, 0),
  old_orders.operator_note,
  coalesce(old_orders.created_at, now()),
  coalesce(old_orders.updated_at, now()),
  coalesce(old_orders.scenario_type, 'legacy'),
  coalesce(old_orders.scenario_city, ''),
  coalesce(old_orders.scenario_street, ''),
  coalesce(old_orders.total_units, 0),
  coalesce(old_orders.tokens_reserved, 0),
  coalesce(old_orders.simulated_subtotal, old_orders.total, 0),
  coalesce(old_orders.simulated_surcharge, 0),
  coalesce(old_orders.simulated_token_credit, 0),
  coalesce(old_orders.simulated_total, old_orders.total, 0),
  coalesce(old_orders.rewards_applied, false),
  coalesce(old_orders.tokens_returned, false),
  coalesce(old_orders.stock_deducted, false)
from old_orders
join auth_map on auth_map.old_id = old_orders.user_id
on conflict (id) do update set
  display_id = excluded.display_id,
  user_id = excluded.user_id,
  mode = excluded.mode,
  status = excluded.status,
  fulfillment_method = excluded.fulfillment_method,
  location_note = excluded.location_note,
  total = excluded.total,
  points_awarded = excluded.points_awarded,
  xp_awarded = excluded.xp_awarded,
  operator_note = excluded.operator_note,
  created_at = excluded.created_at,
  updated_at = excluded.updated_at,
  scenario_type = excluded.scenario_type,
  scenario_city = excluded.scenario_city,
  scenario_street = excluded.scenario_street,
  total_units = excluded.total_units,
  tokens_reserved = excluded.tokens_reserved,
  simulated_subtotal = excluded.simulated_subtotal,
  simulated_surcharge = excluded.simulated_surcharge,
  simulated_token_credit = excluded.simulated_token_credit,
  simulated_total = excluded.simulated_total,
  rewards_applied = excluded.rewards_applied,
  tokens_returned = excluded.tokens_returned,
  stock_deducted = excluded.stock_deducted;

insert into public.order_items (
  id,
  order_id,
  variant_id,
  name_snapshot,
  variant_label,
  unit_price,
  quantity,
  gram_amount
)
select
  row.id,
  row.order_id,
  case when product_variants.id is null then null else row.variant_id end,
  row.name_snapshot,
  row.variant_label,
  row.unit_price,
  coalesce(row.quantity, 1),
  row.gram_amount
from jsonb_to_recordset((select data->'order_items' from import_payload)) as row(
  id uuid,
  order_id uuid,
  quantity integer,
  unit_price numeric,
  variant_id uuid,
  gram_amount integer,
  name_snapshot text,
  variant_label text
)
join public.orders on orders.id = row.order_id
left join public.product_variants on product_variants.id = row.variant_id
on conflict (id) do update set
  order_id = excluded.order_id,
  variant_id = excluded.variant_id,
  name_snapshot = excluded.name_snapshot,
  variant_label = excluded.variant_label,
  unit_price = excluded.unit_price,
  quantity = excluded.quantity,
  gram_amount = excluded.gram_amount;

insert into public.order_status_history (
  id,
  order_id,
  status,
  changed_by,
  note,
  created_at
)
select
  row.id,
  row.order_id,
  row.status::public.order_status,
  auth_map.new_id,
  row.note,
  coalesce(row.created_at, now())
from jsonb_to_recordset((select data->'order_status_history' from import_payload)) as row(
  id uuid,
  order_id uuid,
  status text,
  changed_by uuid,
  note text,
  created_at timestamptz
)
join public.orders on orders.id = row.order_id
left join auth_map on auth_map.old_id = row.changed_by
on conflict (id) do update set
  order_id = excluded.order_id,
  status = excluded.status,
  changed_by = excluded.changed_by,
  note = excluded.note,
  created_at = excluded.created_at;

insert into public.feedback (
  id,
  order_id,
  user_id,
  rating,
  message,
  status,
  moderated_by,
  moderated_at,
  created_at,
  updated_at
)
select
  row.id,
  row.order_id,
  user_map.new_id,
  row.rating,
  row.message,
  coalesce(row.status, 'pending')::public.feedback_status,
  moderator_map.new_id,
  row.moderated_at,
  coalesce(row.created_at, now()),
  coalesce(row.updated_at, now())
from jsonb_to_recordset((select data->'feedback' from import_payload)) as row(
  id uuid,
  order_id uuid,
  user_id uuid,
  rating integer,
  message text,
  status text,
  moderated_by uuid,
  moderated_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz
)
join public.orders on orders.id = row.order_id
join auth_map user_map on user_map.old_id = row.user_id
left join auth_map moderator_map on moderator_map.old_id = row.moderated_by
on conflict (id) do update set
  order_id = excluded.order_id,
  user_id = excluded.user_id,
  rating = excluded.rating,
  message = excluded.message,
  status = excluded.status,
  moderated_by = excluded.moderated_by,
  moderated_at = excluded.moderated_at,
  created_at = excluded.created_at,
  updated_at = excluded.updated_at;

insert into public.daily_claims (
  id,
  user_id,
  claimed_on,
  streak,
  points_awarded,
  xp_awarded,
  mode
)
select
  row.id,
  auth_map.new_id,
  row.claimed_on,
  row.streak,
  row.points_awarded,
  row.xp_awarded,
  coalesce(row.mode, 'test')::public.order_mode
from jsonb_to_recordset((select data->'daily_claims' from import_payload)) as row(
  id uuid,
  user_id uuid,
  claimed_on date,
  streak integer,
  points_awarded integer,
  xp_awarded integer,
  mode text
)
join auth_map on auth_map.old_id = row.user_id
on conflict (id) do update set
  user_id = excluded.user_id,
  claimed_on = excluded.claimed_on,
  streak = excluded.streak,
  points_awarded = excluded.points_awarded,
  xp_awarded = excluded.xp_awarded,
  mode = excluded.mode;

insert into public.loyalty_ledger (
  id,
  user_id,
  reason,
  points_delta,
  xp_delta,
  reference_type,
  reference_id,
  mode,
  created_at
)
select
  row.id,
  auth_map.new_id,
  row.reason,
  coalesce(row.points_delta, 0),
  coalesce(row.xp_delta, 0),
  row.reference_type,
  row.reference_id,
  coalesce(row.mode, 'test')::public.order_mode,
  coalesce(row.created_at, now())
from jsonb_to_recordset((select data->'loyalty_ledger' from import_payload)) as row(
  id uuid,
  user_id uuid,
  reason text,
  points_delta integer,
  xp_delta integer,
  reference_type text,
  reference_id uuid,
  mode text,
  created_at timestamptz
)
join auth_map on auth_map.old_id = row.user_id
on conflict (id) do update set
  user_id = excluded.user_id,
  reason = excluded.reason,
  points_delta = excluded.points_delta,
  xp_delta = excluded.xp_delta,
  reference_type = excluded.reference_type,
  reference_id = excluded.reference_id,
  mode = excluded.mode,
  created_at = excluded.created_at;

create temp table admin_ids on commit drop as
select trim(value) as telegram_subject
from regexp_split_to_table(:'admin_ids', ',') as value
where trim(value) <> '';

insert into public.staging_allowlist (
  telegram_subject,
  role,
  enabled,
  note,
  access_status,
  access_username,
  access_decided_at
)
select
  telegram_subject,
  'admin'::public.app_role,
  true,
  'admin from TELEGRAM_ADMIN_IDS after Cloud user data import',
  'approved',
  'admin',
  now()
from admin_ids
on conflict (telegram_subject) do update set
  role = 'admin',
  enabled = true,
  access_status = 'approved',
  note = excluded.note,
  access_decided_at = now();

update public.profiles
set role = 'admin',
    blocked = false
where telegram_subject in (select telegram_subject from admin_ids);

do $$
declare
  v_max integer;
begin
  select coalesce(max(display_id::integer), 0)
  into v_max
  from public.orders
  where display_id ~ '^[0-9]+$';

  if to_regclass('public.order_display_seq') is not null then
    perform setval('public.order_display_seq', greatest(v_max, 1), v_max > 0);
  end if;
end $$;

notify pgrst, 'reload schema';

commit;

select 'profiles' as table_name, count(*) from public.profiles
union all select 'approved_allowlist', count(*) from public.staging_allowlist where enabled and access_status = 'approved'
union all select 'orders', count(*) from public.orders
union all select 'order_items', count(*) from public.order_items
union all select 'feedback', count(*) from public.feedback
union all select 'kyc_cases', count(*) from public.kyc_cases
union all select 'kyc_documents', count(*) from public.kyc_documents
union all select 'loyalty_ledger', count(*) from public.loyalty_ledger
union all select 'wallet_balances', count(*) from public.wallet_balances
order by table_name;
SQL

echo "Restarting API containers..."
docker compose restart rest auth functions >/dev/null

echo "Cloud user data import complete."
echo "Backup saved in: $BACKUP_DIR"
