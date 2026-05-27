# Street Family

React/Vite storefront and admin interface backed by Supabase.

## VPS Deployment

The repository now includes a production frontend container, Docker Compose configuration and a host Nginx reverse-proxy example. For a beginner-friendly Russian guide covering Git, choosing a free port alongside existing VPS projects, HTTPS and later updates, see [`docs/DEPLOY_VPS_RU.md`](docs/DEPLOY_VPS_RU.md).

## One Environment File

The project uses exactly one local/deployment configuration file: `.env.deploy` in the repository root.

```bash
npm install
copy .env.deploy.example .env.deploy
npm run dev
```

The same `.env.deploy` is used for Vite, Docker Compose and `supabase secrets set --env-file .env.deploy`. It is ignored by Git. For the complete Russian step-by-step Supabase and Telegram setup, use [`docs/SUPABASE_SETUP_RU.md`](docs/SUPABASE_SETUP_RU.md).

Checks:

```bash
npm run typecheck
npm run build
```

## Supabase Backend

The exact beginner setup commands are in [`docs/SUPABASE_SETUP_RU.md`](docs/SUPABASE_SETUP_RU.md). Backend migrations are:

- [`supabase/migrations/202605250001_street_family_mvp.sql`](supabase/migrations/202605250001_street_family_mvp.sql)
- [`supabase/migrations/202605250002_telegram_bot_media.sql`](supabase/migrations/202605250002_telegram_bot_media.sql)
- [`supabase/migrations/202605250003_manual_kyc.sql`](supabase/migrations/202605250003_manual_kyc.sql)
- [`supabase/migrations/202605250004_broadcasts.sql`](supabase/migrations/202605250004_broadcasts.sql)
- [`supabase/migrations/202605250005_demo_loyalty_feedback_rules.sql`](supabase/migrations/202605250005_demo_loyalty_feedback_rules.sql)
- [`supabase/migrations/202605250006_remove_admin_mfa.sql`](supabase/migrations/202605250006_remove_admin_mfa.sql)

On a workstation with a browser use `npx supabase@latest login`. On a headless
VPS use a Personal Access Token through `SUPABASE_ACCESS_TOKEN`, as shown in
[`docs/SUPABASE_SETUP_RU.md`](docs/SUPABASE_SETUP_RU.md). After linking the project, apply and deploy:

```bash
npx supabase@latest db push
npx supabase@latest secrets set --env-file .env.deploy
npx supabase@latest functions deploy --use-api
```

All configuration values are defined once in root `.env.deploy`, copied from `.env.deploy.example`:

```dotenv
VITE_SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co
VITE_SUPABASE_PUBLISHABLE_KEY=sb_publishable_REPLACE_ME
STREET_FAMILY_PORT=18087
TELEGRAM_BOT_TOKEN=123456:telegram_bot_token
TELEGRAM_BOT_USERNAME=your_bot_username
TELEGRAM_WEBHOOK_SECRET=long_random_webhook_secret
TELEGRAM_ADMIN_IDS=123456789,987654321
TELEGRAM_MINI_APP_URL=https://street.example.com
TELEGRAM_INIT_DATA_MAX_AGE_SECONDS=600
KYC_PURGE_SECRET=long_random_cron_secret
```

Set the Telegram bot webhook using the deployed function URL and the same webhook secret:

```text
https://api.telegram.org/bot<BOT_TOKEN>/setWebhook?url=https://<project-ref>.supabase.co/functions/v1/telegram-bot-webhook&secret_token=<TELEGRAM_WEBHOOK_SECRET>
```

## Authentication And Admins

- Website login opens the Telegram bot with a one-time deep link. The browser session is issued only after confirmation in the bot.
- Sending a plain `/start` message makes the bot return an `Apri Street Family` Mini App button and installs an equivalent chat menu button. Telegram does not allow a bot to open a Mini App without the user's button tap.
- When the app is opened inside Telegram, `telegram-miniapp-auth` validates signed `Telegram.WebApp.initData` on the server and creates the Supabase session automatically. Do not trust `initDataUnsafe` in frontend code.
- `TELEGRAM_MINI_APP_URL` must be the public HTTPS URL of the deployed frontend.
- `TELEGRAM_ADMIN_IDS` contains comma-separated Telegram numeric user IDs, for example `123456789,987654321`. When any of these users enters through the bot or Mini App, they are assigned role `admin` automatically.
- Admin users see an admin badge and panel link in their profile and the admin navigation action.
- The admin panel is available to Telegram users assigned role `admin`; actions remain protected by RLS/RPC checks and audit logging.
- Non-admin Telegram users registering through the bot receive member access; an explicitly disabled member remains blocked.
- Functions receiving unsigned browser startup requests or Telegram webhooks are configured with `verify_jwt = false` in [`supabase/config.toml`](supabase/config.toml). They authenticate through Telegram signatures or challenge secrets in their handlers.

## Orders And Notifications

- The client invokes the `submit-test-order` Edge Function, not the order RPC directly.
- The function creates a demo-request transaction and sends a Telegram Bot API notification to every ID in `TELEGRAM_ADMIN_IDS`.
- Every listed admin must have opened the bot at least once, otherwise Telegram will not permit the bot to initiate messages to that chat.
- The supported scenarios are `meetup`, `delivery_zone` and `delivery_italia`; allowed cities, minimum grams and required street fields are validated in the database function.
- Totals, surcharge and token credit are simulations only. No request performs payment, exchange, delivery or pickup.
- Direct browser execution and the superseded internal order function are revoked after applying the migrations.

## Demo Rules And Loyalty

- The authenticated `/info` page displays the simulation rules and community-news links for Instagram and Viber; Signal remains `In arrivo` until configured.
- The catalogue exposes reference prices for `25`, `50`, `100`, `300`, `500` and `1000 g`. Members can select `50` to `1000 g` in `25 g` increments; intermediate prices are interpolated server-side between adjacent configured tiers and rounded to whole euro values ending in `0` or `5`.
- `Gettoni` are the loyalty credit shown to members. After KYC approval, a member receives a one-time `5` gettoni gift immediately upon submitting the first order; regular order rewards are awarded when an admin marks the order `completed`. Gettoni are reserved atomically when used and their balance is capped at `100`.
- XP remains separate from gettoni. The only member game is `Ruota dei premi`, consuming one ticket earned on every fifth completed demo request.
- A member may submit one feedback entry for each of their own completed requests. Only admin-published feedback is shown in staging.

## Product Media

- Admins upload files directly in the catalog panel; URL entry is no longer required.
- Files are stored in the private `product-media` Storage bucket and storefront URLs are short-lived signed URLs.
- Each product supports at most 5 images and 3 videos; the database trigger enforces the limit.
- Media records carry `uploading`, `ready` or `failed` state; the admin UI shows upload progress while large files such as videos are transferring.

## Broadcast News

- Admins create in-app broadcasts from the `Broadcast` admin tab and can publish, archive or delete each message.
- Publishing a broadcast shows it in the notification bell and sends it through the Telegram bot to allowlisted, non-blocked users that have opened the bot.
- Deleting a broadcast removes it from the app and makes the bot delete the Telegram messages it previously sent for that broadcast on a best-effort basis.
- When an admin creates a product, the `Crea news nuovo prodotto` checkbox creates a linked news draft. It is deliberately not published automatically so media and catalogue visibility can be checked first.
- Broadcast and linked-product creation operations require the admin role and are written to the admin audit log.

## First-Order Manual KYC

- Before a user's first test-order can be submitted, KYC status must be `approved`.
- Once that KYC is approved, submitting the first order credits `5` gettoni immediately and only once.
- The user must capture exactly three images: document front, document back and a selfie while holding the document.
- The frontend uses `navigator.mediaDevices.getUserMedia()` and a canvas snapshot. It does not expose a file-picker input for KYC.
- A browser application cannot cryptographically prove that a submitted image originated from the live camera without an external verification or device-attestation service. This implementation removes the normal upload path and requires active camera permission in the UI.
- KYC images are stored in the separate private `kyc-documents` Storage bucket. There are no browser read/upload policies for this bucket; authenticated uploads and reviews go through Edge Functions only.
- Administrators may view KYC images only from an admin session. Document views generate 60-second signed URLs and an audit event; approve/reject decisions are also audited.
- Approving or rejecting KYC sends a Telegram status notification to the member. When KYC is rejected, captured image objects and metadata are removed so the user must perform fresh camera captures before resubmitting.
- Approved images are retained permanently (default: 36500 days / 100 years) and configurable in the admin panel. Invoke `purge-expired-kyc` daily with a secret header to delete expired document objects and metadata while keeping the reviewed case record:

```bash
curl -X POST "https://<project-ref>.supabase.co/functions/v1/purge-expired-kyc" \
  -H "X-Kyc-Purge-Secret: <KYC_PURGE_SECRET>"
```

- Schedule the call above in a protected daily cron job and keep `KYC_PURGE_SECRET` outside the frontend and repository.
- Treat KYC records as sensitive personal data: restrict Supabase dashboard/service-role access and never log image URLs or document content.

## Constraints

- Seed product content is representative sample and is not an approved commercial catalogue.
- Product sales or fulfillment require a separate compliance decision and are outside this build.

References: [Supabase Edge Function secrets](https://supabase.com/docs/guides/functions/secrets), [Supabase Storage](https://supabase.com/docs/guides/storage), [Telegram Bot API](https://core.telegram.org/bots/api).
