import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import type { PostgresDatabase } from "./postgres";

/**
 * Applies the migrations in `dir` (`NNNN_name.sql`) that the database has not seen, in name order,
 * each in its own transaction, and records them in `schema_migrations`. An advisory lock makes
 * replicas that start together apply them once.
 */
const LOCK_ID = 7_216_001;

export async function migrate(db: PostgresDatabase, dir: string, log: (name: string) => void): Promise<string[]> {
  const files = readdirSync(dir).filter((name) => /^\d{4}_.+\.sql$/.test(name)).sort();
  return db.withClient(async (client) => {
    await client.query("SELECT pg_advisory_lock($1)", [LOCK_ID]);
    try {
      await client.query(`CREATE TABLE IF NOT EXISTS schema_migrations (
        name TEXT PRIMARY KEY,
        applied_at TEXT NOT NULL
      )`);
      const applied = new Set((await client.query<{ name: string }>("SELECT name FROM schema_migrations")).rows.map((row) => row.name));
      const done: string[] = [];
      for (const name of files.filter((file) => !applied.has(file))) {
        await client.query("BEGIN");
        try {
          await client.query(readFileSync(join(dir, name), "utf8"));
          await client.query("INSERT INTO schema_migrations (name, applied_at) VALUES ($1, $2)", [name, new Date().toISOString()]);
          await client.query("COMMIT");
        } catch (error) {
          await client.query("ROLLBACK");
          throw new Error(`Migration ${name} failed: ${error instanceof Error ? error.message : String(error)}`);
        }
        log(name);
        done.push(name);
      }
      return done;
    } finally {
      await client.query("SELECT pg_advisory_unlock($1)", [LOCK_ID]);
    }
  });
}
