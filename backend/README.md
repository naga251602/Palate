# Palate — Backend

Supabase Edge Functions backend for the Palate iOS app. Handles restaurant search (Yelp-cached), visit logging, social activity feeds, APNs push notifications, and reservation reminders.

---

## Stack

| Layer | Technology |
|---|---|
| Auth | Supabase Auth (email/password + OTP) |
| Database | Supabase Postgres + pg_cron |
| Storage | Supabase Storage |
| Realtime | Supabase Realtime |
| Restaurant Data | Yelp Fusion API (cached 24h) |
| Push | APNs via ES256 JWT |
| Email | Resend |
| Runtime | Supabase Edge Functions (Deno) |

---

## Project Structure

```
backend/
├── supabase/
│   ├── config.toml
│   ├── migrations/
│   │   └── 20260518000000_initial_schema.sql   # All tables, RLS, triggers, cron
│   └── functions/
│       ├── _shared/
│       │   └── utils.ts                         # Shared helpers (auth, Yelp, responses)
│       ├── search-restaurants/index.ts
│       ├── restaurant-detail/index.ts
│       ├── log-visit/index.ts
│       ├── schedule-reminder/index.ts
│       ├── send-push/index.ts
│       ├── import-instagram/index.ts
│       ├── import-email/index.ts
│       ├── profile-details/index.ts
│       ├── notifications/index.ts
│       ├── feed/index.ts
│       └── stats/index.ts
├── .env.example
├── .gitignore
└── README.md
```

---

## Setup

### 1. Prerequisites

- [Supabase CLI](https://supabase.com/docs/guides/cli) `>= 1.150`
- [Deno](https://deno.land/) `>= 1.40` (for local function development)
- A Supabase project (free tier works)

### 2. Clone & configure

```bash
git clone <your-repo>
cd Palate/backend
cp .env.example .env
# Fill in all values in .env
```

### 3. Link to your Supabase project

```bash
supabase login
supabase link --project-ref YOUR_PROJECT_REF
```

### 4. Run the migration

```bash
supabase db push
```

This creates all tables, indexes, RLS policies, storage buckets, and the `pg_cron` reservation reminder job.

### 5. Set pg_cron Postgres parameters

The cron job needs to call your edge function. Run this in the Supabase SQL Editor:

```sql
ALTER SYSTEM SET app.supabase_url = 'https://YOUR_PROJECT_REF.supabase.co';
ALTER SYSTEM SET app.service_role_key = 'YOUR_SERVICE_ROLE_KEY';
SELECT pg_reload_conf();
```

### 6. Set Edge Function secrets

```bash
supabase secrets set \
  YELP_API_KEY=your_yelp_key \
  RESEND_API_KEY=your_resend_key \
  APNS_KEY_ID=XXXXXXXXXX \
  APNS_TEAM_ID=XXXXXXXXXX \
  APNS_PRIVATE_KEY="$(cat AuthKey_XXXXXXXXXX.p8)" \
  APNS_BUNDLE_ID=com.yourname.palate \
  APNS_ENV=sandbox \
  RESEND_WEBHOOK_SECRET=your-inbound-email-secret
```

### 7. Deploy functions

```bash
supabase functions deploy
```

Or deploy individually:

```bash
supabase functions deploy search-restaurants
supabase functions deploy log-visit
# etc.
```

---

## API Reference

All endpoints require `Authorization: Bearer <access_token>` except `send-push` (internal).

### `POST /functions/v1/search-restaurants`

Search for restaurants. Results are cached in Postgres for 24h to stay within Yelp's 5,000/day rate limit.

**Body**
```json
{
  "query": "ramen",
  "lat": 34.0522,
  "lng": -118.2437,
  "radius": 10000,
  "limit": 20,
  "offset": 0,
  "price": ["$$", "$$$"],
  "open_now": true
}
```

**Response**
```json
{
  "restaurants": [...],
  "total": 42,
  "cached": false
}
```

---

### `POST /functions/v1/restaurant-detail`

Full detail for one restaurant including hours, Yelp reviews, and the calling user's visit history.

**Body**
```json
{ "yelp_id": "daikokuya-los-angeles" }
```

---

### `POST /functions/v1/log-visit`

Create or update a visit. Handles dish logging, total_visit increment, follower fan-out, push notifications, and milestone checks.

**Body**
```json
{
  "restaurant_id": "uuid",
  "visit_type": "visited",
  "visit_date": "2026-05-17",
  "visit_time": "19:00",
  "party_size": 2,
  "rating": 5,
  "notes": "Incredible tasting menu",
  "dishes": [
    { "name": "Langoustine crudo", "rating": 5 },
    { "name": "Duck confit", "rating": 4 }
  ]
}
```

Pass `visit_id` to update an existing visit instead of creating a new one.

**Response**
```json
{
  "visit_id": "uuid",
  "streak_count": 8,
  "milestone": "10_visits",
  "points_earned": 50
}
```

---

### `POST /functions/v1/schedule-reminder`

Schedules an APNs reminder for a reservation. The actual push fires via `pg_cron` (runs every minute).

**Body**
```json
{
  "reservation_id": "uuid",
  "restaurant_name": "Le Bernardin",
  "reservation_datetime": "2026-05-17T20:30:00",
  "hours_before": 3
}
```

---

### `POST /functions/v1/send-push` *(internal)*

Dispatches APNs push to a single user. Also handles the cron batch mode (`"type": "cron_reminder_dispatch"`). Automatically removes expired device tokens.

---

### `POST /functions/v1/import-instagram`

Extracts a restaurant name from an Instagram post URL via Open Graph metadata, then finds the best Yelp match.

**Body**
```json
{
  "url": "https://www.instagram.com/p/ABC123/",
  "lat": 34.0522,
  "lng": -118.2437
}
```

**Response**
```json
{
  "extracted_name": "Majordōmo",
  "yelp_match": { ...restaurant object },
  "confidence": 0.91
}
```

---

### `GET /functions/v1/feed`

Paginated friend activity feed. Automatically marks returned items as read.

**Query params:** `?limit=20&before=2026-05-16T00:00:00Z`

---

### `GET /functions/v1/stats`

Aggregated profile stats: visit counts, cuisines, miles traveled, weekly streak, milestones, etc.

### `POST /functions/v1/import-email`

Inbound webhook that maps recipient email addresses to `contact_items`, resolves Yelp restaurant data, creates a visit with `visited` or `upcoming` classification, and writes a notification row with a logo image. It only processes emails that look like restaurant/reservation mail, so unrelated inbound email is rejected before any Yelp lookup or database write.

### `GET /functions/v1/profile-details`

Returns the authenticated user's profile plus grouped contact items. `POST` can add multiple emails, Instagram accounts, or phone numbers. `DELETE` removes a contact item by id.

### `GET /functions/v1/notifications`

Returns paginated user notifications and marks fetched items as read.

---

## Local Development

```bash
supabase start          # starts local Supabase (Postgres, Auth, Storage, Studio)
supabase functions serve --env-file .env  # serves all functions with hot reload
```

Local Studio UI: http://localhost:54323

Test a function:
```bash
curl -i --request POST \
  http://localhost:54321/functions/v1/search-restaurants \
  --header 'Authorization: Bearer YOUR_LOCAL_ANON_KEY' \
  --header 'Content-Type: application/json' \
  --data '{"query":"ramen","lat":34.0522,"lng":-118.2437}'
```

---

## iOS Integration

See [`docs/route-guid.md`](docs/route-guid.md) for the iOS ↔ backend mapping. Key points:

- The iOS app uses a lightweight URLSession client in `../App/Palate/Services/SupabaseClient.swift`.
- Upload photos directly from iOS to Supabase Storage; store the `storage_path` in `visit_photos` via `log-visit`
- Register APNs device token on app launch → `POST /push_tokens` (direct table insert via `supabase-swift`)
- Map search uses `MKLocalSearch` natively; tap a pin → call `restaurant-detail` to enrich with Yelp data

---

## Notes

- **Yelp rate limit:** 5,000 calls/day on free tier. The 24h cache in the `restaurants` table is the main mitigation. Consider upgrading if the app scales.
- **APNs sandbox vs production:** Set `APNS_ENV=sandbox` for local/TestFlight, `production` for App Store.
- **Instagram import:** Meta's scraping restrictions mean Open Graph extraction is best-effort. Confidence scores below 0.6 should prompt the user to confirm the match manually.
- **pg_cron:** Must be enabled on your Supabase project. Available on all paid plans and most free projects. Check *Project Settings → Extensions*.


---

## New backend capabilities

### Profile details + multiple contact methods
The `contact_items` table already supports multiple `email`, `instagram`, and `phone` rows per user. The new `GET /functions/v1/profile-details` endpoint returns the profile plus grouped contact items for rendering profile details in the app.

### Email import / user mapping
A new `POST /functions/v1/import-email` webhook maps inbound email recipient addresses to `contact_items.type = 'email'`, resolves the matching user, classifies the visit as `visited` or `upcoming` from the visit date, and writes a `notifications` row with a Yelp image/logo. It rejects unrelated email before doing any Yelp lookup or row creation.

Recommended environment variable:
```bash
RESEND_WEBHOOK_SECRET=your-inbound-email-secret
```

### Yelp detail payload
`POST /functions/v1/restaurant-detail` now returns richer Yelp-backed fields:
- rating
- review count
- phone number
- cuisine tags / cuisine names
- hours
- reviews
- a synthesized `about` string for the app UI

### Authentication errors
Supabase Auth still returns its own raw error payloads during sign-in. Map them in the iOS client to friendly copy such as `Invalid login credentials`, `Please verify your email before logging in`, and `Too many attempts. Please try again later`.


## Webhook Auth

The `import-email` function should be deployed with `verify_jwt = false` because Resend webhook requests do not include a Supabase JWT. The function is secured by the `RESEND_WEBHOOK_SECRET` header check.

### Resend inbound emails

Resend inbound emails are handled by the `import-email` Edge Function.

Important setup notes:

- Set `verify_jwt = false` for the `import-email` function in `supabase/config.toml`.
- Use the Resend webhook signing secret in `RESEND_WEBHOOK_SECRET`.
- Resend webhooks only include metadata in the webhook event; the function fetches the full received email content using the Resend Receiving API before parsing reservation details.

