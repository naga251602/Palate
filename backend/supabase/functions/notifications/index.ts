// supabase/functions/notifications/index.ts
// GET /functions/v1/notifications       — fetch paginated notifications (marks fetched unread items as read)
// DELETE /functions/v1/notifications    — delete a single notification by id

import { err, getServiceClient, handleCors, ok, requireUser } from "../_shared/utils.ts";

Deno.serve(async (req) => {
  const cors = handleCors(req);
  if (cors) return cors;

  const supabase = getServiceClient();

  try {
    const user = await requireUser(req, supabase);

    // ── DELETE: remove a single notification ───────────────────────────────
    if (req.method === "DELETE") {
      const body = await req.json().catch(() => ({}));
      const notificationId = body?.notification_id as string | undefined;
      if (!notificationId) return err("notification_id is required");

      const { error } = await supabase
        .from("notifications")
        .delete()
        .eq("id", notificationId)
        .eq("user_id", user.id); // ensure ownership

      if (error) throw error;
      return ok({ deleted: true, notification_id: notificationId });
    }

    // ── GET: fetch paginated notifications ────────────────────────────────
    if (req.method !== "GET") return err("Method not allowed", 405);

    const url = new URL(req.url);
    const limit = Math.min(parseInt(url.searchParams.get("limit") ?? "20"), 50);
    const before = url.searchParams.get("before");

    let query = supabase
      .from("notifications")
      .select(`
        id,
        type,
        title,
        body,
        logo_url,
        is_read,
        created_at,
        restaurant:restaurants!notifications_restaurant_id_fkey (
          id,
          name,
          image_url,
          cuisine_tags,
          price_range
        ),
        visit:visits!notifications_visit_id_fkey (
          id,
          visit_type,
          visit_date,
          visit_time
        )
      `)
      .eq("user_id", user.id)
      .order("created_at", { ascending: false })
      .limit(limit + 1);

    if (before) {
      query = query.lt("created_at", before);
    }

    const { data: items, error } = await query;
    if (error) throw error;

    const hasMore = (items?.length ?? 0) > limit;
    const notifications = (items ?? []).slice(0, limit);

    const unreadIds = notifications.filter((i) => !i.is_read).map((i) => i.id);
    if (unreadIds.length > 0) {
      await supabase
        .from("notifications")
        .update({ is_read: true })
        .in("id", unreadIds);
    }

    return ok({ items: notifications, has_more: hasMore });
  } catch (e) {
    console.error(e);
    return err(e instanceof Error ? e.message : "Internal error", 500);
  }
});
