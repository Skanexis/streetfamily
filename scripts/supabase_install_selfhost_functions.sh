#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELFHOST_SUPABASE_DIR="${SELFHOST_SUPABASE_DIR:-}"
ENV_DEPLOY_FILE="${ENV_DEPLOY_FILE:-$ROOT_DIR/.env.deploy}"

if [ -z "$SELFHOST_SUPABASE_DIR" ]; then
  echo "Set SELFHOST_SUPABASE_DIR, for example: /opt/supabase-project" >&2
  exit 1
fi

if [ ! -d "$SELFHOST_SUPABASE_DIR" ] || [ ! -f "$SELFHOST_SUPABASE_DIR/docker-compose.yml" ]; then
  echo "SELFHOST_SUPABASE_DIR must point to the self-hosted Supabase docker directory." >&2
  exit 1
fi

if [ ! -f "$ENV_DEPLOY_FILE" ]; then
  echo "Missing ENV_DEPLOY_FILE: $ENV_DEPLOY_FILE" >&2
  exit 1
fi

command -v rsync >/dev/null 2>&1 || {
  echo "Missing required command: rsync" >&2
  exit 1
}

ENV_FUNCTIONS="$SELFHOST_SUPABASE_DIR/.env.functions"
OVERRIDE_FILE="$SELFHOST_SUPABASE_DIR/docker-compose.functions-env.yml"

echo "Writing self-hosted Edge Functions env file..."
grep -E '^(TELEGRAM_|KYC_PURGE_SECRET=|ESTRAZIONE_)' "$ENV_DEPLOY_FILE" > "$ENV_FUNCTIONS"
chmod 600 "$ENV_FUNCTIONS"

cat > "$OVERRIDE_FILE" <<'EOF'
services:
  functions:
    env_file:
      - .env.functions
EOF

if ! grep -q 'docker-compose.functions-env.yml' "$SELFHOST_SUPABASE_DIR/.env"; then
  if grep -q '^COMPOSE_FILE=' "$SELFHOST_SUPABASE_DIR/.env"; then
    sed -i 's#^COMPOSE_FILE=.*#&:docker-compose.functions-env.yml#' "$SELFHOST_SUPABASE_DIR/.env"
  else
    printf '\nCOMPOSE_FILE=docker-compose.yml:docker-compose.functions-env.yml\n' >> "$SELFHOST_SUPABASE_DIR/.env"
  fi
fi

echo "Copying Edge Functions source..."
mkdir -p "$SELFHOST_SUPABASE_DIR/volumes/functions"
rsync -a \
  --exclude '.env*' \
  "$ROOT_DIR/supabase/functions/" \
  "$SELFHOST_SUPABASE_DIR/volumes/functions/"

if [ ! -d "$SELFHOST_SUPABASE_DIR/volumes/functions/main" ]; then
  mkdir -p "$SELFHOST_SUPABASE_DIR/volumes/functions/main"
fi

if [ ! -f "$SELFHOST_SUPABASE_DIR/volumes/functions/main/index.ts" ]; then
  cat > "$SELFHOST_SUPABASE_DIR/volumes/functions/main/index.ts" <<'EOF'
console.log('main function started')

Deno.serve(async (req: Request) => {
  const url = new URL(req.url)
  const parts = url.pathname.split('/').filter(Boolean)
  const serviceName = parts[0] === 'functions' && parts[1] === 'v1' ? parts[2] : parts[0]

  if (!serviceName) {
    return new Response(JSON.stringify({ error: 'missing function name in request' }), {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
    })
  }

  if (serviceName === 'main' || serviceName.startsWith('_')) {
    return new Response(JSON.stringify({ error: 'function not found' }), {
      status: 404,
      headers: { 'Content-Type': 'application/json' },
    })
  }

  const servicePath = `/home/deno/functions/${serviceName}`
  const env = Deno.env.toObject()
  const envVars = Object.keys(env).map((key) => [key, env[key]])

  try {
    const worker = await EdgeRuntime.userWorkers.create({
      servicePath,
      memoryLimitMb: 150,
      workerTimeoutMs: 60 * 1000,
      noModuleCache: false,
      importMapPath: null,
      envVars,
    })
    return await worker.fetch(req)
  } catch (caught) {
    console.error(caught)
    return new Response(JSON.stringify({ error: String(caught) }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' },
    })
  }
})
EOF
  echo "Created self-hosted Edge Functions main entrypoint."
fi

echo "Recreating functions container..."
(cd "$SELFHOST_SUPABASE_DIR" && docker compose up -d --force-recreate --no-deps functions)

echo "Functions installed into: $SELFHOST_SUPABASE_DIR/volumes/functions"
