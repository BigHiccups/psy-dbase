// Horário combinado dentro de um convite
export type ScheduleInput = {
  weekday: number;      // 0=domingo, 6=sábado
  startTime: string;    // "HH:MM"
  durationMin?: number; // default 50
};

export type CreateInviteInput = {
  userId: string;
  patientNameHint?: string;
  phone: string;
  schedules: ScheduleInput[];
};

export type ScheduleOutput = {
  weekday: number;
  startTime: string;
  durationMin: number;
};

export type CreateInviteResult = {
  inviteId: string;
  token: string;
  publicUrl: string;
  shortUrl: string;
  whatsappUrl: string;
  phone: string;
  schedules: ScheduleOutput[];
};  