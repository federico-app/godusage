import { readdirSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { migrate } from "../server/migrate";
import type { PostgresDatabase } from "../server/postgres";
import { env, MIGRATIONS_DIR } from "./env";

describe("transactions", () => {
  it("commit together or not at all", async () => {
    const insert = (tx: { run: typeof env.db.run }, id: string) =>
      tx.run("INSERT INTO users (id, apple_sub, display_name, created_at) VALUES ($1, $1, 'T', 'x')", [id]);
    await expect(
      env.db.transaction(async (tx) => {
        await insert(tx, "tx-user-1");
        await insert(tx, "tx-user-1");
      }),
    ).rejects.toThrow(/duplicate key/);
    expect(await env.db.first("SELECT id FROM users WHERE id = 'tx-user-1'")).toBeNull();
    // Several statements started at once inside one transaction run one after another.
    await env.db.transaction((tx) => Promise.all([insert(tx, "tx-user-2"), insert(tx, "tx-user-3")]));
    expect(await env.db.first("SELECT COUNT(*) AS n FROM users WHERE id LIKE 'tx-user-%'")).toEqual({ n: 2 });
  });
});

describe("migrations", () => {
  it("are recorded once, and replicas starting together apply nothing twice", async () => {
    const db = env.db as PostgresDatabase;
    const files = readdirSync(MIGRATIONS_DIR).filter((name) => name.endsWith(".sql")).sort();
    const recorded = await db.query<{ name: string }>("SELECT name FROM schema_migrations ORDER BY name");
    expect(recorded.map((row) => row.name)).toEqual(files);
    expect(await Promise.all([migrate(db, MIGRATIONS_DIR, () => {}), migrate(db, MIGRATIONS_DIR, () => {})])).toEqual([[], []]);
  });

  it("leave the D1-only caches out of Postgres", async () => {
    const tables = await env.db.query<{ table_name: string }>("SELECT table_name FROM information_schema.tables WHERE table_schema = current_schema()");
    const names = tables.map((row) => row.table_name);
    expect(names).not.toContain("stats_cache");
    expect(names).not.toContain("team_champions");
    expect(names).not.toContain("read_budget");
  });
});
