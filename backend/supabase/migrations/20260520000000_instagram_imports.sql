-- ============================================================
-- Migration: Instagram imports audit table + wishlist constraints
-- ============================================================

-- ── instagram_imports: one row per shared post processed ─────────────────────
CREATE TABLE IF NOT EXISTS public.instagram_imports (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid REFERENCES public.profiles(id) ON DELETE CASCADE,
  sender_igsid     text,           -- Meta Instagram-scoped user ID (numeric)
  sender_username  text,           -- resolved @handle (may be null)
  instagram_url    text NOT NULL,
  caption_text     text,
  extracted_name   text,
  location_hint    text,
  restaurant_id    uuid REFERENCES public.restaurants(id),
  created_at       timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_instagram_imports_user       ON public.instagram_imports(user_id);
CREATE INDEX IF NOT EXISTS idx_instagram_imports_sender     ON public.instagram_imports(sender_igsid);
CREATE INDEX IF NOT EXISTS idx_instagram_imports_restaurant ON public.instagram_imports(restaurant_id);

ALTER TABLE public.instagram_imports ENABLE ROW LEVEL SECURITY;
CREATE POLICY "own_all" ON public.instagram_imports FOR ALL USING (auth.uid() = user_id);

-- ── wishlists: unique constraint required for upsert onConflict ───────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.wishlists'::regclass
      AND conname  = 'wishlists_user_restaurant_unique'
  ) THEN
    ALTER TABLE public.wishlists
      ADD CONSTRAINT wishlists_user_restaurant_unique
      UNIQUE (user_id, restaurant_id);
  END IF;
END;
$$;

-- ── notifications table (if not already present) ──────────────────────────────
-- import-email references this table; adding here in case it's missing
CREATE TABLE IF NOT EXISTS public.notifications (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid REFERENCES public.profiles(id) ON DELETE CASCADE,
  type          text NOT NULL,
  title         text NOT NULL,
  body          text,
  restaurant_id uuid REFERENCES public.restaurants(id),
  visit_id      uuid REFERENCES public.visits(id),
  logo_url      text,
  source        text,
  metadata      jsonb DEFAULT '{}',
  is_read       boolean DEFAULT false,
  created_at    timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_notifications_user ON public.notifications(user_id, created_at DESC);

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
CREATE POLICY "own_all" ON public.notifications FOR ALL USING (auth.uid() = user_id);

-- ── Index: filter wishlists by source ────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_wishlists_saved_from ON public.wishlists(user_id, saved_from);
