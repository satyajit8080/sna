import { SignJWT, jwtVerify } from "jose";
import type { FastifyReply, FastifyRequest } from "fastify";
import { cfg } from "../config.js";

const key = new TextEncoder().encode(cfg.JWT_SECRET);

declare module "fastify" {
  interface FastifyRequest {
    userId: string;
    tz: string;
  }
}

export async function issueToken(userId: string): Promise<string> {
  return new SignJWT({ sub: userId })
    .setProtectedHeader({ alg: "HS256" })
    .setIssuedAt()
    .setIssuer("snapcal")
    .setExpirationTime("90d")
    .sign(key);
}

export async function requireAuth(req: FastifyRequest, reply: FastifyReply) {
  const header = req.headers.authorization;
  if (!header?.startsWith("Bearer ")) return reply.code(401).send({ error: "unauthorized" });
  try {
    const { payload } = await jwtVerify(header.slice(7), key, { issuer: "snapcal" });
    req.userId = String(payload.sub);
    req.tz = String(req.headers["x-timezone"] ?? "UTC");
  } catch {
    return reply.code(401).send({ error: "unauthorized" });
  }
}
