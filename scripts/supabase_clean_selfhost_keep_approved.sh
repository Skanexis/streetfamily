#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELFHOST_SUPABASE_DIR="${SELFHOST_SUPABASE_DIR:-/opt/supabase-project}"
ENV_DEPLOY_FILE="${ENV_DEPLOY_FILE:-$ROOT_DIR/.env.deploy}"
STAMP="$(date -u +"%Y%m%dT%H%M%SZ")"
SAFE_DIR="${SAFE_DIR:-$ROOT_DIR/backups/clean-reset-keep-approved-$STAMP}"
DB_CONTAINER="${SELFHOST_DB_CONTAINER:-supabase-db}"

if [ "${CONFIRM_CLEAN_SELFHOST:-}" != "yes" ]; then
  cat >&2 <<'EOF'
Refusing to clean self-hosted Supabase without confirmation.

This script keeps only approved Telegram IDs, then rebuilds the self-hosted
database from local migrations. It moves old self-hosted db/storage/functions
volumes aside; it does not touch Supabase Cloud.

Run with:
  CONFIRM_CLEAN_SELFHOST=yes ./scripts/supabase_clean_selfhost_keep_approved.sh
EOF
  exit 1
fi

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

need docker
need grep
need sed

if [ ! -d "$SELFHOST_SUPABASE_DIR" ] || [ ! -f "$SELFHOST_SUPABASE_DIR/docker-compose.yml" ]; then
  echo "SELFHOST_SUPABASE_DIR must point to the self-hosted Supabase docker directory." >&2
  echo "Current: $SELFHOST_SUPABASE_DIR" >&2
  exit 1
fi

if [ ! -f "$ENV_DEPLOY_FILE" ]; then
  echo "Missing ENV_DEPLOY_FILE: $ENV_DEPLOY_FILE" >&2
  exit 1
fi

if [ ! -d "$ROOT_DIR/supabase/migrations" ]; then
  echo "Missing migrations directory: $ROOT_DIR/supabase/migrations" >&2
  exit 1
fi

mkdir -p "$SAFE_DIR"
chmod 700 "$SAFE_DIR"
cp "$ENV_DEPLOY_FILE" "$SAFE_DIR/env.deploy.backup"
cp "$SELFHOST_SUPABASE_DIR/.env" "$SAFE_DIR/selfhost.env.backup"
chmod 600 "$SAFE_DIR"/*.backup

echo "Safe backup directory: $SAFE_DIR"

cd "$SELFHOST_SUPABASE_DIR"
docker compose up -d db
until docker exec "$DB_CONTAINER" pg_isready -U postgres >/dev/null 2>&1; do
  sleep 2
done

echo "Saving approved allowlist from current self-hosted database..."
docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
alter table public.staging_allowlist
  add column if not exists access_status text not null default 'approved'
    check (access_status in ('pending', 'approved', 'rejected')),
  add column if not exists access_requested_at timestamptz,
  add column if not exists access_username text,
  add column if not exists access_notified_at timestamptz,
  add column if not exists access_decided_at timestamptz;

update public.staging_allowlist
set access_status = 'approved'
where enabled is true;

update public.staging_allowlist
set access_status = 'rejected'
where enabled is not true;

update public.staging_allowlist
set access_requested_at = coalesce(access_requested_at, created_at, now());

update public.staging_allowlist
set access_decided_at = coalesce(access_decided_at, created_at, now())
where enabled is true;
SQL

docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 --csv -c "
select
  telegram_subject,
  role,
  coalesce(access_username, '') as access_username,
  coalesce(note, '') as note
from public.staging_allowlist
where enabled is true
  and access_status = 'approved'
order by telegram_subject;
" > "$SAFE_DIR/approved_allowlist.csv"

APPROVED_COUNT="$(tail -n +2 "$SAFE_DIR/approved_allowlist.csv" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
echo "Approved IDs saved: $APPROVED_COUNT"

if [ "$APPROVED_COUNT" = "0" ] && [ "${ALLOW_EMPTY_APPROVED:-}" != "yes" ]; then
  cat >&2 <<EOF
No approved Telegram IDs were saved. Refusing to continue.

Check:
  $SAFE_DIR/approved_allowlist.csv

If you really want a fully empty allowlist except TELEGRAM_ADMIN_IDS, rerun with:
  ALLOW_EMPTY_APPROVED=yes CONFIRM_CLEAN_SELFHOST=yes $0
EOF
  exit 1
fi

cat > "$SAFE_DIR/reapply_approved_allowlist.sql" <<'SQL'
begin;

create temp table _approved_allowlist_import (
  telegram_subject text,
  role text,
  access_username text,
  note text
);

copy _approved_allowlist_import(telegram_subject, role, access_username, note)
from stdin with (format csv, header true);
SQL

cat "$SAFE_DIR/approved_allowlist.csv" >> "$SAFE_DIR/reapply_approved_allowlist.sql"

cat >> "$SAFE_DIR/reapply_approved_allowlist.sql" <<'SQL'
\.

insert into public.staging_allowlist (
  telegram_subject,
  role,
  enabled,
  access_status,
  access_requested_at,
  access_decided_at,
  access_username,
  note
)
select
  telegram_subject,
  coalesce(nullif(role, ''), 'user')::public.app_role,
  true,
  'approved',
  now(),
  now(),
  nullif(access_username, ''),
  coalesce(nullif(note, ''), 'kept approved during clean reset')
from _approved_allowlist_import
where telegram_subject is not null and telegram_subject <> ''
on conflict (telegram_subject) do update
set role = excluded.role,
    enabled = true,
    access_status = 'approved',
    access_decided_at = now(),
    access_username = coalesce(public.staging_allowlist.access_username, excluded.access_username),
    note = excluded.note;

insert into public.staging_allowlist (
  telegram_subject,
  role,
  enabled,
  access_status,
  access_requested_at,
  access_decided_at,
  note
)
select
  trim(value),
  'admin',
  true,
  'approved',
  now(),
  now(),
  'TELEGRAM_ADMIN_IDS after clean reset'
from regexp_split_to_table(:'admin_ids', ',') as value
where trim(value) <> ''
on conflict (telegram_subject) do update
set role = 'admin',
    enabled = true,
    access_status = 'approved',
    access_decided_at = now(),
    note = 'TELEGRAM_ADMIN_IDS after clean reset';

notify pgrst, 'reload schema';

commit;
SQL

echo "Moving old self-hosted volumes aside..."
docker compose down

move_aside() {
  local path="$1"
  if [ -e "$path" ]; then
    local target="$path.before-clean-reset-$STAMP"
    if [ -e "$target" ]; then
      echo "Refusing to overwrite existing backup path: $target" >&2
      exit 1
    fi
    sudo mv "$path" "$target"
    echo "Moved $path -> $target"
  fi
}

move_aside "volumes/db/data"
move_aside "volumes/storage"
move_aside "volumes/functions"

echo "Starting clean Supabase stack..."
docker compose up -d
until docker exec "$DB_CONTAINER" pg_isready -U postgres >/dev/null 2>&1; do
  sleep 2
done

echo "Waiting for Supabase internal schemas and Storage tables..."
for _ in $(seq 1 120); do
  if docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -Atc "select to_regclass('auth.users') is not null and to_regclass('storage.buckets') is not null and to_regclass('storage.objects') is not null;" | grep -q '^t$'; then
    break
  fi
  sleep 2
done

if ! docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -Atc "select to_regclass('storage.buckets') is not null;" | grep -q '^t$'; then
  echo "storage.buckets was not created by self-hosted Supabase. Check storage container logs:" >&2
  echo "  cd $SELFHOST_SUPABASE_DIR && docker compose logs --tail=100 storage" >&2
  exit 1
fi

echo "Applying local app migrations..."
cd "$ROOT_DIR"
for file in supabase/migrations/*.sql; do
  echo "Applying $file"
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 < "$file"
done

ADMIN_IDS="$(grep '^TELEGRAM_ADMIN_IDS=' "$ENV_DEPLOY_FILE" | cut -d= -f2- | tr -d ' ' || true)"
echo "Reapplying approved allowlist. TELEGRAM_ADMIN_IDS=$ADMIN_IDS"
docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres \
  -v ON_ERROR_STOP=1 \
  -v admin_ids="$ADMIN_IDS" \
  < "$SAFE_DIR/reapply_approved_allowlist.sql"

echo "Verification:"
docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres <<'SQL'
select count(*) as auth_users from auth.users;
select count(*) as profiles from public.profiles;
select count(*) as orders from public.orders;
select count(*) as approved_ids
from public.staging_allowlist
where enabled is true and access_status = 'approved';

select telegram_subject, role, enabled, access_status
from public.staging_allowlist
order by role desc, telegram_subject
limit 50;
SQL

echo "Clean reset completed."
echo "Approved allowlist backup: $SAFE_DIR/approved_allowlist.csv"
echo "Old volumes were moved aside under: $SELFHOST_SUPABASE_DIR/volumes/*.before-clean-reset-$STAMP"
