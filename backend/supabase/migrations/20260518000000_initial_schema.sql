-- ============================================================
-- Palate — Initial Schema Migration
-- ============================================================

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_cron";
CREATE EXTENSION IF NOT EXISTS "pg_net";

-- ============================================================
-- TABLES
-- ============================================================

-- profiles
CREATE TABLE IF NOT EXISTS public.profiles (
  id              uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  username        text UNIQUE NOT NULL,
  display_name    text,
  avatar_url      text,
  bio             text,
  is_pro          boolean DEFAULT false,
  total_visits    integer DEFAULT 0,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now()
);

-- contact_items
CREATE TABLE IF NOT EXISTS public.contact_items (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid REFERENCES public.profiles(id) ON DELETE CASCADE,
  type        text CHECK (type IN ('email','instagram','phone')),
  value       text NOT NULL,
  is_primary  boolean DEFAULT false,
  created_at  timestamptz DEFAULT now()
);

-- restaurants (Yelp cache)
CREATE TABLE IF NOT EXISTS public.restaurants (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  yelp_id         text UNIQUE NOT NULL,
  name            text NOT NULL,
  address         text,
  city            text,
  state           text,
  country         text,
  lat             float8,
  lng             float8,
  phone           text,
  price_range     text,
  cuisine_tags    text[],
  rating          float4,
  review_count    integer,
  image_url       text,
  yelp_url        text,
  hours           jsonb,
  is_open_now     boolean,
  last_synced_at  timestamptz,
  created_at      timestamptz DEFAULT now()
);

-- visits
CREATE TABLE IF NOT EXISTS public.visits (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid REFERENCES public.profiles(id) ON DELETE CASCADE,
  restaurant_id   uuid REFERENCES public.restaurants(id),
  visit_type      text CHECK (visit_type IN ('visited','upcoming','wishlist')),
  visit_date      date,
  visit_time      time,
  party_size      integer,
  rating          float4,
  notes           text,
  source          text,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now()
);

-- visit_photos
CREATE TABLE IF NOT EXISTS public.visit_photos (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  visit_id      uuid REFERENCES public.visits(id) ON DELETE CASCADE,
  user_id       uuid REFERENCES public.profiles(id),
  storage_path  text NOT NULL,
  caption       text,
  created_at    timestamptz DEFAULT now()
);

-- dishes
CREATE TABLE IF NOT EXISTS public.dishes (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  visit_id    uuid REFERENCES public.visits(id) ON DELETE CASCADE,
  name        text NOT NULL,
  rating      integer CHECK (rating BETWEEN 1 AND 5),
  notes       text,
  photo_path  text
);

-- wishlists
CREATE TABLE IF NOT EXISTS public.wishlists (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid REFERENCES public.profiles(id) ON DELETE CASCADE,
  restaurant_id   uuid REFERENCES public.restaurants(id),
  saved_from      text,
  saved_at        timestamptz DEFAULT now()
);

-- reservations
CREATE TABLE IF NOT EXISTS public.reservations (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id             uuid REFERENCES public.profiles(id) ON DELETE CASCADE,
  restaurant_id       uuid REFERENCES public.restaurants(id),
  visit_id            uuid REFERENCES public.visits(id),
  reservation_date    date NOT NULL,
  reservation_time    time NOT NULL,
  party_size          integer NOT NULL,
  confirmation_code   text,
  platform            text,
  reminder_sent       boolean DEFAULT false,
  cancelled_at        timestamptz,
  created_at          timestamptz DEFAULT now()
);

-- follows
CREATE TABLE IF NOT EXISTS public.follows (
  follower_id   uuid REFERENCES public.profiles(id) ON DELETE CASCADE,
  following_id  uuid REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at    timestamptz DEFAULT now(),
  PRIMARY KEY (follower_id, following_id)
);

-- activity_feed
CREATE TABLE IF NOT EXISTS public.activity_feed (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id        uuid REFERENCES public.profiles(id),
  recipient_id    uuid REFERENCES public.profiles(id),
  type            text,
  visit_id        uuid REFERENCES public.visits(id),
  restaurant_id   uuid REFERENCES public.restaurants(id),
  is_read         boolean DEFAULT false,
  created_at      timestamptz DEFAULT now()
);

-- push_tokens
CREATE TABLE IF NOT EXISTS public.push_tokens (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid REFERENCES public.profiles(id) ON DELETE CASCADE,
  device_token  text NOT NULL,
  platform      text DEFAULT 'ios',
  created_at    timestamptz DEFAULT now(),
  UNIQUE (user_id, device_token)
);

-- notification_preferences
CREATE TABLE IF NOT EXISTS public.notification_preferences (
  user_id                 uuid PRIMARY KEY REFERENCES public.profiles(id),
  reservation_reminder    boolean DEFAULT true,
  friend_activity         boolean DEFAULT true,
  nearby_hotspots         boolean DEFAULT true,
  milestone_streaks       boolean DEFAULT true,
  reminder_hours_before   integer DEFAULT 3
);

-- ============================================================
-- INDEXES
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_restaurants_yelp_id       ON public.restaurants(yelp_id);
CREATE INDEX IF NOT EXISTS idx_restaurants_last_synced   ON public.restaurants(last_synced_at);
CREATE INDEX IF NOT EXISTS idx_restaurants_city          ON public.restaurants(city);
CREATE INDEX IF NOT EXISTS idx_restaurants_location      ON public.restaurants(lat, lng);

CREATE INDEX IF NOT EXISTS idx_visits_user_id            ON public.visits(user_id);
CREATE INDEX IF NOT EXISTS idx_visits_restaurant_id      ON public.visits(restaurant_id);
CREATE INDEX IF NOT EXISTS idx_visits_visit_date         ON public.visits(visit_date DESC);
CREATE INDEX IF NOT EXISTS idx_visits_type               ON public.visits(visit_type);

CREATE INDEX IF NOT EXISTS idx_wishlists_user_id         ON public.wishlists(user_id);
CREATE INDEX IF NOT EXISTS idx_activity_feed_recipient   ON public.activity_feed(recipient_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_follows_follower          ON public.follows(follower_id);
CREATE INDEX IF NOT EXISTS idx_follows_following         ON public.follows(following_id);
CREATE INDEX IF NOT EXISTS idx_push_tokens_user_id       ON public.push_tokens(user_id);
CREATE INDEX IF NOT EXISTS idx_reservations_user_id      ON public.reservations(user_id);
CREATE INDEX IF NOT EXISTS idx_reservations_reminder     ON public.reservations(reminder_sent, reservation_date, reservation_time)
  WHERE cancelled_at IS NULL;

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================

-- profiles
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "public_read"  ON public.profiles FOR SELECT USING (true);
CREATE POLICY "own_write"    ON public.profiles FOR ALL    USING (auth.uid() = id);

-- contact_items
ALTER TABLE public.contact_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "own_all" ON public.contact_items FOR ALL USING (auth.uid() = user_id);

-- restaurants — public read, service role write
ALTER TABLE public.restaurants ENABLE ROW LEVEL SECURITY;
CREATE POLICY "public_read"        ON public.restaurants FOR SELECT USING (true);
CREATE POLICY "service_role_write" ON public.restaurants FOR ALL USING (auth.role() = 'service_role');

-- visits
ALTER TABLE public.visits ENABLE ROW LEVEL SECURITY;
CREATE POLICY "own_all"       ON public.visits FOR ALL    USING (auth.uid() = user_id);
CREATE POLICY "followers_read" ON public.visits FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM public.follows
    WHERE follower_id = auth.uid() AND following_id = visits.user_id
  )
);

-- visit_photos
ALTER TABLE public.visit_photos ENABLE ROW LEVEL SECURITY;
CREATE POLICY "own_all"        ON public.visit_photos FOR ALL    USING (auth.uid() = user_id);
CREATE POLICY "followers_read" ON public.visit_photos FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM public.follows f
    JOIN public.visits v ON v.id = visit_photos.visit_id
    WHERE f.follower_id = auth.uid() AND f.following_id = v.user_id
  )
);

-- dishes
ALTER TABLE public.dishes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "visit_owner_all" ON public.dishes FOR ALL USING (
  EXISTS (
    SELECT 1 FROM public.visits v WHERE v.id = dishes.visit_id AND v.user_id = auth.uid()
  )
);

-- wishlists
ALTER TABLE public.wishlists ENABLE ROW LEVEL SECURITY;
CREATE POLICY "own_all" ON public.wishlists FOR ALL USING (auth.uid() = user_id);

-- reservations
ALTER TABLE public.reservations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "own_all" ON public.reservations FOR ALL USING (auth.uid() = user_id);

-- follows
ALTER TABLE public.follows ENABLE ROW LEVEL SECURITY;
CREATE POLICY "own_all"       ON public.follows FOR ALL    USING (auth.uid() = follower_id);
CREATE POLICY "public_read"   ON public.follows FOR SELECT USING (true);

-- activity_feed
ALTER TABLE public.activity_feed ENABLE ROW LEVEL SECURITY;
CREATE POLICY "recipient_read" ON public.activity_feed FOR SELECT USING (auth.uid() = recipient_id);
CREATE POLICY "service_write"  ON public.activity_feed FOR INSERT WITH CHECK (auth.role() = 'service_role');

-- push_tokens
ALTER TABLE public.push_tokens ENABLE ROW LEVEL SECURITY;
CREATE POLICY "own_all" ON public.push_tokens FOR ALL USING (auth.uid() = user_id);

-- notification_preferences
ALTER TABLE public.notification_preferences ENABLE ROW LEVEL SECURITY;
CREATE POLICY "own_all" ON public.notification_preferences FOR ALL USING (auth.uid() = user_id);

-- ============================================================
-- TRIGGERS
-- ============================================================

-- Auto-create profile on signup
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.profiles (id, username, display_name)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'username', split_part(NEW.email, '@', 1)),
    COALESCE(NEW.raw_user_meta_data->>'display_name', split_part(NEW.email, '@', 1))
  );
  INSERT INTO public.notification_preferences (user_id) VALUES (NEW.id);
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Auto-update profiles.updated_at
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER profiles_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER visits_updated_at
  BEFORE UPDATE ON public.visits
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ============================================================
-- STORAGE BUCKETS
-- ============================================================

INSERT INTO storage.buckets (id, name, public)
VALUES
  ('palate-avatars',       'palate-avatars',       true),
  ('palate-visit-photos',  'palate-visit-photos',  true)
ON CONFLICT (id) DO NOTHING;

-- Storage RLS
CREATE POLICY "avatar_owner_upload" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'palate-avatars' AND auth.uid()::text = (storage.foldername(name))[1]
  );

CREATE POLICY "avatar_owner_delete" ON storage.objects
  FOR DELETE USING (
    bucket_id = 'palate-avatars' AND auth.uid()::text = (storage.foldername(name))[1]
  );

CREATE POLICY "avatar_public_read" ON storage.objects
  FOR SELECT USING (bucket_id = 'palate-avatars');

CREATE POLICY "visit_photo_owner_upload" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'palate-visit-photos' AND auth.uid()::text = (storage.foldername(name))[1]
  );

CREATE POLICY "visit_photo_owner_delete" ON storage.objects
  FOR DELETE USING (
    bucket_id = 'palate-visit-photos' AND auth.uid()::text = (storage.foldername(name))[1]
  );

CREATE POLICY "visit_photo_public_read" ON storage.objects
  FOR SELECT USING (bucket_id = 'palate-visit-photos');

-- ============================================================
-- PG_CRON — Reservation Reminder Dispatcher
-- ============================================================
-- Runs every minute; calls the send-push edge function for due reminders.
-- Replace YOUR_PROJECT_REF with your actual Supabase project ref.

SELECT cron.schedule(
  'reservation-reminder-check',
  '* * * * *',
  $$
  SELECT net.http_post(
    url := current_setting('app.supabase_url') || '/functions/v1/send-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || current_setting('app.service_role_key')
    ),
    body := jsonb_build_object(
      'type', 'cron_reminder_dispatch'
    )
  )
  FROM public.reservations r
  JOIN public.notification_preferences np ON np.user_id = r.user_id
  WHERE
    r.reminder_sent = false
    AND r.cancelled_at IS NULL
    AND np.reservation_reminder = true
    AND (r.reservation_date + r.reservation_time)::timestamptz
        - (np.reminder_hours_before || ' hours')::interval <= now()
  LIMIT 1;  -- http_post fires once; the function handles the full batch
  $$
);
