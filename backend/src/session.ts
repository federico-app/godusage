import { nowISO, randomToken, sha256Hex, unauthorized } from "./http";

/** App sessions (Mac app, iOS app). */
export const APP_SESSION_DAYS = 180;
/** Browser sessions for the members-only web leaderboard. */
export const WEB_SESSION_DAYS = 30;
/** Sliding expiry is extended at most once a day, so reads do not turn into writes. */
const RENEW_AFTER_MS = 24 * 60 * 60 * 1000;
export const WEB_SESSION_COOKIE = "godusage_session";

export interface SessionUser {
  id: string;
  displayName: string;
}

export async function createSession(db: D1Database, userID: string, lifetimeDays = APP_SESSION_DAYS): Promise<string> {
  const token = randomToken(32);
  await db
    .prepare("INSERT INTO sessions (token_hash, user_id, created_at, expires_at, lifetime_days) VALUES (?, ?, ?, ?, ?)")
    .bind(await sha256Hex(token), userID, nowISO(), expiryFrom(new Date(), lifetimeDays), lifetimeDays)
    .run();
  return token;
}

/** Resolves the `Authorization: Bearer` session to its user, or throws 401. */
export async function requireUser(request: Request, db: D1Database): Promise<SessionUser> {
  const token = bearerToken(request);
  if (!token) throw unauthorized("Sign in to use teams.");
  return userForToken(db, token);
}

/** The browser session from the web cookie, or null when there is none or it is no longer valid. */
export async function cookieUser(request: Request, db: D1Database): Promise<SessionUser | null> {
  const token = cookieToken(request);
  if (!token) return null;
  try {
    return await userForToken(db, token);
  } catch {
    return null;
  }
}

async function userForToken(db: D1Database, token: string): Promise<SessionUser> {
  const tokenHash = await sha256Hex(token);
  const row = await db
    .prepare(
      `SELECT u.id, u.display_name, s.expires_at, s.lifetime_days FROM sessions s JOIN users u ON u.id = s.user_id
       WHERE s.token_hash = ?`,
    )
    .bind(tokenHash)
    .first<{ id: string; display_name: string; expires_at: string; lifetime_days: number }>();
  if (!row) throw unauthorized();

  const now = new Date();
  const expiresAt = new Date(row.expires_at);
  if (expiresAt <= now) {
    await db.prepare("DELETE FROM sessions WHERE token_hash = ?").bind(tokenHash).run();
    throw unauthorized("Your session expired. Sign in again.");
  }
  if (expiresAt.getTime() - now.getTime() < row.lifetime_days * 86_400_000 - RENEW_AFTER_MS) {
    await db.prepare("UPDATE sessions SET expires_at = ? WHERE token_hash = ?")
      .bind(expiryFrom(now, row.lifetime_days), tokenHash)
      .run();
  }
  return { id: row.id, displayName: row.display_name };
}

export async function deleteSession(request: Request, db: D1Database): Promise<void> {
  const token = bearerToken(request) ?? cookieToken(request);
  if (!token) return;
  await db.prepare("DELETE FROM sessions WHERE token_hash = ?").bind(await sha256Hex(token)).run();
}

/** The cookie that keeps a browser signed in to the web leaderboard. */
export function webSessionCookie(token: string): string {
  return `${WEB_SESSION_COOKIE}=${token}; Path=/; Max-Age=${WEB_SESSION_DAYS * 86_400}; HttpOnly; Secure; SameSite=Lax`;
}

export function clearedWebSessionCookie(): string {
  return `${WEB_SESSION_COOKIE}=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax`;
}

function bearerToken(request: Request): string | null {
  const header = request.headers.get("authorization");
  const match = header?.match(/^Bearer ([A-Za-z0-9_-]{20,})$/);
  return match?.[1] ?? null;
}

function cookieToken(request: Request): string | null {
  for (const part of (request.headers.get("cookie") ?? "").split(";")) {
    const [name, value] = part.trim().split("=", 2);
    if (name === WEB_SESSION_COOKIE && value && /^[A-Za-z0-9_-]{20,}$/.test(value)) return value;
  }
  return null;
}

function expiryFrom(date: Date, lifetimeDays: number): string {
  return new Date(date.getTime() + lifetimeDays * 86_400_000).toISOString();
}
