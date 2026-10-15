// ─────────────────────────────────────────────────────────────────────────────
// reservationExtractor.ts
// Extracts restaurant reservation fields from raw email HTML/text.
//
// Pipeline (mirrors the attached JS reference, adapted for Deno/server):
//   1. detectBrand()          — identify Resy / OpenTable / General
//   2. sliceRelevantSection() — cut the HTML to just the reservation block
//                               using brand-specific start/end markers
//   3. stripToPlainText()     — convert the sliced HTML to clean plain text
//   4. extractEntities()      — pull structured dates, phones, addresses
//   5. field extractors       — pattern-match against enriched text
// ─────────────────────────────────────────────────────────────────────────────

export type Brand = "Resy" | "OpenTable" | "General";

export interface ReservationResult {
  restaurant: string | null;
  datetime:   string | null;
  count:      number | null;
  address:    string | null;
  email:      string | null;
}

export interface ExtractionDebugResult {
  result:      ReservationResult;
  sources:     Record<keyof ReservationResult, string | null>;
  cleanedText: string;
  brand:       Brand;
  sliced:      boolean; // true = brand markers found, false = full-text fallback
  entities:    DetectedEntities;
}

export interface DetectedEntities {
  dates:        string[];
  phoneNumbers: string[];
  addresses:    string[];
}

interface MatchResult<T> {
  value:  T | null;
  source: string | null;
}

type StringPattern = [RegExp, string];
type NumberPattern = [RegExp, string];

// ─────────────────────────────────────────────────────────────────────────────
// 1. Brand detection
// ─────────────────────────────────────────────────────────────────────────────

export function detectBrand(raw: string): Brand {
  const lower = raw.toLowerCase();
  if (lower.includes("resy"))                              return "Resy";
  if (lower.includes("opentable") || lower.includes("open table")) return "OpenTable";
  return "General";
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. Brand-aware section slicer
//    Mirrors detectAndExtract() / extract_resy() / extract_open_table() from
//    the reference JS but runs in Deno (no DOMParser — we work on raw strings
//    and let stripToPlainText handle HTML removal afterwards).
// ─────────────────────────────────────────────────────────────────────────────

interface SliceResult {
  sliced: string;
  didSlice: boolean;
}

function sliceRelevantSection(raw: string, brand: Brand): SliceResult {
  const lower = raw.toLowerCase();

  if (brand === "Resy") {
    return sliceResy(raw, lower);
  }
  if (brand === "OpenTable") {
    const r = sliceOpenTable(raw, lower);
    if (r.didSlice) return r;
    // OpenTable sometimes misdetected — fall through to general
  }
  return sliceGeneral(raw, lower);
}

function sliceResy(raw: string, lower: string): SliceResult {
  const startTokens = [
    "[image: resy]",
    "reservation booked",
    "reservation confirmed",
    "reservation",
    "confirmed",
    "booked",
  ];
  const endToken = "thank you for making a reservation";

  let startIdx = -1;
  for (const token of startTokens) {
    const idx = lower.indexOf(token);
    if (idx !== -1) { startIdx = idx; break; }
  }
  const endIdx = lower.indexOf(endToken);

  if (startIdx !== -1 && endIdx !== -1 && endIdx > startIdx) {
    return { sliced: raw.slice(startIdx, endIdx + endToken.length), didSlice: true };
  }
  return { sliced: raw, didSlice: false };
}

function sliceOpenTable(raw: string, lower: string): SliceResult {
  const startTokens = [
    "[image: opentable]",
    "reservation confirmed",
    "reservation",
    "booking",
    "booked",
    "confirmed",
  ];
  const endTokens = [
    "cancel your reservation",
    "modify your reservation",
    "cancel or modify",
    "what to know before you go",
    "cancel",
    "modify",
  ];

  let startIdx = -1;
  for (const token of startTokens) {
    const idx = lower.indexOf(token);
    if (idx !== -1) { startIdx = idx; break; }
  }

  let endIdx = -1;
  for (const token of endTokens) {
    const idx = lower.indexOf(token);
    if (idx !== -1 && (endIdx === -1 || idx < endIdx)) endIdx = idx;
  }

  if (startIdx !== -1 && endIdx !== -1 && endIdx > startIdx) {
    return { sliced: raw.slice(startIdx, endIdx), didSlice: true };
  }
  return { sliced: raw, didSlice: false };
}

function sliceGeneral(raw: string, lower: string): SliceResult {
  const startTokens = [
    "reservation confirmed",
    "reservation booked",
    "your reservation",
    "your booking",
    "reservation",
    "booking",
    "booked",
    "confirmed",
  ];
  const endTokens = [
    "cancel your reservation",
    "modify your reservation",
    "cancel or modify",
    "what to know before you go",
    "unsubscribe",
    "cancel",
    "modify",
  ];

  let startIdx = -1;
  for (const token of startTokens) {
    const idx = lower.indexOf(token);
    if (idx !== -1) { startIdx = idx; break; }
  }

  let endIdx = -1;
  for (const token of endTokens) {
    const idx = lower.indexOf(token);
    // Skip "cancel" / "modify" that appear BEFORE the start (e.g. in nav headers)
    if (idx !== -1 && idx > (startIdx === -1 ? 0 : startIdx) && (endIdx === -1 || idx < endIdx)) {
      endIdx = idx;
    }
  }

  if (startIdx !== -1 && endIdx !== -1 && endIdx > startIdx) {
    return { sliced: raw.slice(startIdx, endIdx), didSlice: true };
  }
  if (startIdx !== -1) {
    // No clear end marker — take up to 6000 chars from start to cap noise
    return { sliced: raw.slice(startIdx, startIdx + 6000), didSlice: true };
  }
  return { sliced: raw, didSlice: false };
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. Plain-text stripper (unchanged from prior version)
// ─────────────────────────────────────────────────────────────────────────────

export function stripToPlainText(raw: string): string {
  let t = raw;

  // Quoted-printable: join soft-wrapped lines
  t = t.replace(/=\r?\n/g, "");
  t = t.replace(/=([0-9A-Fa-f]{2})/g, (_, h) => String.fromCharCode(parseInt(h, 16)));

  t = t.replace(/<style[\s\S]*?<\/style>/gi, "");
  t = t.replace(/<script[\s\S]*?<\/script>/gi, "");

  // Block-level tags → newlines
  t = t.replace(/<\/?(div|p|tr|td|th|li|br|hr|h[1-6]|table|thead|tbody|tfoot)[^>]*>/gi, "\n");

  // Strip remaining tags
  t = t.replace(/<[^>]+>/g, "");

  // HTML entities
  t = t
    .replace(/&amp;/gi,  "&")
    .replace(/&lt;/gi,   "<")
    .replace(/&gt;/gi,   ">")
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/gi,  "'")
    .replace(/&nbsp;/gi, " ")
    .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(parseInt(n)))
    .replace(/&[a-z]+;/gi, " ");

  // Strip URLs and MIME noise
  t = t.replace(/https?:\/\/\S+/g, "");
  t = t.replace(/<https?:\/\/[^>]+>/g, "");
  t = t.replace(/<\+?\d[\d\-]+>/g, "");
  t = t.replace(/mailto:[^\s>")]+/g, "");

  t = t.replace(
    /^(Received|DKIM-Signature|ARC-[\w-]+|X-[\w-]+|Authentication-Results|Return-Path|Delivered-To|MIME-Version|Content-Type|Content-Transfer-Encoding|Message-ID|References|In-Reply-To|X-Gm[\w-]*):[^\n]*/gim,
    ""
  );

  t = t.replace(/^--[\w\-]+.*$/gm, "");
  t = t.replace(/\[image:[^\]]*\]/gi, "");
  t = t.replace(/\[---[\s\S]*?---\]/g, "");

  t = t.replace(/\n{3,}/g, "\n\n");
  t = t.split("\n").map((l) => l.trim()).filter((l) => l.length > 0).join("\n");
  t = t.replace(/^[=\-_*~]{3,}$/gm, "");

  return t.trim();
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. Entity pre-extraction
//    Mirrors extractEntities() from the reference JS. Pulls dates, phones and
//    addresses with targeted regexes and appends them as a structured block so
//    the field extractors below can match them even if the plain-text layout
//    scrambled the original context.
// ─────────────────────────────────────────────────────────────────────────────

export function extractEntities(text: string): DetectedEntities {
  // Dates: numeric (MM/DD/YYYY etc.) OR written (Jan 5, 2025)
  const dateRegex =
    /\b\d{1,2}[/\-\.]\d{1,2}[/\-\.]\d{2,4}\b|\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2},?\s+\d{4}\b/gi;

  // Phones: North American + international
  const phoneRegex = /(?:\+?1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}/g;

  // Street addresses
  const addressRegex =
    /\d{1,5}\s+[A-Za-z0-9\s.,]{3,30}(?:St|Street|Ave|Avenue|Rd|Road|Blvd|Lane|Ln|Drive|Dr|Way|Pl|Place)\b[A-Za-z0-9\s.,#\-]{0,60}/gi;

  const dedup = <T>(arr: T[]) => [...new Set(arr)];

  return {
    dates:        dedup((text.match(dateRegex)   ?? []).map((s) => s.trim())),
    phoneNumbers: dedup((text.match(phoneRegex)  ?? []).map((s) => s.trim())),
    addresses:    dedup((text.match(addressRegex)?? []).map((s) => s.trim())),
  };
}

/**
 * Appends the entity block to the cleaned text so field extractors see
 * all structured data in one pass (mirrors "combinedText" in the reference JS).
 */
function appendEntityBlock(cleanText: string, entities: DetectedEntities): string {
  const lines: string[] = [];
  if (entities.dates.length)        lines.push(`Detected dates: ${entities.dates.join(", ")}`);
  if (entities.phoneNumbers.length) lines.push(`Detected phones: ${entities.phoneNumbers.join(", ")}`);
  if (entities.addresses.length)    lines.push(`Detected addresses: ${entities.addresses.join(", ")}`);
  if (!lines.length) return cleanText;
  return `${cleanText}\n\n--- Detected Entities ---\n${lines.join("\n")}`;
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. Field extractors (pattern matchers, same as before — now applied to the
//    enriched text produced by the pipeline above)
// ─────────────────────────────────────────────────────────────────────────────

function collapseWhitespace(s: string): string {
  return s.replace(/\s+/g, " ").trim();
}

function firstStringMatch(
  text: string,
  patterns: StringPattern[],
  transform?: (m: RegExpMatchArray) => string
): MatchResult<string> {
  for (const [pattern, source] of patterns) {
    const m = text.match(pattern);
    if (m) {
      const value = transform ? transform(m) : collapseWhitespace(m[1] ?? m[0]);
      return { value, source };
    }
  }
  return { value: null, source: null };
}

function firstNumberMatch(
  text: string,
  patterns: NumberPattern[],
  transform: (m: RegExpMatchArray) => number
): MatchResult<number> {
  for (const [pattern, source] of patterns) {
    const m = text.match(pattern);
    if (m) return { value: transform(m), source };
  }
  return { value: null, source: null };
}

const WORD_TO_NUM: Record<string, number> = {
  one: 1, two: 2, three: 3, four: 4, five: 5,
  six: 6, seven: 7, eight: 8, nine: 9, ten: 10,
};

function extractRestaurant(text: string): MatchResult<string> {
  return firstStringMatch(text, [
    [/Restaurant\s+name\s*:\s*(.+)/i,                                            "label:restaurant-name"],
    [/(?:Property|Venue|Location)\s+name\s*:\s*(.+)/i,                          "label:venue-name"],
    [/Reservation booked\.\s*\n\*?([^\n*]+)/,                                    "resy-header"],
    [/(?:reservation|booking|table)\s+at\s+([A-Za-z0-9 &'\-]{3,50}?)\s+(?:is confirmed|confirmed|has been)/i, "confirmed-phrase"],
    [/(?:reservation at|dining at|booked at|table at)\s+([A-Za-z0-9 &'\-]{3,50}?)(?:\s+(?:is|on|for)|\.|,|$)/i, "at-phrase"],
    [/confirmed[^\n]{0,30}\n\*?([A-Z][A-Za-z0-9 &'\-]{2,50})\*?\n/i,           "post-confirmed-line"],
    [/([A-Z][A-Za-z0-9 &'\-]{2,40}(?:Restaurant|Bistro|Grill|Cafe|Bar|Kitchen|Diner|Eatery|House|Lounge|Inn|Tavern|Brasserie|Cantina|Trattoria|Steakhouse|Pizzeria))/, "suffix-match"],
  ]);
}

function extractDatetime(text: string): MatchResult<string> {
  const dateLabel = text.match(/Reservation\s+date\s*:\s*(.+)/i);
  const timeLabel = text.match(/Reservation\s+time\s*:\s*(.+)/i);

  if (dateLabel && timeLabel) {
    return {
      value: collapseWhitespace(`${dateLabel[1].trim()} at ${timeLabel[1].trim()}`),
      source: "label:date+time",
    };
  }
  if (dateLabel) return { value: collapseWhitespace(dateLabel[1].trim()), source: "label:date" };

  return firstStringMatch(text, [
    [/((?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday),?\s+\d{1,2}\s+\w+\s+at\s+\d{1,2}:\d{2}\s*(?:am|pm))/i, "resy-format"],
    [/((?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)\.?,?\s+\w+\s+\d{1,2}\s+at\s+\d{1,2}:\d{2}\s*(?:AM|PM|am|pm))/i, "short-weekday"],
    [/((?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday),?\s+(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\s+\d{1,2},?\s+\d{4}[,\s]+(?:at\s+)?\d{1,2}:\d{2}\s*(?:AM|PM|am|pm)?)/i, "full-weekday-month"],
    [/((?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\s+\d{1,2}(?:st|nd|rd|th)?,?\s+\d{4}[,\s]+(?:at\s+)?\d{1,2}:\d{2}\s*(?:AM|PM|am|pm)?)/i, "month-day-year-time"],
    [/(\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4}[,\s]+(?:at\s+)?\d{1,2}:\d{2}\s*(?:AM|PM|am|pm)?)/i, "numeric-date"],
    [/((?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\s+\d{1,2}(?:st|nd|rd|th)?,?\s+\d{4})/i, "month-day-year"],
    // Entity-block fallback: "Detected dates: May 20, 2026"
    [/Detected dates:\s*(.+)/i, "entity-dates"],
    [/(?:at\s+)?(\d{1,2}:\d{2}\s*(?:AM|PM|am|pm))/i, "time-only"],
  ]);
}

function extractCount(text: string): MatchResult<number> {
  const transform = (m: RegExpMatchArray): number => {
    const raw = (m[1] ?? "").toLowerCase();
    return WORD_TO_NUM[raw] !== undefined ? WORD_TO_NUM[raw] : parseInt(raw, 10);
  };

  return firstNumberMatch(text, [
    [/Party\s+size\s*:\s*(\d+)/i,                                                "label:party-size"],
    [/(?:Number\s+of\s+)?(?:Guests?|Covers?|Diners?|People|Pax)\s*:\s*(\d+)/i,  "label:guest-count"],
    [/(\d+)\s+Guests?/i,                                                         "guests-keyword"],
    [/\bfor\s+(\d+|one|two|three|four|five|six|seven|eight|nine|ten)\s+(?:people|person|guests?|pax|covers?|diners?)/i, "for-N-people"],
    [/(?:party|group)\s+of\s+(\d+|one|two|three|four|five|six|seven|eight|nine|ten)/i, "party-of"],
    [/\btable\s+for\s+(\d+|one|two|three|four|five|six|seven|eight|nine|ten)/i, "table-for"],
    [/\b(\d+|one|two|three|four|five|six|seven|eight|nine|ten)\s+(?:people|person|guests?|pax|diners?)/i, "N-people"],
  ], transform);
}

function extractAddress(text: string): MatchResult<string> {
  const clean = (m: RegExpMatchArray): string => {
    let val = collapseWhitespace(m[1] ?? "");
    val = val.replace(/,\s*[A-Za-z ]+,\s*[A-Z]{2}\s*$/, "").trim();
    return val;
  };

  return firstStringMatch(text, [
    [/Address\s*:\s*([^\n]{10,120})/i,    "label:address"],
    [/Location\s*:\s*([^\n]{10,120})/i,   "label:location"],
    [/(\d{1,5}\s+[A-Za-z0-9 .,'#\-]{3,60}(?:Street|St|Avenue|Ave|Boulevard|Blvd|Road|Rd|Drive|Dr|Lane|Ln|Court|Ct|Way|Place|Pl|Highway|Hwy|Pkwy)[A-Za-z0-9 ,.\-]{0,80}(?:[A-Z]{2}\s+\d{5}(?:-\d{4})?)?)/, "street-address"],
    // Entity-block fallback: addresses pulled by extractEntities()
    [/Detected addresses:\s*(\d{1,5}\s+[^\n,]{5,80})/i, "entity-address"],
  ], clean);
}

function extractEmail(text: string): MatchResult<string> {
  return firstStringMatch(text, [
    [/[\w.+\-]+@[\w.\-]+\.\w{2,}/, "email-pattern"],
  ]);
}

// ─────────────────────────────────────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Extract reservation fields from a raw email string.
 * Runs the full brand-detection → slicing → stripping → entity-enrichment
 * → pattern-matching pipeline.
 */
export function extractReservation(rawEmail: string): ReservationResult {
  const { result } = extractReservationDebug(rawEmail);
  return result;
}

/**
 * Same as extractReservation but also returns debug metadata:
 * brand, whether slicing occurred, detected entities, and which
 * pattern source matched each field.
 */
export function extractReservationDebug(rawEmail: string): ExtractionDebugResult {
  // Step 1 — detect brand
  const brand = detectBrand(rawEmail);

  // Step 2 — slice to the relevant section using brand-specific markers
  const { sliced, didSlice } = sliceRelevantSection(rawEmail, brand);

  // Step 3 — strip HTML / MIME noise → clean plain text
  const cleanedText = stripToPlainText(sliced);

  // Step 4 — extract entities and append as structured block
  const entities  = extractEntities(cleanedText);
  const enriched  = appendEntityBlock(cleanedText, entities);

  // Step 5 — run field extractors on the enriched text
  const restaurant = extractRestaurant(enriched);
  const datetime   = extractDatetime(enriched);
  const count      = extractCount(enriched);
  const address    = extractAddress(enriched);
  const email      = extractEmail(enriched);

  return {
    result: {
      restaurant: restaurant.value,
      datetime:   datetime.value,
      count:      count.value,
      address:    address.value,
      email:      email.value,
    },
    sources: {
      restaurant: restaurant.source,
      datetime:   datetime.source,
      count:      count.source,
      address:    address.source,
      email:      email.source,
    },
    cleanedText: enriched,
    brand,
    sliced: didSlice,
    entities,
  };
}
