import pg from "pg";
import { cfg, isProd } from "./config.js";

pg.types.setTypeParser(1700, (v) => parseFloat(v)); // numeric -> number

export const pool = new pg.Pool({
  connectionString: cfg.DATABASE_URL,
  max: 20,
  idleTimeoutMillis: 30_000,
  ssl: isProd ? { rejectUnauthorized: false } : undefined,
});

export async function q<T = any>(sql: string, params: unknown[] = []): Promise<T[]> {
  const r = await pool.query(sql, params as any[]);
  return r.rows as T[];
}

export async function one<T = any>(sql: string, params: unknown[] = []): Promise<T | null> {
  const rows = await q<T>(sql, params);
  return rows[0] ?? null;
}

export async function tx<T>(fn: (c: pg.PoolClient) => Promise<T>): Promise<T> {
  const c = await pool.connect();
  try {
    await c.query("BEGIN");
    const out = await fn(c);
    await c.query("COMMIT");
    return out;
  } catch (e) {
    await c.query("ROLLBACK");
    throw e;
  } finally {
    c.release();
  }
}
