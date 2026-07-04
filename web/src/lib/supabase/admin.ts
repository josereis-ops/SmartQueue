import { createClient } from "@supabase/supabase-js";

/** Cliente service_role — apenas rotas servidor (cron, jobs). Nunca expor ao browser. */
export function createAdminClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL?.trim();
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY?.trim();

  if (!url || !key) {
    throw new Error(
      "SUPABASE_SERVICE_ROLE_KEY em falta. Necessario para import Evalyze cron."
    );
  }

  return createClient(url, key, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  });
}
