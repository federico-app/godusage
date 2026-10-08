import { DatabaseSync } from "node:sqlite";
import type { Queryable } from "../src/db";
import type { PostgresDatabase } from "./postgres";

/**
 * Loads a D1 export (`wrangler d1 export`, see .github/workflows/backend-export.yml) into the empty
 * Postgres database. The dump is SQLite SQL, so it is first run into an in-memory SQLite database;
 * then each table's rows are copied, in foreign-key order, in one transaction. Columns are matched by
 * name: D1-only columns (teams.stats_version) are left behind, and so are the D1-only tables (the
 * stats cache, champions cache, and read budget), which the server keeps in Redis or no longer needs.
 */
export const IMPORTED_TABLES = [
  "users",
  "sessions",
  "teams",
  "team_members",
  "devices",
  "usage_days",
  "usage_model_days",
  "account_keys",
  "auth_requests",
  "login_codes",
  "reactions",
  "challenges",
  "team_plans",
] as const;

/** Sign-ins in flight (minutes long): a test sign-in against the new server may have left some. */
const EPHEMERAL_TABLES = new Set(["auth_requests", "login_codes"]);

const BATCH_ROWS = 1000;

export async function importD1Dump(db: PostgresDatabase, dumpSQL: string, log: (message: string) => void): Promise<Record<string, number>> {
  const sqlite = new DatabaseSync(":memory:", { enableForeignKeyConstraints: false });
  try {
    sqlite.exec(dumpSQL);
    const present = new Set(
      (sqlite.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").all() as { name: string }[]).map((row) => row.name),
    );
    const missing = IMPORTED_TABLES.filter((table) => !present.has(table));
    if (missing.length > 0) throw new Error(`This is not a complete GodUsage D1 export: it has no ${missing.join(", ")} table.`);

    return await db.transaction(async (tx) => {
      const counts: Record<string, number> = {};
      for (const table of IMPORTED_TABLES) {
        const existing = (await tx.first<{ n: number }>(`SELECT COUNT(*) AS n FROM ${table}`))?.n ?? 0;
        if (existing === 0) continue;
        if (!EPHEMERAL_TABLES.has(table)) throw new Error(`Postgres already has rows in ${table}: import a D1 export only into a new, empty database.`);
        await tx.run(`DELETE FROM ${table}`);
        log(`${table}: dropped ${existing} pending sign-ins made before the import`);
      }
      for (const table of IMPORTED_TABLES) counts[table] = await copyTable(sqlite, tx, table, log);
      return counts;
    });
  } finally {
    sqlite.close();
  }
}

async function copyTable(sqlite: DatabaseSync, tx: Queryable, table: string, log: (message: string) => void): Promise<number> {
  const sourceColumns = (sqlite.prepare(`PRAGMA table_info("${table}")`).all() as { name: string }[]).map((row) => row.name);
  const targetColumns = (
    await tx.query<{ column_name: string }>(
      "SELECT column_name FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1 ORDER BY ordinal_position",
      [table],
    )
  ).map((row) => row.column_name);
  const columns = targetColumns.filter((column) => sourceColumns.includes(column));
  const skipped = sourceColumns.filter((column) => !targetColumns.includes(column));
  if (skipped.length > 0) log(`${table}: leaving D1-only columns behind: ${skipped.join(", ")}`);

  const list = columns.map((column) => `"${column}"`).join(", ");
  const rows = sqlite.prepare(`SELECT ${list} FROM "${table}"`).all();
  for (let start = 0; start < rows.length; start += BATCH_ROWS) {
    await tx.run(`INSERT INTO ${table} (${list}) SELECT ${list} FROM jsonb_populate_recordset(NULL::${table}, $1::jsonb)`, [
      JSON.stringify(rows.slice(start, start + BATCH_ROWS)),
    ]);
  }
  log(`${table}: ${rows.length} rows`);
  return rows.length;
}
