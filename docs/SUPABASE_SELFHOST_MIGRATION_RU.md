# Миграция Supabase Cloud -> self-hosted Supabase

Цель: сначала сохранить все данные из Supabase Cloud, затем поднять self-hosted Supabase на VPS, восстановить туда базу, Storage и Edge Functions, и только после проверки переключить сайт.

Не удаляйте старый Supabase-проект, пока новый self-hosted не прошел проверки ниже.

## Что переносится

- База Postgres: `public`, `auth.users`, RLS, RPC, триггеры, роли и данные.
- Storage buckets: `product-media` и `kyc-documents`.
- Edge Functions из `supabase/functions`.
- Secrets для Telegram/KYC из `.env.deploy`.

Что не переносится автоматически:

- Старые JWT-сессии пользователей. После переключения пользователи должны войти заново через Telegram.
- Dashboard-настройки self-hosted Supabase. Они задаются в `.env` self-hosted проекта.
- Telegram webhook. Его нужно переставить на новый URL Functions.

## 0. Срочно снизить риск

Пока старый проект еще живой:

1. Не удаляйте Supabase Cloud project.
2. Не заливайте новые фото/видео в каталог.
3. Если есть тяжелые видео в `product-media`, временно снимите их с публикации в админке.
4. Делайте бэкап с машины, где есть Docker. Supabase CLI запускает `pg_dump` через Docker.

## 1. Аварийный бэкап Supabase Cloud

На VPS или локальной Linux-машине установите нужные инструменты:

```bash
sudo apt update
sudo apt install -y curl ca-certificates nodejs npm docker.io postgresql-client rclone
sudo systemctl enable --now docker
```

Скопируйте проект на машину, где будет лежать бэкап:

```bash
cd /opt/apps/streetfamily
git pull origin main
chmod +x scripts/*.sh
```

В Supabase Dashboard откройте `Connect` и скопируйте настоящий connection string. На VPS лучше использовать `Session pooler`: прямой `db.PROJECT_REF.supabase.co` часто доступен только по IPv6, и тогда `psql` падает с `Network is unreachable`. Не оставляйте `...`, `PROJECT_REF`, `DB_PASSWORD` или `HOST` из примера.

Если в пароле есть `@`, `#`, `/`, `:` или пробелы, пароль должен быть URL-encoded. Быстро закодировать пароль можно так:

```bash
node -e 'console.log(encodeURIComponent(process.argv[1]))' 'PASTE_DB_PASSWORD_HERE'
```

Безопаснее не вставлять пароль прямо в команду, а ввести скрыто:

```bash
read -s -p "Database password: " DB_PASS_RAW; echo
DB_PASS_ENCODED="$(node -e 'console.log(encodeURIComponent(process.argv[1]))' "$DB_PASS_RAW")"
export SUPABASE_DB_URL='postgresql://postgres.PROJECT_REF:'"$DB_PASS_ENCODED"'@REAL_POOLER_HOST:5432/postgres?sslmode=require'
```

Пример формы, не копируйте его дословно:

```bash
export SUPABASE_DB_URL='postgresql://postgres.abcdefghijklmnopqrst:encoded_password@aws-0-eu-central-1.pooler.supabase.com:5432/postgres?sslmode=require'
```

Для Storage откройте `Storage -> S3 Configuration -> Access keys`, создайте access key и выставьте:

```bash
export PLATFORM_S3_ENDPOINT='https://PROJECT_REF.storage.supabase.co/storage/v1/s3'
export PLATFORM_S3_REGION='YOUR_REGION'
export PLATFORM_S3_ACCESS_KEY_ID='YOUR_ACCESS_KEY_ID'
export PLATFORM_S3_SECRET_ACCESS_KEY='YOUR_SECRET_ACCESS_KEY'
```

Запустите бэкап:

```bash
./scripts/supabase_cloud_backup.sh
```

После завершения в `backups/supabase-cloud-...` должны быть:

- `roles.sql`
- `schema.sql`
- `data.sql`
- `row-counts-before.tsv`
- `buckets-before.tsv`
- `storage/product-media/`
- `storage/kyc-documents/`
- `env.deploy.backup`

Если скрипт написал предупреждение, что `auth.users` не найден в `data.sql`, остановитесь: старый проект нельзя удалять, пока не будет нормального дампа Auth.

## 2. Поднять self-hosted Supabase на VPS

Рекомендуется отдельный поддомен, например:

```text
supa.streetfamily.net
```

На VPS:

```bash
cd /opt
curl -fsSL https://supabase.link/setup.sh | sh
cd supabase-project
```

В `.env` self-hosted проекта проверьте минимум:

```dotenv
SUPABASE_PUBLIC_URL=https://supa.streetfamily.net
API_EXTERNAL_URL=https://supa.streetfamily.net
SITE_URL=https://streetfamily.net
ADDITIONAL_REDIRECT_URLS=https://streetfamily.net
FUNCTIONS_VERIFY_JWT=false
```

Для этого проекта `FUNCTIONS_VERIFY_JWT=false` нужен потому, что Telegram webhook и Telegram login endpoints публичные. Защищенные функции дополнительно проверяют пользователя внутри кода через Supabase Auth.

Запуск:

```bash
sh run.sh start
sh run.sh secrets
docker compose ps
```

Подключите `supa.streetfamily.net` через Nginx к Kong self-hosted Supabase, обычно к `http://127.0.0.1:8000`. В проекте есть шаблон `deploy/nginx-supabase-vps.conf.example`.

```bash
sudo cp /opt/apps/streetfamily/deploy/nginx-supabase-vps.conf.example /etc/nginx/sites-available/supabase-selfhost.conf
sudo nano /etc/nginx/sites-available/supabase-selfhost.conf
sudo ln -s /etc/nginx/sites-available/supabase-selfhost.conf /etc/nginx/sites-enabled/supabase-selfhost.conf
sudo nginx -t
sudo systemctl reload nginx
sudo certbot --nginx -d supa.streetfamily.net
```

`SUPABASE_PUBLIC_URL` и `API_EXTERNAL_URL` должны совпадать с публичным HTTPS-адресом.

## 3. Восстановить базу в self-hosted

Возьмите путь к бэкапу:

```bash
export BACKUP_DIR='/opt/apps/streetfamily/backups/supabase-cloud-YYYYMMDDTHHMMSSZ'
```

Для restore используйте прямой доступ к контейнеру `supabase-db`. Не восстанавливайте через pooler/внешний порт: на внутренних storage-таблицах может быть `permission denied`, например для `buckets_vectors`.

```bash
export SELFHOST_DB_CONTAINER=supabase-db
```

Восстановление запускается только с явным подтверждением:

```bash
CONFIRM_RESTORE_SELFHOST=yes ./scripts/supabase_restore_selfhost_db.sh "$BACKUP_DIR"
```

Сравните счетчики:

```bash
diff -u "$BACKUP_DIR/row-counts-before.tsv" "$BACKUP_DIR/row-counts-after.tsv" || true
```

Небольшая разница в системных таблицах допустима, но `auth.users`, `public.profiles`, `orders`, `product_media`, `kyc_documents` должны совпадать.

## 4. Перенести Storage

Если старый Supabase Cloud еще доступен, копируйте напрямую S3 -> S3:

```bash
export PLATFORM_S3_ENDPOINT='https://PROJECT_REF.storage.supabase.co/storage/v1/s3'
export PLATFORM_S3_REGION='YOUR_REGION'
export PLATFORM_S3_ACCESS_KEY_ID='YOUR_ACCESS_KEY_ID'
export PLATFORM_S3_SECRET_ACCESS_KEY='YOUR_SECRET_ACCESS_KEY'

export SELFHOST_S3_ENDPOINT='https://supa.streetfamily.net/storage/v1/s3'
export SELFHOST_S3_REGION='stub'
export SELFHOST_S3_ACCESS_KEY_ID='S3_PROTOCOL_ACCESS_KEY_ID_FROM_SELFHOST_ENV'
export SELFHOST_S3_SECRET_ACCESS_KEY='S3_PROTOCOL_ACCESS_KEY_SECRET_FROM_SELFHOST_ENV'

./scripts/supabase_copy_storage_to_selfhost.sh
```

Если старый Supabase уже ограничен, но локальный Storage backup есть:

```bash
export SOURCE_STORAGE_DIR="$BACKUP_DIR/storage"
export SELFHOST_S3_ENDPOINT='https://supa.streetfamily.net/storage/v1/s3'
export SELFHOST_S3_REGION='stub'
export SELFHOST_S3_ACCESS_KEY_ID='S3_PROTOCOL_ACCESS_KEY_ID_FROM_SELFHOST_ENV'
export SELFHOST_S3_SECRET_ACCESS_KEY='S3_PROTOCOL_ACCESS_KEY_SECRET_FROM_SELFHOST_ENV'

./scripts/supabase_copy_storage_to_selfhost.sh
```

Не копируйте файлы вручную в `volumes/storage`: self-hosted Storage должен получить объекты через S3/API, чтобы метаданные были корректными.

## 5. Установить Edge Functions и secrets

На VPS, где лежит этот проект и self-hosted Supabase:

```bash
export SELFHOST_SUPABASE_DIR=/opt/supabase-project
export ENV_DEPLOY_FILE=/opt/apps/streetfamily/.env.deploy
./scripts/supabase_install_selfhost_functions.sh
```

Скрипт:

- создаст `/opt/supabase-project/.env.functions` из Telegram/KYC значений;
- добавит compose override для `functions.env_file`;
- скопирует `supabase/functions/*` в `/opt/supabase-project/volumes/functions`;
- пересоздаст контейнер `functions`.

Проверка логов:

```bash
cd /opt/supabase-project
docker compose logs --tail=100 functions
```

## 6. Переключить frontend

В `/opt/supabase-project/.env` возьмите:

- `SUPABASE_PUBLIC_URL`
- `SUPABASE_PUBLISHABLE_KEY`

Если `SUPABASE_PUBLISHABLE_KEY` пустой, используйте legacy `ANON_KEY` как frontend key.

В `/opt/apps/streetfamily/.env.deploy` замените:

```dotenv
VITE_SUPABASE_URL=https://supa.streetfamily.net
VITE_SUPABASE_PUBLISHABLE_KEY=SELFHOST_PUBLISHABLE_OR_ANON_KEY
```

Пересоберите frontend:

```bash
cd /opt/apps/streetfamily
sudo docker compose --env-file .env.deploy -p street-family up -d --build
curl http://127.0.0.1:18087/healthz
```

## 7. Переключить Telegram webhook

После проверки функций:

```bash
source /opt/apps/streetfamily/.env.deploy
curl "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setWebhook?url=https://supa.streetfamily.net/functions/v1/telegram-bot-webhook&secret_token=${TELEGRAM_WEBHOOK_SECRET}"
curl "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getWebhookInfo"
```

## 8. Проверки перед отключением старого Supabase

Проверьте:

1. Сайт открывается.
2. `/start` в Telegram возвращает кнопку Mini App.
3. Вход через Telegram создает сессию.
4. Админ видит админку.
5. Каталог загружает картинки через signed URL.
6. KYC capture отправляется и виден админу.
7. Тестовый заказ создает запись и уведомление в Telegram.

Только после этого старый Supabase Cloud можно считать неактивным.

## Источники

- Supabase Restore Platform Project to Self-Hosted: <https://supabase.com/docs/guides/self-hosting/restore-from-platform>
- Supabase Self-Hosting with Docker: <https://supabase.com/docs/guides/self-hosting/docker>
- Supabase Self-Hosted Functions: <https://supabase.com/docs/guides/self-hosting/self-hosted-functions>
- Supabase Copy Storage Objects from Platform: <https://supabase.com/docs/guides/self-hosting/copy-from-platform-s3>
