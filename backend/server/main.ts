import { createServer } from "node:http";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { fetchAppleKeys } from "../src/apple";
import { createApp } from "../src/index";
import { SqliteD1 } from "./d1Sqlite";
import { fetchRequest, importDump, installWorkerGlobals, memoryRateLimit, migrate } from "./runtime";

/**
 * The teams backend as a plain Node server (the Docker image Coolify runs), with the Worker's routes
 * on a local SQLite database.
 *
 *   node server.mjs                 serve (applies pending migrations first)
 *   node server.mjs import <dump>   load a `wrangler d1 export` dump into a new database, then exit
 *
 * Configuration (environment): DATABASE_PATH, PORT, APPLE_AUDIENCES, APPLE_WEB_CLIENT_ID,
 * DOWNLOAD_URL, READ_BUDGET_PER_DAY.
 */

const MAX_BODY_BYTES = 1024 * 1024;

function log(event: string, fields: Record<string, unknown> = {}): void {
  console.log(JSON.stringify({ event, ...fields }));
}

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Missing environment variable ${name}.`);
  return value;
}

installWorkerGlobals();
const here = dirname(fileURLToPath(import.meta.url));
const d1 = new SqliteD1(process.env.DATABASE_PATH ?? "/data/godusage.db");

if (process.argv[2] === "import") {
  const dump = process.argv[3];
  if (!dump) throw new Error("Usage: node server.mjs import <dump.sql>");
  importDump(d1, dump);
  log("imported", { dump });
  process.exit(0);
}

migrate(d1, process.env.MIGRATIONS_DIR ?? join(here, "migrations"), (message) => log("migration", { message }));

// The same names and limits as wrangler.jsonc.
const env = {
  DB: d1.asD1(),
  AUTH_LIMITER: memoryRateLimit(20, 60),
  API_LIMITER: memoryRateLimit(120, 60),
  PAGE_LIMITER: memoryRateLimit(30, 60),
  APPLE_AUDIENCES: required("APPLE_AUDIENCES"),
  APPLE_WEB_CLIENT_ID: required("APPLE_WEB_CLIENT_ID"),
  DOWNLOAD_URL: process.env.DOWNLOAD_URL ?? "https://github.com/federico-app/godusage/releases/latest",
  // No daily database bill here; the budget only guards against runaway reads.
  READ_BUDGET_PER_DAY: process.env.READ_BUDGET_PER_DAY ?? "1000000000",
} as unknown as Env;

const app = createApp({ fetchAppleKeys, now: () => new Date() });

const server = createServer((req, res) => {
  const chunks: Buffer[] = [];
  let size = 0;
  req.on("data", (chunk: Buffer) => {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) {
      res.writeHead(413, { "content-type": "application/json" }).end(JSON.stringify({ error: { code: "too_large", message: "Request too large." } }));
      req.destroy();
      return;
    }
    chunks.push(chunk);
  });
  req.on("end", async () => {
    if (res.writableEnded) return;
    try {
      const request = fetchRequest(req.method ?? "GET", req.url ?? "/", req.headers, Buffer.concat(chunks), req.socket.remoteAddress);
      const response = await app.fetch(request, env);
      const headers: Record<string, string | string[]> = {};
      response.headers.forEach((value, name) => {
        if (name !== "set-cookie") headers[name] = value;
      });
      const cookies = response.headers.getSetCookie();
      if (cookies.length > 0) headers["set-cookie"] = cookies;
      res.writeHead(response.status, headers);
      res.end(Buffer.from(await response.arrayBuffer()));
    } catch (error) {
      log("server_error", { message: error instanceof Error ? error.message : String(error) });
      if (!res.headersSent) res.writeHead(500, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: { code: "internal", message: "Something went wrong. Try again later." } }));
    }
  });
});

const port = Number(process.env.PORT ?? 8787);
server.listen(port, () => log("listening", { port }));

function shutdown(): void {
  server.close(() => {
    d1.db.close();
    process.exit(0);
  });
}
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
