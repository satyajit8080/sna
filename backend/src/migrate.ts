import { readdir, readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { pool } from "./db.js";

const DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../migrations");

/**
 * Forward-only migrations. Never drops or truncates anything — every file must
 * be additive and idempotent, so a redeploy that replays them is harmless.
 * An advisory lock makes concurrent Railway instances safe: the second one
 * blocks, then finds every migration already applied.
 */
export async function migrate(): Promise<void> {
  const client = await pool.connect();
  try {
    await client.query(`
      CREATE TABLE IF NOT EXISTS schema_migrations (
        name       text PRIMARY KEY,
        checksum   text NOT NULL,
        applied_at timestamptz NOT NULL DEFAULT now()
      )`);

    await client.query("SELECT pg_advisory_lock(hashtext('snapcal_migrations'))");

    const applied = new Map<string, string>(
      (await client.query<{ name: string; checksum: string }>("SELECT name, checksum FROM schema_migrations"))
        .rows.map((r) => [r.name, r.checksum])
    );

    const files = (await readdir(DIR)).filter((f) => f.endsWith(".sql")).sort();
    let ran = 0;

    for (const name of files) {
      const sql = await readFile(path.join(DIR, name), "utf8");
      const checksum = createHash("sha256").update(sql).digest("hex").slice(0, 16);
      const previous = applied.get(name);

      if (previous === checksum) continue;

      if (previous && previous !== checksum) {
        // An already-applied file changed. Refuse rather than guess — the fix is
        // always a new migration file, never an edit to an old one.
        throw new Error(
          `Migration ${name} was modified after being applied (${previous} -> ${checksum}). ` +
          `Add a new migration file instead of editing this one.`
        );
      }

      process.stdout.write(`→ applying ${name}\n`);
      await client.query("BEGIN");
      try {
        await client.query(sql);
        await client.query(
          "INSERT INTO schema_migrations (name, checksum) VALUES ($1,$2) ON CONFLICT (name) DO UPDATE SET checksum = EXCLUDED.checksum",
          [name, checksum]
        );
        await client.query("COMMIT");
        ran++;
      } catch (e) {
        await client.query("ROLLBACK");
        throw e;
      }
    }

    process.stdout.write(ran ? `✓ ${ran} migration(s) applied\n` : "✓ database up to date\n");
  } finally {
    await client.query("SELECT pg_advisory_unlock(hashtext('snapcal_migrations'))").catch(() => {});
    client.release();
  }
}

/** Fails loudly if the schema is not what the running code expects. */
export async function verifySchema(): Promise<void> {
  const required = [
    "users", "profiles", "nutrition_targets", "food_database", "meals",
    "meal_items", "weight_logs", "water_logs", "subscriptions", "ai_usage", "analysis_cache",
  ];

  const { rows } = await pool.query<{ table_name: string }>(
    `SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'`
  );
  const present = new Set(rows.map((r) => r.table_name));
  const missing = required.filter((t) => !present.has(t));
  if (missing.length) throw new Error(`Missing tables: ${missing.join(", ")}. Run npm run migrate.`);

  const { rows: exts } = await pool.query<{ extname: string }>(`SELECT extname FROM pg_extension`);
  const have = new Set(exts.map((e) => e.extname));
  const missingExt = ["pgcrypto", "citext", "pg_trgm"].filter((e) => !have.has(e));
  if (missingExt.length) throw new Error(`Missing PostgreSQL extensions: ${missingExt.join(", ")}`);
}

// `npm run migrate`
if (process.argv[1] && process.argv[1].endsWith("migrate.js")) {
  migrate()
    .then(() => verifySchema())
    .then(() => pool.end())
    .then(() => process.exit(0))
    .catch((e) => {
      console.error(e.message);
      process.exit(1);
    });
}
