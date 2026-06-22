#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${1:-${BACKUP_DIR:-}}"

if [ -z "$BACKUP_DIR" ]; then
  echo "Usage: SELFHOST_DB_URL='postgres://...' CONFIRM_RESTORE_SELFHOST=yes $0 /path/to/backup" >&2
  exit 1
fi

if [ "${CONFIRM_RESTORE_SELFHOST:-}" != "yes" ]; then
  cat >&2 <<'EOF'
Refusing to restore without confirmation.
Set CONFIRM_RESTORE_SELFHOST=yes only when SELFHOST_DB_URL points to the NEW self-hosted Supabase database.
EOF
  exit 1
fi

if [ -z "${SELFHOST_DB_URL:-}" ]; then
  echo "Set SELFHOST_DB_URL to the new self-hosted Supabase Postgres connection string." >&2
  exit 1
fi

for file in roles.sql schema.sql data.sql; do
  if [ ! -f "$BACKUP_DIR/$file" ]; then
    echo "Missing backup file: $BACKUP_DIR/$file" >&2
    exit 1
  fi
done

command -v psql >/dev/null 2>&1 || {
  echo "Missing required command: psql" >&2
  exit 1
}

echo "Restoring database into SELFHOST_DB_URL..."
psql \
  --single-transaction \
  --variable ON_ERROR_STOP=1 \
  --file "$BACKUP_DIR/roles.sql" \
  --file "$BACKUP_DIR/schema.sql" \
  --command 'SET session_replication_role = replica' \
  --file "$BACKUP_DIR/data.sql" \
  --dbname "$SELFHOST_DB_URL"

echo "Writing row-count snapshot after restore..."
psql "$SELFHOST_DB_URL" -v ON_ERROR_STOP=1 -f "$ROOT_DIR/scripts/supabase_row_counts.sql" > "$BACKUP_DIR/row-counts-after.tsv"

echo "Restore completed. Compare:"
echo "  $BACKUP_DIR/row-counts-before.tsv"
echo "  $BACKUP_DIR/row-counts-after.tsv"
