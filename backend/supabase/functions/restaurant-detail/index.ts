// supabase/functions/restaurant-detail/index.ts
// POST /functions/v1/restaurant-detail
// Returns full restaurant detail including Yelp business data, reviews, and user visit history.

import { err, getServiceClient, handleCors, ok, requireUser, yelpFetch } from "../_shared/utils.ts";

Deno.serve(async (req) => {
  const cors = handleCors(req);
  if (cors) return cors;

  const supabase = getServiceClient();

  try {
    const user = await requireUser(req, supabase);
    const { yelp_id } = await req.json();

    if (!yelp_id) return err("yelp_id is required");

    // ── 1. Fetch from Yelp ─────────────────────────────────────────────────
    const [business, reviewsData] = await Promise.all([
      yelpFetch(`/businesses/${yelp_id}`),
      yelpFetch(`/businesses/${yelp_id}/reviews`, { limit: 3 }),
    ]);

    const categories = business.categories ?? [];
    const cuisineTags = categories.map((c: { alias: string }) => c.alias);
    const cuisineNames = categories.map((c: { title: string }) => c.title).filter(Boolean);
    const about = buildAbout({
      categories: cuisineNames,
      price: business.price,
      rating: business.rating,
      reviewCount: business.review_count,
      city: business.location?.city,
      state: business.location?.state,
      isOpenNow: business.hours?.[0]?.is_open_now,
    });

    // ── 2. Upsert into cache ───────────────────────────────────────────────
    const restaurantData = {
      yelp_id: business.id,
      name: business.name,
      address: business.location?.address1 ?? null,
      city: business.location?.city ?? null,
      state: business.location?.state ?? null,
      country: business.location?.country ?? null,
      lat: business.coordinates?.latitude ?? null,
      lng: business.coordinates?.longitude ?? null,
      phone: business.display_phone ?? null,
      price_range: business.price ?? null,
      cuisine_tags: cuisineTags,
      rating: business.rating ?? null,
      review_count: business.review_count ?? null,
      image_url: business.image_url ?? null,
      yelp_url: business.url ?? null,
      hours: parseHours(business.hours),
      is_open_now: business.hours?.[0]?.is_open_now ?? null,
      last_synced_at: new Date().toISOString(),
    };

    const { data: restaurant } = await supabase
      .from("restaurants")
      .upsert(restaurantData, { onConflict: "yelp_id" })
      .select()
      .single();

    // ── 3. User's visit history for this restaurant ────────────────────────
    const { data: visits } = await supabase
      .from("visits")
      .select("id, visit_date, rating, visit_type")
      .eq("user_id", user.id)
      .eq("restaurant_id", restaurant?.id)
      .order("visit_date", { ascending: false });

    const userVisitCount = visits?.length ?? 0;
    const userLastVisited = visits?.[0]?.visit_date ?? null;

    // ── 4. Format Yelp reviews ─────────────────────────────────────────────
    const yelpReviews = (reviewsData.reviews ?? []).map((r: YelpReview) => ({
      author: r.user?.name ?? "Anonymous",
      rating: r.rating,
      text: r.text,
      time_created: r.time_created,
    }));

    return ok({
      restaurant,
      about,
      phone: business.display_phone ?? null,
      rating: business.rating ?? null,
      review_count: business.review_count ?? null,
      cuisine_tags: cuisineTags,
      cuisine_names: cuisineNames,
      hours: restaurant?.hours ?? {},
      yelp_reviews: yelpReviews,
      user_visit_count: userVisitCount,
      user_last_visited: userLastVisited,
    });
  } catch (e) {
    console.error(e);
    return err(e instanceof Error ? e.message : "Internal error", 500);
  }
});

// ── Helpers ────────────────────────────────────────────────────────────────────
function parseHours(hoursArr: YelpHours[] | undefined): Record<string, string> {
  if (!hoursArr?.[0]?.open) return {};
  const days = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];
  const result: Record<string, string> = {};
  for (const h of hoursArr[0].open) {
    const day = days[h.day];
    result[day] = `${h.start.slice(0, 2)}:${h.start.slice(2)}-${h.end.slice(0, 2)}:${h.end.slice(2)}`;
  }
  return result;
}

function buildAbout(input: {
  categories: string[];
  price?: string | null;
  rating?: number | null;
  reviewCount?: number | null;
  city?: string | null;
  state?: string | null;
  isOpenNow?: boolean | null;
}): string {
  const parts: string[] = [];

  if (input.categories.length) parts.push(input.categories.join(" · "));
  if (input.price) parts.push(input.price);
  if (input.rating != null) parts.push(`${input.rating.toFixed(1)}★`);
  if (input.reviewCount != null) parts.push(`${input.reviewCount} reviews`);
  const location = [input.city, input.state].filter(Boolean).join(", ");
  if (location) parts.push(location);
  if (input.isOpenNow != null) parts.push(input.isOpenNow ? "Open now" : "Currently closed");

  return parts.join(" • ");
}

interface YelpHours {
  open: { day: number; start: string; end: string }[];
  is_open_now?: boolean;
}

interface YelpReview {
  user?: { name?: string };
  rating: number;
  text: string;
  time_created: string;
}
