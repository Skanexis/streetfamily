#!/usr/bin/env bash
set -Eeuo pipefail

BUCKETS="${BUCKETS:-product-media kyc-documents}"

command -v rclone >/dev/null 2>&1 || {
  echo "Missing required command: rclone" >&2
  exit 1
}

for name in SELFHOST_S3_ENDPOINT SELFHOST_S3_REGION SELFHOST_S3_ACCESS_KEY_ID SELFHOST_S3_SECRET_ACCESS_KEY; do
  if [ -z "${!name:-}" ]; then
    echo "Set $name first." >&2
    exit 1
  fi
done

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
RCLONE_CONFIG_FILE="$TMP_DIR/rclone.conf"

cat > "$RCLONE_CONFIG_FILE" <<EOF
[selfhost]
type = s3
provider = Other
access_key_id = ${SELFHOST_S3_ACCESS_KEY_ID}
secret_access_key = ${SELFHOST_S3_SECRET_ACCESS_KEY}
endpoint = ${SELFHOST_S3_ENDPOINT}
region = ${SELFHOST_S3_REGION}
acl = private
EOF

if [ -n "${SOURCE_STORAGE_DIR:-}" ]; then
  for bucket in $BUCKETS; do
    echo "Uploading local Storage backup bucket: $bucket"
    RCLONE_CONFIG="$RCLONE_CONFIG_FILE" rclone copy "$SOURCE_STORAGE_DIR/$bucket" "selfhost:$bucket" --progress
  done
else
  for name in PLATFORM_S3_ENDPOINT PLATFORM_S3_REGION PLATFORM_S3_ACCESS_KEY_ID PLATFORM_S3_SECRET_ACCESS_KEY; do
    if [ -z "${!name:-}" ]; then
      echo "Set $name first, or set SOURCE_STORAGE_DIR to upload from a local backup." >&2
      exit 1
    fi
  done

  cat >> "$RCLONE_CONFIG_FILE" <<EOF

[platform]
type = s3
provider = Other
access_key_id = ${PLATFORM_S3_ACCESS_KEY_ID}
secret_access_key = ${PLATFORM_S3_SECRET_ACCESS_KEY}
endpoint = ${PLATFORM_S3_ENDPOINT}
region = ${PLATFORM_S3_REGION}
acl = private
EOF

  for bucket in $BUCKETS; do
    echo "Copying Storage bucket platform:$bucket -> selfhost:$bucket"
    RCLONE_CONFIG="$RCLONE_CONFIG_FILE" rclone copy "platform:$bucket" "selfhost:$bucket" --progress
  done
fi

echo "Storage copy completed."
