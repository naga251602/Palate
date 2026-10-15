-- ============================================================
-- Palate — Email contact mapping + notifications
-- ============================================================

-- Allow fast lookup of contact items by type/value
CREATE INDEX IF NOT EXISTS idx_contact_items_user_type_value
  ON public.contact_items(user_id, type, lower(value));

CREATE INDEX IF NOT EXISTS idx_contact_items_type_value
  ON public.contact_items(type, lower(value));

-- Ensure the sign-up trigger stores the primary auth email as a contact item
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.profiles (id, username, display_name)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'username', split_part(NEW.email, '@', 1)),
    COALESCE(NEW.raw_user_meta_data->>'display_name', split_part(NEW.email, '@', 1))
  );

  INSERT INTO public.contact_items (user_id, type, value, is_primary)
  VALUES (NEW.id, 'email', NEW.email, true);

  INSERT INTO public.notification_preferences (user_id) VALUES (NEW.id);
  RETURN NEW;
END;
$$;

-- Notification center table for imported email events and future app alerts
CREATE TABLE IF NOT EXISTS public.notifications (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid REFERENCES public.profiles(id) ON DELETE CASCADE,
  type          text NOT NULL,
  title         text NOT NULL,
  body          text,
  logo_url      text,
  restaurant_id uuid REFERENCES public.restaurants(id),
  visit_id      uuid REFERENCES public.visits(id),
  source        text,
  metadata      jsonb NOT NULL DEFAULT '{}'::jsonb,
  is_read       boolean DEFAULT false,
  created_at    timestamptz DEFAULT now()
);

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
CREATE POLICY "own_all"       ON public.notifications FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "service_write" ON public.notifications FOR INSERT WITH CHECK (auth.role() = 'service_role');

CREATE INDEX IF NOT EXISTS idx_notifications_user_created
  ON public.notifications(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notifications_unread
  ON public.notifications(user_id, is_read, created_at DESC);
