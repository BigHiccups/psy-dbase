import type { Request, Response } from "express";
import { createInvite } from "./invites.service.js";
import { validateSchedules } from "./invites.validation.js";

export async function handleCreateInvite(req: Request, res: Response) {
  const userId = (req as any).userId as string;
  const { patientNameHint, phone, schedules } = req.body;

  if (!phone) {
    return res.status(400).json({ error: "Telefone é obrigatório." });
  }

  const validatedSchedules = validateSchedules(schedules);

  const result = await createInvite({
    userId,
    patientNameHint,
    phone,
    schedules: validatedSchedules,
  });

  return res.status(201).json(result);
}