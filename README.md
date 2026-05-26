# Street Family - Closed Staging MVP

React/Vite storefront and admin interface backed by Supabase. This environment creates test requests only: it implements no payment, delivery, meetup execution or commercial fulfillment.

## VPS Deployment

The repository now includes a production frontend container, Docker Compose configuration and a host Nginx reverse-proxy example. For a beginner-friendly Russian guide covering Git, choosing a free port alongside existing VPS projects, HTTPS and later updates, see [`docs/DEPLOY_VPS_RU.md`](docs/DEPLOY_VPS_RU.md).

## Local Frontend

```bash
npm install
copy .env.example .env
npm run dev
```

Client-side environment:

```dotenv
VITE_SUPABASE_URL=https://your-project.supabase.co
VITE_SUPABASE_PUBLISHABLE_KEY=your_publishable_key
```

Checks:

```bash
npm run typecheck
npm run build
```

## Supabase Backend

Apply the migrations in order:

- [`supabase/migrations/202605250001_street_family_mvp.sql`](supabase/migrations/202605250001_street_family_mvp.sql)
- [`supabase/migrations/202605250002_telegram_bot_media.sql`](supabase/migrations/202605250002_telegram_bot_media.sql)
- [`supabase/migrations/202605250003_manual_kyc.sql`](supabase/migrations/202605250003_manual_kyc.sql)
- [`supabase/migrations/202605250004_broadcasts.sql`](supabase/migrations/202605250004_broadcasts.sql)
- [`supabase/migrations/202605250005_demo_loyalty_feedback_rules.sql`](supabase/migrations/202605250005_demo_loyalty_feedback_rules.sql)

Deploy these Edge Functions:

```bash
supabase functions deploy telegram-auth-start
supabase functions deploy telegram-auth-status
supabase functions deploy telegram-bot-webhook
supabase functions deploy submit-test-order
supabase functions deploy kyc-status
supabase functions deploy upload-kyc-capture
supabase functions deploy submit-kyc
supabase functions deploy admin-kyc-documents
supabase functions deploy review-kyc
supabase functions deploy purge-expired-kyc
supabase secrets set --env-file supabase/functions/.env
```

Create `supabase/functions/.env` from `supabase/functions/.env.example`. These are server-side secrets only:

```dotenv
TELEGRAM_BOT_TOKEN=123456:telegram_bot_token
TELEGRAM_BOT_USERNAME=your_bot_username
TELEGRAM_WEBHOOK_SECRET=long_random_webhook_secret
TELEGRAM_ADMIN_IDS=123456789,987654321
KYC_PURGE_SECRET=long_random_cron_secret
```

Set the Telegram bot webhook using the deployed function URL and the same webhook secret:

```text
https://api.telegram.org/bot<BOT_TOKEN>/setWebhook?url=https://<project-ref>.supabase.co/functions/v1/telegram-bot-webhook&secret_token=<TELEGRAM_WEBHOOK_SECRET>
```

## Authentication And Admins

- Website login opens the Telegram bot with a one-time deep link. The browser session is issued only after the user confirms in the bot.
- `TELEGRAM_ADMIN_IDS` contains Telegram numeric user IDs. When one of these users logs in through the bot, they are automatically added to the staging allowlist with role `admin`.
- Admin users see the admin badge in their profile and the `/admin` entry in navigation.
- The admin panel additionally requires TOTP MFA (`aal2`) before protected operations are accessible.
- Non-admin users remain closed-staging allowlist members and can be admitted from the admin panel using their Telegram numeric ID.

## Orders And Notifications

- The client invokes the `submit-test-order` Edge Function, not the order RPC directly.
- The function creates a demo-request transaction and sends a Telegram Bot API notification to every ID in `TELEGRAM_ADMIN_IDS`.
- Every listed admin must have opened the bot at least once, otherwise Telegram will not permit the bot to initiate messages to that chat.
- The supported scenarios are `meetup`, `delivery_zone` and `delivery_italia`; allowed cities, minimum units and required street fields are validated in the database function.
- Totals, surcharge and token credit are simulations only. No request performs payment, exchange, delivery or pickup.
- Direct browser execution and the superseded internal order function are revoked after applying the migrations.

## Demo Rules And Loyalty

- The authenticated `/info` page displays the simulation rules and community-news links for Instagram and Viber; Signal remains `In arrivo` until configured.
- The neutral catalogue exposes only packages of `50`, `100`, `300`, `500` and `1000 units`.
- `Gettoni` are the loyalty credit shown to members. They are reserved atomically when used in a demo request and awarded only when an admin marks that request `completed`; their balance is capped at `100`.
- XP remains separate from gettoni. The only member game is `Ruota dei premi`, consuming one ticket earned on every fifth completed demo request.
- A member may submit one feedback entry for each of their own completed requests. Only admin-published feedback is shown in staging.

## Product Media

- Admins upload files directly in the catalog panel; URL entry is no longer required.
- Files are stored in the private `product-media` Storage bucket and storefront URLs are short-lived signed URLs.
- Each product supports at most 5 images and 3 videos; the database trigger enforces the limit.
- Media records carry `uploading`, `ready` or `failed` state; the admin UI shows upload progress while large files such as videos are transferring.

## Broadcast News

- Admins create in-app broadcasts from the `Broadcast` admin tab and can publish or archive each message.
- Published broadcasts appear in the notification bell for allowlisted staging users; drafts remain admin-only under RLS.
- When an admin creates a product, the `Crea news nuovo prodotto` checkbox creates a linked news draft. It is deliberately not published automatically so media and catalogue visibility can be checked first.
- Broadcast and linked-product creation operations require admin MFA and are written to the admin audit log.

## First-Order Manual KYC

- Before a user's first test-order can be submitted, KYC status must be `approved`.
- The user must capture exactly three images: document front, document back and a selfie while holding the document.
- The frontend uses `navigator.mediaDevices.getUserMedia()` and a canvas snapshot. It does not expose a file-picker input for KYC.
- A browser application cannot cryptographically prove that a submitted image originated from the live camera without an external verification or device-attestation service. This implementation removes the normal upload path and requires active camera permission in the UI.
- KYC images are stored in the separate private `kyc-documents` Storage bucket. There are no browser read/upload policies for this bucket; authenticated uploads and reviews go through Edge Functions only.
- Administrators may view KYC images only after MFA (`aal2`). Document views generate 60-second signed URLs and an audit event; approve/reject decisions are also audited.
- Approving or rejecting KYC sends a Telegram status notification to the member. When KYC is rejected, captured image objects and metadata are removed so the user must perform fresh camera captures before resubmitting.
- Approved images receive a retention deadline, defaulting to `365` days and configurable in the admin panel. Invoke `purge-expired-kyc` daily with a secret header to delete expired document objects and metadata while keeping the reviewed case record:

```bash
curl -X POST "https://<project-ref>.supabase.co/functions/v1/purge-expired-kyc" \
  -H "X-Kyc-Purge-Secret: <KYC_PURGE_SECRET>"
```

- Schedule the call above in a protected daily cron job and keep `KYC_PURGE_SECRET` outside the frontend and repository.
- Treat KYC records as sensitive personal data: restrict Supabase dashboard/service-role access and never log image URLs or document content.

## Constraints

- Seed product content is test-only and is not an approved commercial catalogue.
- Product sales or fulfillment require a separate compliance decision and are outside this build.

References: [Supabase Edge Function secrets](https://supabase.com/docs/guides/functions/secrets), [Supabase Storage](https://supabase.com/docs/guides/storage), [Telegram Bot API](https://core.telegram.org/bots/api).
