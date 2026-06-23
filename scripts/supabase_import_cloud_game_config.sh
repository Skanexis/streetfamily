#!/usr/bin/env bash
set -euo pipefail

IMPORT_JSON="${1:-/opt/apps/streetfamily/import/cloud_game_config.json}"
SELFHOST_SUPABASE_DIR="${SELFHOST_SUPABASE_DIR:-/opt/supabase-project}"
BACKUP_DIR="${BACKUP_DIR:-/opt/apps/streetfamily/backups/cloud-game-config-import-$(date -u +%Y%m%dT%H%M%SZ)}"

if [[ "${CONFIRM_IMPORT_CLOUD_GAME_CONFIG:-}" != "yes" ]]; then
  cat >&2 <<EOF
Refusing to import without confirmation.

This imports mini-game admin configuration from Supabase Cloud:
  - reward_definitions
  - game_configs
  - game_reward_options

Run:
  CONFIRM_IMPORT_CLOUD_GAME_CONFIG=yes $0 "$IMPORT_JSON"
EOF
  exit 1
fi

if [[ ! -f "$IMPORT_JSON" ]]; then
  echo "Import JSON not found: $IMPORT_JSON" >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"
NORMALIZED_JSON="$BACKUP_DIR/cloud_game_config_inner.json"

echo "Normalizing Cloud game config JSON..."
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

required = ["reward_definitions", "game_configs", "game_reward_options"]
missing = [key for key in required if key not in data]
if missing:
    raise SystemExit(f"Missing keys in JSON: {', '.join(missing)}")

dst.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
for key in required:
    print(f"{key}: {len(data.get(key, []))}")
PY

cd "$SELFHOST_SUPABASE_DIR"
docker compose up -d db rest >/dev/null

echo "Waiting for self-host database..."
for _ in $(seq 1 60); do
  if docker exec supabase-db pg_isready -U postgres -d postgres >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
docker exec supabase-db pg_isready -U postgres -d postgres >/dev/null

echo "Saving current self-host mini-game config backup..."
docker exec supabase-db pg_dump -U postgres -d postgres \
  --data-only --no-owner --no-privileges \
  -t public.reward_definitions \
  -t public.game_configs \
  -t public.game_reward_options \
  > "$BACKUP_DIR/selfhost-game-config-before.sql"

docker cp "$NORMALIZED_JSON" supabase-db:/tmp/cloud_game_config_inner.json

echo "Importing mini-game config into Postgres..."
docker exec -i supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
begin;

create temp table import_payload(data jsonb) on commit drop;
\copy import_payload(data) from '/tmp/cloud_game_config_inner.json'

create temp table incoming_reward_definitions on commit drop as
select *
from jsonb_to_recordset((select data->'reward_definitions' from import_payload)) as row(
  id uuid,
  code text,
  label text,
  kind text,
  value numeric,
  active boolean
);

insert into public.reward_definitions (
  id,
  code,
  label,
  kind,
  value,
  active
)
select
  id,
  code,
  label,
  kind::public.reward_kind,
  value,
  coalesce(active, true)
from incoming_reward_definitions
where code is not null
on conflict (code) do update set
  label = excluded.label,
  kind = excluded.kind,
  value = excluded.value,
  active = excluded.active;

create temp table reward_map on commit drop as
select incoming.id as old_id, target.id as new_id
from incoming_reward_definitions incoming
join public.reward_definitions target on target.code = incoming.code;

create temp table incoming_game_configs on commit drop as
select *
from jsonb_to_recordset((select data->'game_configs' from import_payload)) as row(
  game_type text,
  title text,
  cost integer,
  active boolean,
  xp_on_points_win integer
);

update public.game_configs
set active = false
where game_type in (
  select game_type::public.game_type
  from incoming_game_configs
  where game_type is not null
);

insert into public.game_configs (
  game_type,
  title,
  cost,
  active,
  xp_on_points_win
)
select
  game_type::public.game_type,
  title,
  coalesce(cost, 0),
  false,
  coalesce(xp_on_points_win, 0)
from incoming_game_configs
where game_type is not null
on conflict (game_type) do update set
  title = excluded.title,
  cost = excluded.cost,
  active = false,
  xp_on_points_win = excluded.xp_on_points_win;

create temp table incoming_game_reward_options on commit drop as
select *
from jsonb_to_recordset((select data->'game_reward_options' from import_payload)) as row(
  id uuid,
  game_type text,
  code text,
  label text,
  points_awarded integer,
  xp_awarded integer,
  reward_definition_id uuid,
  weight integer,
  color text,
  active boolean
);

delete from public.game_reward_options option_row
where option_row.game_type in (
  select distinct game_type::public.game_type
  from incoming_game_reward_options
  where game_type is not null
)
and not exists (
  select 1
  from incoming_game_reward_options incoming
  where incoming.game_type::public.game_type = option_row.game_type
    and incoming.code = option_row.code
)
and not exists (
  select 1
  from public.game_plays play
  where play.reward_option_id = option_row.id
);

update public.game_reward_options option_row
set active = false
where option_row.game_type in (
  select distinct game_type::public.game_type
  from incoming_game_reward_options
  where game_type is not null
)
and not exists (
  select 1
  from incoming_game_reward_options incoming
  where incoming.game_type::public.game_type = option_row.game_type
    and incoming.code = option_row.code
);

insert into public.game_reward_options (
  id,
  game_type,
  code,
  label,
  points_awarded,
  xp_awarded,
  reward_definition_id,
  weight,
  color,
  active
)
select
  incoming.id,
  incoming.game_type::public.game_type,
  incoming.code,
  incoming.label,
  coalesce(incoming.points_awarded, 0),
  coalesce(incoming.xp_awarded, 0),
  reward_map.new_id,
  coalesce(incoming.weight, 1),
  coalesce(incoming.color, '#A3FF12'),
  coalesce(incoming.active, true)
from incoming_game_reward_options incoming
left join reward_map on reward_map.old_id = incoming.reward_definition_id
where incoming.game_type is not null
  and incoming.code is not null
on conflict (game_type, code) do update set
  label = excluded.label,
  points_awarded = excluded.points_awarded,
  xp_awarded = excluded.xp_awarded,
  reward_definition_id = excluded.reward_definition_id,
  weight = excluded.weight,
  color = excluded.color,
  active = excluded.active;

delete from public.reward_definitions definition
where not exists (
  select 1
  from incoming_reward_definitions incoming
  where incoming.code = definition.code
)
and not exists (
  select 1
  from public.game_reward_options option_row
  where option_row.reward_definition_id = definition.id
)
and not exists (
  select 1
  from public.user_rewards user_reward
  where user_reward.reward_definition_id = definition.id
);

update public.game_configs target
set active = coalesce(incoming.active, true)
from incoming_game_configs incoming
where target.game_type = incoming.game_type::public.game_type
  and incoming.game_type is not null;

notify pgrst, 'reload schema';

commit;

select 'reward_definitions' as table_name, count(*) from public.reward_definitions
union all select 'game_configs', count(*) from public.game_configs
union all select 'game_reward_options', count(*) from public.game_reward_options
union all select 'active_game_reward_options', count(*) from public.game_reward_options where active
order by table_name;
SQL

echo "Restarting API containers..."
docker compose restart rest functions >/dev/null

echo "Cloud mini-game config import complete."
echo "Backup saved in: $BACKUP_DIR"
