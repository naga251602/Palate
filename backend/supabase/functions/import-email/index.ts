// supabase/functions/import-email/index.ts
// POST /functions/v1/import-email
// Resend inbound email webhook: fetch received email content, parse reservation details,
// map sender email to a user, optionally enrich with Yelp, then create visits + notifications.

import { Webhook } from "npm:svix";

import { extractEntities, extractReservationDebug, stripToPlainText } from "../_shared/reservationExtractor.ts";
import {
  err,
  getServiceClient,
  handleCors,
  normalizeEmail,
  ok,
  parseEmailList,
  yelpFetch,
} from "../_shared/utils.ts";

interface ImportEmailRequest {
  // Resend webhook support
  type?: string;
  data?: Record<string, unknown>;

  // Optional legacy/custom forwarded payload support
  from?: string | string[];
  to?: string | string[];
  cc?: string | string[];
  subject?: string;
  body?: string;
  sent_at?: string;
  yelp_id?: string;
  restaurant_name?: string;
  visit_date?: string;
  visit_time?: string;
  party_size?: number | string;
  notes?: string;
  logo_url?: string;
  location?: string;
}

interface ResendReceivedEmail {
  object?: string;
  id: string;
  to?: string[];
  from?: string;
  created_at?: string;
  subject?: string;
  html?: string | null;
  text?: string | null;
  headers?: Record<string, string>;
  bcc?: string[];
  cc?: string[];
  reply_to?: string[];
  message_id?: string;
  raw?: { download_url?: string; expires_at?: string } | null;
}

interface ParsedReservationDetails {
  restaurantName: string | null;
  address: string | null;
  phone: string | null;
  partySize: number | null;
  tableLabel: string | null;
  confirmationCode: string | null;
  visitDate: string | null;
  visitTime: string | null;
  parsedAt: string | null;
}

type YelpBusiness = {
  id: string;
  name: string;
  location?: {
    address1?: string;
    address2?: string;
    address3?: string;
    city?: string;
    state?: string;
    country?: string;
    zip_code?: string;
  };
  coordinates?: { latitude?: number; longitude?: number };
  display_phone?: string;
  price?: string;
  categories?: { alias: string; title?: string }[];
  rating?: number;
  review_count?: number;
  image_url?: string;
  url?: string;
  hours?: { open?: { day: number; start: string; end: string }[]; is_open_now?: boolean }[];
};

const RESERVATION_HINTS = [
  "reservation",
  "reserved",
  "booking",
  "booked",
  "table",
  "confirmed",
  "confirmation",
  "dinner",
  "lunch",
  "brunch",
  "restaurant",
  "dining",
  "your table",
  "your reservation",
  "reservation details",
];

const COMMON_NON_RESTAURANT_WORDS = new Set([
  "reservation",
  "confirmed",
  "confirmation",
  "table",
  "booking",
  "guest",
  "guests",
  "party",
  "size",
  "restaurant",
  "dining",
  "dinner",
  "lunch",
  "brunch",
  "your",
  "visit",
  "date",
  "time",
  "code",
  "number",
  "phone",
  "address",
  "location",
  "name",
]);

Deno.serve(async (req) => {
  const cors = handleCors(req);
  if (cors) return cors;

  const supabase = getServiceClient();

  try {
    if (req.method !== "POST") return err("Method not allowed", 405);

    const webhookSecret = Deno.env.get("RESEND_WEBHOOK_SECRET") ?? Deno.env.get("EMAIL_WEBHOOK_SECRET");
    if (!webhookSecret) {
      return err("RESEND_WEBHOOK_SECRET is not configured", 500);
    }

    const rawBody = await req.text();
    const signature = req.headers.get("svix-signature");
    const timestamp = req.headers.get("svix-timestamp");
    const id = req.headers.get("svix-id");
    if (!signature || !timestamp || !id) {
      return err("Unauthorized", 401);
    }

    let rawPayload: ImportEmailRequest;
    try {
      const webhook = new Webhook(webhookSecret);
      rawPayload = webhook.verify(rawBody, {
        "svix-id": id,
        "svix-timestamp": timestamp,
        "svix-signature": signature,
      }) as ImportEmailRequest;
    } catch {
      return err("Unauthorized", 401);
    }

    if (!isSupportedInboundPayload(rawPayload)) {
      return err("Unsupported email payload", 400);
    }

    const { envelope, parsedText, rawText } = await normalizeInboundEmail(rawPayload);

    const senderEmails = parseEmailList(envelope.from);
    if (!senderEmails.length) {
      return new Response(
        JSON.stringify({
          error: "At least one sender email is required",
          debug: { source: "resend.email.received", sender: senderEmails },
        }),
        { status: 400, headers: { "Content-Type": "application/json" } },
      );
    }

    const { data: contactRows, error: contactErr } = await supabase
      .from("contact_items")
      .select("user_id, type, value, is_primary, created_at")
      .eq("type", "email");
    if (contactErr) throw contactErr;

    const normalizedSender = new Set(senderEmails.map(normalizeEmail));
    const matches = (contactRows ?? []).filter((row) => normalizedSender.has(normalizeEmail(row.value)));

    if (!matches.length) {
      return new Response(
        JSON.stringify({
          error: "No user matched the sender email address",
          debug: buildDebugPayload({
            envelope,
            parsedText,
            details: (await parseReservationDetails(rawText, envelope.sent_at ?? null)).details,
            visitType: "visited",
            visitDate: new Date().toISOString().slice(0, 10),
            visitTime: null,
            userId: null,
            restaurant: null,
            yelp: null,
          }),
        }),
        { status: 404, headers: { "Content-Type": "application/json" } },
      );
    }

    const userId = pickBestMatch(matches)?.user_id;
    if (!userId) {
      return new Response(
        JSON.stringify({
          error: "No user matched the sender email address",
          debug: buildDebugPayload({
            envelope,
            parsedText,
            details: (await parseReservationDetails(rawText, envelope.sent_at ?? null)).details,
            visitType: "visited",
            visitDate: new Date().toISOString().slice(0, 10),
            visitTime: null,
            userId: null,
            restaurant: null,
            yelp: null,
          }),
        }),
        { status: 404, headers: { "Content-Type": "application/json" } },
      );
    }

    const { details, geminiRaw, geminiError: geminiErr, cleanText: geminiCleanText, brand: emailBrand } = await parseReservationDetails(rawText, envelope.sent_at ?? envelope.created_at ?? null);

    const signalText = [envelope.subject ?? "", parsedText].filter(Boolean).join("\n\n");

    if (!hasMeaningfulReservationSignals(signalText) && !hasCoreReservationDetails(details)) {
      return err("Email does not look like a restaurant reservation or visit import", 400);
    }

    const { restaurant, unsupported } = await resolveRestaurant(supabase, {
      ...envelope,
      restaurant_name: envelope.restaurant_name ?? details.restaurantName ?? undefined,
      location: envelope.location ?? details.address ?? undefined,
    }, details, parsedText);

    // ── Unsupported format: notify user and bail out ───────────────────────
    if (unsupported) {
      const unsupportedTitle = "Email format not supported";
      const unsupportedBody = "We couldn't reliably read the restaurant name or address from this email. Please log manually.";

      // Diagnose exactly why it went unsupported
      const unsupportedReason = !details.restaurantName
        ? "gemini_returned_no_restaurant_name"
        : !details.address && !details.restaurantName
        ? "gemini_returned_no_name_and_no_address"
        : isGarbageRestaurantName(details.restaurantName ?? "")
        ? `garbage_name: "${details.restaurantName}"`
        : "yelp_all_tiers_failed_no_address";

      await supabase.from("notifications").insert({
        user_id: userId,
        type: "email_import_failed",
        title: unsupportedTitle,
        body: unsupportedBody,
        restaurant_id: null,
        visit_id: null,
        logo_url: null,
        source: "email",
        metadata: {
          source: "resend.email.received",
          subject: envelope.subject ?? null,
          sender: parseEmailList(envelope.from),
          reason: "unsupported_format",
          parsed_excerpt: parsedText.slice(0, 500),
        },
      });

      // Fire push for the unsupported-format notification too
      try {
        const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
        const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
        await fetch(`${supabaseUrl}/functions/v1/send-push`, {
          method: "POST",
          headers: { "Content-Type": "application/json", "Authorization": `Bearer ${serviceKey}` },
          body: JSON.stringify({
            user_id: userId,
            title: unsupportedTitle,
            body: unsupportedBody,
            data: { type: "email_import_failed" },
          }),
        });
      } catch (pushErr) {
        console.warn("[import-email] send-push (unsupported) failed:", pushErr);
      }

      return ok({
        mapped_user_id: userId,
        status: "unsupported_format",
        message: "Could not parse restaurant name or address from this email. Notification sent to user.",
        debug: {
          unsupported_reason: unsupportedReason,
          email_brand: emailBrand,
          gemini_clean_text_length: geminiCleanText.length,
          gemini_clean_text_preview: geminiCleanText.slice(0, 800),
          gemini_raw_response: geminiRaw,
          gemini_error: geminiErr ?? null,
          details_from_gemini: {
            restaurantName:   details.restaurantName,
            address:          details.address,
            phone:            details.phone,
            partySize:        details.partySize,
            confirmationCode: details.confirmationCode,
            visitDate:        details.visitDate,
            visitTime:        details.visitTime,
          },
        },
      });
    }

    const reservationDateTime = parseVisitDateTime(
      details.visitDate,
      details.visitTime,
      envelope.sent_at ?? envelope.created_at ?? null,
    );

    const now = new Date();
    const visitType: "visited" | "upcoming" = reservationDateTime && reservationDateTime.getTime() > now.getTime()
      ? "upcoming"
      : "visited";

    const visitDate = reservationDateTime
      ? reservationDateTime.toISOString().slice(0, 10)
      : normalizeDate(envelope.visit_date ?? envelope.sent_at ?? new Date().toISOString());

    const visitTime = reservationDateTime
      ? reservationDateTime.toISOString().slice(11, 16)
      : normalizeTime(envelope.visit_time ?? null);

    const notes = buildVisitNotes({
      restaurantName: restaurant.name,
      address: details.address ?? restaurant.address ?? null,
      phone: details.phone ?? restaurant.phone ?? null,
      partySize: details.partySize,
      tableLabel: details.tableLabel,
      confirmationCode: details.confirmationCode,
      visitType,
      visitDate,
      visitTime,
    });

    const { data: visit, error: visitErr } = await supabase
      .from("visits")
      .insert({
        user_id: userId,
        restaurant_id: restaurant.id,
        visit_type: visitType,
        visit_date: visitDate,
        visit_time: visitTime ?? null,
        party_size: details.partySize ?? (typeof envelope.party_size === "number" ? envelope.party_size : (typeof envelope.party_size === "string" ? safeInt(envelope.party_size) : null)),
        rating: null,
        notes,
        source: "email",
      })
      .select()
      .single();
    if (visitErr) throw visitErr;

    if (visitType === "visited") {
      const { data: profile } = await supabase
        .from("profiles")
        .select("total_visits")
        .eq("id", userId)
        .single();

      await supabase
        .from("profiles")
        .update({ total_visits: (profile?.total_visits ?? 0) + 1 })
        .eq("id", userId);
    }

    const title = `${restaurant.name} - sent from email`;
    const bodyText = visitType === "upcoming"
      ? "Added to Next Up"
      : "Added to Previously Visited";

    const debug = buildDebugPayload({
      envelope,
      parsedText,
      details,
      visitType,
      visitDate,
      visitTime,
      userId,
      restaurant: restaurant ? {
        id: restaurant.id,
        name: restaurant.name,
        address: restaurant.address,
        phone: restaurant.phone,
      } : null,
      yelp: restaurant?.yelp_id?.startsWith("email:") ? null : {
        yelp_id: restaurant.yelp_id,
        name: restaurant.name,
        tier: (restaurant as Record<string, unknown>)._yelpTier as string ?? null,
      },
    });

    await supabase.from("notifications").insert({
      user_id: userId,
      type: "email_import",
      title,
      body: bodyText,
      restaurant_id: restaurant.id,
      visit_id: visit.id,
      logo_url: envelope.logo_url ?? restaurant.image_url ?? null,
      source: "email",
      metadata: {
        ...debug,
        source: "email",
        visit_type: visitType,
      },
    });

    // ── Fire a real APNs push so the user sees it on their lock screen ─────
    // We call send-push internally using the service role key.
    // Errors are non-fatal — the visit and notification are already committed.
    try {
      const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
      const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
      await fetch(`${supabaseUrl}/functions/v1/send-push`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": `Bearer ${serviceKey}`,
        },
        body: JSON.stringify({
          user_id: userId,
          title,
          body: bodyText,
          data: {
            type: "email_import",
            restaurant_id: restaurant.id,
            visit_id: visit.id,
            visit_type: visitType,
          },
        }),
      });
    } catch (pushErr) {
      console.warn("[import-email] send-push failed (non-fatal):", pushErr);
    }

    return ok({
      mapped_user_id: userId,
      restaurant: {
        id: restaurant.id,
        name: restaurant.name,
        address: restaurant.address,
        phone: restaurant.phone,
        image_url: restaurant.image_url ?? null,
        yelp_id: restaurant.yelp_id,
      },
      visit,
      notification: {
        title,
        body: bodyText,
        logo_url: envelope.logo_url ?? restaurant.image_url ?? null,
      },
      parsed: {
        restaurant_name: details.restaurantName,
        address: details.address,
        phone: details.phone,
        party_size: details.partySize,
        table_label: details.tableLabel,
        confirmation_code: details.confirmationCode,
        visit_date: visitDate,
        visit_time: visitTime,
        visit_type: visitType,
      },
      debug,
    });
  } catch (e) {
    console.error(e);
    return err(e instanceof Error ? e.message : "Internal error", 500);
  }
});

async function normalizeInboundEmail(rawPayload: ImportEmailRequest) {
  const emailId = typeof rawPayload.data?.email_id === "string" ? rawPayload.data.email_id : null;
  if (!emailId) throw new Error("email_id is required for Resend inbound emails");

  const receivedEmail = await fetchReceivedEmail(emailId);
  const to = parseEmailList(receivedEmail.to ?? []);
  const cc = parseEmailList(receivedEmail.cc ?? []);
  const recipients = [...to, ...cc];

  // rawText is the unprocessed combined email content.
  // We pass this to parseReservationDetails → extractReservationDebug which
  // calls stripToPlainText internally. Using the pre-normalised content here
  // caused double-stripping that corrupted structured fields like
  // "Reservation date: May 20 at 7:30 PM".
  const rawText = [
    receivedEmail.text ?? "",
    receivedEmail.html ?? "",
  ].filter(Boolean).join("\n\n");

  // parsedText (display-safe normalized text) is used for signal detection and
  // excerpt logging — NOT for the structured field extractor.
  const parsedText = normalizeContent([
    receivedEmail.text ?? "",
    stripHtml(receivedEmail.html ?? ""),
  ].filter(Boolean).join("\n\n"));

  return {
    envelope: {
      from: receivedEmail.from ?? (typeof rawPayload.data?.from === "string" ? rawPayload.data.from : undefined),
      to: receivedEmail.to ?? (Array.isArray(rawPayload.data?.to) ? rawPayload.data.to as string[] : undefined),
      cc: receivedEmail.cc ?? (Array.isArray(rawPayload.data?.cc) ? rawPayload.data.cc as string[] : undefined),
      subject: receivedEmail.subject ?? (typeof rawPayload.data?.subject === "string" ? rawPayload.data.subject : undefined),
      body: receivedEmail.text ?? stripHtml(receivedEmail.html ?? ""),
      sent_at: receivedEmail.created_at ?? (typeof rawPayload.data?.["created_at"] === "string" ? rawPayload.data["created_at"] as string : undefined),
      location: typeof rawPayload.data?.location === "string" ? rawPayload.data.location : undefined,
      restaurant_name: typeof rawPayload.data?.restaurant_name === "string" ? rawPayload.data.restaurant_name : undefined,
      yelp_id: typeof rawPayload.data?.yelp_id === "string" ? rawPayload.data.yelp_id : undefined,
      visit_date: typeof rawPayload.data?.visit_date === "string" ? rawPayload.data.visit_date : undefined,
      visit_time: typeof rawPayload.data?.visit_time === "string" ? rawPayload.data.visit_time : undefined,
      party_size: typeof rawPayload.data?.party_size === "string" || typeof rawPayload.data?.party_size === "number"
        ? rawPayload.data.party_size as string | number
        : undefined,
      logo_url: typeof rawPayload.data?.logo_url === "string" ? rawPayload.data.logo_url : undefined,
      notes: typeof rawPayload.data?.notes === "string" ? rawPayload.data.notes : undefined,
    } as ImportEmailRequest,
    parsedText,
    rawText,
    recipients,
  };
}

async function fetchReceivedEmail(emailId: string): Promise<ResendReceivedEmail> {
  const apiKey = Deno.env.get("RESEND_API_KEY");
  if (!apiKey) throw new Error("RESEND_API_KEY is not configured");

  const res = await fetch(`https://api.resend.com/emails/receiving/${encodeURIComponent(emailId)}`, {
    headers: {
      Authorization: `Bearer ${apiKey}`,
      Accept: "application/json",
    },
  });

  if (!res.ok) {
    throw new Error(`Failed to fetch received email ${res.status}: ${await res.text()}`);
  }

  return await res.json() as ResendReceivedEmail;
}

function isSupportedInboundPayload(rawPayload: ImportEmailRequest): boolean {
  if (!rawPayload || typeof rawPayload !== "object") return false;
  return rawPayload.type === "email.received"
    && typeof rawPayload.data === "object"
    && rawPayload.data !== null
    && typeof rawPayload.data.email_id === "string"
    && rawPayload.data.email_id.trim().length > 0;
}

async function resolveRestaurant(
  supabase: ReturnType<typeof getServiceClient>,
  body: ImportEmailRequest,
  details: ParsedReservationDetails,
  parsedText: string,
): Promise<{ restaurant: Record<string, unknown>; unsupported: boolean }> {
  // ── 1. Name resolution ─────────────────────────────────────────────────
  // details.restaurantName is Gemini's output — trust it as the primary source.
  // Only fall back to subject-line heuristics if Gemini returned nothing.
  // Do NOT re-run extractRestaurantFromLines here — it scans raw email lines
  // with regex and routinely picks up garbage ("Confirmed", "10:00 PM", etc.)
  // which then fails isGarbageRestaurantName and incorrectly returns unsupported.
  const candidateName =
    details.restaurantName ||          // Gemini's answer — primary source
    body.restaurant_name ||            // explicit override in webhook payload
    extractRestaurantFromSubject(body.subject ?? ""); // subject-line fallback only

  const restaurantName = cleanupRestaurantCandidate(candidateName ?? "");

  // ── 2. Validate the name isn't garbage ─────────────────────────────────
  // Reject names that are clearly not restaurant names:
  //   • pure numbers or time strings ("10", "7:30", "10 minutes")
  //   • generic booking words ("Table For 2", "Party of 4")
  //   • very short tokens that slipped through
  if (!restaurantName || isGarbageRestaurantName(restaurantName)) {
    console.warn(`[import-email] Extracted name "${restaurantName}" looks like garbage — treating as unsupported`);
    return { restaurant: await insertUnsupportedPlaceholder(supabase, body, details), unsupported: true };
  }

  const address = details.address ?? body.location ?? null;
  const phone = details.phone ?? null;

  // ── 3. Yelp verification waterfall ─────────────────────────────────────
  //
  //   Tier 1: name + full address  (most specific, lower score bar)
  //   Tier 2: name + city/state extracted from address
  //   Tier 3: name + every city/state hint found in email body
  //   → any tier hit → upsert the Yelp-enriched restaurant row
  //   → all tiers miss + no address → unsupported format
  //   → all tiers miss + address known → store synthetic record
  //
  const yelp = await lookupYelpBusiness(restaurantName, address, parsedText);

  if (yelp.business) {
    const business = yelp.business;
    const restaurantData = {
      yelp_id: business.id,
      name: business.name,
      address: business.location?.address1 ?? address,
      city: business.location?.city ?? null,
      state: business.location?.state ?? null,
      country: business.location?.country ?? null,
      lat: business.coordinates?.latitude ?? null,
      lng: business.coordinates?.longitude ?? null,
      phone: business.display_phone ?? phone,
      price_range: business.price ?? null,
      cuisine_tags: (business.categories ?? []).map((c) => c.alias),
      rating: business.rating ?? null,
      review_count: business.review_count ?? null,
      image_url: business.image_url ?? body.logo_url ?? null,
      yelp_url: business.url ?? null,
      hours: parseHours(business.hours),
      is_open_now: business.hours?.[0]?.is_open_now ?? null,
      last_synced_at: new Date().toISOString(),
    };

    const { data: restaurant, error } = await supabase
      .from("restaurants")
      .upsert(restaurantData, { onConflict: "yelp_id" })
      .select()
      .single();
    if (error) throw error;
    // Attach yelp tier to restaurant for debug logging downstream
    return { restaurant: { ...restaurant, _yelpTier: yelp.tier }, unsupported: false };
  }

  // ── 4. All Yelp tiers failed ─────────────────────────────────────────────
  // If we have no Yelp match AND no address, the name alone is too unreliable
  // to store — fire unsupported-format notification.
  if (!address) {
    console.warn(
      `[import-email] All Yelp tiers failed, no address for "${restaurantName}" — unsupported format`
    );
    return { restaurant: await insertUnsupportedPlaceholder(supabase, body, details), unsupported: true };
  }

  // ── 5. Synthetic record (name + address known, no Yelp) ─────────────────
  const syntheticKey = buildSyntheticRestaurantKey({
    restaurantName,
    address,
    phone,
    visitDate: details.visitDate,
    confirmationCode: details.confirmationCode,
  });

  const restaurantData = {
    yelp_id: syntheticKey,
    name: restaurantName,
    address,
    city: null,
    state: null,
    country: null,
    lat: null,
    lng: null,
    phone,
    price_range: null,
    cuisine_tags: [],
    rating: null,
    review_count: null,
    image_url: body.logo_url ?? null,
    yelp_url: null,
    hours: null,
    is_open_now: null,
    last_synced_at: new Date().toISOString(),
  };

  const { data: restaurant, error } = await supabase
    .from("restaurants")
    .upsert(restaurantData, { onConflict: "yelp_id" })
    .select()
    .single();
  if (error) throw error;
  return { restaurant, unsupported: false };
}

/**
 * Returns true for strings that clearly are not restaurant names.
 * This catches things like "10 minutes", "7:30 PM", "Table For 2",
 * "Party of 4", "2 Guests", bare numbers, single generic words, etc.
 */
function isGarbageRestaurantName(name: string): boolean {
  const n = name.trim();
  if (!n || n.length < 3) return true;

  // Pure number
  if (/^\d+$/.test(n)) return true;

  // Time string: "7:30", "7:30 PM", "19:00"
  if (/^\d{1,2}:\d{2}(\s*(am|pm))?$/i.test(n)) return true;

  // Duration: "10 minutes", "2 hours", "30 min"
  if (/^\d+\s+(minute|hour|day|min|hr|sec)s?$/i.test(n)) return true;

  // Date-only fragments: "May 20", "20th", "Monday"
  if (/^(monday|tuesday|wednesday|thursday|friday|saturday|sunday)$/i.test(n)) return true;
  if (/^(january|february|march|april|may|june|july|august|september|october|november|december)\s+\d{1,2}(st|nd|rd|th)?$/i.test(n)) return true;
  if (/^\d{1,2}(st|nd|rd|th)?\s+(january|february|march|april|may|june|july|august|september|october|november|december)$/i.test(n)) return true;

  // Booking form labels: "Table For 2", "Party of 4", "2 Guests", "For 4 People"
  if (/^(table\s+for|party\s+of|for\s+\d|\d+\s+(guest|person|people|cover|diner))/i.test(n)) return true;

  // Starts with a number followed by words (e.g. "2 Adults", "4 People", "10 West")
  // Exception: street addresses like "123 Main St" — but those get caught by extractAddress
  if (/^\d+\s+[a-z]/i.test(n) && !/\b(st|ave|blvd|rd|dr|ln|ct|way|pl)\b/i.test(n)) return true;

  // Generic single words that slipped through cleanupRestaurantCandidate
  const lower = n.toLowerCase();
  if (COMMON_NON_RESTAURANT_WORDS.has(lower)) return true;

  // Looks like a URL fragment or email
  if (/[@.]/.test(n) && !/[&']/.test(n)) return true;

  // All-caps short abbreviation (likely a status code, not a name)
  if (/^[A-Z]{2,6}$/.test(n)) return true;

  // Looks like a confirmation code (all alphanumeric, 4-10 chars, no spaces)
  if (/^[A-Z0-9]{4,10}$/.test(n)) return true;

  return false;
}

/**
 * Creates or finds a sentinel restaurant row used when the email format
 * is too ambiguous to extract a real restaurant name + address.
 */
async function insertUnsupportedPlaceholder(
  supabase: ReturnType<typeof getServiceClient>,
  body: ImportEmailRequest,
  details: ParsedReservationDetails,
) {
  // Use a stable synthetic key so we don't create duplicates on re-delivery
  const subject = (body.subject ?? "unknown").slice(0, 60);
  const key = `email:unsupported|subj:${subject
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80)}`;

  const { data, error } = await supabase
    .from("restaurants")
    .upsert({
      yelp_id: key,
      name: "Unknown Restaurant",
      address: details.address ?? null,
      city: null, state: null, country: null,
      lat: null, lng: null, phone: details.phone ?? null,
      price_range: null, cuisine_tags: [],
      rating: null, review_count: null,
      image_url: null, yelp_url: null,
      hours: null, is_open_now: null,
      last_synced_at: new Date().toISOString(),
    }, { onConflict: "yelp_id" })
    .select()
    .single();
  if (error) throw error;
  return data;
}

// Minimum name-similarity score before we accept a Yelp result.
// Score breakdown: exact=100, substring=60, per-word-overlap=10 each.
// A score of 0 means no name overlap at all — always reject that.
// ── Yelp verification waterfall ───────────────────────────────────────────────
//
// Tier 1: name + full address  → highest confidence, most specific
// Tier 2: name + city/state    → medium confidence
// Tier 3: name only (all city/state hints from text) → lower confidence
// Each tier requires a minimum name-similarity score to accept the result.
// If all tiers fail → caller treats as unsupported format.
//
// This mirrors the requirement: verify with {name + address}, then
// {name only}, then give up and fire "unsupported format" notification.
// ──────────────────────────────────────────────────────────────────────────────

const MIN_SCORE_WITH_ADDRESS = 20;  // Tier 1+2: address pins us to the right area, lower bar
const MIN_SCORE_NAME_ONLY    = 40;  // Tier 3: no address context, require stronger name match

type YelpTier = "name+address" | "name+city" | "name-only";

interface YelpLookupResult {
  business:     YelpBusiness | null;
  locationUsed: string | null;
  tier:         YelpTier | null;
}

async function lookupYelpBusiness(
  restaurantName: string,
  address: string | null,
  rawText: string,
): Promise<YelpLookupResult> {
  const queryName = cleanupRestaurantCandidate(restaurantName) ?? restaurantName;

  // ── Tier 1: full address ────────────────────────────────────────────────
  if (address) {
    const cleanedAddress = cleanupAddressCandidate(address);
    if (cleanedAddress) {
      const r = await yelpSearch(queryName, cleanedAddress, MIN_SCORE_WITH_ADDRESS);
      if (r) {
        console.log(`[yelp] Tier 1 hit (name+address): "${r.name}" @ "${cleanedAddress}"`);
        return { business: r, locationUsed: cleanedAddress, tier: "name+address" };
      }
    }

    // ── Tier 2: city/state extracted from address ───────────────────────
    const cityStateFromAddr = extractCityStateHint(cleanupAddressCandidate(address) ?? address);
    if (cityStateFromAddr) {
      const r = await yelpSearch(queryName, cityStateFromAddr, MIN_SCORE_WITH_ADDRESS);
      if (r) {
        console.log(`[yelp] Tier 2 hit (name+city from address): "${r.name}" @ "${cityStateFromAddr}"`);
        return { business: r, locationUsed: cityStateFromAddr, tier: "name+city" };
      }
    }
  }

  // ── Tier 3: name only — try every city/state hint found in the email ───
  // Higher score threshold because there's no address anchor.
  const cityStateHints = buildCityStateHints(rawText);
  for (const hint of cityStateHints) {
    const r = await yelpSearch(queryName, hint, MIN_SCORE_NAME_ONLY);
    if (r) {
      console.log(`[yelp] Tier 3 hit (name+text-hint): "${r.name}" @ "${hint}"`);
      return { business: r, locationUsed: hint, tier: "name-only" };
    }
  }

  console.warn(`[yelp] All tiers failed for "${queryName}" — no confident match found`);
  return { business: null, locationUsed: null, tier: null };
}

/** Searches Yelp and returns the best business only if it meets the score threshold. */
async function yelpSearch(
  queryName: string,
  location: string,
  minScore: number,
): Promise<YelpBusiness | null> {
  try {
    const search = await yelpFetch("/businesses/search", {
      term: queryName,
      location,
      limit: 5,
      sort_by: "best_match",
    });

    const businesses = Array.isArray(search?.businesses) ? search.businesses as YelpBusiness[] : [];
    if (!businesses.length) return null;

    const { business: chosen, score } = chooseBestBusinessWithScore(businesses, queryName);
    if (!chosen?.id) return null;

    if (score < minScore) {
      console.log(
        `[yelp] Candidate "${chosen.name}" scored ${score.toFixed(1)} < threshold ${minScore} for query "${queryName}" @ "${location}" — skipping`
      );
      return null;
    }

    // Fetch full detail to get hours, photos, etc.
    const details = await yelpFetch(`/businesses/${chosen.id}`) as YelpBusiness;
    return { ...details, hours: details.hours ?? chosen.hours ?? [] };
  } catch (error) {
    const msg = error instanceof Error ? error.message : String(error);
    if (/LOCATION_NOT_FOUND|not found|Could not execute search/i.test(msg)) return null;
    throw error;
  }
}

/** Returns city/state strings found anywhere in the email text. */
function buildCityStateHints(text: string): string[] {
  const hints = new Set<string>();

  // "Los Angeles, CA" / "Los Angeles, CA 90012"
  const re1 = /([A-Za-z][A-Za-z .'\-]{1,40}),\s*([A-Z]{2})(?:\s+\d{5}(?:-\d{4})?)?/g;
  let m: RegExpExecArray | null;
  while ((m = re1.exec(text)) !== null) {
    hints.add(m[0].trim());
    // Also add just "City, ST" without zip
    hints.add(`${m[1].trim()}, ${m[2].trim()}`);
  }

  return [...hints].filter(Boolean);
}

function extractCityStateHint(text: string): string | null {
  if (!text) return null;
  const hints = buildCityStateHints(text);
  return hints[0] ?? null;
}

function chooseBestBusinessWithScore(
  businesses: YelpBusiness[],
  queryName: string,
): { business: YelpBusiness; score: number } {
  const normalizedQuery = normalizeRestaurantName(queryName);

  const scored = businesses.map((business) => {
    const normalizedBusiness = normalizeRestaurantName(business.name);
    let score = 0;

    if (normalizedBusiness === normalizedQuery) score += 100;
    else if (
      normalizedBusiness.includes(normalizedQuery) ||
      normalizedQuery.includes(normalizedBusiness)
    ) score += 60;

    // Word overlap (ignore short filler words like "at", "the", "of")
    const queryWords    = normalizedQuery.split(" ").filter((w) => w.length > 2);
    const businessWords = normalizedBusiness.split(" ").filter(Boolean);
    const overlap = queryWords.filter((w) => businessWords.includes(w)).length;
    score += overlap * 10;

    // Small review-count boost — only within already name-matched results
    if (score > 0 && (business.review_count ?? 0) > 0) {
      score += Math.min((business.review_count ?? 0) / 1000, 5);
    }

    return { business, score };
  });

  scored.sort((a, b) => b.score - a.score);
  return { business: scored[0]?.business ?? businesses[0], score: scored[0]?.score ?? 0 };
}

function chooseBestBusiness(businesses: YelpBusiness[], queryName: string): YelpBusiness {
  return chooseBestBusinessWithScore(businesses, queryName).business;
}

function normalizeRestaurantName(input: string): string {
  return cleanupRestaurantCandidate(input)
    ?.toLowerCase()
    .replace(/[^a-z0-9\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim() ?? "";
}

function buildSyntheticRestaurantKey(input: {
  restaurantName: string;
  address: string | null;
  phone: string | null;
  visitDate?: string | null;
  confirmationCode?: string | null;
}) {
  const slug = (value: string | null | undefined) => (value ?? "")
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80);

  const parts = [
    `name:${slug(input.restaurantName)}`,
    input.address ? `addr:${slug(input.address)}` : null,
    input.phone ? `phone:${slug(input.phone)}` : null,
    input.visitDate ? `date:${slug(input.visitDate)}` : null,
    input.confirmationCode ? `conf:${slug(input.confirmationCode)}` : null,
  ].filter(Boolean);

  return `email:${parts.join("|")}`;
}

function pickBestMatch(matches: { user_id: string; is_primary?: boolean; created_at?: string }[]) {
  return [...matches].sort((a, b) => {
    if (a.is_primary && !b.is_primary) return -1;
    if (!a.is_primary && b.is_primary) return 1;
    const aTime = a.created_at ? Date.parse(a.created_at) : 0;
    const bTime = b.created_at ? Date.parse(b.created_at) : 0;
    return aTime - bTime;
  })[0];
}

function hasCoreReservationDetails(details: ParsedReservationDetails): boolean {
  return Boolean(
    details.restaurantName
      || details.address
      || details.phone
      || details.partySize
      || details.tableLabel
      || details.confirmationCode
      || details.visitDate,
  );
}

function hasMeaningfulReservationSignals(text: string): boolean {
  const cleaned = text.toLowerCase();
  return RESERVATION_HINTS.some((hint) => cleaned.includes(hint))
    || Boolean(extractConfirmationCode(cleaned))
    || Boolean(extractPartySize(cleaned))
    || Boolean(extractRestaurantName(cleaned))
    || Boolean(extractAddress(cleaned))
    || Boolean(extractPhone(cleaned))
    || Boolean(extractDateTime(cleaned));
}


// ─────────────────────────────────────────────────────────────────────────────
// Gemini structured extraction
//
// Called with the cleaned + entity-enriched snippet produced by
// extractReservationDebug (same text your JS passes to callGemini).
// Returns a partial ParsedReservationDetails — only the fields Gemini
// is confident about. Nulls mean "couldn't extract".
//
// Set GEMINI_API_KEY as a Supabase secret:
//   supabase secrets set GEMINI_API_KEY=your_key
// ─────────────────────────────────────────────────────────────────────────────

interface GeminiExtracted {
  restaurant_name:   string | null;
  date:              string | null;
  time:              string | null;
  address:           string | null;
  party_size:        string | null;
  confirmation_code: string | null;
  phone:             string | null;
}

async function callGemini(cleanedSnippet: string): Promise<GeminiExtracted | null> {
  const apiKey = Deno.env.get("GEMINI_API_KEY");
  if (!apiKey) {
    console.warn("[gemini] GEMINI_API_KEY not set — skipping AI extraction");
    return null;
  }

  // Model string is read from GEMINI_MODEL env var so you can change it without redeploy.
  // From the Google AI Studio screenshot: "Gemini 3.5 Flash" → API string: gemini-3.5-flash
  // Other confirmed strings: gemini-2.0-flash, gemini-1.5-flash
  // Set: supabase secrets set GEMINI_MODEL=gemini-3.5-flash
  const model = Deno.env.get("GEMINI_MODEL") ?? "gemini-2.0-flash";
  const apiUrl =
    `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${apiKey}`;
  console.log(`[gemini] Using model: ${model}`);

  const prompt =
    `Extract reservation details from the following restaurant confirmation text. ` +
    `Return ONLY the JSON object with the exact schema specified — no explanation, no markdown, no extra keys.

` +
    `Text:
${cleanedSnippet.slice(0, 3000)}`;

  const payload = {
    contents: [{ parts: [{ text: prompt }] }],
    generationConfig: {
      responseMimeType: "application/json",
      responseSchema: {
        type: "OBJECT",
        properties: {
          restaurant_name:   { type: "STRING", description: "The restaurant or venue name. Empty string if unknown." },
          date:              { type: "STRING", description: "Reservation date in YYYY-MM-DD format. Empty string if unknown." },
          time:              { type: "STRING", description: "Reservation time in HH:MM 24h format. Empty string if unknown." },
          address:           { type: "STRING", description: "Full street address including city and state. Empty string if unknown." },
          party_size:        { type: "STRING", description: "Number of guests as a digit string. Empty string if unknown." },
          confirmation_code: { type: "STRING", description: "Booking or confirmation code. Empty string if unknown." },
          phone:             { type: "STRING", description: "Restaurant phone number. Empty string if unknown." },
        },
        required: ["restaurant_name", "date", "time", "address", "party_size", "confirmation_code", "phone"],
      },
    },
  };

  // NOTE: callGemini now throws on failure instead of returning null.
  // The caller (parseReservationDetails) catches and includes the error in debug output.
  const res = await fetch(apiUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });

  const responseText = await res.text();

  if (!res.ok) {
    // Throw so the error surfaces in the debug response — not silently swallowed
    console.error(`[gemini] API ${res.status} — body: ${responseText.slice(0, 400)}`);
    throw new Error(`Gemini API ${res.status}: ${responseText.slice(0, 300)}`);
  }

  const json = JSON.parse(responseText);
  const raw = json?.candidates?.[0]?.content?.parts?.[0]?.text;

  if (!raw) {
    console.error("[gemini] No text in candidates:", JSON.stringify(json).slice(0, 300));
    throw new Error("Gemini returned empty candidates");
  }

  const cleaned = raw.replace(/^```json\s*/i, "").replace(/```\s*$/i, "").trim();
  const parsed: GeminiExtracted = JSON.parse(cleaned);

  console.log("[gemini] Extracted:", JSON.stringify(parsed));
  return parsed;
}

/** Converts Gemini's response to ParsedReservationDetails.
 *  Gemini is the single source of truth — empty strings become null,
 *  date/time are validated and normalised. */
function geminiToDetails(g: GeminiExtracted): ParsedReservationDetails {
  const nullIfEmpty = (s: string | null | undefined) =>
    (s && s.trim() ? s.trim() : null);

  // Date: Gemini returns YYYY-MM-DD per schema. Validate strictly.
  const dateStr = nullIfEmpty(g.date);
  const visitDate = dateStr && /^\d{4}-\d{2}-\d{2}$/.test(dateStr) ? dateStr : null;

  // Time: Gemini returns HH:MM (24h) per schema. Pad and validate.
  const timeStr = nullIfEmpty(g.time);
  const visitTime = timeStr && /^\d{1,2}:\d{2}$/.test(timeStr)
    ? timeStr.padStart(5, "0")
    : null;

  const partySizeStr = nullIfEmpty(g.party_size);
  const partySizeNum = partySizeStr ? parseInt(partySizeStr, 10) : null;

  return {
    restaurantName:   nullIfEmpty(g.restaurant_name),
    address:          nullIfEmpty(g.address),
    phone:            nullIfEmpty(g.phone),
    partySize:        Number.isFinite(partySizeNum) && (partySizeNum as number) > 0 ? (partySizeNum as number) : null,
    tableLabel:       null,
    confirmationCode: nullIfEmpty(g.confirmation_code),
    visitDate,
    visitTime,
    parsedAt:         visitDate ? `${visitDate}T${visitTime ?? "00:00"}:00` : null,
  };
}

async function parseReservationDetails(text: string, fallbackCreatedAt?: string | null): Promise<{
  details: ParsedReservationDetails;
  geminiRaw: GeminiExtracted | null;
  cleanText: string;
  brand: string;
  geminiError?: string | null;
}> {
  // Step 1 — brand-aware slice + strip to clean plain text
  const debug = extractReservationDebug(text);
  const snippet = debug.cleanedText;

  // Step 2 — entity extraction runs on the FULL raw email (mirrors JS: extractEntities(input))
  // NOT on the sliced snippet — entities like phone numbers and addresses often appear
  // in the email footer/header which gets cut off during brand slicing.
  // stripToPlainText first so the regexes aren't confused by HTML tags.
  const fullPlainText = stripToPlainText(text);
  const entities = extractEntities(fullPlainText);
  const entityBlock = [
    entities.dates.length        ? `Dates: ${entities.dates.join(", ")}`        : null,
    entities.phoneNumbers.length ? `Phones: ${entities.phoneNumbers.join(", ")}` : null,
    entities.addresses.length    ? `Addresses: ${entities.addresses.join(", ")}` : null,
  ].filter(Boolean).join("\n");

  // Step 3 — combine sliced snippet + full-email entities, collapse blank lines
  // (mirrors JS: combinedText = result.text + "\n" + entitiesText, then filter empty lines)
  const combined = entityBlock
    ? `${snippet}\n\n--- Detected Entities ---\n${entityBlock}`
    : snippet;
  const cleanText = combined
    .split("\n")
    .filter((line) => line.trim() !== "")
    .join("\n");

  console.log(`[import-email] Brand: ${debug.brand} | Sliced: ${debug.sliced} | cleanText length: ${cleanText.length}`);

  // Step 4+5 — call Gemini, use ONLY its output
  let gemini: GeminiExtracted | null = null;
  let geminiError: string | null = null;

  try {
    gemini = await callGemini(cleanText);
  } catch (e) {
    geminiError = e instanceof Error ? e.message : String(e);
    console.error("[import-email] callGemini threw:", geminiError);
  }

  if (!gemini) {
    const fallbackDate = fallbackCreatedAt ? new Date(fallbackCreatedAt) : null;
    const fd = fallbackDate && !isNaN(fallbackDate.getTime()) ? fallbackDate : null;
    return {
      details: {
        restaurantName:   null,
        address:          null,
        phone:            null,
        partySize:        null,
        tableLabel:       null,
        confirmationCode: null,
        visitDate:        fd ? fd.toISOString().slice(0, 10) : null,
        visitTime:        fd ? fd.toISOString().slice(11, 16) : null,
        parsedAt:         fd ? fd.toISOString() : null,
      },
      // geminiRaw is null here — geminiError tells you why
      geminiRaw: null,
      geminiError,
      cleanText,
      brand: debug.brand,
    };
  }

  const details = geminiToDetails(gemini);

  if (!details.visitDate && fallbackCreatedAt) {
    const fb = new Date(fallbackCreatedAt);
    if (!isNaN(fb.getTime())) {
      details.visitDate = fb.toISOString().slice(0, 10);
      details.visitTime = details.visitTime ?? fb.toISOString().slice(11, 16);
      details.parsedAt  = fb.toISOString();
    }
  }

  console.log("[gemini] Final details:", JSON.stringify({
    restaurantName:   details.restaurantName,
    visitDate:        details.visitDate,
    visitTime:        details.visitTime,
    address:          details.address,
    partySize:        details.partySize,
    confirmationCode: details.confirmationCode,
  }));

  return { details: details as ParsedReservationDetails, geminiRaw: gemini, cleanText, brand: debug.brand };
}

function normalizePhoneCandidate(input: string | null): string | null {
  if (!input) return null;
  const digits = input.replace(/[^\d+]/g, "");
  return digits || input;
}

function parseVisitDateTime(visitDate?: string | null, visitTime?: string | null, fallbackIso?: string | null): Date | null {
  if (visitDate) {
    const datePart = visitDate.slice(0, 10);
    const timePart = visitTime && /\d{1,2}:\d{2}/.test(visitTime)
      ? (visitTime.length === 5 ? `${visitTime}:00` : visitTime)
      : "00:00:00";

    const parsed = new Date(`${datePart}T${timePart}`);
    if (!isNaN(parsed.getTime())) return parsed;
  }

  if (fallbackIso) {
    const parsed = new Date(fallbackIso);
    if (!isNaN(parsed.getTime())) return parsed;
  }

  return null;
}

function buildVisitNotes(
  details: {
    restaurantName: string;
    address: string | null;
    phone: string | null;
    partySize: number | null;
    tableLabel: string | null;
    confirmationCode: string | null;
    visitType: string;
    visitDate: string;
    visitTime: string | null;
  },
): string {
  const lines = [
    "Sent from email",
    `Restaurant: ${details.restaurantName}`,
    details.address ? `Address: ${details.address}` : null,
    details.phone ? `Phone: ${details.phone}` : null,
    details.partySize ? `Party size: ${details.partySize}` : null,
    details.tableLabel ? `Table: ${details.tableLabel}` : null,
    details.confirmationCode ? `Confirmation code: ${details.confirmationCode}` : null,
    `Added to: ${details.visitType === "upcoming" ? "Next Up" : "Previously Visited"}`,
    `Date: ${details.visitDate}${details.visitTime ? ` ${details.visitTime}` : ""}`,
  ].filter(Boolean);
  return lines.join("\n");
}

function buildDebugPayload(params: {
  envelope: ImportEmailRequest;
  parsedText: string;
  details: ParsedReservationDetails;
  visitType: "visited" | "upcoming";
  visitDate: string;
  visitTime: string | null;
  userId: string | null;
  restaurant: { id: string; name: string; address: string | null; phone: string | null } | null;
  yelp: { yelp_id: string; name: string; tier?: string | null } | null;
}) {
  return {
    source: "resend.email.received",
    sender: parseEmailList(params.envelope.from),
    recipients: [...parseEmailList(params.envelope.to), ...parseEmailList(params.envelope.cc)],
    subject: params.envelope.subject ?? null,
    sent_at: params.envelope.sent_at ?? null,
    parsed_excerpt: params.parsedText.slice(0, 1500),
    extracted: {
      restaurant_name: params.details.restaurantName,
      address: params.details.address,
      phone: params.details.phone,
      party_size: params.details.partySize,
      table_label: params.details.tableLabel,
      confirmation_code: params.details.confirmationCode,
      visit_date: params.visitDate,
      visit_time: params.visitTime,
      visit_type: params.visitType,
      parsed_at: params.details.parsedAt,
    },
    matched_user_id: params.userId,
    restaurant: params.restaurant,
    yelp: params.yelp
      ? { yelp_id: params.yelp.yelp_id, name: params.yelp.name, tier: params.yelp.tier ?? null }
      : null,
  };
}

function normalizeDate(input: string): string {
  const parsed = new Date(input);
  if (!isNaN(parsed.getTime())) return parsed.toISOString().slice(0, 10);
  return new Date().toISOString().slice(0, 10);
}

function normalizeTime(input?: string | null): string | null {
  if (!input) return null;
  const match = input.match(/^(\d{1,2}):(\d{2})/);
  if (!match) return null;
  const hh = match[1].padStart(2, "0");
  const mm = match[2];
  return `${hh}:${mm}`;
}

function safeInt(input: string): number | null {
  const n = Number.parseInt(input, 10);
  return Number.isFinite(n) ? n : null;
}

function normalizeContent(input: string): string {
  return stripHtml(input)
    .replace(/\r/g, "\n")
    .replace(/[\t ]+/g, " ")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

function stripHtml(html: string): string {
  if (!html) return "";
  let text = html;
  text = text.replace(/<script[\s\S]*?<\/script>/gi, " ");
  text = text.replace(/<style[\s\S]*?<\/style>/gi, " ");
  text = text.replace(/<br\s*\/?/gi, "\n");
  text = text.replace(/<\/p>/gi, "\n");
  text = text.replace(/<\/div>/gi, "\n");
  text = text.replace(/<[^>]+>/g, " ");
  text = text.replace(/&nbsp;/gi, " ");
  text = text.replace(/&amp;/gi, "&");
  text = text.replace(/&quot;/gi, '"');
  text = text.replace(/&#39;/gi, "'");
  text = text.replace(/&lt;/gi, "<");
  text = text.replace(/&gt;/gi, ">");
  return text.replace(/\s+/g, " ").trim();
}

function extractRestaurantName(text: string): string | null {
  if (!text) return null;

  const labeledPatterns = [
    /(?:restaurant|venue|place|location|dining at)\s*[:\-]\s*([^\n,;:.]{2,80})/i,
    /(?:reservation|booking|table|confirmed|confirmation|booked)\s+(?:at|for|@)\s+([^\n,;:.]{2,80})/i,
    /(?:your\s+)?(?:reservation|table)\s+(?:is\s+)?(?:at|for|with)\s+([^\n,;:.]{2,80})/i,
    /(?:dinner|lunch|brunch)\s+(?:at|for)\s+([^\n,;:.]{2,80})/i,
    /(?:name)\s*[:\-]\s*([^\n,;:.]{2,80})/i,
  ];

  for (const pattern of labeledPatterns) {
    const match = text.match(pattern)?.[1]?.trim();
    if (match) {
      const candidate = cleanupRestaurantCandidate(match);
      if (candidate) return candidate;
    }
  }

  const atPattern = text.match(/\b(?:at|for)\s+([A-Z][A-Za-z0-9&'’().\- ]{2,80})/)?.[1]?.trim();
  if (atPattern) {
    const candidate = cleanupRestaurantCandidate(atPattern);
    if (candidate) return candidate;
  }

  return null;
}

function extractRestaurantFromSubject(subject: string): string | null {
  const clean = subject.replace(/^(fwd|fw|re)\s*:\s*/i, "").trim();
  const patterns = [
    /reservation\s+at\s+(.+?)(?:\s+is\s+confirmed|\s+confirmed|$)/i,
    /your\s+reservation\s+at\s+(.+?)(?:\s+is\s+confirmed|\s+confirmed|$)/i,
    /booking\s+at\s+(.+?)(?:\s+is\s+confirmed|\s+confirmed|$)/i,
    /table\s+at\s+(.+?)(?:\s+is\s+confirmed|\s+confirmed|$)/i,
    /at\s+(.+?)(?:\s+is\s+confirmed|\s+confirmed|$)/i,
  ];

  for (const re of patterns) {
    const m = clean.match(re);
    if (m?.[1]) {
      const candidate = cleanupRestaurantCandidate(m[1]);
      if (candidate) return candidate;
    }
  }
  return null;
}

function extractRestaurantFromLines(lines: string[]): string | null {
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.length < 3 || trimmed.length > 80) continue;
    if (/[0-9]/.test(trimmed) && !/^[A-Z]/.test(trimmed)) continue;
    if (/^(reservation|confirmed|confirmation|table|booking|guest|party|date|time|address|phone)/i.test(trimmed)) continue;
    if (!/^[A-Z]/.test(trimmed)) continue;
    const words = trimmed.split(/\s+/).filter(Boolean);
    if (words.length > 5) continue;
    if (words.some((word) => COMMON_NON_RESTAURANT_WORDS.has(word.toLowerCase()))) continue;
    const candidate = cleanupRestaurantCandidate(trimmed);
    // Run the garbage filter here too — this catches time strings ("10 Minutes"),
    // date fragments ("May 20"), party-size labels ("For 2"), etc. that slip past
    // the word-level checks above.
    if (candidate && !isGarbageRestaurantName(candidate)) return candidate;
  }
  return null;
}

function cleanupRestaurantCandidate(candidate: string): string | null {
  const cleaned = candidate
    .replace(/^["'`“”]+|["'`“”]+$/g, "")
    .replace(/\s+/g, " ")
    .trim();

  if (!cleaned) return null;
  if (cleaned.length < 2 || cleaned.length > 80) return null;
  if (/^(reservation|confirmed|confirmation|table|booking|guest|party|date|time)$/i.test(cleaned)) return null;
  return cleaned;
}

function extractAddress(text: string): string | null {
  if (!text) return null;

  const labeledPatterns = [
    /(?:address|location|located at|venue|where)\s*[:\-]\s*([^\n]{5,120})/i,
    /(?:find us at|visit us at|we are at)\s+([^\n]{5,120})/i,
  ];
  for (const pattern of labeledPatterns) {
    const match = text.match(pattern)?.[1]?.trim();
    if (match) return cleanupAddressCandidate(match);
  }

  const streetPattern = text.match(/\b\d{1,6}\s+[A-Za-z0-9.'’#\- ]{3,80},\s*[A-Za-z0-9.'’#\- ]{2,80}(?:,\s*[A-Z]{2})?(?:\s+\d{5}(?:-\d{4})?)?/);
  if (streetPattern?.[0]) return cleanupAddressCandidate(streetPattern[0]);

  return null;
}

function extractAddressFromLines(lines: string[]): string | null {
  for (const line of lines) {
    const addr = extractAddress(line);
    if (addr) return addr;
  }
  return null;
}

function cleanupAddressCandidate(candidate: string): string | null {
  const cleaned = candidate.replace(/\s+/g, " ").trim();
  if (!cleaned || cleaned.length < 5) return null;
  return cleaned;
}

function extractPhone(text: string): string | null {
  if (!text) return null;
  const labeled = text.match(/(?:phone|tel|telephone|call|contact)\s*[:\-]?\s*(\+?\d?[\s.\-\(\)]?(?:\(\d{3}\)|\d{3})[\s.\-]?\d{3}[\s.\-]?\d{4})/i)?.[1];
  if (labeled) return normalizePhoneCandidate(labeled);

  const generic = text.match(/(?:\+?\d{1,3}[\s.\-]?)?(?:\(\d{3}\)|\d{3})[\s.\-]?\d{3}[\s.\-]?\d{4}/)?.[0];
  if (generic) return normalizePhoneCandidate(generic);
  return null;
}

function extractPhoneFromLines(lines: string[]): string | null {
  for (const line of lines) {
    const phone = extractPhone(line);
    if (phone) return phone;
  }
  return null;
}

function extractConfirmationCode(text: string): string | null {
  if (!text) return null;
  const patterns = [
    /(?:confirmation\s*(?:code|number)?|reservation\s*(?:code|number)?|booking\s*(?:code|number)?|reference|ref|code)\s*[:#\-]?\s*([A-Z0-9][A-Z0-9\-]{3,24})/i,
    /(?:conf(?:irmation)?\s*#)\s*([A-Z0-9][A-Z0-9\-]{3,24})/i,
    /\b#([A-Z0-9][A-Z0-9\-]{3,24})\b/i,
  ];
  for (const pattern of patterns) {
    const match = text.match(pattern)?.[1]?.trim();
    if (match) return match.toUpperCase();
  }
  return null;
}

function extractConfirmationCodeFromLines(lines: string[]): string | null {
  for (const line of lines) {
    const code = extractConfirmationCode(line);
    if (code) return code;
  }
  return null;
}

function extractPartySize(text: string): { partySize: number | null; tableLabel: string | null } | null {
  if (!text) return null;

  const patterns: Array<{ pattern: RegExp; label?: string }> = [
    { pattern: /party\s*(?:size|of|for)?\s*(?:is|:|=)?\s*(\d{1,2})\b/i },
    { pattern: /(?:table\s*(?:for|of)?|for)\s*(\d{1,2})\s*(?:guests?|people|pax|covers?)?\b/i, label: "table" },
    { pattern: /(\d{1,2})\s*(?:guests?|people|pax|covers?)\b/i },
    { pattern: /(?:seating|seated)\s*(?:for|of)?\s*(\d{1,2})\b/i },
  ];

  for (const { pattern, label } of patterns) {
    const match = text.match(pattern);
    if (match?.[1]) {
      const n = safeInt(match[1]);
      if (n !== null && n > 0 && n < 100) {
        const raw = match[0].trim();
        return {
          partySize: n,
          tableLabel: label ? raw : null,
        };
      }
    }
  }

  return null;
}

function extractPartySizeFromLines(lines: string[]): { partySize: number | null; tableLabel: string | null } | null {
  for (const line of lines) {
    const parsed = extractPartySize(line);
    if (parsed) return parsed;
  }
  return null;
}

function extractDateTime(text: string): Date | null {
  if (!text) return null;
  const lines = text.split(/\n+/).map((line) => line.trim()).filter(Boolean);
  for (const line of lines) {
    const dt = parseDateTimeLine(line);
    if (dt) return dt;
  }
  return parseDateTimeLine(text);
}

function extractDateTimeFromLines(lines: string[]): Date | null {
  for (const line of lines) {
    const dt = parseDateTimeLine(line);
    if (dt) return dt;
  }
  return null;
}

function parseDateTimeLine(line: string): Date | null {
  if (!line) return null;
  const now = new Date();

  const relative = line.match(/\b(today|tomorrow|yesterday|tonight)\b(?:.*?\b(?:at|@)\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm)?)?/i);
  if (relative?.[1]) {
    const base = new Date(now);
    const word = relative[1].toLowerCase();
    if (word === "tomorrow") base.setDate(base.getDate() + 1);
    if (word === "yesterday") base.setDate(base.getDate() - 1);

    let hour = 0;
    let minute = 0;
    if (relative[2]) {
      const parsed = parseClockTime(relative[2], relative[3], relative[4], word === "tonight");
      if (parsed) {
        hour = parsed.hour;
        minute = parsed.minute;
      }
    } else if (word === "tonight") {
      hour = 19;
      minute = 0;
    }
    base.setHours(hour, minute, 0, 0);
    return base;
  }

  let match = line.match(/\b(\d{4})[-\/](\d{1,2})[-\/](\d{1,2})(?:[T\s,]+(\d{1,2})(?::(\d{2}))?(?:\s*(am|pm))?)?/i);
  if (match) {
    return buildDateTime(
      safeInt(match[1])!,
      safeInt(match[2])! - 1,
      safeInt(match[3])!,
      parseClockTime(match[4], match[5], match[6])
    );
  }

  match = line.match(/\b(\d{1,2})[\/](\d{1,2})[\/](\d{2,4})(?:[T\s,]+(\d{1,2})(?::(\d{2}))?(?:\s*(am|pm))?)?/i);
  if (match) {
    const year = normalizeYear(safeInt(match[3])!);
    return buildDateTime(
      year,
      safeInt(match[1])! - 1,
      safeInt(match[2])!,
      parseClockTime(match[4], match[5], match[6])
    );
  }

  match = line.match(/\b(january|february|march|april|may|june|july|august|september|october|november|december)\s+(\d{1,2})(?:,?\s*(\d{2,4}))?(?:\s+(?:at|@)\s*(\d{1,2})(?::(\d{2}))?(?:\s*(am|pm))?)?/i);
  if (match) {
    const month = monthToIndex(match[1]);
    const year = match[3] ? normalizeYear(safeInt(match[3])!) : now.getFullYear();
    return buildDateTime(year, month, safeInt(match[2])!, parseClockTime(match[4], match[5], match[6]));
  }

  match = line.match(/\b(\d{1,2})(?:st|nd|rd|th)?\s+(january|february|march|april|may|june|july|august|september|october|november|december)(?:\s+(\d{2,4}))?(?:\s+(?:at|@)\s*(\d{1,2})(?::(\d{2}))?(?:\s*(am|pm))?)?/i);
  if (match) {
    const year = match[3] ? normalizeYear(safeInt(match[3])!) : now.getFullYear();
    return buildDateTime(year, monthToIndex(match[2]), safeInt(match[1])!, parseClockTime(match[4], match[5], match[6]));
  }

  return null;
}

function parseClockTime(
  hourStr?: string | null,
  minuteStr?: string | null,
  meridiem?: string | null,
  preferEvening = false,
): { hour: number; minute: number } | null {
  if (!hourStr) return null;
  let hour = safeInt(hourStr);
  if (hour === null) return null;
  const minute = minuteStr ? Math.min(Math.max(safeInt(minuteStr) ?? 0, 0), 59) : 0;
  const mer = meridiem?.toLowerCase();

  if (mer === "am" || mer === "pm") {
    if (hour === 12) hour = mer === "am" ? 0 : 12;
    else if (mer === "pm") hour += 12;
    return { hour, minute };
  }

  if (preferEvening && hour > 0 && hour <= 11) {
    hour += 12;
  }
  return { hour, minute };
}

function buildDateTime(
  year: number,
  monthIndex: number,
  day: number,
  time: { hour: number; minute: number } | null,
): Date | null {
  if (!Number.isFinite(year) || !Number.isFinite(monthIndex) || !Number.isFinite(day)) return null;
  const hour = time?.hour ?? 0;
  const minute = time?.minute ?? 0;
  const dt = new Date(year, monthIndex, day, hour, minute, 0, 0);
  if (isNaN(dt.getTime())) return null;
  return dt;
}

function monthToIndex(month: string): number {
  const map: Record<string, number> = {
    january: 0,
    february: 1,
    march: 2,
    april: 3,
    may: 4,
    june: 5,
    july: 6,
    august: 7,
    september: 8,
    october: 9,
    november: 10,
    december: 11,
  };
  return map[month.toLowerCase()] ?? 0;
}

function normalizeYear(year: number): number {
  if (year < 100) return year >= 70 ? 1900 + year : 2000 + year;
  return year;
}

function parseHours(hoursArr: YelpBusiness["hours"] | undefined): Record<string, string> {
  if (!hoursArr?.[0]?.open) return {};
  const days = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];
  const result: Record<string, string> = {};
  for (const h of hoursArr[0].open) {
    const day = days[h.day];
    result[day] = `${h.start.slice(0, 2)}:${h.start.slice(2)}-${h.end.slice(0, 2)}:${h.end.slice(2)}`;
  }
  return result;
}