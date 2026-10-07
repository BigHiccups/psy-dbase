import type { ScheduleInput } from "./invites.types.js";

const WEEKDAY_MIN = 0;
const WEEKDAY_MAX = 6;
const DURATION_MIN = 15;
const DURATION_MAX = 240;
const DEFAULT_DURATION = 50;

// Valida "HH:MM" entre 00:00 e 23:59
function isValidTime(value: string): boolean {
  return /^([01]\d|2[0-3]):[0-5]\d$/.test(value);
}

// Valida e normaliza a lista de horários do convite
export function validateSchedules(input: unknown): ScheduleInput[] {
  if (!Array.isArray(input) || input.length === 0) {
    throw new Error("Informe pelo menos um horário de sessão.");
  }

  const seen = new Set<string>();
  const normalized: ScheduleInput[] = [];

  for (const raw of input) {
    if (typeof raw !== "object" || raw === null) {
      throw new Error("Horário inválido.");
    }

    const { weekday, startTime, durationMin } = raw as Record<string, unknown>;

    if (
      typeof weekday !== "number" ||
      !Number.isInteger(weekday) ||
      weekday < WEEKDAY_MIN ||
      weekday > WEEKDAY_MAX
    ) {
      throw new Error("Dia da semana inválido.");
    }

    if (typeof startTime !== "string" || !isValidTime(startTime)) {
      throw new Error("Horário inválido. Use o formato HH:MM.");
    }

    const duration =
      durationMin === undefined ? DEFAULT_DURATION : Number(durationMin);

    if (
      !Number.isInteger(duration) ||
      duration < DURATION_MIN ||
      duration > DURATION_MAX
    ) {
      throw new Error(
        `Duração deve estar entre ${DURATION_MIN} e ${DURATION_MAX} minutos.`
      );
    }

    // Evita duplicata (mesmo dia + mesmo horário)
    const key = `${weekday}-${startTime}`;
    if (seen.has(key)) {
      throw new Error("Horário duplicado no convite.");
    }
    seen.add(key);

    normalized.push({ weekday, startTime, durationMin: duration });
  }

  return normalized;
}