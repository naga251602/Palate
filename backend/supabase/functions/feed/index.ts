// supabase/functions/feed/index.ts
// GET /functions/v1/feed
// Returns the paginated friend activity feed for the authenticated user.

import { err, getServiceClient, handleCors, ok, requireUser } from "../_shared/utils.ts";

Deno.serve(async (req) => {
  const cors = handleCors(req);
  if (cors) return cors;

  const supabase = getServiceClient();

  try {
    const user = await requireUser(req, supabase);
    const url = new URL(req.url);
    const limit = Math.min(parseInt(url.searchParams.get("limit") ?? "20"), 50);
    const before = url.searchParams.get("before"); // ISO datetime cursor

    let query = supabase
      .from("activity_feed")
      .select(`
        id,
        type,
        created_at,
        is_read,
        actor:profiles!activity_feed_actor_id_fkey (
          username,
          display_name,
          avatar_url
        ),
        visit:visits!activity_feed_visit_id_fkey (
          rating,
          notes,
          visit_date,
          dishes (name, rating)
        ),
        restaurant:restaurants!activity_feed_restaurant_id_fkey (
          id,
          name,
          city,
          image_url,
          cuisine_tags,
          price_range
        )
      `)
      .eq("recipient_id", user.id)
      .order("created_at", { ascending: false })
      .limit(limit + 1); // fetch one extra to determine has_more

    if (before) {
      query = query.lt("created_at", before);
    }

    const { data: items, error } = await query;
    if (error) throw error;

    const hasMore = (items?.length ?? 0) > limit;
    const feed = (items ?? []).slice(0, limit);

    // Mark fetched items as read
    const unreadIds = feed.filter((i) => !i.is_read).map((i) => i.id);
    if (unreadIds.length > 0) {
      await supabase
        .from("activity_feed")
        .update({ is_read: true })
        .in("id", unreadIds);
    }

    return ok({ items: feed, has_more: hasMore });
  } catch (e) {
    console.error(e);
    return err(e instanceof Error ? e.message : "Internal error", 500);
  }
});
