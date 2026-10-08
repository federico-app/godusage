import { randomBytes } from "node:crypto";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { Env } from "../src/context";
import { migrate } from "../server/migrate";
import { PostgresDatabase } from "../server/postgres";
import { RedisCache } from "../server/redis";

/**
 * The environment every test runs against: real Postgres and Redis (`npm run test:services` starts
 * them locally; CI uses service containers). Each test file gets a fresh Postgres schema with the
 * migrations applied and its own Redis key prefix, so files run in parallel without seeing each other.
 * test/setup.ts drops both after the file.
 */
export const DATABASE_URL = process.env.TEST_DATABASE_URL ?? "postgres://godusage:godusage@127.0.0.1:55432/godusage_test";
export const REDIS_URL = process.env.TEST_REDIS_URL ?? "redis://127.0.0.1:56379";
export const MIGRATIONS_DIR = join(dirname(fileURLToPath(import.meta.url)), "../migrations");

/** A new, empty schema with the migrations applied. */
export async function freshSchema(): Promise<{ schema: string; db: PostgresDatabase }> {
  const schema = `test_${randomBytes(6).toString("hex")}`;
  const admin = new PostgresDatabase(DATABASE_URL, { max: 1 });
  try {
    await admin.run(`CREATE SCHEMA ${schema}`);
  } catch (error) {
    throw new Error(
      `Cannot reach the test database at ${DATABASE_URL} (${error instanceof Error ? error.message : String(error)}). Run \`npm run test:services\` first.`,
    );
  } finally {
    await admin.close();
  }
  const db = new PostgresDatabase(DATABASE_URL, { schema, max: 4 });
  await migrate(db, MIGRATIONS_DIR, () => {});
  return { schema, db };
}

export async function dropSchema(schema: string): Promise<void> {
  const admin = new PostgresDatabase(DATABASE_URL, { max: 1 });
  try {
    await admin.run(`DROP SCHEMA ${schema} CASCADE`);
  } finally {
    await admin.close();
  }
}

const { schema, db } = await freshSchema();
const cache = await RedisCache.connect(REDIS_URL, { prefix: `${schema}:` });

export const env: Env = {
  db,
  cache,
  APPLE_AUDIENCES: "com.montinovo.godusage",
  APPLE_WEB_CLIENT_ID: "com.montinovo.godusage.web",
  DOWNLOAD_URL: "https://github.com/federico-app/godusage/releases/latest",
  APP_SCHEME: "godusage",
};

export async function closeEnv(): Promise<void> {
  await cache.clear();
  await cache.close();
  await db.close();
  await dropSchema(schema);
}
