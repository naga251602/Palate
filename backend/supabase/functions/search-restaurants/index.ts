// supabase/functions/search-restaurants/index.ts
// POST /functions/v1/search-restaurants
// Searches Yelp (with 24h local cache) and returns restaurant results.

import { err, getServiceClient, handleCors, ok, requireUser, yelpFetch } from "../_shared/utils.ts";

interface SearchRequest {
  query: string;
  lat: number;
  lng: number;
  radius?: number;
  limit?: number;
  offset?: number;
  price?: string[];
  open_now?: boolean;
}

Deno.serve(async (req) => {
  const cors = handleCors(req);
  if (cors) return cors;

  const supabase = getServiceClient();

  try {
    await requireUser(req, supabase);

    const body: SearchRequest = await req.json();
    const { query, lat, lng, radius = 10000, limit = 20, offset = 0, price, open_now } = body;

    if (!query || lat == null || lng == null) {
      return err("query, lat, lng are required");
    }

    // ── 1. Check cache ─────────────────────────────────────────────────────
    const cacheExpiry = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();

    const { data: cached } = await supabase
      .from("restaurants")
      .select("*")
      .gte("last_synced_at", cacheExpiry)
      .textSearch("name", query, { type: "websearch" })
      .gte("lat", lat - 0.15)
      .lte("lat", lat + 0.15)
      .gte("lng", lng - 0.15)
      .lte("lng", lng + 0.15)
      .limit(limit)
      .range(offset, offset + limit - 1);

    if (cached && cached.length >= limit / 2) {
      const withDistance = cached.map((r) => ({
        ...r,
        about: buildAbout(r),
        distance_meters: haversineMeters(lat, lng, r.lat, r.lng),
      })).sort((a, b) => a.distance_meters - b.distance_meters);

      return ok({ restaurants: withDistance, total: withDistance.length, cached: true });
    }

    // ── 2. Call Yelp ───────────────────────────────────────────────────────
    const yelpParams: Record<string, string | number | boolean> = {
      term: query,
      latitude: lat,
      longitude: lng,
      radius,
      limit,
      offset,
      sort_by: "best_match",
    };
    if (price?.length) yelpParams.price = price.map((p) => p.length).join(",");
    if (open_now) yelpParams.open_now = true;

    const yelpData = await yelpFetch("/businesses/search", yelpParams);

    // ── 3. Upsert into restaurants cache ──────────────────────────────────
    const restaurants = (yelpData.businesses ?? []).map((b: YelpBusiness) => ({
      yelp_id: b.id,
      name: b.name,
      address: b.location?.address1 ?? null,
      city: b.location?.city ?? null,
      state: b.location?.state ?? null,
      country: b.location?.country ?? null,
      lat: b.coordinates?.latitude ?? null,
      lng: b.coordinates?.longitude ?? null,
      phone: b.display_phone ?? null,
      price_range: b.price ?? null,
      cuisine_tags: b.categories?.map((c: { alias: string }) => c.alias) ?? [],
      rating: b.rating ?? null,
      review_count: b.review_count ?? null,
      image_url: b.image_url ?? null,
      yelp_url: b.url ?? null,
      is_open_now: b.hours?.[0]?.is_open_now ?? null,
      last_synced_at: new Date().toISOString(),
    }));

    const { data: upserted } = await supabase
      .from("restaurants")
      .upsert(restaurants, { onConflict: "yelp_id" })
      .select();

    const withDistance = (upserted ?? restaurants).map((r) => ({
      ...r,
      about: buildAbout(r),
      distance_meters: haversineMeters(lat, lng, r.lat ?? lat, r.lng ?? lng),
    }));

    return ok({
      restaurants: withDistance,
      total: yelpData.total ?? withDistance.length,
      cached: false,
    });
  } catch (e) {
    console.error(e);
    return err(e instanceof Error ? e.message : "Internal error", 500);
  }
});

// ── Helpers ────────────────────────────────────────────────────────────────────
function haversineMeters(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const R = 6371000;
  const toRad = (d: number) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function buildAbout(r: {
  cuisine_tags?: string[] | null;
  price_range?: string | null;
  rating?: number | null;
  review_count?: number | null;
  city?: string | null;
  state?: string | null;
  is_open_now?: boolean | null;
}): string {
  const parts: string[] = [];
  if (r.cuisine_tags?.length) parts.push(r.cuisine_tags.join(" · "));
  if (r.price_range) parts.push(r.price_range);
  if (r.rating != null) parts.push(`${r.rating.toFixed(1)}★`);
  if (r.review_count != null) parts.push(`${r.review_count} reviews`);
  const location = [r.city, r.state].filter(Boolean).join(", ");
  if (location) parts.push(location);
  if (r.is_open_now != null) parts.push(r.is_open_now ? "Open now" : "Currently closed");
  return parts.join(" • ");
}

interface YelpBusiness {
  id: string;
  name: string;
  location?: { address1?: string; city?: string; state?: string; country?: string };
  coordinates?: { latitude?: number; longitude?: number };
  display_phone?: string;
  price?: string;
  categories?: { alias: string }[];
  rating?: number;
  review_count?: number;
  image_url?: string;
  url?: string;
  hours?: { is_open_now?: boolean }[];
}
