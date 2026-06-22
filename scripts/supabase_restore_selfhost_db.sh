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
Set CONFIRM_RESTORE_SELFHOST=yes only when the target is the NEW self-hosted Supabase database.
EOF
  exit 1
fi

SELFHOST_DB_CONTAINER="${SELFHOST_DB_CONTAINER:-supabase-db}"

for file in roles.sql schema.sql data.sql; do
  if [ ! -f "$BACKUP_DIR/$file" ]; then
    echo "Missing backup file: $BACKUP_DIR/$file" >&2
    exit 1
  fi
done

command -v docker >/dev/null 2>&1 || {
  echo "Missing required command: docker" >&2
  exit 1
}

FILTERED_DATA="$BACKUP_DIR/data.no-storage-vectors.sql"
echo "Filtering Supabase Storage vector table COPY blocks..."
awk '
  /^COPY / && ($0 ~ /buckets_vectors/ || $0 ~ /vector_indexes/) { skip=1; next }
  skip && $0 == "\\." { skip=0; next }
  !skip { print }
' "$BACKUP_DIR/data.sql" > "$FILTERED_DATA"

if grep -nE '^COPY .*buckets_vectors|^COPY .*vector_indexes' "$FILTERED_DATA"; then
  echo "Filtered data still contains Storage vector COPY blocks. Refusing to restore." >&2
  exit 1
fi

echo "Restoring database through Docker container: $SELFHOST_DB_CONTAINER"
{
  cat "$BACKUP_DIR/roles.sql"
  cat "$BACKUP_DIR/schema.sql"
  echo 'SET session_replication_role = replica;'
  cat "$FILTERED_DATA"
} | docker exec -i "$SELFHOST_DB_CONTAINER" psql \
  -U postgres \
  -d postgres \
  --single-transaction \
  --variable ON_ERROR_STOP=1

echo "Writing row-count snapshot after restore..."
docker exec -i "$SELFHOST_DB_CONTAINER" psql \
  -U postgres \
  -d postgres \
  --variable ON_ERROR_STOP=1 \
  < "$ROOT_DIR/scripts/supabase_row_counts.sql" > "$BACKUP_DIR/row-counts-after.tsv"

echo "Restore completed. Compare:"
echo "  $BACKUP_DIR/row-counts-before.tsv"
echo "  $BACKUP_DIR/row-counts-after.tsv"
