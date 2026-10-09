import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { fetchAppleKeys } from "../src/apple";
import type { Env } from "../src/context";
import { createApp } from "../src/index";
import { requestListener } from "./http";
import { importD1Dump } from "./importD1";
import { migrate } from "./migrate";
import { PostgresDatabase } from "./postgres";
import { RedisCache } from "./redis";

/**
 * The teams backend: a Node HTTP server on Postgres and Redis (the Docker image Coolify runs).
 *
 *   node server.mjs                     apply pending migrations, then serve
 *   node server.mjs import-d1 <dump>    apply migrations, load a D1 export into the empty database, exit
 *                                       (`-` reads the dump from stdin)
 *
 * Environment: DATABASE_URL, REDIS_URL, APPLE_AUDIENCES, APPLE_WEB_CLIENT_ID, PROXY_SECRET (to accept
 * requests from the proxy Worker), DOWNLOAD_URL (optional), APP_SCHEME (`godusage`, the default, or
 * `godusage-dev`), PORT (default 8787).
 */

function log(event: string, fields: Record<string, unknown> = {}): void {
  console.log(JSON.stringify({ event, ...fields }));
}

function logError(event: string, error: unknown): void {
  console.error(JSON.stringify({ event, message: error instanceof Error ? error.message : String(error) }));
}

function appScheme(value: string | undefined): Env["APP_SCHEME"] {
  if (!value || value === "godusage") return "godusage";
  if (value === "godusage-dev") return value;
  throw new Error(`APP_SCHEME must be godusage or godusage-dev, got ${value}.`);
}

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Missing environment variable ${name}.`);
  return value;
}

const here = dirname(fileURLToPath(import.meta.url));
const db = new PostgresDatabase(required("DATABASE_URL"), { onError: (error) => logError("postgres_error", error) });
await migrate(db, process.env.MIGRATIONS_DIR ?? join(here, "migrations"), (name) => log("migration_applied", { name }));

if (process.argv[2] === "import-d1") {
  const path = process.argv[3];
  if (!path) throw new Error("Usage: node server.mjs import-d1 <dump.sql | ->");
  const dump = readFileSync(path === "-" ? 0 : path, "utf8");
  const counts = await importD1Dump(db, dump, (message) => log("import", { message }));
  log("import_done", { counts });
  await db.close();
  process.exit(0);
}

const cache = await RedisCache.connect(required("REDIS_URL"), { onError: (error) => logError("redis_error", error) });
const proxySecret = process.env.PROXY_SECRET || undefined;
const env: Env = {
  db,
  cache,
  APPLE_AUDIENCES: required("APPLE_AUDIENCES"),
  APPLE_WEB_CLIENT_ID: required("APPLE_WEB_CLIENT_ID"),
  DOWNLOAD_URL: process.env.DOWNLOAD_URL || "https://github.com/federico-app/godusage/releases/latest",
  APP_SCHEME: appScheme(process.env.APP_SCHEME),
};
const app = createApp({ fetchAppleKeys, now: () => new Date() });

const server = createServer(requestListener(app, env, proxySecret, logError));

const port = Number(process.env.PORT ?? 8787);
server.listen(port, () => log("listening", { port, proxy: proxySecret !== undefined }));

function shutdown(): void {
  server.close(async () => {
    await Promise.allSettled([db.close(), cache.close()]);
    process.exit(0);
  });
}
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
