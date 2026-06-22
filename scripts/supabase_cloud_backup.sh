#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$(date -u +"%Y%m%dT%H%M%SZ")"
BACKUP_ROOT="${BACKUP_ROOT:-$ROOT_DIR/backups}"
BACKUP_DIR="${BACKUP_DIR:-$BACKUP_ROOT/supabase-cloud-$STAMP}"
BUCKETS="${BUCKETS:-product-media kyc-documents}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

need node
need npx
need docker
need grep
need sed
need tar

if [ -z "${SUPABASE_DB_URL:-}" ]; then
  cat >&2 <<'EOF'
Set SUPABASE_DB_URL first.
Example:
  export SUPABASE_DB_URL='postgresql://postgres.<project-ref>:<password>@aws-...pooler.supabase.com:5432/postgres'
Copy it from Supabase Dashboard -> Connect.
EOF
  exit 1
fi

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

echo "Backup directory: $BACKUP_DIR"
echo "Dumping database roles..."
npx supabase@latest db dump --db-url "$SUPABASE_DB_URL" -f "$BACKUP_DIR/roles.sql" --role-only

echo "Dumping database schema..."
npx supabase@latest db dump --db-url "$SUPABASE_DB_URL" -f "$BACKUP_DIR/schema.sql"

echo "Dumping database data..."
npx supabase@latest db dump --db-url "$SUPABASE_DB_URL" -f "$BACKUP_DIR/data.sql" --use-copy --data-only

echo "Saving local migration/function sources..."
tar -C "$ROOT_DIR" -czf "$BACKUP_DIR/repo-supabase-sources.tar.gz" supabase

if [ -f "$ROOT_DIR/.env.deploy" ]; then
  cp "$ROOT_DIR/.env.deploy" "$BACKUP_DIR/env.deploy.backup"
  chmod 600 "$BACKUP_DIR/env.deploy.backup"
fi

if command -v psql >/dev/null 2>&1; then
  echo "Saving row-count snapshot..."
  psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f "$ROOT_DIR/scripts/supabase_row_counts.sql" > "$BACKUP_DIR/row-counts-before.tsv"

  echo "Saving bucket snapshot..."
  psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -Atc "select id, name, public from storage.buckets order by id;" > "$BACKUP_DIR/buckets-before.tsv" || true
else
  echo "psql is not installed; skipped row-count and bucket snapshots."
fi

if command -v rclone >/dev/null 2>&1 &&
   [ -n "${PLATFORM_S3_ENDPOINT:-}" ] &&
   [ -n "${PLATFORM_S3_REGION:-}" ] &&
   [ -n "${PLATFORM_S3_ACCESS_KEY_ID:-}" ] &&
   [ -n "${PLATFORM_S3_SECRET_ACCESS_KEY:-}" ]; then
  RCLONE_CONFIG_FILE="$BACKUP_DIR/rclone-platform.conf"
  cat > "$RCLONE_CONFIG_FILE" <<EOF
[platform]
type = s3
provider = Other
access_key_id = ${PLATFORM_S3_ACCESS_KEY_ID}
secret_access_key = ${PLATFORM_S3_SECRET_ACCESS_KEY}
endpoint = ${PLATFORM_S3_ENDPOINT}
region = ${PLATFORM_S3_REGION}
acl = private
EOF
  chmod 600 "$RCLONE_CONFIG_FILE"
  mkdir -p "$BACKUP_DIR/storage"
  for bucket in $BUCKETS; do
    echo "Downloading Storage bucket: $bucket"
    RCLONE_CONFIG="$RCLONE_CONFIG_FILE" rclone copy "platform:$bucket" "$BACKUP_DIR/storage/$bucket" --progress
  done
else
  cat > "$BACKUP_DIR/STORAGE_NOT_DOWNLOADED.txt" <<'EOF'
Storage files were not downloaded.

To include Storage in the emergency backup, install rclone and export:
  PLATFORM_S3_ENDPOINT
  PLATFORM_S3_REGION
  PLATFORM_S3_ACCESS_KEY_ID
  PLATFORM_S3_SECRET_ACCESS_KEY

Then rerun scripts/supabase_cloud_backup.sh.
EOF
  echo "Storage download skipped: rclone or PLATFORM_S3_* variables are missing."
fi

if ! grep -Eq 'COPY (auth\.users|"auth"\."users")' "$BACKUP_DIR/data.sql"; then
  cat >&2 <<EOF
WARNING: data.sql does not appear to contain auth.users.
Do not delete the old Supabase project until this is resolved.
Backup path: $BACKUP_DIR
EOF
fi

if command -v sha256sum >/dev/null 2>&1; then
  (cd "$BACKUP_DIR" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
fi

echo "Backup completed: $BACKUP_DIR"
