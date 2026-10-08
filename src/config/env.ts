import "dotenv/config";

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Variável de ambiente ausente: ${name}`);
  return value;
}

export const env = {
  port: Number(process.env.PORT ?? 3333),
  supabaseUrl: required("SUPABASE_URL"),
  supabaseServiceRoleKey: required("SUPABASE_SERVICE_ROLE_KEY"),
  frontendUrl: required("FRONTEND_URL"),
  tinyurlApiToken: required("TINYURL_API_TOKEN"),
  corsOrigins: (process.env.CORS_ORIGINS ?? process.env.FRONTEND_URL ?? "")
    .split(",")
    .map((o) => o.trim())
    .filter(Boolean),

  // Google Calendar OAuth
  googleClientId: required("GOOGLE_CLIENT_ID"),
  googleClientSecret: required("GOOGLE_CLIENT_SECRET"),
  googleRedirectUri: required("GOOGLE_REDIRECT_URI"),
};