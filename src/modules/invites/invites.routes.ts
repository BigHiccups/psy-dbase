import { Router } from "express";
import { requireAuth } from "../../middlewares/auth.js";
import { handleCreateInvite } from "./invites.controller.js";

export const invitesRoutes = Router();

invitesRoutes.post("/", requireAuth, handleCreateInvite);