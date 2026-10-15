// supabase/functions/profile-details/index.ts
// GET/POST/DELETE /functions/v1/profile-details
// Returns the authenticated user's profile and grouped contact items (emails, Instagram, phone).

import { err, getServiceClient, handleCors, normalizeEmail, ok, requireUser } from "../_shared/utils.ts";

type ContactType = "email" | "instagram" | "phone";

interface ContactItemInput {
  type: ContactType;
  value: string;
  is_primary?: boolean;
}

Deno.serve(async (req) => {
  const cors = handleCors(req);
  if (cors) return cors;

  const supabase = getServiceClient();

  try {
    const user = await requireUser(req, supabase);

    if (req.method === "GET") {
      const payload = await loadProfileDetails(supabase, user.id);
      return ok(payload);
    }

    if (req.method === "POST") {
      const body = await req.json();
      const items: ContactItemInput[] = Array.isArray(body?.items) ? body.items : body?.item ? [body.item] : [];

      if (!items.length) return err("items are required");

      const saved: unknown[] = [];
      for (const item of items) {
        if (!["email", "instagram", "phone"].includes(item.type)) {
          return err(`Unsupported contact type: ${item.type}`);
        }

        const value = normalizeContactValue(item.type, item.value);
        if (!value) return err("Contact value is required");

        const { data: existing, error: existingErr } = await supabase
          .from("contact_items")
          .select("id")
          .eq("user_id", user.id)
          .eq("type", item.type)
          .ilike("value", value)
          .maybeSingle();
        if (existingErr) throw existingErr;

        if (existing?.id) {
          const { data, error } = await supabase
            .from("contact_items")
            .update({ value, is_primary: item.is_primary ?? false })
            .eq("id", existing.id)
            .eq("user_id", user.id)
            .select()
            .single();
          if (error) throw error;
          saved.push(data);
        } else {
          const { data, error } = await supabase
            .from("contact_items")
            .insert({
              user_id: user.id,
              type: item.type,
              value,
              is_primary: item.is_primary ?? false,
            })
            .select()
            .single();
          if (error) throw error;
          saved.push(data);
        }

        // If this item is being set as primary, demote all other items of the same type.
        // Without this, multiple items can have is_primary=true simultaneously.
        if (item.is_primary) {
          const savedId = (saved[saved.length - 1] as { id?: string })?.id;
          if (savedId) {
            await supabase
              .from("contact_items")
              .update({ is_primary: false })
              .eq("user_id", user.id)
              .eq("type", item.type)
              .neq("id", savedId);
          }
        }
      }

      const payload = await loadProfileDetails(supabase, user.id);
      return ok({ ...payload, saved });
    }

    if (req.method === "DELETE") {
      const body = await req.json().catch(() => ({}));
      const contactItemId = body?.contact_item_id;
      if (!contactItemId) return err("contact_item_id is required");

      const { error } = await supabase
        .from("contact_items")
        .delete()
        .eq("id", contactItemId)
        .eq("user_id", user.id);
      if (error) throw error;

      return ok({ deleted: true });
    }

    return err("Method not allowed", 405);
  } catch (e) {
    console.error(e);
    return err(e instanceof Error ? e.message : "Internal error", 500);
  }
});

async function loadProfileDetails(supabase: ReturnType<typeof getServiceClient>, userId: string) {
  const { data: profile, error: profileErr } = await supabase
    .from("profiles")
    .select("id, username, display_name, avatar_url, bio, is_pro, total_visits, created_at, updated_at")
    .eq("id", userId)
    .single();
  if (profileErr) throw profileErr;

  const { data: contactItems, error: contactsErr } = await supabase
    .from("contact_items")
    .select("id, type, value, is_primary, created_at")
    .eq("user_id", userId)
    .order("is_primary", { ascending: false })
    .order("created_at", { ascending: true });
  if (contactsErr) throw contactsErr;

  return {
    profile,
    contact_items: groupContactItems(contactItems ?? []),
    contact_items_flat: contactItems ?? [],
  };
}

function groupContactItems(items: { type: string; value: string; is_primary: boolean; created_at?: string }[]) {
  const result: Record<string, typeof items> = {
    email: [],
    instagram: [],
    phone: [],
  };
  for (const item of items) {
    if (item.type in result) result[item.type].push(item);
  }
  return result;
}

function normalizeContactValue(type: ContactType, value: string): string {
  const trimmed = value.trim();
  if (type === "email") return normalizeEmail(trimmed);
  return trimmed;
}
