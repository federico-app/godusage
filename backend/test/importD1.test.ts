import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { importD1Dump, IMPORTED_TABLES } from "../server/importD1";
import type { PostgresDatabase } from "../server/postgres";
import { sha256Hex } from "../src/http";
import { env } from "./env";
import { api } from "./support";

const D1_MIGRATIONS = join(dirname(fileURLToPath(import.meta.url)), "../d1-migrations");
const TOKEN = "imported-session-token-0123456789abcdef";
const TEAM = "team-imported-1";
const KEY = "ab".repeat(32);

/** A D1 database as production has it (every D1 migration applied, rows in every table), exported the way `wrangler d1 export` writes it. */
async function d1Export(): Promise<string> {
  const db = new DatabaseSync(":memory:");
  db.exec("CREATE TABLE d1_migrations (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE, applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL)");
  for (const name of readdirSync(D1_MIGRATIONS).sort()) {
    db.exec(readFileSync(join(D1_MIGRATIONS, name), "utf8"));
    db.prepare("INSERT INTO d1_migrations (name) VALUES (?)").run(name);
  }
  const at = "2026-10-01T09:00:00.000Z";
  db.exec(`
    INSERT INTO users VALUES ('u-ada', 'apple-ada', 'Ada', '${at}'), ('u-bob', 'apple-bob', 'Bob O''Brien', '${at}');
    INSERT INTO sessions VALUES ('${await sha256Hex(TOKEN)}', 'u-ada', '${at}', '2027-03-01T00:00:00.000Z', 180);
    INSERT INTO teams (id, name, owner_id, invite_code, public_token, created_at, stats_version) VALUES ('${TEAM}', 'Crew', 'u-ada', 'invite-1', NULL, '${at}', 7);
    INSERT INTO team_members VALUES ('${TEAM}', 'u-ada', 'owner', '${at}'), ('${TEAM}', 'u-bob', 'member', '2026-10-02T09:00:00.000Z');
    INSERT INTO devices (user_id, id, name, updated_at, app_version) VALUES ('u-ada', 'mac-1', 'MacBook', '${at}', '1.0.9'), ('u-bob', 'mac-2', 'iMac', '${at}', NULL);
    INSERT INTO usage_days (user_id, device_id, provider, day, scope, tokens, cost_usd, account_key) VALUES
      ('u-ada', 'mac-1', 'claude', '2026-10-05', 'device', 9000000000123, 12.5, NULL),
      ('u-ada', 'mac-1', 'cursor', '2026-10-05', 'account', 300, 3.25, '${KEY}'),
      ('u-bob', 'mac-2', 'codex', '2026-10-05', 'device', 50, NULL, NULL);
    INSERT INTO usage_model_days (user_id, device_id, provider, day, model, scope, tokens, cost_usd, account_key) VALUES
      ('u-ada', 'mac-1', 'claude', '2026-10-05', 'claude-opus-4-1', 'device', 9000000000123, 12.5, NULL);
    INSERT INTO account_keys VALUES ('u-ada', '${KEY}', 'cursor');
    INSERT INTO auth_requests (state, nonce, code_challenge, app_state, expires_at, kind, return_to) VALUES ('st', 'no', 'cc', 'as', '${at}', 'web', '/teams/x');
    INSERT INTO login_codes VALUES ('code-hash', 'u-bob', 'cc', 1, '${at}');
    INSERT INTO reactions VALUES ('${TEAM}', 'u-bob', 'u-ada', 'fire', '2026-10-05', '${at}');
    INSERT INTO challenges VALUES ('ch-1', '${TEAM}', 'most_tokens', '2026-10-01', '2026-10-07', 'u-ada', '${at}');
    INSERT INTO team_plans VALUES ('plan-1', '${TEAM}', 'claude', 'Max', 200.0, 1, 0, '${at}');
    INSERT INTO team_champions VALUES ('${TEAM}', '2026-10', '[]', '${at}');
    INSERT INTO stats_cache VALUES ('${TEAM}', 'stats|7d', 7, '{}', '${at}');
    INSERT INTO read_budget VALUES ('2026-10-05', 1234);
  `);
  const lines = ["PRAGMA defer_foreign_keys=TRUE;"];
  const tables = db.prepare("SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY rowid").all() as { name: string; sql: string }[];
  for (const { name, sql } of tables) {
    lines.push(`${sql};`);
    const columns = (db.prepare(`PRAGMA table_info("${name}")`).all() as { name: string }[]).map((column) => `quote("${column.name}")`);
    for (const row of db.prepare(`SELECT ${columns.join(" || ',' || ")} AS v FROM "${name}"`).all() as { v: string }[]) {
      lines.push(`INSERT INTO "${name}" VALUES(${row.v});`);
    }
  }
  for (const { sql } of db.prepare("SELECT sql FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL").all() as { sql: string }[]) lines.push(`${sql};`);
  db.close();
  return lines.join("\n");
}

describe("import-d1", () => {
  it("copies a D1 export into the empty database, leaving the D1-only caches behind", async () => {
    // A test sign-in against the new server before the import leaves a pending request: it is dropped.
    await env.db.run("INSERT INTO auth_requests (state, nonce, code_challenge, app_state, expires_at) VALUES ('pre', 'n', 'c', 'a', 'x')");
    const counts = await importD1Dump(env.db as PostgresDatabase, await d1Export(), () => {});
    expect(Object.keys(counts)).toEqual([...IMPORTED_TABLES]);
    expect(counts).toMatchObject({ users: 2, sessions: 1, teams: 1, team_members: 2, devices: 2, usage_days: 3, usage_model_days: 1, account_keys: 1, team_plans: 1 });

    const ada = await env.db.query("SELECT tokens, cost_usd, account_key FROM usage_days WHERE user_id = 'u-ada' ORDER BY provider");
    expect(ada).toEqual([
      { tokens: 9000000000123, cost_usd: 12.5, account_key: null },
      { tokens: 300, cost_usd: 3.25, account_key: KEY },
    ]);
    expect(await env.db.query("SELECT state FROM auth_requests")).toEqual([{ state: "st" }]);
    expect(await env.db.first("SELECT display_name FROM users WHERE id = 'u-bob'")).toEqual({ display_name: "Bob O'Brien" });
    expect(await env.db.first("SELECT app_version FROM devices WHERE id = 'mac-1'")).toEqual({ app_version: "1.0.9" });
    expect(await env.db.first("SELECT monthly_cost_usd, renewal_day FROM team_plans")).toEqual({ monthly_cost_usd: 200, renewal_day: 1 });

    // The imported session works, and the board adds up.
    const stats = await api("GET", `/v1/teams/${TEAM}/stats?range=today`, { token: TOKEN });
    expect(stats.status).toBe(200);
    expect(stats.body.stats.totals).toEqual({ tokens: 9000000000123 + 300 + 50, costUSD: 15.75 });
    expect(stats.body.team).toEqual({ id: TEAM, name: "Crew" });
  });

  it("refuses a database that already has rows, and a dump that is not a GodUsage export", async () => {
    await expect(importD1Dump(env.db as PostgresDatabase, await d1Export(), () => {})).rejects.toThrow(/already has rows in users/);
    await expect(importD1Dump(env.db as PostgresDatabase, "CREATE TABLE users (id TEXT);", () => {})).rejects.toThrow(/not a complete GodUsage D1 export/);
  });
});
