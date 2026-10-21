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

  for (const [, group] of groups) {
    const first = group[0];

    // O código original parava aqui se não tivesse dateTime
    if (!first.start?.dateTime || !first.end?.dateTime) {
      console.log("[calendar.import] Pulando grupo (sem dateTime):", first.summary);
      continue;
    }

    const start = new Date(first.start.dateTime);
    const endDt = new Date(first.end.dateTime);

    // --- CORREÇÃO 1: FUSO HORÁRIO ---
    const timeFormatter = new Intl.DateTimeFormat("pt-BR", {
      timeZone: "America/Sao_Paulo",
      hour: "2-digit",
      minute: "2-digit",
      hour12: false,
    });
    let startTime = timeFormatter.format(start);
    if (startTime === "24:00") startTime = "00:00";

    const weekdayFormatter = new Intl.DateTimeFormat("en-US", {
      timeZone: "America/Sao_Paulo",
      weekday: "short",
    });
    const weekdayStr = weekdayFormatter.format(start);
    const weekdayMap: Record<string, number> = {
      "Sun": 0, "Mon": 1, "Tue": 2, "Wed": 3, "Thu": 4, "Fri": 5, "Sat": 6,
    };
    const weekday = weekdayMap[weekdayStr] ?? 1;

    // --- CORREÇÃO 2: DURAÇÃO (O BANCO EXIGE 15 A 240 MINUTOS) ---
    let durationMin = Math.round((endDt.getTime() - start.getTime()) / 60000);
    if (durationMin < 15) durationMin = 50; // Se vier 0 ou negativo, assume 50
    if (durationMin > 240) durationMin = 240; // Se vier muito longo, trava em 240
    // -------------------------------------------------------------

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
      .filter((ev) => ev.id && ev.start?.dateTime && ev.end?.dateTime)
      .map((ev) => {
        const occStart = new Date(ev.start!.dateTime!);
        
        // Extrai a data corretamente no fuso do Brasil
        const isoDateFormatter = new Intl.DateTimeFormat("en-CA", {
          timeZone: "America/Sao_Paulo",
          year: "numeric",
          month: "2-digit",
          day: "2-digit",
        });
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
          google_event_id: ev.id!,
        };
      });

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
      // MUDANÇA CRUCIAL: console.error para aparecer em vermelho nos logs da Vercel
      console.error(
        "[calendar.import] FALHA AO INSERIR NO BANCO:",
        apptError.message,
        "Dados:",
        JSON.stringify(newRows[0], null, 2)
      );
      continue;
    }

    result.importedAppointments += count ?? newRows.length;
  }

  return result;
}