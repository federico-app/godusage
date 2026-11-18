import { type ClientInfo, readClientHeader } from "./clientHeader";
import type { Queryable } from "./db";
import { nowISO, randomToken, sha256Hex, unauthorized } from "./http";

/** App sessions (Mac app, iOS app). */
export const APP_SESSION_DAYS = 180;
/** Browser sessions for the members-only web leaderboard. */
export const WEB_SESSION_DAYS = 30;
/** Sliding expiry is extended at most once a day, so reads do not turn into writes. */
const RENEW_AFTER_MS = 24 * 60 * 60 * 1000;
/** A linked device's last access and details are written at most once an hour, unless they change. */
export const SEEN_AFTER_MS = 60 * 60 * 1000;
export const WEB_SESSION_COOKIE = "godusage_session";

export interface SessionUser {
  id: string;
  displayName: string;
}

/**
 * `pairedDevice` names the phone or iPad of a session made by QR pairing (see `routes/pairing.ts`);
 * `client` is what that device reported in its `X-GodUsage-Client` header, recorded with the session.
 */
export async function createSession(
  db: Queryable,
  userID: string,
  lifetimeDays = APP_SESSION_DAYS,
  pairedDevice: string | null = null,
  client: ClientInfo | null = null,
): Promise<string> {
  const token = randomToken(32);
  const now = nowISO();
  await db.run(
    `INSERT INTO sessions (token_hash, user_id, created_at, expires_at, lifetime_days, paired_device, device_model, os_version, app_version, last_seen_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`,
    [
      await sha256Hex(token),
      userID,
      now,
      expiryFrom(new Date(), lifetimeDays),
      lifetimeDays,
      pairedDevice,
      pairedDevice === null ? null : (client?.model ?? null),
      pairedDevice === null ? null : (client?.osVersion ?? null),
      pairedDevice === null ? null : (client?.appVersion ?? null),
      pairedDevice === null ? null : now,
    ],
  );
  return token;
}

/** Resolves the `Authorization: Bearer` session to its user, or throws 401. */
export async function requireUser(request: Request, db: Queryable): Promise<SessionUser> {
  return (await requireSession(request, db)).user;
}

/** The bearer session's user, and the paired device's name when the session came from QR pairing. */
export async function requireSession(request: Request, db: Queryable): Promise<{ user: SessionUser; pairedDevice: string | null }> {
  const token = bearerToken(request);
  if (!token) throw unauthorized("Sign in to use teams.");
  return sessionForToken(db, token, request);
}

/** The browser session from the web cookie, or null when there is none or it is no longer valid. */
export async function cookieUser(request: Request, db: Queryable): Promise<SessionUser | null> {
  const token = cookieToken(request);
  if (!token) return null;
  try {
    return (await sessionForToken(db, token, null)).user;
  } catch {
    return null;
  }
}

interface SessionRow extends DeviceRow {
  id: string;
  display_name: string;
  expires_at: string;
  lifetime_days: number;
  paired_device: string | null;
}

interface DeviceRow {
  device_model: string | null;
  os_version: string | null;
  app_version: string | null;
  last_seen_at: string | null;
}

/** `request` is the bearer request, whose client header a paired device's session records; null for cookies. */
async function sessionForToken(db: Queryable, token: string, request: Request | null): Promise<{ user: SessionUser; pairedDevice: string | null }> {
  const tokenHash = await sha256Hex(token);
  const row = await db.first<SessionRow>(
    `SELECT u.id, u.display_name, s.expires_at, s.lifetime_days, s.paired_device, s.device_model, s.os_version, s.app_version, s.last_seen_at
     FROM sessions s JOIN users u ON u.id = s.user_id
     WHERE s.token_hash = $1`,
    [tokenHash],
  );
  if (!row) throw unauthorized();

  const now = new Date();
  const expiresAt = new Date(row.expires_at);
  if (expiresAt <= now) {
    await db.run("DELETE FROM sessions WHERE token_hash = $1", [tokenHash]);
    throw unauthorized("Your session expired. Sign in again.");
  }
  if (expiresAt.getTime() - now.getTime() < row.lifetime_days * 86_400_000 - RENEW_AFTER_MS) {
    await db.run("UPDATE sessions SET expires_at = $1 WHERE token_hash = $2", [expiryFrom(now, row.lifetime_days), tokenHash]);
  }
  if (row.paired_device !== null && request) {
    await recordDeviceSeen(db, tokenHash, row, readClientHeader(request), now);
  }
  return { user: { id: row.id, displayName: row.display_name }, pairedDevice: row.paired_device };
}

/**
 * Records that a linked device used its session, and what it reported about itself. Writes only when
 * the last record is an hour old (or missing) or a reported detail changed, so most reads stay reads.
 * A detail the device didn't report keeps its stored value.
 */
async function recordDeviceSeen(db: Queryable, tokenHash: string, row: DeviceRow, client: ClientInfo | null, now: Date): Promise<void> {
  const next = {
    device_model: client?.model ?? row.device_model,
    os_version: client?.osVersion ?? row.os_version,
    app_version: client?.appVersion ?? row.app_version,
  };
  const changed = next.device_model !== row.device_model || next.os_version !== row.os_version || next.app_version !== row.app_version;
  const lastSeen = row.last_seen_at ? new Date(row.last_seen_at).getTime() : Number.NaN;
  const stale = Number.isNaN(lastSeen) || now.getTime() - lastSeen >= SEEN_AFTER_MS;
  if (!changed && !stale) return;
  await db.run("UPDATE sessions SET last_seen_at = $1, device_model = $2, os_version = $3, app_version = $4 WHERE token_hash = $5", [
    now.toISOString(),
    next.device_model,
    next.os_version,
    next.app_version,
    tokenHash,
  ]);
}

export async function deleteSession(request: Request, db: Queryable): Promise<void> {
  const token = bearerToken(request) ?? cookieToken(request);
  if (!token) return;
  await db.run("DELETE FROM sessions WHERE token_hash = $1", [await sha256Hex(token)]);
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
