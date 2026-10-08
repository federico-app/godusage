import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { SqliteD1 } from "../../server/d1Sqlite";
import { installWorkerGlobals, memoryRateLimit, migrate } from "../../server/runtime";

/**
 * Stands in for `cloudflare:test` when the suite runs on the Node server's runtime
 * (vitest.node.config.ts): the same bindings, on an in-memory SQLite database.
 */
installWorkerGlobals();
const d1 = new SqliteD1(":memory:");

export const env = {
  DB: d1.asD1(),
  AUTH_LIMITER: memoryRateLimit(20, 60),
  API_LIMITER: memoryRateLimit(120, 60),
  PAGE_LIMITER: memoryRateLimit(30, 60),
  APPLE_AUDIENCES: "com.montinovo.godusage",
  APPLE_WEB_CLIENT_ID: "com.montinovo.godusage.web",
  DOWNLOAD_URL: "https://github.com/federico-app/godusage/releases/latest",
  READ_BUDGET_PER_DAY: "3500000",
  TEST_MIGRATIONS: [],
} as unknown as Env;

export async function applyD1Migrations(): Promise<void> {
  migrate(d1, join(dirname(fileURLToPath(import.meta.url)), "../../migrations"), () => {});
}
