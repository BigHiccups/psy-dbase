import type { Request, Response, NextFunction } from "express";

// Tratamento centralizado de erros
export function errorHandler(
  err: Error,
  _req: Request,
  res: Response,
  _next: NextFunction
) {
  console.error("[error]", err.message);
  res.status(400).json({ error: err.message ?? "Erro inesperado." });
}