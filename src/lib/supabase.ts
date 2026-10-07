import { createClient } from "@supabase/supabase-js";
import ws from "ws";
import { env } from "../config/env.js";

// Cliente admin — usa service_role, ignora RLS.
// Passa o WebSocket do Node 20 via pacote "ws".
export const supabaseAdmin = createClient(
  env.supabaseUrl,
  env.supabaseServiceRoleKey,
  {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
    realtime: {
      transport: ws as any,
    },
  }
);