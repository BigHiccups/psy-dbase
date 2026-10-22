import { google } from "googleapis";
import { supabaseAdmin } from "../../lib/supabase.js";
import { env } from "../../config/env.js";

function createOAuthClient() {
  return new google.auth.OAuth2(
    env.googleClientId,
    env.googleClientSecret,
    env.googleRedirectUri
  );
}

export function getAuthUrl(userId: string): string {
  const oauth2Client = createOAuthClient();
  return oauth2Client.generateAuthUrl({
    access_type: "offline",
    prompt: "consent select_account",
    scope: ["https://www.googleapis.com/auth/calendar"],
    state: userId,
  });
}

export async function handleCallback(code: string, userId: string) {
  const oauth2Client = createOAuthClient();
  const { tokens } = await oauth2Client.getToken(code);

  if (!tokens.refresh_token) {
    throw new Error("O Google não retornou refresh_token.");
  }

  const { error } = await supabaseAdmin
    .from("google_credentials")
    .upsert({
      user_id: userId,
      refresh_token: tokens.refresh_token,
      access_token: tokens.access_token ?? null,
      expires_at: tokens.expiry_date ? new Date(tokens.expiry_date).toISOString() : null,
      scope: tokens.scope ?? "https://www.googleapis.com/auth/calendar",
      updated_at: new Date().toISOString(),
    });

  if (error) throw new Error("Falha ao salvar credenciais: " + error.message);
}

export async function getConnectionStatus(userId: string) {
  const { data, error } = await supabaseAdmin
    .from("google_credentials")
    .select("user_id, scope, created_at, updated_at")
    .eq("user_id", userId)
    .maybeSingle();

  if (error) throw new Error("Falha ao consultar credenciais: " + error.message);

  return {
    connected: !!data,
    scope: data?.scope ?? null,
    connectedAt: data?.created_at ?? null,
  };
}

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

export async function disconnect(userId: string) {
  const { error } = await supabaseAdmin
    .from("google_credentials")
    .delete()
    .eq("user_id", userId);

  if (error) throw new Error("Falha ao desconectar: " + error.message);
}

export async function listEvents(userId: string, timeMin: string, timeMax: string) {
  const auth = await getAuthorizedClient(userId);
  const calendar = google.calendar({ version: "v3", auth });

  const res = await calendar.events.list({
    calendarId: "primary",
    timeMin,
    timeMax,
    singleEvents: true,
    orderBy: "startTime",
    maxResults: 2500,
  });

  return res.data.items ?? [];
}

type ImportResult = {
  importedEvents: number;
  importedAppointments: number;
  importedPatients: number;
  skipped: number;
  patients: { id: string; full_name: string }[];
};

export async function importCalendarEvents(
  userId: string,
  daysAhead = 90
): Promise<ImportResult> {
  const now = new Date();
  const end = new Date();

  now.setDate(now.getDate() - 60);
  end.setDate(end.getDate() + daysAhead);

  const events = await listEvents(userId, now.toISOString(), end.toISOString());

  const groups = new Map<string, typeof events>();
  for (const ev of events) {
    const key = ev.recurringEventId ?? ev.id ?? "";
    if (!key) continue;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key)!.push(ev);
  }

  const timeFormatter = new Intl.DateTimeFormat("pt-BR", {
    timeZone: "America/Sao_Paulo", hour: "2-digit", minute: "2-digit", hour12: false,
  });
  const weekdayFormatter = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Sao_Paulo", weekday: "short",
  });
  const isoDateFormatter = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Sao_Paulo", year: "numeric", month: "2-digit", day: "2-digit",
  });
  const weekdayMap: Record<string, number> = {
    "Sun": 0, "Mon": 1, "Tue": 2, "Wed": 3, "Thu": 4, "Fri": 5, "Sat": 6,
  };

  // Monta um array gigante com TUDO pronto
  const payload: any[] = [];

  for (const [, group] of groups) {
    let earliestEvent = group[0];
    let earliestTime = Infinity;

    for (const ev of group) {
      let dtStr = ev.start?.dateTime || (ev.start?.date ? `${ev.start.date}T08:00:00` : "");
      if (dtStr) {
        const time = new Date(dtStr).getTime();
        if (time < earliestTime) {
          earliestTime = time;
          earliestEvent = ev;
        }
      }
    }

    const first = earliestEvent;
    let startDateTimeStr = first.start?.dateTime || (first.start?.date ? `${first.start.date}T08:00:00` : "");
    if (!startDateTimeStr) continue;

    const start = new Date(startDateTimeStr);
    let startTime = timeFormatter.format(start);
    if (startTime === "24:00") startTime = "00:00";

    const weekday = weekdayMap[weekdayFormatter.format(start)] ?? 1;
    const anchorDate = isoDateFormatter.format(start);

    let durationMin = 60;
    if (first.end?.dateTime && first.start?.dateTime) {
      const endDt = new Date(first.end.dateTime);
      durationMin = Math.round((endDt.getTime() - start.getTime()) / 60000);
      if (durationMin < 15) durationMin = 50;
      if (durationMin > 240) durationMin = 240;
    }

    payload.push({
      recurringId: first.recurringEventId ?? first.id,
      rawName: first.summary ?? "Sem nome",
      startTime,
      weekday,
      anchorDate,
      durationMin,
    });
  }

  // O Segredo: Envia tudo de uma vez para o SQL fazer o trabalho pesado!
  const { data: count, error } = await supabaseAdmin.rpc("bulk_import_google_calendar", {
    p_events: payload,
  });

  if (error) throw new Error("Erro na importação: " + error.message);

  return {
    importedEvents: events.length,
    importedAppointments: (count as number) ?? 0,
    importedPatients: (count as number) ?? 0,
    skipped: 0,
    patients: [],
  };
}