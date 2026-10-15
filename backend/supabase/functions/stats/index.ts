// supabase/functions/stats/index.ts
// GET /functions/v1/stats
// Returns aggregated profile stats for the authenticated user.

import { err, getServiceClient, handleCors, ok, requireUser } from "../_shared/utils.ts";

const MILESTONE_THRESHOLDS = [1, 10, 50, 100, 250];

Deno.serve(async (req) => {
  const cors = handleCors(req);
  if (cors) return cors;

  const supabase = getServiceClient();

  try {
    const user = await requireUser(req, supabase);

    // ── Fetch all completed visits with restaurant data ─────────────────────
    const { data: visits, error: visitsErr } = await supabase
      .from("visits")
      .select(`
        id, rating, visit_date, restaurant_id,
        restaurant:restaurants (
          id, name, city, state, country,
          lat, lng, cuisine_tags, price_range
        )
      `)
      .eq("user_id", user.id)
      .eq("visit_type", "visited")
      .order("visit_date", { ascending: true });

    if (visitsErr) throw visitsErr;

    const totalVisits = visits?.length ?? 0;

    if (totalVisits === 0) {
      return ok({
        total_visits: 0,
        unique_cuisines: 0,
        total_miles_traveled: 0,
        countries_visited: 0,
        cities_visited: 0,
        current_streak_weeks: 0,
        favorite_cuisine: null,
        most_visited_restaurant: null,
        avg_rating_given: null,
        milestones: [],
      });
    }

    // ── Unique cuisines ────────────────────────────────────────────────────
    const allCuisines = visits
      ?.flatMap((v) => (v.restaurant as { cuisine_tags?: string[] } | null)?.cuisine_tags ?? []) ?? [];
    const uniqueCuisines = new Set(allCuisines).size;

    // ── Geographic stats ───────────────────────────────────────────────────
    const countries = new Set<string>();
    const cities = new Set<string>();
    let totalMeters = 0;
    let prevLat: number | null = null;
    let prevLng: number | null = null;

    for (const v of visits ?? []) {
      const r = v.restaurant as { country?: string; city?: string; lat?: number; lng?: number } | null;
      if (!r) continue;
      if (r.country) countries.add(r.country);
      if (r.city) cities.add(r.city);
      if (r.lat != null && r.lng != null) {
        if (prevLat != null && prevLng != null) {
          totalMeters += haversineMeters(prevLat, prevLng, r.lat, r.lng);
        }
        prevLat = r.lat;
        prevLng = r.lng;
      }
    }

    const totalMiles = Math.round(totalMeters / 1609.34);

    // ── Weekly streak ──────────────────────────────────────────────────────
    const streakWeeks = computeWeeklyStreak(visits?.map((v) => v.visit_date) ?? []);

    // ── Favorite cuisine ───────────────────────────────────────────────────
    const cuisineCounts: Record<string, number> = {};
    for (const c of allCuisines) cuisineCounts[c] = (cuisineCounts[c] ?? 0) + 1;
    const favCuisine =
      Object.entries(cuisineCounts).sort((a, b) => b[1] - a[1])[0]?.[0] ?? null;

    // ── Most visited restaurant ────────────────────────────────────────────
    const restCounts: Record<string, { name: string; count: number }> = {};
    for (const v of visits ?? []) {
      const r = v.restaurant as { id?: string; name?: string } | null;
      if (!r?.id) continue;
      if (!restCounts[r.id]) restCounts[r.id] = { name: r.name ?? "", count: 0 };
      restCounts[r.id].count++;
    }
    const mostVisited = Object.values(restCounts).sort((a, b) => b.count - a.count)[0] ?? null;

    // ── Average rating ────────────────────────────────────────────────────
    const rated = visits?.filter((v) => v.rating != null) ?? [];
    const avgRating =
      rated.length > 0
        ? Math.round((rated.reduce((s, v) => s + (v.rating ?? 0), 0) / rated.length) * 10) / 10
        : null;

    // ── Milestones ────────────────────────────────────────────────────────
    const milestones = MILESTONE_THRESHOLDS.filter((t) => totalVisits >= t).map((t) =>
      t === 1 ? "first_visit" : `${t}_visits`
    );
    if (streakWeeks >= 7) milestones.push("streak_7_weeks");

    return ok({
      total_visits: totalVisits,
      unique_cuisines: uniqueCuisines,
      total_miles_traveled: totalMiles,
      countries_visited: countries.size,
      cities_visited: cities.size,
      current_streak_weeks: streakWeeks,
      favorite_cuisine: favCuisine,
      most_visited_restaurant: mostVisited,
      avg_rating_given: avgRating,
      milestones,
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

function computeWeeklyStreak(dates: (string | null)[]): number {
  const weeks = new Set(
    dates
      .filter(Boolean)
      .map((d) => {
        const dt = new Date(d!);
        const startOfYear = new Date(dt.getFullYear(), 0, 1);
        return `${dt.getFullYear()}-W${Math.ceil(((dt.getTime() - startOfYear.getTime()) / 86400000 + startOfYear.getDay() + 1) / 7)}`;
      })
  );

  const sortedWeeks = Array.from(weeks).sort();
  if (!sortedWeeks.length) return 0;

  // Walk backwards from the most recent week to get the CURRENT streak.
  // (The old code returned maxStreak — the best streak ever — which is wrong
  //  because a user who was active months ago but hasn't visited recently would
  //  still show a high streak count.)
  let currentStreak = 1;

  for (let i = sortedWeeks.length - 1; i >= 1; i--) {
    const prev = sortedWeeks[i - 1].split("-W");
    const curr = sortedWeeks[i].split("-W");
    const prevYear = parseInt(prev[0]), prevWeek = parseInt(prev[1]);
    const currYear = parseInt(curr[0]), currWeek = parseInt(curr[1]);

    const isConsecutive =
      (currYear === prevYear && currWeek === prevWeek + 1) ||
      (currYear === prevYear + 1 && prevWeek >= 52 && currWeek === 1);

    if (isConsecutive) {
      currentStreak++;
    } else {
      break; // streak broken — stop here
    }
  }

  return currentStreak;
}
