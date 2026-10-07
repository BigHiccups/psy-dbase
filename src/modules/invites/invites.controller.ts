import type { Request, Response } from "express";
import { createInvite } from "./invites.service.js";

export async function handleCreateInvite(req: Request, res: Response) {
  const userId = (req as any).userId as string;
  const { patientNameHint, phone } = req.body;

  if (!phone) {
    return res.status(400).json({ error: "Telefone é obrigatório." });
  }

  const result = await createInvite({ userId, patientNameHint, phone });
  return res.status(201).json(result);
}