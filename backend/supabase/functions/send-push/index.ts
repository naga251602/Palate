// supabase/functions/send-push/index.ts
// POST /functions/v1/send-push
// Internal — dispatches APNs push to a single user, or handles cron batch dispatch.

import { err, getServiceClient, handleCors, ok } from "../_shared/utils.ts";

interface SendPushRequest {
  // Direct push
  user_id?: string;
  title?: string;
  body?: string;
  data?: Record<string, unknown>;
  // Cron dispatch trigger
  type?: "cron_reminder_dispatch";
}

interface ApnsPayload {
  aps: {
    alert: { title: string; body: string };
    sound: string;
    badge?: number;
  };
  [key: string]: unknown;
}

Deno.serve(async (req) => {
  const cors = handleCors(req);
  if (cors) return cors;

  const supabase = getServiceClient();

  try {
    const body: SendPushRequest = await req.json();

    // ── Cron batch mode ────────────────────────────────────────────────────
    if (body.type === "cron_reminder_dispatch") {
      return await handleCronDispatch(supabase);
    }

    // ── Direct push mode ───────────────────────────────────────────────────
    const { user_id, title, body: msgBody, data } = body;
    if (!user_id || !title || !msgBody) {
      return err("user_id, title, and body are required");
    }

    const result = await pushToUser(supabase, user_id, title, msgBody, data ?? {});
    return ok(result);
  } catch (e) {
    console.error(e);
    return err(e instanceof Error ? e.message : "Internal error", 500);
  }
});

// ── Cron: find all due reminders and fire them ─────────────────────────────────
async function handleCronDispatch(supabase: ReturnType<typeof getServiceClient>) {
  const now = new Date();

  const { data: dueReservations } = await supabase
    .from("reservations")
    .select(`
      id, user_id, reservation_date, reservation_time, restaurant_id,
      restaurants(name),
      profiles!reservations_user_id_fkey(display_name),
      notification_preferences!inner(reservation_reminder, reminder_hours_before)
    `)
    .eq("reminder_sent", false)
    .is("cancelled_at", null)
    .eq("notification_preferences.reservation_reminder", true);

  if (!dueReservations?.length) return ok({ dispatched: 0 });

  let dispatched = 0;

  for (const res of dueReservations) {
    const hoursBeforeVal = (res as { notification_preferences?: { reminder_hours_before?: number }[] })
      .notification_preferences?.[0]?.reminder_hours_before ?? 3;
    const reservationDt = new Date(`${res.reservation_date}T${res.reservation_time}`);
    const fireAt = new Date(reservationDt.getTime() - hoursBeforeVal * 60 * 60 * 1000);

    if (now >= fireAt) {
      const restaurantName = (res as { restaurants?: { name?: string } }).restaurants?.name ?? "your reservation";

      await pushToUser(
        supabase,
        res.user_id,
        "Reservation Tonight 🍽️",
        `Your table at ${restaurantName} is in ${hoursBeforeVal} hour${hoursBeforeVal !== 1 ? "s" : ""}.`,
        { type: "reservation_reminder", restaurant_id: res.restaurant_id }
      );

      await supabase
        .from("reservations")
        .update({ reminder_sent: true })
        .eq("id", res.id);

      dispatched++;
    }
  }

  return ok({ dispatched });
}

// ── Core push logic ────────────────────────────────────────────────────────────
async function pushToUser(
  supabase: ReturnType<typeof getServiceClient>,
  userId: string,
  title: string,
  body: string,
  data: Record<string, unknown>
) {
  const { data: tokens, error: tokenErr } = await supabase
    .from("push_tokens")
    .select("id, device_token")
    .eq("user_id", userId)
    .eq("platform", "ios");

  if (tokenErr) {
    console.error(`[send-push] Error fetching tokens for user ${userId}:`, tokenErr);
  }

  if (!tokens?.length) {
    console.warn(`[send-push] No iOS push tokens found for user ${userId} — was the device token uploaded after login?`);
    return { sent: 0, user_id: userId };
  }

  console.log(`[send-push] Sending to ${tokens.length} token(s) for user ${userId}`);

  // Count unread notifications for badge
  const { count: unreadCount } = await supabase
    .from("notifications")
    .select("id", { count: "exact", head: true })
    .eq("user_id", userId)
    .eq("is_read", false);

  const apnsEnv = Deno.env.get("APNS_ENV") ?? "sandbox";
  const bundleId = Deno.env.get("APNS_BUNDLE_ID");

  if (!bundleId) {
    console.error("[send-push] APNS_BUNDLE_ID env var is not set — push will fail");
  }

  const apnsHost = apnsEnv === "production"
    ? "api.push.apple.com"
    : "api.sandbox.push.apple.com";

  console.log(`[send-push] Using APNs host: ${apnsHost}, bundleId: ${bundleId}`);

  const jwt = await buildApnsJwt();

  const payload: ApnsPayload = {
    aps: {
      alert: { title, body },
      sound: "default",
      badge: (unreadCount ?? 0) + 1,
    },
    ...data,
  };

  const expiredTokenIds: string[] = [];
  let sent = 0;

  for (const { id, device_token } of tokens) {
    try {
      const res = await fetch(`https://${apnsHost}/3/device/${device_token}`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": `Bearer ${jwt}`,
          "apns-topic": bundleId!,
          "apns-push-type": "alert",
          "apns-priority": "10",
        },
        body: JSON.stringify(payload),
      });

      if (res.status === 200) {
        sent++;
        console.log(`[send-push] ✓ Delivered to token …${device_token.slice(-8)}`);
      } else if (res.status === 410) {
        // Token is no longer valid
        expiredTokenIds.push(id);
        console.warn(`[send-push] Token …${device_token.slice(-8)} expired (410) — queued for removal`);
      } else {
        const errBody = await res.text();
        console.error(`[send-push] APNs ${res.status} for token …${device_token.slice(-8)}: ${errBody}`);
      }
    } catch (e) {
      console.error(`[send-push] Network error pushing to …${device_token.slice(-8)}:`, e);
    }
  }

  // Clean up expired tokens
  if (expiredTokenIds.length > 0) {
    await supabase.from("push_tokens").delete().in("id", expiredTokenIds);
    console.log(`[send-push] Removed ${expiredTokenIds.length} expired token(s)`);
  }

  return { sent, expired_removed: expiredTokenIds.length, user_id: userId };
}

// ── APNs JWT (ES256, valid 60 min) ─────────────────────────────────────────────
async function buildApnsJwt(): Promise<string> {
  const keyId = Deno.env.get("APNS_KEY_ID");
  const teamId = Deno.env.get("APNS_TEAM_ID");
  const p8Raw = Deno.env.get("APNS_PRIVATE_KEY");

  if (!keyId || !teamId || !p8Raw) {
    const missing = [!keyId && "APNS_KEY_ID", !teamId && "APNS_TEAM_ID", !p8Raw && "APNS_PRIVATE_KEY"]
      .filter(Boolean).join(", ");
    throw new Error(`[send-push] Missing required env vars: ${missing}`);
  }

  // The env var is often pasted with literal "\n" instead of real newlines.
  // Normalise both cases so the PEM parses correctly.
  const p8Normalised = p8Raw.replace(/\\n/g, "\n");

  const header = { alg: "ES256", kid: keyId };
  const now = Math.floor(Date.now() / 1000);
  const claims = { iss: teamId, iat: now };

  const encoder = new TextEncoder();
  const headerB64 = b64url(encoder.encode(JSON.stringify(header)));
  const claimsB64 = b64url(encoder.encode(JSON.stringify(claims)));
  const signingInput = `${headerB64}.${claimsB64}`;

  // Strip any PEM wrapper — Apple .p8 files are PKCS#8 but labelled "EC PRIVATE KEY"
  // or sometimes just "PRIVATE KEY". Strip whichever variant is present.
  const pemBody = p8Normalised
    .replace(/-----BEGIN (?:EC )?PRIVATE KEY-----/g, "")
    .replace(/-----END (?:EC )?PRIVATE KEY-----/g, "")
    .replace(/\s/g, "");

  if (!pemBody) {
    throw new Error("[send-push] APNS_PRIVATE_KEY is empty after stripping PEM headers");
  }

  let keyData: Uint8Array;
  try {
    keyData = Uint8Array.from(atob(pemBody), (c) => c.charCodeAt(0));
  } catch {
    throw new Error("[send-push] APNS_PRIVATE_KEY contains invalid base64 — check for copy/paste errors");
  }

  const key = await crypto.subtle.importKey(
    "pkcs8",
    keyData,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );

  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    encoder.encode(signingInput)
  );

  return `${signingInput}.${b64url(new Uint8Array(signature))}`;
}

function b64url(data: Uint8Array): string {
  // Use chunked approach to avoid stack overflow on large arrays with spread operator
  let binary = "";
  const chunkSize = 1024;
  for (let i = 0; i < data.length; i += chunkSize) {
    binary += String.fromCharCode(...data.subarray(i, i + chunkSize));
  }
  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}
