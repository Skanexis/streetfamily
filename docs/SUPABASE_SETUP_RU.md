# Настройка Supabase и Telegram с нуля

В проекте используется один реальный файл настроек: `.env.deploy` в корне проекта.

```text
.env.deploy
|- VITE_SUPABASE_*        -> Vite/frontend и Docker build
|- STREET_FAMILY_PORT     -> Docker на VPS
|- TELEGRAM_*             -> Supabase Edge Functions
`- KYC_PURGE_SECRET       -> защищенная очистка KYC
```

Файл `.env.deploy` уже исключен из Git. Не публикуйте его в репозиторий.

Не вставляйте реальные `TELEGRAM_BOT_TOKEN`, `TELEGRAM_WEBHOOK_SECRET`,
`KYC_PURGE_SECRET` или Supabase access token в этот Markdown-файл, README,
чат или скриншоты. Если token бота уже был показан, откройте `@BotFather`,
выполните `/revoke` для бота и используйте новый token только в `.env.deploy`.

## 1. Создать проект Supabase

1. Откройте <https://database.new> и создайте проект.
2. В Supabase Dashboard откройте `Project Settings -> API`.
3. Скопируйте:
   - `Project URL`, например `https://abcdefgh.supabase.co`;
   - `Publishable key`, начинающийся с `sb_publishable_`.
4. Запишите `Project Ref`: это часть URL перед `.supabase.co`, в примере `abcdefgh`.

## 2. Заполнить один `.env.deploy`

В PowerShell в папке проекта:

```powershell
Copy-Item .env.deploy.example .env.deploy
notepad .env.deploy
```

Заполните файл:

```dotenv
VITE_SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co
VITE_SUPABASE_PUBLISHABLE_KEY=sb_publishable_REPLACE_ME
STREET_FAMILY_PORT=18087

TELEGRAM_BOT_TOKEN=123456:replace_with_bot_token
TELEGRAM_BOT_USERNAME=replace_with_bot_username_without_at
TELEGRAM_WEBHOOK_SECRET=replace_with_long_random_secret
TELEGRAM_ADMIN_IDS=123456789,987654321
TELEGRAM_MINI_APP_URL=https://street.example.com
TELEGRAM_INIT_DATA_MAX_AGE_SECONDS=600
KYC_PURGE_SECRET=replace_with_long_random_secret
```

`VITE_SUPABASE_URL` и `VITE_SUPABASE_PUBLISHABLE_KEY` являются публичными настройками frontend. Все значения `TELEGRAM_*` и `KYC_PURGE_SECRET` не должны попадать в браузер или Git.

Сгенерировать два секрета в PowerShell:

```powershell
[guid]::NewGuid().ToString("N") + [guid]::NewGuid().ToString("N")
[guid]::NewGuid().ToString("N") + [guid]::NewGuid().ToString("N")
```

Первое значение вставьте в `TELEGRAM_WEBHOOK_SECRET`, второе в `KYC_PURGE_SECRET`.

## 3. Создать Telegram-бота и узнать admin ID

1. В Telegram откройте `@BotFather`.
2. Выполните `/newbot`, задайте имя и username бота.
3. Полученный token вставьте в `TELEGRAM_BOT_TOKEN`.
4. Username без символа `@` вставьте в `TELEGRAM_BOT_USERNAME`.
5. Напишите новому боту любое сообщение до установки webhook.
6. В браузере откройте:

```text
https://api.telegram.org/bot<TELEGRAM_BOT_TOKEN>/getUpdates
```

В ответе найдите `"from":{"id":123456789}`. Это ваш Telegram ID. Вставьте его в `TELEGRAM_ADMIN_IDS`. Для нескольких админов используйте запятую:

```dotenv
TELEGRAM_ADMIN_IDS=123456789,987654321
```

## 4. Подключить проект через Supabase CLI

Нужен Node.js, он уже требуется для frontend.

### Вариант A: на своем компьютере с браузером

В PowerShell:

```powershell
npx supabase@latest login
npx supabase@latest link --project-ref YOUR_PROJECT_REF
```

При `link` Supabase может запросить пароль базы, который задавался при создании проекта.

### Вариант B: на VPS по SSH, где браузера нет

Не используйте обычный `npx supabase@latest login`: VPS не сможет открыть
страницу входа. На своем компьютере в браузере откройте:

```text
https://supabase.com/dashboard/account/tokens
```

Создайте `Personal Access Token`. Затем на VPS, в папке проекта, выполните:

```bash
read -s -p "Paste Supabase Personal Access Token: " SUPABASE_ACCESS_TOKEN; echo
export SUPABASE_ACCESS_TOKEN
npx supabase@latest projects list
npx supabase@latest link --project-ref YOUR_PROJECT_REF
```

Команда `read -s` не показывает token на экране и не записывает его в историю
команд. Переменная действует только в текущем SSH-сеансе.

Если терминал уже показывает `Enter your verification code:` после неудачного
входа, сначала нажмите `Ctrl+C`, затем выполните команды варианта B.

## 5. Загрузить таблицы и функции базы

Сначала посмотреть список миграций, которые будут применены:

```powershell
npx supabase@latest db push --dry-run
```

Если в выводе перечислены миграции `202605250001` ... `202605250005`, примените их:

```powershell
npx supabase@latest db push
```

Команда создаёт таблицы, RLS-политики, приватные Storage buckets, RPC для demo-заявок, feedback, KYC и админки.

## 6. Загрузить secrets из того же `.env.deploy`

Используется тот же единственный `.env.deploy`:

```powershell
npx supabase@latest secrets set --env-file .env.deploy
npx supabase@latest secrets list
```

В Supabase дополнительно загрузятся публичные `VITE_*` и `STREET_FAMILY_PORT`. Это лишние для Edge Functions значения, но они не являются секретами и позволяют не заводить второй env-файл.

`SUPABASE_URL`, `SUPABASE_ANON_KEY` и `SUPABASE_SERVICE_ROLE_KEY` вручную добавлять не требуется: Supabase предоставляет их Edge Functions автоматически.

## 7. Задеплоить Edge Functions

Конфигурация доступа уже находится в `supabase/config.toml`: Telegram endpoints доступны до входа, остальные пользовательские/KYC функции требуют авторизованную сессию.

```powershell
npx supabase@latest functions deploy --use-api
```

Проверить, что функции появились:

```powershell
npx supabase@latest functions list
```

## 8. Разместить frontend и указать Mini App URL

Для Telegram Mini App требуется публичный HTTPS-адрес сайта. Сначала поднимите frontend на VPS по инструкции [DEPLOY_VPS_RU.md](DEPLOY_VPS_RU.md) и включите HTTPS.

После получения настоящего адреса сайта замените в `.env.deploy`:

```dotenv
TELEGRAM_MINI_APP_URL=https://ваш-домен.example.com
```

Повторно отправьте secrets:

```powershell
npx supabase@latest secrets set --env-file .env.deploy
```

Перепубликовывать функции после смены secrets не нужно.

## 9. Включить Telegram webhook

В PowerShell, подставив ваши значения:

```powershell
$token = "ВАШ_TELEGRAM_BOT_TOKEN"
$secret = "ВАШ_TELEGRAM_WEBHOOK_SECRET"
$ref = "YOUR_PROJECT_REF"
Invoke-RestMethod "https://api.telegram.org/bot$token/setWebhook?url=https://$ref.supabase.co/functions/v1/telegram-bot-webhook&secret_token=$secret"
```

Ответ должен содержать `"ok": true`.

## 10. Проверить работу

1. Напишите боту `/start`.
2. Бот должен прислать кнопку `Apri Street Family Demo`.
3. Нажмите кнопку: сайт открывается внутри Telegram и авторизует пользователя автоматически.
4. Для ID из `TELEGRAM_ADMIN_IDS` в профиле появится `Admin / Apri pannello amministrazione`.
5. Отправьте demo-заявку: сообщение о новой заявке должно прийти всем администраторам из `TELEGRAM_ADMIN_IDS`, которые ранее открыли бота.

Telegram не разрешает автоматически открыть Mini App без нажатия пользователем кнопки после `/start`.

## 11. Обновления

После изменений базы или Functions:

```powershell
npx supabase@latest db push
npx supabase@latest secrets set --env-file .env.deploy
npx supabase@latest functions deploy --use-api
```

После изменений frontend отправьте код в Git и пересоберите контейнер на VPS по инструкции деплоя.

## Диагностика

Проверить webhook:

```powershell
$token = "ВАШ_TELEGRAM_BOT_TOKEN"
Invoke-RestMethod "https://api.telegram.org/bot$token/getWebhookInfo"
```

Проверить функции и secrets:

```powershell
npx supabase@latest functions list
npx supabase@latest secrets list
```

Источники: [Supabase CLI / db push](https://supabase.com/docs/reference/cli/supabase-secrets), [Supabase Function secrets](https://supabase.com/docs/guides/functions/secrets), [Supabase Edge Functions deploy](https://supabase.com/docs/guides/functions/deploy), [Telegram Mini Apps](https://core.telegram.org/bots/webapps).
