import type { Handler } from "../context";
import { forbidden, json, noContent, notFound, randomToken, readJSONObject, requireName, sha256Hex, unauthorized } from "../http";
import { createSession, requireSession, requireUser } from "../session";

/**
 * QR pairing: the GodUsage iPhone app signs in to the account of a Mac that is already signed in.
 *
 * 1. The Mac asks POST /v1/auth/pairing for a one-time code and shows it as a QR code.
 * 2. The phone scans it and posts the code to POST /v1/auth/pairing/exchange, which spends the code
 *    and returns a session of the same account, tagged with the phone's name.
 * 3. The Mac lists linked devices (GET /v1/me/linked-devices) and can unlink one (DELETE …/:id).
 *
 * A code lives a few minutes and works once. Only its SHA-256 is stored. Paired sessions cannot
 * make codes, so every linked device traces back to a Mac signed in with Apple.
 */

export const PAIRING_CODE_TTL_MS = 3 * 60 * 1000;
const DEVICE_NAME_MAX = 60;
const CODE = /^[A-Za-z0-9_-]{43}$/;
const SESSION_ID = /^[0-9a-f]{64}$/;

/** POST /v1/auth/pairing → { code, expiresAt } */
export const createPairingCode: Handler = async ({ request, env, deps }) => {
  const { user, pairedDevice } = await requireSession(request, env.db);
  if (pairedDevice !== null) throw forbidden("Link a new device from a Mac signed in to GodUsage.");

  const code = randomToken(32);
  const now = deps.now();
  const expiresAt = new Date(now.getTime() + PAIRING_CODE_TTL_MS).toISOString();
  await env.db.transaction(async (tx) => {
    await tx.run("DELETE FROM pairing_codes WHERE user_id = $1 OR expires_at < $2", [user.id, now.toISOString()]);
    await tx.run("INSERT INTO pairing_codes (code_hash, user_id, expires_at) VALUES ($1, $2, $3)", [await sha256Hex(code), user.id, expiresAt]);
  });
  return json({ code, expiresAt }, 201);
};

/** POST /v1/auth/pairing/exchange { code, deviceName } → { token, user } */
export const exchangePairingCode: Handler = async ({ request, env, deps }) => {
  const body = await readJSONObject(request);
  const deviceName = requireName(body.deviceName, "deviceName", DEVICE_NAME_MAX);
  if (typeof body.code !== "string" || !CODE.test(body.code)) {
    throw unauthorized("This isn't a GodUsage pairing code. Show the code on your Mac again.");
  }
  const row = await env.db.first<{ user_id: string; expires_at: string }>(
    "DELETE FROM pairing_codes WHERE code_hash = $1 RETURNING user_id, expires_at",
    [await sha256Hex(body.code)],
  );
  if (!row || new Date(row.expires_at) <= deps.now()) {
    throw unauthorized("This code expired or was already used. Show a new one on your Mac.");
  }
  const user = await env.db.first<{ id: string; display_name: string }>("SELECT id, display_name FROM users WHERE id = $1", [row.user_id]);
  if (!user) throw unauthorized("This account no longer exists.");

  const token = await createSession(env.db, user.id, undefined, deviceName);
  console.log(JSON.stringify({ event: "device_paired", userID: user.id }));
  return json({ token, user: { id: user.id, displayName: user.display_name } }, 201);
};

/** GET /v1/me/linked-devices → { devices: [{ id, name, linkedAt }] }, newest first. */
export const listLinkedDevices: Handler = async ({ request, env }) => {
  const user = await requireUser(request, env.db);
  const rows = await env.db.query<{ token_hash: string; paired_device: string; created_at: string }>(
    "SELECT token_hash, paired_device, created_at FROM sessions WHERE user_id = $1 AND paired_device IS NOT NULL ORDER BY created_at DESC",
    [user.id],
  );
  // The id is the session's token hash: it identifies the session but cannot be used as a token.
  return json({ devices: rows.map((row) => ({ id: row.token_hash, name: row.paired_device, linkedAt: row.created_at })) });
};

/** DELETE /v1/me/linked-devices/:id — signs that device out. */
export const unlinkDevice: Handler = async ({ request, env, params }) => {
  const user = await requireUser(request, env.db);
  const id = params.id ?? "";
  if (!SESSION_ID.test(id)) throw notFound("That device isn't linked to your account.");
  const deleted = await env.db.run("DELETE FROM sessions WHERE token_hash = $1 AND user_id = $2 AND paired_device IS NOT NULL", [id, user.id]);
  if (deleted === 0) throw notFound("That device isn't linked to your account.");
  console.log(JSON.stringify({ event: "device_unlinked", userID: user.id }));
  return noContent();
};
