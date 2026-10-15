// supabase/functions/_shared/utils.ts
// Shared helpers used across all Palate edge functions

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

// ── Supabase client (service role — for server-side ops) ──────────────────────
export function getServiceClient(): SupabaseClient {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } }
  );
}

// ── Supabase client scoped to the calling user ────────────────────────────────
export function getUserClient(authHeader: string): SupabaseClient {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } }
  );
}

// ── Standard JSON response helpers ───────────────────────────────────────────
export const ok = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });

export const err = (message: string, status = 400) =>
  new Response(JSON.stringify({ error: message }), {
    status,
    headers: { "Content-Type": "application/json" },
  });

// ── CORS preflight ────────────────────────────────────────────────────────────
export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-webhook-secret, x-email-webhook-secret",
};

export const handleCors = (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
};

// ── Auth: extract user from JWT ───────────────────────────────────────────────
export async function requireUser(req: Request, supabase: SupabaseClient) {
  const token = req.headers.get("Authorization")?.replace("Bearer ", "");
  if (!token) throw new Error("Missing authorization token");

  const { data: { user }, error } = await supabase.auth.getUser(token);
  if (error || !user) throw new Error("Unauthorized");
  return user;
}

// ── Normalize emails for lookup ───────────────────────────────────────────────
export function normalizeEmail(email: string): string {
  return email.trim().toLowerCase();
}

export function parseEmailList(input?: string | string[] | null): string[] {
  if (!input) return [];
  const raw = Array.isArray(input) ? input : input.split(",");
  return raw
    .map((item) => normalizeEmail(item))
    .filter(Boolean);
}

// ── Visit classification ──────────────────────────────────────────────────────
export function classifyVisitType(visitDate?: string | null, visitTime?: string | null): "visited" | "upcoming" {
  if (!visitDate) return "visited";

  const now = new Date();
  const datePart = visitDate.slice(0, 10);
  const today = now.toISOString().slice(0, 10);

  if (datePart > today) return "upcoming";
  if (datePart < today) return "visited";

  if (!visitTime) return "visited";

  const candidate = new Date(`${datePart}T${visitTime.length === 5 ? `${visitTime}:00` : visitTime}`);
  if (isNaN(candidate.getTime())) return "visited";

  return candidate.getTime() > now.getTime() ? "upcoming" : "visited";
}

// ── Yelp API helper ───────────────────────────────────────────────────────────
export async function yelpFetch(path: string, params?: Record<string, string | number | boolean>) {
  const apiKey = Deno.env.get("YELP_API_KEY")!;
  const url = new URL(`https://api.yelp.com/v3${path}`);
  if (params) {
    Object.entries(params).forEach(([k, v]) => url.searchParams.set(k, String(v)));
  }
  const res = await fetch(url.toString(), {
    headers: { Authorization: `Bearer ${apiKey}` },
  });
  if (!res.ok) throw new Error(`Yelp API error ${res.status}: ${await res.text()}`);
  return res.json();
}

// ── Milestone checker ─────────────────────────────────────────────────────────
export function checkMilestone(totalVisits: number): string | null {
  const milestones: Record<number, string> = {
    1: "first_visit",
    10: "10_visits",
    50: "50_visits",
    100: "100_visits",
    250: "250_visits",
  };
  return milestones[totalVisits] ?? null;
}

// ── Points calculator ─────────────────────────────────────────────────────────
export function calculatePoints(visitType: string, hasDishes: boolean, hasPhotos: boolean): number {
  let pts = 10; // base
  if (visitType === "visited") pts += 20;
  if (hasDishes) pts += 10;
  if (hasPhotos) pts += 10;
  return pts;
}

// ── Friendly auth error helper for client-side mapping ────────────────────────
export function normalizeAuthErrorMessage(message: string): string {
  const text = message.toLowerCase();

  if (text.includes("invalid login credentials")) return "Invalid login credentials";
  if (text.includes("email not confirmed")) return "Please verify your email before logging in";
  if (text.includes("password should be at least")) return "Password is too short";
  if (text.includes("user not found")) return "Account not found";
  if (text.includes("too many requests")) return "Too many attempts. Please try again later";
  if (text.includes("token has expired")) return "Your session expired. Please sign in again";

  return message;
}
