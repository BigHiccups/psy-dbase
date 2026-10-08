import { google } from "googleapis";
import { supabaseAdmin } from "../../lib/supabase.js";
import { env } from "../../config/env.js";

// Cria o cliente OAuth2 configurado com nossas credenciais
function createOAuthClient() {
  return new google.auth.OAuth2(
    env.googleClientId,
    env.googleClientSecret,
    env.googleRedirectUri
  );
}

// Gera a URL de autorização do Google
// O usuário acessa essa URL, autoriza, e o Google chama nosso callback
export function getAuthUrl(userId: string): string {
  const oauth2Client = createOAuthClient();

  return oauth2Client.generateAuthUrl({
    access_type: "offline",              // garante refresh_token
    prompt: "consent select_account",    // força consentimento + escolha de conta
    scope: [
      "https://www.googleapis.com/auth/calendar",
    ],
    // Passa o userId no state para recuperar no callback
    state: userId,
  });
}

// Troca o code pelo refresh_token e salva no banco
export async function handleCallback(code: string, userId: string) {
  const oauth2Client = createOAuthClient();

  const { tokens } = await oauth2Client.getToken(code);

  if (!tokens.refresh_token) {
    throw new Error(
      "O Google não retornou refresh_token. " +
        "Remova o acesso do app em myaccount.google.com/permissions e tente novamente."
    );
  }

  // Log temporário: confirma qual conta autorizou
  // (remover depois que validar)
  try {
    const clientForInfo = createOAuthClient();
    clientForInfo.setCredentials(tokens);
    const oauth2 = google.oauth2({ version: "v2", auth: clientForInfo });
    const userInfo = await oauth2.userinfo.get();
    console.log("[calendar] conta autorizada:", userInfo.data.email);
  } catch (err) {
    console.warn("[calendar] falha ao consultar e-mail autorizado:", err);
  }

  const { error } = await supabaseAdmin
    .from("google_credentials")
    .upsert({
      user_id: userId,
      refresh_token: tokens.refresh_token,
      access_token: tokens.access_token ?? null,
      expires_at: tokens.expiry_date
        ? new Date(tokens.expiry_date).toISOString()
        : null,
      scope: tokens.scope ?? "https://www.googleapis.com/auth/calendar",
      updated_at: new Date().toISOString(),
    });

  if (error) {
    throw new Error("Falha ao salvar credenciais do Google: " + error.message);
  }
}

// Verifica se o usuário já conectou o Google Calendar
export async function getConnectionStatus(userId: string) {
  const { data, error } = await supabaseAdmin
    .from("google_credentials")
    .select("user_id, scope, created_at, updated_at")
    .eq("user_id", userId)
    .maybeSingle();

  if (error) {
    throw new Error("Falha ao consultar credenciais: " + error.message);
  }

  return {
    connected: !!data,
    scope: data?.scope ?? null,
    connectedAt: data?.created_at ?? null,
  };
}

// Cria um cliente autenticado para chamar a API do Calendar
// (renova o access token automaticamente se estiver expirado)
export async function getAuthorizedClient(userId: string) {
  const { data, error } = await supabaseAdmin
    .from("google_credentials")
    .select("refresh_token")
    .eq("user_id", userId)
    .maybeSingle();

  if (error || !data?.refresh_token) {
    throw new Error("Usuário não conectou o Google Calendar.");
  }

  const oauth2Client = createOAuthClient();
  oauth2Client.setCredentials({ refresh_token: data.refresh_token });

  return oauth2Client;
}

// Desconecta (remove credenciais)
export async function disconnect(userId: string) {
  const { error } = await supabaseAdmin
    .from("google_credentials")
    .delete()
    .eq("user_id", userId);

  if (error) {
    throw new Error("Falha ao desconectar: " + error.message);
  }
}

// =========================================================
// Google Calendar API
// =========================================================

// Lista eventos de um período
// Retorna eventos expandidos (recorrência materializada)
export async function listEvents(
  userId: string,
  timeMin: string,
  timeMax: string
) {
  const auth = await getAuthorizedClient(userId);
  const calendar = google.calendar({ version: "v3", auth });

  const res = await calendar.events.list({
    calendarId: "primary",
    timeMin,
    timeMax,
    singleEvents: true,       // expande eventos recorrentes em ocorrências
    orderBy: "startTime",
    maxResults: 2500,
  });

  return res.data.items ?? [];
}