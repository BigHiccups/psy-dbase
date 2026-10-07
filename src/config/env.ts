import "dotenv/config";

// Valida e expõe variáveis de ambiente — falha cedo se faltar alguma
function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Variável de ambiente ausente: ${name}`);
  return value;
}

export const env = {
  port: Number(process.env.PORT ?? 3333),
  supabaseUrl: required("SUPABASE_URL"),
  supabaseServiceRoleKey: required("SUPABASE_SERVICE_ROLE_KEY"),
  frontendUrl: process.env.FRONTEND_URL ?? "http://localhost:5173",
};