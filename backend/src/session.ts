import { nowISO, randomToken, sha256Hex, unauthorized } from "./http";

const SESSION_DAYS = 180;
/** Sliding expiry is extended at most once a day, so reads do not turn into writes. */
const RENEW_AFTER_MS = 24 * 60 * 60 * 1000;

export interface SessionUser {
  id: string;
  displayName: string;
}

export async function createSession(db: D1Database, userID: string): Promise<string> {
  const token = randomToken(32);
  await db
    .prepare("INSERT INTO sessions (token_hash, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)")
    .bind(await sha256Hex(token), userID, nowISO(), expiryFrom(new Date()))
    .run();
  return token;
}

/** Resolves the `Authorization: Bearer` session to its user, or throws 401. */
export async function requireUser(request: Request, db: D1Database): Promise<SessionUser> {
  const token = bearerToken(request);
  if (!token) throw unauthorized("Sign in to use teams.");
  const tokenHash = await sha256Hex(token);
  const row = await db
    .prepare(
      `SELECT u.id, u.display_name, s.expires_at FROM sessions s JOIN users u ON u.id = s.user_id
       WHERE s.token_hash = ?`,
    )
    .bind(tokenHash)
    .first<{ id: string; display_name: string; expires_at: string }>();
  if (!row) throw unauthorized();

  const now = new Date();
  const expiresAt = new Date(row.expires_at);
  if (expiresAt <= now) {
    await db.prepare("DELETE FROM sessions WHERE token_hash = ?").bind(tokenHash).run();
    throw unauthorized("Your session expired. Sign in again.");
  }
  if (expiresAt.getTime() - now.getTime() < SESSION_DAYS * 86_400_000 - RENEW_AFTER_MS) {
    await db.prepare("UPDATE sessions SET expires_at = ? WHERE token_hash = ?").bind(expiryFrom(now), tokenHash).run();
  }
  return { id: row.id, displayName: row.display_name };
}

export async function deleteSession(request: Request, db: D1Database): Promise<void> {
  const token = bearerToken(request);
  if (!token) return;
  await db.prepare("DELETE FROM sessions WHERE token_hash = ?").bind(await sha256Hex(token)).run();
}

function bearerToken(request: Request): string | null {
  const header = request.headers.get("authorization");
  const match = header?.match(/^Bearer ([A-Za-z0-9_-]{20,})$/);
  return match?.[1] ?? null;
}

function expiryFrom(date: Date): string {
  return new Date(date.getTime() + SESSION_DAYS * 86_400_000).toISOString();
}
