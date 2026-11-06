import { copyFileSync, mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import { migrate } from "../server/migrate";
import { PostgresDatabase } from "../server/postgres";
import { DATABASE_URL, dropSchema, MIGRATIONS_DIR } from "./env";

const LAST_BEFORE = "0012_plan_hidden_accounts.sql";
const schema = `test_migr_${Date.now().toString(36)}`;
const dir = mkdtempSync(join(tmpdir(), "godusage-migrations-"));

afterAll(async () => {
  rmSync(dir, { recursive: true, force: true });
  await dropSchema(schema);
});

describe("0013_team_working_hours", () => {
  it("copies each person's hours to every team they're in", async () => {
    const admin = new PostgresDatabase(DATABASE_URL, { max: 1 });
    await admin.run(`CREATE SCHEMA ${schema}`);
    await admin.close();
    const db = new PostgresDatabase(DATABASE_URL, { schema, max: 2 });
    try {
      for (const name of readdirSync(MIGRATIONS_DIR).filter((file) => file.endsWith(".sql") && file <= LAST_BEFORE)) {
        copyFileSync(join(MIGRATIONS_DIR, name), join(dir, name));
      }
      await migrate(db, dir, () => {});
      for (const id of ["u1", "u2"]) {
        await db.run("INSERT INTO users (id, apple_sub, display_name, created_at) VALUES ($1, $1, $1, 'x')", [id]);
      }
      for (const team of ["t1", "t2"]) {
        await db.run("INSERT INTO teams (id, name, owner_id, invite_code, created_at) VALUES ($1, $1, 'u1', $1, 'x')", [team]);
        await db.run("INSERT INTO team_members (team_id, user_id, role, joined_at) VALUES ($1, 'u1', 'owner', 'x')", [team]);
      }
      await db.run("INSERT INTO team_members (team_id, user_id, role, joined_at) VALUES ('t1', 'u2', 'member', 'x')");
      await db.run("INSERT INTO work_schedules (user_id, days, start_minute, end_minute, updated_at) VALUES ('u1', '[5,6,7]', 570, 1110, 'x')");

      for (const name of readdirSync(MIGRATIONS_DIR).filter((file) => file > LAST_BEFORE)) copyFileSync(join(MIGRATIONS_DIR, name), join(dir, name));
      await migrate(db, dir, () => {});
      const rows = await db.query<{ team_id: string; user_id: string; days: string }>("SELECT team_id, user_id, days FROM team_work_schedules ORDER BY team_id");
      expect(rows).toEqual([
        { team_id: "t1", user_id: "u1", days: "[5,6,7]" },
        { team_id: "t2", user_id: "u1", days: "[5,6,7]" },
      ]);
    } finally {
      await db.close();
    }
  });
});
