import express from "express";
import cors from "cors";
import { invitesRoutes } from "./modules/invites/invites.routes.js";
import { errorHandler } from "./middlewares/errorHandler.js";
import { env } from "./config/env.js";

export function createApp() {
  const app = express();

  app.use(cors({ origin: env.frontendUrl }));
  app.use(express.json());

  app.get("/health", (_req, res) => res.json({ ok: true }));
  app.use("/invites", invitesRoutes);

  app.use(errorHandler);
  return app;
}