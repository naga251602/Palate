# Palate Backend Route Guide

This guide lists the HTTP endpoints in the current backend zip, grouped by source/age.

## Legend

- **Supabase Auth**: built-in platform endpoint
- **Initial schema snapshot**: endpoints tied to the base schema migration
- **Email/contact snapshot**: profile/contact/notification additions
- **Function snapshot**: custom Edge Function code

## Important notes

- Most endpoints require `Authorization: Bearer <access_token>`.
- `import-email` is a webhook and uses `verify_jwt = false`; it is secured with Resend webhook signature verification.
- `send-push` is internal.
- `stats` is read-only and is derived from visits.
- `recently visited` / `Next Up` / `wishlist` are projections built from `visits` and `wishlists`, not separate stat tables.
- `log-visit` now supports **POST** for create/update and **DELETE** for removing a visit.

---

## 1) Supabase Auth endpoints

These are built-in Supabase endpoints.

### `POST /auth/v1/signup`
Create an account.

**Request**
```json
{ "email": "user@example.com", "password": "secret" }
```

**Response**
```json
{ "access_token": "...", "refresh_token": "...", "user": { "id": "..." } }
```

### `POST /auth/v1/token?grant_type=password`
Login with email/password.

**Request**
```json
{ "email": "user@example.com", "password": "secret" }
```

**Response**
```json
{ "access_token": "...", "refresh_token": "...", "user": { "id": "..." } }
```

### `POST /auth/v1/otp`
Send OTP / magic link email.

**Request**
```json
{ "email": "user@example.com", "type": "magiclink" }
```

**Response**
```json
{ "message": "OTP sent" }
```

### `POST /auth/v1/verify`
Verify OTP.

**Request**
```json
{ "email": "user@example.com", "token": "123456", "type": "email" }
```

**Response**
```json
{ "access_token": "...", "refresh_token": "...", "user": { "id": "..." } }
```

### `POST /auth/v1/logout`
End session.

**Response**
```json
{ "message": "Logged out" }
```

### `POST /auth/v1/token?grant_type=refresh_token`
Refresh session.

**Request**
```json
{ "refresh_token": "..." }
```

**Response**
```json
{ "access_token": "...", "refresh_token": "..." }
```

---

## 2) Restaurant + visit endpoints

### `POST /functions/v1/search-restaurants`
**Age / source:** Function snapshot

Search Yelp, cache results in `restaurants`, return nearby restaurants with distance and about text.

**Request**
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
  "restaurants": [
    {
      "id": "uuid",
      "yelp_id": "abc123",
      "name": "Daikokuya",
      "address": "327 E 1st St",
      "city": "Los Angeles",
      "state": "CA",
      "country": "US",
      "lat": 34.0493,
      "lng": -118.2386,
      "phone": "(213) 626-1680",
      "price_range": "$$",
      "cuisine_tags": ["ramen", "japanese"],
      "rating": 4.5,
      "review_count": 3241,
      "image_url": "https://...",
      "yelp_url": "https://...",
      "is_open_now": true,
      "last_synced_at": "2026-05-18T00:00:00Z",
      "about": "ramen · japanese • $$ • 4.5★ • 3241 reviews • Los Angeles, CA • Open now",
      "distance_meters": 840
    }
  ],
  "total": 42,
  "cached": false
}
```

### `POST /functions/v1/restaurant-detail`
**Age / source:** Function snapshot

Returns full Yelp-backed restaurant detail, reviews, and the current user’s visit history for that restaurant.

**Request**
```json
{ "yelp_id": "daikokuya-los-angeles" }
```

**Response**
```json
{
  "restaurant": { "id": "uuid", "yelp_id": "...", "name": "..." },
  "about": "Japanese • $$ • 4.5★ • 3241 reviews • Los Angeles, CA • Open now",
  "phone": "(213) 626-1680",
  "rating": 4.5,
  "review_count": 3241,
  "cuisine_tags": ["ramen", "japanese"],
  "cuisine_names": ["Ramen", "Japanese"],
  "hours": { "mon": "11:00-22:00" },
  "yelp_reviews": [
    {
      "author": "Sarah M.",
      "rating": 5,
      "text": "Incredible...",
      "time_created": "2026-04-01"
    }
  ],
  "user_visit_count": 3,
  "user_last_visited": "2026-04-22"
}
```

### `POST /functions/v1/log-visit`
**Age / source:** Function snapshot

Create or update a visit row. This is the main CRUD entry point for:
- Recently Visited
- Next Up
- log view entries

**Request**
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

**Update existing visit**
```json
{ "visit_id": "uuid", "restaurant_id": "uuid", "visit_type": "upcoming" }
```

**Response**
```json
{
  "visit_id": "uuid",
  "streak_count": 8,
  "milestone": "10_visits",
  "points_earned": 50
}
```

### `DELETE /functions/v1/log-visit`
**Age / source:** Function snapshot

Delete a visit row. Also removes related visit activity and notification records, and updates `profiles.total_visits` when the deleted visit was a completed visit.

**Request**
```json
{ "visit_id": "uuid" }
```

**Response**
```json
{
  "deleted": true,
  "visit_id": "uuid",
  "previous_visit_type": "visited",
  "total_visits": 17
}
```

### `POST /functions/v1/schedule-reminder`
**Age / source:** Function snapshot

Schedule a reservation reminder. The actual dispatch is done by cron.

**Request**
```json
{
  "reservation_id": "uuid",
  "restaurant_name": "Le Bernardin",
  "reservation_datetime": "2026-05-17T20:30:00",
  "hours_before": 3
}
```

**Response**
```json
{
  "scheduled": true,
  "fires_at": "2026-05-17T17:30:00Z",
  "reservation_id": "uuid",
  "restaurant_name": "Le Bernardin"
}
```

### `POST /functions/v1/import-instagram`
**Age / source:** Function snapshot

Extract a restaurant name from an Instagram URL and find the best Yelp match.

**Request**
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
  "yelp_match": { "id": "uuid", "name": "Majordōmo" },
  "confidence": 0.91
}
```

### `POST /functions/v1/import-email`
**Age / source:** Email/contact snapshot + Function snapshot

Inbound Resend webhook. Verifies the Resend signature, fetches the full received email by `email_id`, extracts reservation fields, maps the sender email to a saved contact email, and creates:
- a restaurant row,
- a visit row,
- a notification row.

**Request**
```json
{
  "type": "email.received",
  "data": {
    "email_id": "uuid"
  }
}
```

**Response**
```json
{
  "mapped_user_id": "uuid",
  "restaurant": {
    "id": "uuid",
    "name": "Niku",
    "address": "..."
  },
  "visit": { "id": "uuid", "visit_type": "upcoming" },
  "notification": {
    "title": "Niku - sent from email",
    "body": "Added to Next Up",
    "logo_url": "https://..."
  },
  "parsed": {
    "restaurant_name": "Niku",
    "address": "...",
    "phone": "...",
    "party_size": 2,
    "table_label": "table for 2",
    "confirmation_code": "ABC123",
    "visit_date": "2026-05-20",
    "visit_time": "19:00",
    "visit_type": "upcoming"
  }
}
```

---

## 3) Social + notifications + stats

### `GET /functions/v1/feed`
**Age / source:** Initial schema snapshot

Paginated friend activity feed. Marks fetched items as read.

**Query params**
```text
?limit=20&before=2026-05-16T00:00:00Z
```

**Response**
```json
{
  "items": [
    {
      "id": "uuid",
      "type": "new_visit",
      "created_at": "2026-05-15T21:00:00Z",
      "is_read": false,
      "actor": {
        "username": "priya",
        "display_name": "Priya",
        "avatar_url": "https://..."
      },
      "visit": {
        "rating": 5,
        "notes": "Great omakase",
        "visit_date": "2026-05-15",
        "dishes": [
          { "name": "Uni", "rating": 5 }
        ]
      },
      "restaurant": {
        "id": "uuid",
        "name": "Nobu",
        "city": "LA",
        "image_url": "https://...",
        "cuisine_tags": ["japanese", "sushi"],
        "price_range": "$$$$"
      }
    }
  ],
  "has_more": true
}
```

### `GET /functions/v1/notifications`
**Age / source:** Email/contact snapshot

Paginated in-app notifications. Marks fetched unread rows as read.

**Query params**
```text
?limit=20&before=2026-05-16T00:00:00Z
```

**Response**
```json
{
  "items": [
    {
      "id": "uuid",
      "type": "email_import",
      "title": "Niku - sent from email",
      "body": "Added to Next Up",
      "logo_url": "https://...",
      "is_read": false,
      "created_at": "2026-05-18T12:00:00Z",
      "restaurant": { "id": "uuid", "name": "Niku", "image_url": "https://..." },
      "visit": { "id": "uuid", "visit_type": "upcoming", "visit_date": "2026-05-19", "visit_time": "19:00" }
    }
  ],
  "has_more": false
}
```

### `GET /functions/v1/profile-details`
**Age / source:** Email/contact snapshot

Returns the authenticated user’s profile and grouped contact items.

**Response**
```json
{
  "profile": {
    "id": "uuid",
    "username": "gaurav",
    "display_name": "Gaurav",
    "avatar_url": "https://...",
    "bio": "...",
    "is_pro": false,
    "total_visits": 84,
    "created_at": "2026-05-18T00:00:00Z",
    "updated_at": "2026-05-18T00:00:00Z"
  },
  "contact_items": {
    "email": [
      { "id": "uuid", "type": "email", "value": "user@example.com", "is_primary": true }
    ],
    "instagram": [
      { "id": "uuid", "type": "instagram", "value": "@gaurav", "is_primary": false }
    ],
    "phone": [
      { "id": "uuid", "type": "phone", "value": "+1 415 555 0000", "is_primary": false }
    ]
  },
  "contact_items_flat": [
    { "id": "uuid", "type": "email", "value": "user@example.com", "is_primary": true }
  ]
}
```

**Methods**
- `GET`: fetch profile + contact items
- `POST`: add or update one or more contact items
- `DELETE`: remove a contact item by `contact_item_id`

**POST request**
```json
{
  "items": [
    { "type": "email", "value": "user@example.com", "is_primary": true },
    { "type": "instagram", "value": "@gaurav" },
    { "type": "phone", "value": "+1 415 555 0000" }
  ]
}
```

**DELETE request**
```json
{ "contact_item_id": "uuid" }
```

### `GET /functions/v1/stats`
**Age / source:** Initial schema snapshot

Read-only aggregated stats. Derived from `visits` and `restaurants`.

**Response**
```json
{
  "total_visits": 84,
  "unique_cuisines": 16,
  "total_miles_traveled": 12400,
  "countries_visited": 4,
  "cities_visited": 11,
  "current_streak_weeks": 7,
  "favorite_cuisine": "Japanese",
  "most_visited_restaurant": { "name": "Majordōmo", "count": 6 },
  "avg_rating_given": 4.3,
  "milestones": ["first_visit", "10_visits", "50_visits", "streak_7_weeks"]
}
```

---

## 4) Internal / support endpoints

### `POST /functions/v1/send-push`
**Age / source:** Function snapshot

Internal APNs sender. Also handles cron batch mode for reservation reminders.

**Direct push request**
```json
{
  "user_id": "uuid",
  "title": "Reservation Tonight 🍽️",
  "body": "Your table at Le Bernardin is in 3 hours.",
  "data": { "type": "reservation_reminder", "restaurant_id": "uuid" }
}
```

**Cron request**
```json
{ "type": "cron_reminder_dispatch" }
```

---

## 5) What is not a separate endpoint

These are handled through the endpoints above or directly through tables:

- `wishlists` CRUD is not a dedicated Edge Function in this zip
- `push_tokens` are inserted directly from the client into the table
- `stats` is not CRUD — it is computed from visits

---

## 6) Backend gap to keep in mind

If the app wants to:
- create a visit or move it from Next Up to Previously Visited,
- update an existing log entry,
- delete a log entry,

use `POST /functions/v1/log-visit` or `DELETE /functions/v1/log-visit`.

If it wants to:
- add/remove emails, Instagram handles, or phone numbers,

use `GET/POST/DELETE /functions/v1/profile-details`.

If it wants to:
- see stats,

use `GET /functions/v1/stats`.
