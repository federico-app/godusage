import { timingSafeEqual } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import type { SqliteD1 } from "./d1Sqlite";

/** Workers-only Web Crypto extensions the routes use, on Node. */
export function installWorkerGlobals(): void {
  const subtle = crypto.subtle as unknown as { timingSafeEqual?: (a: ArrayBufferView | ArrayBuffer, b: ArrayBufferView | ArrayBuffer) => boolean };
  if (subtle.timingSafeEqual) return;
  const bytes = (value: ArrayBufferView | ArrayBuffer) =>
    ArrayBuffer.isView(value) ? new Uint8Array(value.buffer, value.byteOffset, value.byteLength) : new Uint8Array(value);
  subtle.timingSafeEqual = (a, b) => {
    const left = bytes(a);
    const right = bytes(b);
    if (left.byteLength !== right.byteLength) throw new TypeError("Input buffers must have the same length.");
    return timingSafeEqual(left, right);
  };
}

/**
 * Cloudflare's rate limiting binding, in memory: a fixed window per key. One container serves every
 * request, so the counts are exact (Cloudflare's are per location).
 */
export function memoryRateLimit(limit: number, periodSeconds: number): RateLimit {
  const windows = new Map<string, { start: number; count: number }>();
  let lastSweep = Date.now();
  return {
    async limit({ key }: { key: string }) {
      const now = Date.now();
      const periodMs = periodSeconds * 1000;
      if (now - lastSweep > periodMs) {
        for (const [entry, window] of windows) if (now - window.start >= periodMs) windows.delete(entry);
        lastSweep = now;
      }
      const window = windows.get(key);
      if (!window || now - window.start >= periodMs) {
        windows.set(key, { start: now, count: 1 });
        return { success: true };
      }
      window.count += 1;
      return { success: window.count <= limit };
    },
  } as RateLimit;
}

/**
 * Applies the migrations in `dir` that the database has not seen, in name order, each in its own
 * transaction. Tracks them in `d1_migrations`, the table wrangler uses, so a database exported from
 * D1 continues where it left off.
 */
export function migrate(d1: SqliteD1, dir: string, log: (message: string) => void): void {
  const db = d1.db;
  db.exec(`CREATE TABLE IF NOT EXISTS d1_migrations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT UNIQUE,
    applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL
  )`);
  const applied = new Set((db.prepare("SELECT name FROM d1_migrations").all() as { name: string }[]).map((row) => row.name));
  const pending = readdirSync(dir).filter((name) => name.endsWith(".sql") && !applied.has(name)).sort();
  for (const name of pending) {
    db.exec("BEGIN");
    try {
      db.exec(readFileSync(join(dir, name), "utf8"));
      db.prepare("INSERT INTO d1_migrations (name) VALUES (?)").run(name);
      db.exec("COMMIT");
      log(`applied migration ${name}`);
    } catch (error) {
      db.exec("ROLLBACK");
      throw new Error(`Migration ${name} failed: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
}

/** Loads a `wrangler d1 export` SQL dump into an empty database. */
export function importDump(d1: SqliteD1, path: string): void {
  const tables = d1.db.prepare("SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'").get() as { n: number };
  if (tables.n > 0) throw new Error("The database is not empty: import a D1 export only into a new database.");
  d1.db.exec("PRAGMA foreign_keys = OFF");
  try {
    d1.db.exec(readFileSync(path, "utf8"));
  } finally {
    d1.db.exec("PRAGMA foreign_keys = ON");
  }
}

/** Node's request → a Fetch API Request. Behind Coolify's proxy, the client's address and scheme come from forwarded headers. */
export function fetchRequest(
  method: string,
  url: string,
  headers: Record<string, string | string[] | undefined>,
  body: Buffer | undefined,
  socketAddress: string | undefined,
): Request {
  const requestHeaders = new Headers();
  for (const [name, value] of Object.entries(headers)) {
    if (value === undefined) continue;
    for (const item of Array.isArray(value) ? value : [value]) requestHeaders.append(name, item);
  }
  const forwardedFor = requestHeaders.get("x-forwarded-for")?.split(",")[0]?.trim();
  const clientIP = forwardedFor || requestHeaders.get("x-real-ip") || socketAddress || "unknown";
  // The Worker reads the client's address from Cloudflare's header (rate limits per IP).
  requestHeaders.set("cf-connecting-ip", clientIP);
  const proto = requestHeaders.get("x-forwarded-proto")?.split(",")[0]?.trim() || "http";
  const host = requestHeaders.get("x-forwarded-host") || requestHeaders.get("host") || "localhost";
  return new Request(`${proto}://${host}${url}`, {
    method,
    headers: requestHeaders,
    body: body && body.length > 0 && method !== "GET" && method !== "HEAD" ? body : undefined,
  });
}
