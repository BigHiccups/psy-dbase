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

// =========================================================
// Listagem de eventos
// =========================================================
export async function listEvents(userId: string, timeMin: string, timeMax: string) {
  const auth = await getAuthorizedClient(userId);
  const calendar = google.calendar({ version: "v3", auth });

  const res = await calendar.events.list({
    calendarId: "primary",
    timeMin,
    timeMax,
    singleEvents: true,
    orderBy: "startTime",
    // REMOVIDO: timeZone: "America/Sao_Paulo" para evitar que o Google oculte a hora
    maxResults: 2500,
  });

  return res.data.items ?? [];
}

// =========================================================
// Importação
// =========================================================
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
  end.setDate(end.getDate() + daysAhead);

  const events = await listEvents(userId, now.toISOString(), end.toISOString());

  const groups = new Map<string, typeof events>();
  for (const ev of events) {
    const key = ev.recurringEventId ?? ev.id ?? "";
    if (!key) continue;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key)!.push(ev);
  }

  const result: ImportResult = {
    importedEvents: events.length,
    importedAppointments: 0,
    importedPatients: 0,
    skipped: 0,
    patients: [],
  };

  const isoDateFormatter = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Sao_Paulo",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  });

  const timeFormatter = new Intl.DateTimeFormat("pt-BR", {
    timeZone: "America/Sao_Paulo",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });

  const weekdayFormatter = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Sao_Paulo",
    weekday: "short",
  });
  const weekdayMap: Record<string, number> = {
    "Sun": 0, "Mon": 1, "Tue": 2, "Wed": 3, "Thu": 4, "Fri": 5, "Sat": 6,
  };

  for (const [, group] of groups) {
    const first = group[0];

    // =====================================================
    // TRATAMENTO DE EVENTOS ALL-DAY OU SEM HORA
    // =====================================================
    let startDateTimeStr = first.start?.dateTime;
    
    // Se não tiver hora, mas tiver data (All-day event), assumimos 08:00
    if (!startDateTimeStr && first.start?.date) {
      startDateTimeStr = `${first.start.date}T08:00:00`;
    }

    if (!startDateTimeStr) continue; // Se não tiver nem data, aí sim pulamos

    const start = new Date(startDateTimeStr);
    
    // Se for all-day, a duração é 60min. Se não, calculamos a diferença
    let durationMin = 60;
    if (first.end?.dateTime && first.start?.dateTime) {
       const endDt = new Date(first.end.dateTime);
       durationMin = Math.round((endDt.getTime() - start.getTime()) / 60000);
    }

    const startTime = timeFormatter.format(start);
    const weekdayStr = weekdayFormatter.format(start);
    const weekday = weekdayMap[weekdayStr];

    const rawName = first.summary ?? "Sem nome";
    const recurringId = first.recurringEventId ?? first.id ?? null;

    let patientId: string | null = null;
    let alreadyImportedAsProvider = false;

    if (recurringId) {
      const { data: existingImports } = await supabaseAdmin
        .from("google_imported_recurrences")
        .select("user_id, target_type, target_id")
        .eq("user_id", userId)
        .eq("google_recurring_event_id", recurringId);

      const existingImport = existingImports?.find((x) => x.target_type === "provider") ?? existingImports?.[0];

      if (existingImport) {
        if (existingImport.target_type === "patient") patientId = existingImport.target_id;
        else alreadyImportedAsProvider = true;
      }
    }

    if (alreadyImportedAsProvider) {
      result.skipped += group.length;
      continue;
    }

    if (!patientId) {
      const { data: existingByName } = await supabaseAdmin
        .from("patients")
        .select("id")
        .eq("user_id", userId)
        .eq("full_name", rawName)
        .maybeSingle();

      if (existingByName) {
        patientId = existingByName.id;
        if (recurringId) {
          await supabaseAdmin.from("google_imported_recurrences").insert({
            user_id: userId,
            google_recurring_event_id: recurringId,
            target_type: "patient",
            target_id: existingByName.id,
          });
        }
      }
    }

    if (!patientId) {
      const { data: patient, error: patientError } = await supabaseAdmin
        .from("patients")
        .insert({
          user_id: userId,
          full_name: rawName,
          status: "prospect",
          google_recurring_event_id: recurringId,
        })
        .select()
        .single();

      if (patientError || !patient) {
        console.warn("[calendar.import] falha ao criar paciente:", patientError?.message);
        continue;
      }

      patientId = patient.id;
      result.importedPatients++;
      result.patients.push({ id: patient.id, full_name: rawName });

      if (recurringId) {
        await supabaseAdmin.from("google_imported_recurrences").insert({
          user_id: userId,
          google_recurring_event_id: recurringId,
          target_type: "patient",
          target_id: patient.id,
        });
      }
    }

    const rows = group
      .map((ev) => {
        let evStartStr = ev.start?.dateTime;
        if (!evStartStr && ev.start?.date) {
           evStartStr = `${ev.start.date}T08:00:00`;
        }
        
        if (!evStartStr || !ev.id) return null;

        const occStart = new Date(evStartStr);
        const occDate = isoDateFormatter.format(occStart);

        return {
          user_id: userId,
          patient_id: patientId,
          type: "session" as const,
          weekday,
          start_time: startTime,
          duration_min: durationMin,
          starts_on: occDate,
          ends_on: occDate,
          is_recurring: true,
          status: "active" as const,
          google_event_id: ev.id,
        };
      })
      .filter((r) => r !== null) as any[];

    const existingIds = rows.map((r) => r.google_event_id);
    const { data: existing } = await supabaseAdmin
      .from("appointments")
      .select("google_event_id")
      .in("google_event_id", existingIds);

    const existingSet = new Set((existing ?? []).map((e) => e.google_event_id));
    const newRows = rows.filter((r) => !existingSet.has(r.google_event_id));

    result.skipped += rows.length - newRows.length;
    if (newRows.length === 0) continue;

    const { error: apptError, count } = await supabaseAdmin
      .from("appointments")
      .insert(newRows, { count: "exact" });

    if (apptError) {
      console.warn("[calendar.import] falha ao criar appointments:", apptError.message);
      continue;
    }

    result.importedAppointments += count ?? newRows.length;
  }

  return result;
}