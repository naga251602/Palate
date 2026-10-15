# Palate + Resend Setup Guide

This guide covers the email send and receive flow for Palate when using Resend and Supabase.

## What this setup does

- Receives reservation emails at your Resend inbound address
- Sends `email.received` webhooks to Supabase
- Verifies the webhook signature
- Fetches the full received email content from Resend
- Extracts only reservation data
- Writes the visit into Supabase tables
- Adds a notification row for the app

## What the webhook does not do

Resend inbound webhooks do **not** include the full email body, headers, or attachments in the webhook payload. The webhook only includes metadata, so the backend must fetch the received email content from Resend using the `email_id`.

## 1) Supabase configuration

### A. Disable JWT verification for the webhook function

Edit:

```toml
supabase/config.toml
```

Ensure:

```toml
[functions.import-email]
verify_jwt = false
```

This is required because Resend is not calling the function as a signed-in Supabase user.

### B. Set secrets

Use the Supabase CLI:

```bash
supabase secrets set   RESEND_API_KEY=your_resend_api_key   RESEND_WEBHOOK_SECRET=whsec_your_webhook_signing_secret   YELP_API_KEY=your_yelp_key
```

`RESEND_WEBHOOK_SECRET` is the Resend webhook signing secret from the Webhooks dashboard.

### C. Deploy the function

```bash
supabase functions deploy import-email
```

If you changed other functions too:

```bash
supabase functions deploy
```

---

## 2) Resend inbound email setup

### A. Create or choose a receiving domain

In Resend:

- Go to **Emails**
- Open **Receiving**
- Copy the inbound address, or set up your custom receiving domain

Resend supports both:

- a Resend-managed `*.resend.app` receiving address
- your own custom domain with MX records

### B. Add the webhook

In Resend:

- Go to **Webhooks**
- Create a webhook
- Choose the event:

```text
email.received
```

- Set the webhook endpoint to:

```text
https://YOUR_PROJECT_REF.supabase.co/functions/v1/import-email
```

### C. Copy the signing secret

Resend returns a webhook signing secret for the endpoint. Put that value into:

```bash
RESEND_WEBHOOK_SECRET
```

If the secret in Resend and Supabase do not match exactly, the webhook will be rejected.

---

## 3) How the inbound flow works

1. Someone sends a reservation email to the Resend receiving address.
2. Resend emits an `email.received` webhook.
3. Supabase receives the webhook at `import-email`.
4. The function verifies the webhook signature.
5. The function fetches the full received email content using the `email_id`.
6. The parser extracts only reservation data:
   - restaurant name
   - address
   - phone number
   - party size / table wording
   - confirmation code
   - reservation date and time
7. The function matches the recipient email to a user in `contact_items`.
8. The function upserts the restaurant, creates a visit row, and writes a notification.

---

## 4) Data rules used by the backend

The parser keeps only reservation details.

It stores the reservation as:

- `visit_type = upcoming` when the parsed reservation time is in the future
- `visit_type = visited` when the parsed reservation time is now or in the past

The notification title becomes:

```text
<Restaurant Name> - sent from email
```

The notification body becomes:

- `Added to Next Up`
- or `Added to Previously Visited`

depending on the parsed date/time.

---

## 5) Outbound email sending from Palate

If you want Palate to send email too, use the Resend API with `RESEND_API_KEY`.

Example outbound send request:

```bash
curl -X POST https://api.resend.com/emails   -H "Authorization: Bearer $RESEND_API_KEY"   -H "Content-Type: application/json"   -d '{
    "from":"Palate <onboarding@yourdomain.com>",
    "to":["user@example.com"],
    "subject":"Your reservation was added",
    "html":"<p>Your reservation at Niku was added to Palate.</p>"
  }'
```

This is separate from inbound email receiving.

---

## 6) Testing the webhook

### A. Use a real inbound email

Send a reservation email to the Resend inbound address.

### B. Check the Resend webhook dashboard

Confirm:

- the webhook fired
- the request succeeded
- the signing secret matches

### C. Check Supabase

Look at:

- `restaurants`
- `visits`
- `notifications`

If the data does not appear, the usual causes are:

- wrong webhook signing secret
- `verify_jwt` still enabled
- webhook endpoint URL incorrect
- the email does not contain enough reservation details
- the recipient email does not match a saved `contact_items.email`

---

## 7) Security checklist

- Keep `verify_jwt = false` only for `import-email`
- Verify the Resend webhook signature in the function
- Do not use a custom header secret that Resend is not sending
- Do not accept arbitrary JSON payloads for the email import route
- Do not store the raw full email body in visit notes

---

## 8) Common troubleshooting

### Unauthorized from Supabase
Check that `verify_jwt = false` is set for `import-email`.

### Unauthorized from the function
Check that the Resend webhook signing secret in the dashboard matches `RESEND_WEBHOOK_SECRET`.

### Webhook arrives but no rows are created
Check whether:
- the email is a reservation email
- the parser can find restaurant/date/phone/party size
- the recipient email exists in `contact_items`

### Email body looks empty
That is expected in the webhook payload. The function must fetch the full received email content from Resend using the `email_id`.

---

## 9) Recommended setup order

1. Set `RESEND_API_KEY`
2. Set `RESEND_WEBHOOK_SECRET`
3. Set `verify_jwt = false` for `import-email`
4. Deploy `import-email`
5. Add the webhook in Resend
6. Send a test reservation email
7. Confirm rows appear in Supabase
