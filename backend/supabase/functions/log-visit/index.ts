// supabase/functions/log-visit/index.ts
// POST/DELETE /functions/v1/log-visit
// Creates, updates, or deletes a visit log, writes dishes, fans out activity, checks milestones.

import {
  calculatePoints,
  checkMilestone,
  err,
  getServiceClient,
  handleCors,
  ok,
  requireUser,
} from "../_shared/utils.ts";

interface LogVisitRequest {
  restaurant_id?: string;
  visit_type?: "visited" | "upcoming" | "wishlist";
  visit_date?: string;
  visit_time?: string;
  party_size?: number;
  rating?: number;
  notes?: string;
  dishes?: { name: string; rating?: number; notes?: string }[];
  visit_id?: string;
}

Deno.serve(async (req) => {
  const cors = handleCors(req);
  if (cors) return cors;

  const supabase = getServiceClient();

  try {
    const user = await requireUser(req, supabase);

    if (req.method === "DELETE") {
      const body = await req.json().catch(() => ({}));
      const visitId = body?.visit_id as string | undefined;
      if (!visitId) return err("visit_id is required");

      const { data: visit, error: visitFetchErr } = await supabase
        .from("visits")
        .select("id, user_id, visit_type")
        .eq("id", visitId)
        .eq("user_id", user.id)
        .single();

      if (visitFetchErr || !visit) return err("Visit not found", 404);

      await cleanupVisitArtifacts(supabase, visit.id, user.id);

      if (visit.visit_type === "visited") {
        await decrementTotalVisits(supabase, user.id, 1);
      }

      const { error: deleteErr } = await supabase
        .from("visits")
        .delete()
        .eq("id", visit.id)
        .eq("user_id", user.id);

      if (deleteErr) throw deleteErr;

      const { data: profile } = await supabase
        .from("profiles")
        .select("total_visits")
        .eq("id", user.id)
        .single();

      return ok({
        deleted: true,
        visit_id: visit.id,
        previous_visit_type: visit.visit_type,
        total_visits: profile?.total_visits ?? 0,
      });
    }

    if (req.method !== "POST") {
      return err("Method not allowed", 405);
    }

    const body: LogVisitRequest = await req.json();
    const {
      restaurant_id,
      visit_type,
      visit_date,
      visit_time,
      party_size,
      rating,
      notes,
      dishes = [],
      visit_id,
    } = body;

    if (!restaurant_id || !visit_type) {
      return err("restaurant_id and visit_type are required");
    }

    let previousVisitType: "visited" | "upcoming" | "wishlist" | null = null;
    let visit;

    if (visit_id) {
      const { data: existingVisit, error: existingErr } = await supabase
        .from("visits")
        .select("id, user_id, visit_type, restaurant_id")
        .eq("id", visit_id)
        .eq("user_id", user.id)
        .single();

      if (existingErr || !existingVisit) return err("Visit not found", 404);
      previousVisitType = existingVisit.visit_type as "visited" | "upcoming" | "wishlist";

      const { data, error } = await supabase
        .from("visits")
        .update({
          restaurant_id,
          visit_type,
          visit_date,
          visit_time,
          party_size,
          rating,
          notes,
          updated_at: new Date().toISOString(),
        })
        .eq("id", visit_id)
        .eq("user_id", user.id)
        .select()
        .single();
      if (error) throw error;
      visit = data;
    } else {
      const { data, error } = await supabase
        .from("visits")
        .insert({
          user_id: user.id,
          restaurant_id,
          visit_type,
          visit_date,
          visit_time,
          party_size,
          rating,
          notes,
          source: "manual",
        })
        .select()
        .single();
      if (error) throw error;
      visit = data;
    }

    if (dishes.length > 0) {
      // Delete existing dish rows first — prevents duplicates when updating an existing visit
      if (visit_id) {
        await supabase.from("dishes").delete().eq("visit_id", visit.id);
      }
      const dishRows = dishes.map((d) => ({
        visit_id: visit.id,
        name: d.name,
        rating: d.rating ?? null,
        notes: d.notes ?? null,
      }));
      await supabase.from("dishes").insert(dishRows);
    }

    // Keep reservations table in sync so schedule-reminder can find the row.
    // The iOS client passes visit_id as reservation_id to schedule-reminder, so we
    // use visit.id as the reservation primary key (1-to-1 mapping).
    if (visit_type === "upcoming" && visit_date && visit_time) {
      await supabase.from("reservations").upsert(
        {
          id: visit.id,
          user_id: user.id,
          restaurant_id,
          visit_id: visit.id,
          reservation_date: visit_date,
          reservation_time: visit_time,
          party_size: party_size ?? 2,
          reminder_sent: false,
          cancelled_at: null,
        },
        { onConflict: "id" }
      );
    } else if (previousVisitType === "upcoming" && visit_type !== "upcoming") {
      // Visit moved out of upcoming — cancel the reservation so cron skips it
      await supabase
        .from("reservations")
        .update({ cancelled_at: new Date().toISOString() })
        .eq("visit_id", visit.id);
    }

    const visitBecameVisited =
      visit_type === "visited" && previousVisitType !== "visited";
    const visitStoppedBeingVisited =
      previousVisitType === "visited" && visit_type !== "visited";

    let totalVisits = await getTotalVisits(supabase, user.id);
    if (visitBecameVisited) totalVisits += 1;
    if (visitStoppedBeingVisited) totalVisits = Math.max(0, totalVisits - 1);

    if (visitBecameVisited || visitStoppedBeingVisited) {
      await supabase
        .from("profiles")
        .update({ total_visits: totalVisits })
        .eq("id", user.id);
    }

    const milestone = checkMilestone(totalVisits);

    const announceVisit = !visit_id
      ? visit_type === "visited"
      : previousVisitType !== "visited" && visit_type === "visited";

    if (announceVisit && visit_type === "visited") {
      const { data: followers } = await supabase
        .from("follows")
        .select("follower_id")
        .eq("following_id", user.id);

      if (followers && followers.length > 0) {
        const feedRows = followers.map((f) => ({
          actor_id: user.id,
          recipient_id: f.follower_id,
          type: "new_visit",
          visit_id: visit.id,
          restaurant_id,
        }));
        await supabase.from("activity_feed").insert(feedRows);

        const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
        const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

        const { data: actorProfile } = await supabase
          .from("profiles")
          .select("display_name, username")
          .eq("id", user.id)
          .single();

        const actorName = actorProfile?.display_name ?? actorProfile?.username ?? "Someone";

        const { data: restaurant } = await supabase
          .from("restaurants")
          .select("name")
          .eq("id", restaurant_id)
          .single();

        for (const follower of followers) {
          const { data: prefs } = await supabase
            .from("notification_preferences")
            .select("friend_activity")
            .eq("user_id", follower.follower_id)
            .single();

          if (prefs?.friend_activity) {
            await fetch(`${supabaseUrl}/functions/v1/send-push`, {
              method: "POST",
              headers: {
                "Content-Type": "application/json",
                "Authorization": `Bearer ${serviceKey}`,
              },
              body: JSON.stringify({
                user_id: follower.follower_id,
                title: `${actorName} just visited somewhere 🍽️`,
                body: restaurant?.name
                  ? `They logged a visit to ${restaurant.name}`
                  : "Check their latest visit",
                data: { type: "friend_activity", visit_id: visit.id, restaurant_id },
              }),
            });
          }
        }
      }
    }

    if (milestone && visit_type === "visited") {
      const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
      const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

      const { data: prefs } = await supabase
        .from("notification_preferences")
        .select("milestone_streaks")
        .eq("user_id", user.id)
        .single();

      if (prefs?.milestone_streaks) {
        await fetch(`${supabaseUrl}/functions/v1/send-push`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${serviceKey}`,
          },
          body: JSON.stringify({
            user_id: user.id,
            title: "🎉 Milestone unlocked!",
            body: `You've hit ${totalVisits} visits. Keep exploring!`,
            data: { type: "milestone", milestone },
          }),
        });
      }
    }

    const points = calculatePoints(visit_type, dishes.length > 0, false);

    return ok({
      visit_id: visit.id,
      streak_count: totalVisits,
      milestone,
      points_earned: points,
    });
  } catch (e) {
    console.error(e);
    return err(e instanceof Error ? e.message : "Internal error", 500);
  }
});

async function getTotalVisits(supabase: ReturnType<typeof getServiceClient>, userId: string): Promise<number> {
  const { data, error } = await supabase
    .from("profiles")
    .select("total_visits")
    .eq("id", userId)
    .single();
  if (error) throw error;
  return data?.total_visits ?? 0;
}

async function decrementTotalVisits(supabase: ReturnType<typeof getServiceClient>, userId: string, amount: number) {
  const current = await getTotalVisits(supabase, userId);
  const next = Math.max(0, current - amount);
  const { error } = await supabase
    .from("profiles")
    .update({ total_visits: next })
    .eq("id", userId);
  if (error) throw error;
}

async function cleanupVisitArtifacts(
  supabase: ReturnType<typeof getServiceClient>,
  visitId: string,
  userId: string,
) {
  await supabase.from("dishes").delete().eq("visit_id", visitId);

  await supabase.from("notifications").delete().eq("visit_id", visitId).eq("user_id", userId);
  await supabase.from("activity_feed").delete().eq("visit_id", visitId).or(`recipient_id.eq.${userId},actor_id.eq.${userId}`);

  await supabase.from("reservations").delete().eq("visit_id", visitId).eq("user_id", userId);
}
