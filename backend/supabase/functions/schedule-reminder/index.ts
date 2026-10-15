// supabase/functions/schedule-reminder/index.ts
// POST /functions/v1/schedule-reminder
// Stores reservation reminder details; actual dispatch is handled by pg_cron.

import { err, getServiceClient, handleCors, ok, requireUser } from "../_shared/utils.ts";

interface ScheduleReminderRequest {
  reservation_id: string;
  restaurant_name: string;
  reservation_datetime: string; // ISO 8601
  hours_before?: number;
}

Deno.serve(async (req) => {
  const cors = handleCors(req);
  if (cors) return cors;

  const supabase = getServiceClient();

  try {
    const user = await requireUser(req, supabase);
    const body: ScheduleReminderRequest = await req.json();

    const {
      reservation_id,
      restaurant_name,
      reservation_datetime,
      hours_before = 3,
    } = body;

    if (!reservation_id || !reservation_datetime) {
      return err("reservation_id and reservation_datetime are required");
    }

    // ── Verify ownership ───────────────────────────────────────────────────
    // The iOS client passes the visit_id as reservation_id.
    // First check the reservations table (populated by log-visit); fall back
    // to the visits table so this works even if the upsert hasn't committed yet.
    let ownedReservationId = reservation_id;

    const { data: reservation } = await supabase
      .from("reservations")
      .select("id, user_id")
      .or(`id.eq.${reservation_id},visit_id.eq.${reservation_id}`)
      .eq("user_id", user.id)
      .maybeSingle();

    if (!reservation) {
      // Fallback: verify via the visits table directly
      const { data: visit, error: visitErr } = await supabase
        .from("visits")
        .select("id, user_id")
        .eq("id", reservation_id)
        .eq("user_id", user.id)
        .maybeSingle();

      if (visitErr || !visit) return err("Reservation not found", 404);
      ownedReservationId = visit.id;
    } else {
      ownedReservationId = reservation.id;
    }

    // ── Compute fire time ──────────────────────────────────────────────────
    const reservationTs = new Date(reservation_datetime);
    if (isNaN(reservationTs.getTime())) {
      return err("Invalid reservation_datetime format");
    }
    const firesAt = new Date(reservationTs.getTime() - hours_before * 60 * 60 * 1000);

    // ── Update notification_preferences hours_before if user customised it ─
    await supabase
      .from("notification_preferences")
      .upsert({ user_id: user.id, reminder_hours_before: hours_before }, { onConflict: "user_id" });

    // ── Reset reminder_sent so cron will pick it up ────────────────────────
    await supabase
      .from("reservations")
      .update({ reminder_sent: false })
      .eq("id", ownedReservationId);

    return ok({
      scheduled: true,
      fires_at: firesAt.toISOString(),
      reservation_id,
      restaurant_name,
    });
  } catch (e) {
    console.error(e);
    return err(e instanceof Error ? e.message : "Internal error", 500);
  }
});
