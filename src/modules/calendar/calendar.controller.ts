import type { Request, Response } from "express";
import {
  getAuthUrl,
  handleCallback,
  getConnectionStatus,
  disconnect,
  listEvents,
  importCalendarEvents,
} from "./calendar.service.js";
import { env } from "../../config/env.js";

// GET /calendar/connect
// Retorna a URL de autorização do Google para o frontend redirecionar
export async function handleConnect(req: Request, res: Response) {
  const userId = (req as any).userId as string;
  const url = getAuthUrl(userId);
  return res.json({ url });
}

// GET /calendar/callback?code=...&state=...
// O Google chama aqui depois da autorização. Não exige JWT —
// a autenticação vem do próprio "code" que só o Google tem.
export async function handleOAuthCallback(req: Request, res: Response) {
  const { code, state, error: googleError } = req.query;

  // Usuário negou a autorização
  if (googleError) {
    return res.redirect(`${env.frontendUrl}/settings?google=denied`);
  }

  if (typeof code !== "string" || typeof state !== "string") {
    return res.redirect(`${env.frontendUrl}/settings?google=invalid`);
  }

  try {
    await handleCallback(code, state);
    return res.redirect(`${env.frontendUrl}/settings?google=connected`);
  } catch (err) {
    console.error("[calendar] erro no callback:", err);
    return res.redirect(`${env.frontendUrl}/settings?google=error`);
  }
}

// GET /calendar/status
// Diz se o usuário já conectou
export async function handleStatus(req: Request, res: Response) {
  const userId = (req as any).userId as string;
  const status = await getConnectionStatus(userId);
  return res.json(status);
}

// DELETE /calendar/disconnect
export async function handleDisconnect(req: Request, res: Response) {
  const userId = (req as any).userId as string;
  await disconnect(userId);
  return res.json({ ok: true });
}

// GET /calendar/events?from=ISO&to=ISO
// Lista eventos de um período (útil para debug e para a agenda)
export async function handleListEvents(req: Request, res: Response) {
  const userId = (req as any).userId as string;
  const { from, to } = req.query;

  if (typeof from !== "string" || typeof to !== "string") {
    return res
      .status(400)
      .json({ error: "Parâmetros from e to obrigatórios." });
  }

  const events = await listEvents(userId, from, to);
  return res.json({ events });
}

// POST /calendar/import
// Importa a agenda do Google para o psy-dbase
export async function handleImport(req: Request, res: Response) {
  const userId = (req as any).userId as string;
  const daysAhead = Number(req.body?.daysAhead ?? 90);

  const summary = await importCalendarEvents(userId, daysAhead);
  return res.json(summary);
}