// supabase/functions/import-instagram/index.ts
// POST /functions/v1/import-instagram  — Meta Messenger webhook
//
// Two request types:
//   GET  ?hub.mode=subscribe&hub.verify_token=...&hub.challenge=...  → webhook verification
//   POST {object:"instagram", entry:[...]}                           → DM event
//
// Flow:
//   1. Verify webhook signature (X-Hub-Signature-256)
//   2. Extract sender's Instagram-scoped user ID + the shared post URL from the DM
//   3. Look up contact_items WHERE type='instagram' AND value matches the sender
//   4. Use Gemini to extract restaurant name + location hint from OG metadata
//   5. Yelp match → upsert restaurant → insert wishlist (saved_from='instagram')
//   6. Fire push notification to the matched user

import { err, getServiceClient, handleCors, ok, yelpFetch } from "../_shared/utils.ts";

// ─── Meta webhook verification (GET) ─────────────────────────────────────────

async function handleVerification(req: Request): Promise<Response> {
  const url = new URL(req.url);
  const mode      = url.searchParams.get("hub.mode");
  const token     = url.searchParams.get("hub.verify_token");
  const challenge = url.searchParams.get("hub.challenge");

  const verifyToken = Deno.env.get("INSTAGRAM_VERIFY_TOKEN");
  if (mode === "subscribe" && token === verifyToken && challenge) {
    console.log("[instagram] Webhook verified");
    return new Response(challenge, { status: 200 });
  }
  return err("Forbidden", 403);
}

// ─── HMAC-SHA256 signature verification ──────────────────────────────────────

async function verifySignature(req: Request, rawBody: string): Promise<boolean> {
  const appSecret = Deno.env.get("INSTAGRAM_APP_SECRET");
  if (!appSecret) {
    console.warn("[instagram] INSTAGRAM_APP_SECRET not set — skipping signature check");
    return true; // allow in dev; tighten in prod
  }

  const signature = req.headers.get("X-Hub-Signature-256") ?? "";
  const expected  = signature.replace("sha256=", "");

  const key    = await crypto.subtle.importKey("raw", new TextEncoder().encode(appSecret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac    = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(rawBody));
  const hex    = Array.from(new Uint8Array(mac)).map(b => b.toString(16).padStart(2, "0")).join("");

  return hex === expected;
}

// ─── Main handler ─────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  const cors = handleCors(req);
  if (cors) return cors;

  // Meta sends a GET for webhook registration
  if (req.method === "GET") return handleVerification(req);
  if (req.method !== "POST") return err("Method not allowed", 405);

  const rawBody = await req.text();

  // Verify signature
  const sigOk = await verifySignature(req, rawBody);
  if (!sigOk) return err("Unauthorized", 401);

  const supabase = getServiceClient();

  try {
    const payload = JSON.parse(rawBody) as MetaWebhookPayload;

    // We only care about Instagram DM message events
    if (payload.object !== "instagram") {
      return ok({ status: "ignored", reason: "not instagram object" });
    }

    const results = [];

    for (const entry of payload.entry ?? []) {
      for (const messaging of entry.messaging ?? []) {
        const result = await processMessage(messaging, supabase);
        results.push(result);
      }
    }

    return ok({ processed: results.length, results });
  } catch (e) {
    console.error("[instagram] handler error:", e);
    return err(e instanceof Error ? e.message : "Internal error", 500);
  }
});

// ─── Per-message processor ────────────────────────────────────────────────────

async function processMessage(
  messaging: MessagingEvent,
  supabase: ReturnType<typeof getServiceClient>
): Promise<ProcessResult> {

  const senderId = messaging.sender?.id;
  if (!senderId) return { status: "skipped", reason: "no sender id" };

  // ── Only handle messages that share an Instagram post ─────────────────────
  // When a user shares an Instagram post to your DM, it arrives as an
  // attachment of type "ig_reel", "share", or "story_mention",
  // with a payload.url pointing to the post.
  const attachment = messaging.message?.attachments?.[0];
  const sharedUrl  = extractInstagramUrl(messaging);

  if (!sharedUrl) {
    return { status: "skipped", reason: "no instagram post URL in message", sender: senderId };
  }

  // ── 1. Map sender IGSID → contact_items → user ────────────────────────────
  // Users save their Instagram handle or IGSID in contact_items (type='instagram').
  // We match on both the numeric IGSID and the username (handle).
  const { data: contactRows, error: contactErr } = await supabase
    .from("contact_items")
    .select("user_id, value")
    .eq("type", "instagram");

  if (contactErr) throw contactErr;

  // Normalize: strip leading @ from stored handles for comparison
  const normalize = (v: string) => v.trim().toLowerCase().replace(/^@/, "");

  // Try to resolve the sender's username from the IGSID via Graph API (optional enrichment)
  let senderUsername: string | null = null;
  try {
    senderUsername = await resolveUsernameFromIGSID(senderId);
  } catch (e) {
    console.warn("[instagram] Could not resolve username for IGSID", senderId, e);
  }

  const matched = (contactRows ?? []).find(row => {
    const v = normalize(row.value);
    if (v === normalize(senderId)) return true; // stored as IGSID
    if (senderUsername && v === normalize(senderUsername)) return true; // stored as handle
    return false;
  });

  if (!matched) {
    console.warn("[instagram] No contact_item match for sender:", senderId, senderUsername);
    return {
      status: "unmatched",
      reason: "sender not found in contact_items",
      sender: senderId,
      username: senderUsername,
    };
  }

  const userId = matched.user_id;

  // ── 2. Scrape OG metadata from the shared post URL ────────────────────────
  const { caption, ogLocation } = await scrapeOG(sharedUrl);
  const allText = [caption].filter(Boolean).join(" ");

  // ── 3. Gemini: extract restaurant name + location hint ────────────────────
  const extraction = await extractWithGemini(allText);

  if (!extraction.restaurant_name) {
    await notifyUser(supabase, userId, {
      type: "instagram_import_failed",
      title: "Couldn't identify restaurant",
      body: "We couldn't find a restaurant name in that post. Try tagging the restaurant directly.",
      metadata: { instagram_url: sharedUrl, caption: allText.slice(0, 300) },
    });
    return { status: "no_restaurant", sender: senderId, user_id: userId, url: sharedUrl };
  }

  // ── 4. Yelp search ────────────────────────────────────────────────────────
  const locationHint = extraction.location_hint ?? ogLocation ?? null;
  const yelpParams: Record<string, string | number> = {
    term: extraction.restaurant_name,
    limit: 5,
  };
  if (locationHint) {
    yelpParams.location = locationHint;
  } else {
    yelpParams.location = "Los Angeles, CA";
  }

  const yelpData  = await yelpFetch("/businesses/search", yelpParams);
  const businesses: YelpBusiness[] = yelpData.businesses ?? [];

  if (!businesses.length) {
    await notifyUser(supabase, userId, {
      type: "instagram_import_failed",
      title: "Restaurant not found on Yelp",
      body: `We found "${extraction.restaurant_name}" in the post but couldn't match it on Yelp.`,
      metadata: { instagram_url: sharedUrl, extracted_name: extraction.restaurant_name },
    });
    return { status: "no_yelp_match", sender: senderId, user_id: userId, extracted_name: extraction.restaurant_name };
  }

  const best = businesses[0];

  // ── 5. Upsert restaurant ──────────────────────────────────────────────────
  const { data: restaurant, error: upsertErr } = await supabase
    .from("restaurants")
    .upsert({
      yelp_id:       best.id,
      name:          best.name,
      address:       best.location?.address1  ?? null,
      city:          best.location?.city      ?? null,
      state:         best.location?.state     ?? null,
      country:       best.location?.country   ?? null,
      lat:           best.coordinates?.latitude  ?? null,
      lng:           best.coordinates?.longitude ?? null,
      phone:         best.display_phone       ?? null,
      price_range:   best.price               ?? null,
      cuisine_tags:  best.categories?.map(c => c.alias) ?? [],
      rating:        best.rating              ?? null,
      review_count:  best.review_count        ?? null,
      image_url:     best.image_url           ?? null,
      yelp_url:      best.url                 ?? null,
      last_synced_at: new Date().toISOString(),
    }, { onConflict: "yelp_id" })
    .select()
    .single();

  if (upsertErr || !restaurant) throw new Error("Restaurant upsert failed: " + upsertErr?.message);

  // ── 6. Upsert wishlist ────────────────────────────────────────────────────
  const { data: wishlistEntry } = await supabase
    .from("wishlists")
    .upsert(
      { user_id: userId, restaurant_id: restaurant.id, saved_from: "instagram" },
      { onConflict: "user_id,restaurant_id", ignoreDuplicates: true }
    )
    .select()
    .single();

  // ── 7. Audit log ──────────────────────────────────────────────────────────
  await supabase.from("instagram_imports").insert({
    user_id:        userId,
    sender_igsid:   senderId,
    sender_username: senderUsername,
    instagram_url:  sharedUrl,
    caption_text:   caption ?? null,
    extracted_name: extraction.restaurant_name,
    location_hint:  locationHint,
    restaurant_id:  restaurant.id,
  });

  // ── 8. Push notification ──────────────────────────────────────────────────
  await notifyUser(supabase, userId, {
    type: "instagram_import_success",
    title: `${restaurant.name} added to wishlist`,
    body: `Saved from Instagram post`,
    restaurant_id: restaurant.id,
    metadata: { instagram_url: sharedUrl, saved_from: "instagram" },
  });

  return {
    status: "saved",
    sender: senderId,
    user_id: userId,
    restaurant: { id: restaurant.id, name: restaurant.name },
    wishlist_entry: wishlistEntry ?? null,
  };
}

// ─── Extract Instagram post URL from a DM event ───────────────────────────────
// Meta sends shared posts as attachments. Handles:
//   - type "share"      → payload.url
//   - type "ig_reel"    → payload.url  
//   - type "story_mention" (the mention is your page, the post comes in payload.url)
//   - plain text message containing an instagram.com URL

function extractInstagramUrl(messaging: MessagingEvent): string | null {
  const attachments = messaging.message?.attachments ?? [];

  for (const att of attachments) {
    const url = att.payload?.url ?? att.payload?.reel_url ?? null;
    if (url && url.includes("instagram.com")) return url;
  }

  // Fallback: plain text message containing an IG link
  const text = messaging.message?.text ?? "";
  const match = text.match(/https?:\/\/(?:www\.)?instagram\.com\/[^\s]+/);
  return match?.[0] ?? null;
}

// ─── OG scraper ───────────────────────────────────────────────────────────────

async function scrapeOG(url: string): Promise<{ caption: string; ogLocation: string | null }> {
  try {
    const res = await fetch(url, {
      headers: {
        "User-Agent": "Mozilla/5.0 (compatible; Twitterbot/1.0)",
        "Accept-Language": "en-US,en;q=0.9",
      },
    });
    const html = await res.text();

    const ogDesc =
      html.match(/<meta[^>]+property="og:description"[^>]+content="([^"]+)"/i)?.[1] ??
      html.match(/<meta[^>]+content="([^"]+)"[^>]+property="og:description"/i)?.[1] ?? "";

    const ogTitle =
      html.match(/<meta[^>]+property="og:title"[^>]+content="([^"]+)"/i)?.[1] ??
      html.match(/<meta[^>]+content="([^"]+)"[^>]+property="og:title"/i)?.[1] ?? "";

    // Location embedded in description: "at Nobu • Beverly Hills"
    const locationMatch = ogDesc.match(/(?:at|@)\s+([A-Z][^•\n@#,]{3,50})\s*[•·]/);
    const ogLocation = locationMatch?.[1]?.trim() ?? null;

    return { caption: [ogTitle, ogDesc].filter(Boolean).join(" ").trim(), ogLocation };
  } catch (e) {
    console.warn("[instagram] OG scrape failed:", e);
    return { caption: "", ogLocation: null };
  }
}

// ─── Resolve username from Instagram-scoped ID via Graph API ──────────────────
// Requires instagram_manage_messages + pages_messaging permissions.
// Returns null silently if not configured.

async function resolveUsernameFromIGSID(igsid: string): Promise<string | null> {
  const pageToken = Deno.env.get("INSTAGRAM_PAGE_ACCESS_TOKEN");
  if (!pageToken) return null;

  const res = await fetch(
    `https://graph.facebook.com/v21.0/${igsid}?fields=username&access_token=${pageToken}`
  );
  if (!res.ok) return null;

  const data = await res.json();
  return data.username ?? null;
}

// ─── Gemini extraction ────────────────────────────────────────────────────────

interface GeminiInstagramExtraction {
  restaurant_name: string | null;
  location_hint: string | null;
}

async function extractWithGemini(text: string): Promise<GeminiInstagramExtraction> {
  const empty: GeminiInstagramExtraction = { restaurant_name: null, location_hint: null };
  if (!text.trim()) return empty;

  const apiKey = Deno.env.get("GEMINI_API_KEY");
  if (!apiKey) {
    console.warn("[gemini] GEMINI_API_KEY not set — using heuristic fallback");
    return heuristicExtract(text);
  }

  const model  = Deno.env.get("GEMINI_MODEL") ?? "gemini-2.0-flash";
  const apiUrl = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${apiKey}`;

  const prompt =
    `Extract the restaurant name and location from this Instagram post caption.\n` +
    `Look for: @mentions of restaurants, 📍 location pins, "at RestaurantName", tagged locations, capitalized business names.\n` +
    `If multiple places are mentioned, pick the one being reviewed/featured.\n` +
    `Return only the JSON object — no markdown, no explanation.\n\n` +
    `Caption:\n${text.slice(0, 2000)}`;

  const payload = {
    contents: [{ parts: [{ text: prompt }] }],
    generationConfig: {
      responseMimeType: "application/json",
      responseSchema: {
        type: "OBJECT",
        properties: {
          restaurant_name: { type: "STRING", description: "Clean restaurant name, empty string if none found" },
          location_hint:   { type: "STRING", description: "City, neighbourhood, or address fragment; empty string if none" },
        },
        required: ["restaurant_name", "location_hint"],
      },
    },
  };

  try {
    const res = await fetch(apiUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });

    const responseText = await res.text();
    if (!res.ok) {
      console.error("[gemini] API error", res.status, responseText.slice(0, 300));
      return heuristicExtract(text);
    }

    const json   = JSON.parse(responseText);
    const raw    = json?.candidates?.[0]?.content?.parts?.[0]?.text ?? "";
    const cleaned = raw.replace(/^```json\s*/i, "").replace(/```\s*$/i, "").trim();
    const parsed: GeminiInstagramExtraction = JSON.parse(cleaned);

    return {
      restaurant_name: parsed.restaurant_name?.trim() || null,
      location_hint:   parsed.location_hint?.trim()   || null,
    };
  } catch (e) {
    console.warn("[gemini] extraction failed, falling back:", e);
    return heuristicExtract(text);
  }
}

// ─── Heuristic fallback ───────────────────────────────────────────────────────

function heuristicExtract(text: string): GeminiInstagramExtraction {
  const atMention = text.match(/@([\w.]+)/)?.[1];
  if (atMention) return { restaurant_name: atMention.replace(/[._]/g, " ").trim(), location_hint: extractLocationHint(text) };

  const pin = text.match(/📍\s*([^#\n,]{3,50})/)?.[1]?.trim();
  if (pin) return { restaurant_name: pin, location_hint: extractLocationHint(text) };

  const atPhrase = text.match(/\bat\s+([A-Z][^#\n,.!?]{2,40})/)?.[1]?.trim();
  if (atPhrase) return { restaurant_name: atPhrase, location_hint: extractLocationHint(text) };

  return { restaurant_name: null, location_hint: null };
}

function extractLocationHint(text: string): string | null {
  return text.match(/([A-Z][a-z]+(?: [A-Z][a-z]+)?,\s*[A-Z]{2})/)?.[1]
    ?? text.match(/\bin\s+([A-Z][a-z]+(?: [A-Z][a-z]+){0,2})/)?.[1]
    ?? null;
}

// ─── Push notification helper ─────────────────────────────────────────────────

async function notifyUser(
  supabase: ReturnType<typeof getServiceClient>,
  userId: string,
  opts: { type: string; title: string; body: string; restaurant_id?: string; metadata?: Record<string, unknown> }
) {
  await supabase.from("notifications").insert({
    user_id:       userId,
    type:          opts.type,
    title:         opts.title,
    body:          opts.body,
    restaurant_id: opts.restaurant_id ?? null,
    source:        "instagram",
    metadata:      opts.metadata ?? {},
  });

  try {
    const supabaseUrl  = Deno.env.get("SUPABASE_URL")!;
    const serviceKey   = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    await fetch(`${supabaseUrl}/functions/v1/send-push`, {
      method:  "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${serviceKey}` },
      body:    JSON.stringify({ user_id: userId, title: opts.title, body: opts.body, data: { type: opts.type } }),
    });
  } catch (e) {
    console.warn("[instagram] send-push failed:", e);
  }
}

// ─── Types ────────────────────────────────────────────────────────────────────

interface MetaWebhookPayload {
  object: string;
  entry: {
    id: string;
    time: number;
    messaging: MessagingEvent[];
  }[];
}

interface MessagingEvent {
  sender:    { id: string };
  recipient: { id: string };
  timestamp: number;
  message?: {
    mid:  string;
    text?: string;
    attachments?: {
      type: string;
      payload: {
        url?:      string;
        reel_url?: string;
        title?:    string;
      };
    }[];
  };
}

type ProcessResult = Record<string, unknown>;

type YelpBusiness = {
  id:            string;
  name:          string;
  location?:     { address1?: string; city?: string; state?: string; country?: string };
  coordinates?:  { latitude?: number; longitude?: number };
  display_phone?: string;
  price?:        string;
  categories?:   { alias: string }[];
  rating?:       number;
  review_count?: number;
  image_url?:    string;
  url?:          string;
};
