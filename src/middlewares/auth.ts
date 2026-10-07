import type { Request, Response, NextFunction } from "express";
import { supabaseAdmin } from "../lib/supabase.js";

// Valida o JWT do Supabase e injeta req.userId
export async function requireAuth(req: Request, res: Response, next: NextFunction) {
  const header = req.headers.authorization;

  console.log("[auth] header recebido:", header?.slice(0, 30) + "...");

  if (process.env.NODE_ENV !== "production" && req.headers["x-debug-user"]) {
    (req as any).userId = req.headers["x-debug-user"];
    return next();
  }
  
  if (!header?.startsWith("Bearer ")) {
    return res.status(401).json({ error: "Token ausente." });
  }

  const token = header.slice(7);
  console.log("[auth] token tamanho:", token.length);

  const { data, error } = await supabaseAdmin.auth.getUser(token);

  console.log("[auth] erro supabase:", error);

  if (error || !data.user) {
    return res.status(401).json({ error: "Token inválido." });
  }

  (req as any).userId = data.user.id;
  next();
}
