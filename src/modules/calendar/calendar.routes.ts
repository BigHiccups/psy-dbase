import { Router } from "express";
import { requireAuth } from "../../middlewares/auth.js";
import {
  handleConnect,
  handleOAuthCallback,
  handleStatus,
  handleDisconnect,
  handleListEvents,
  handleImport,         
} from "./calendar.controller.js";

export const calendarRoutes = Router();

// Rota pública — o Google chama sem JWT
// Declarada ANTES das autenticadas, senão o middleware bloqueia
calendarRoutes.get("/callback", handleOAuthCallback);

// Rotas autenticadas
calendarRoutes.get("/connect", requireAuth, handleConnect);
calendarRoutes.get("/status", requireAuth, handleStatus);
calendarRoutes.get("/events", requireAuth, handleListEvents);
calendarRoutes.post("/import", requireAuth, handleImport); 
calendarRoutes.delete("/disconnect", requireAuth, handleDisconnect);