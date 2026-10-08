import type { Handler } from "../context";
import { badRequest, json, noContent, notFound, readJSONObject } from "../http";
import { requireUser } from "../session";
import { bumpUserTeams, forgetUserTeamsCache, guardedWork, readGuard } from "../readGuard";
import { parseUsageUpload, type UsageUpload } from "../usagePayload";

const DEVICE_ID_PATTERN = /^[A-Za-z0-9-]{8,64}$/;

function requireDeviceID(value: string | undefined): string {
  if (!value || !DEVICE_ID_PATTERN.test(value)) throw badRequest("Invalid device id.");
  return value;
}

/**
 * PUT /v1/devices/:deviceID/usage — replaces this device's days from the upload's window start on,
 * atomically, and keeps its older days, so the server holds the full history.
 */
export const putDeviceUsage: Handler = async ({ request, env, params, deps }) => {
  const user = await requireUser(request, env.DB);
  const deviceID = requireDeviceID(params.deviceID);
  const now = deps.now();
  const upload = parseUsageUpload(await readJSONObject(request), now);
  await guardedWork(readGuard(env, now), (db) => storeDeviceUsage(db, user.id, deviceID, upload, now));
  // `partialUploads` tells the app it may send partial uploads (older servers would drop the days a
  // partial upload leaves out).
  return json({ deviceID, days: upload.days.length, models: upload.models.length, updatedAt: now.toISOString(), partialUploads: true });
};

/**
 * Writes one upload and returns the rows D1 wrote. Only rows that changed are written: rows the
 * upload no longer has are deleted, and the rest are upserted, skipping any that are identical.
 * Most of an upload repeats the last one (only today moves), and D1 bills every row written, plus
 * one per index it touches. All rows go in through `json_each`, so the upload is a fixed handful of
 * statements no matter how many days and models it carries.
 *
 * D1 also bills every row read. The deletes seek the (user, scope, day) covering index to the
 * replaced days (the primary key would scan the device's whole history), and a single-column
 * `NOT IN` reads the upload's rows once (a correlated `NOT EXISTS` or a row-value `NOT IN` reads them
 * again for every stored row). A full upload replaces its window; a partial one only the
 * provider-days it carries. When stored usage changed, the user's teams' cached stats are refreshed.
 */
export async function storeDeviceUsage(db: D1Database, userID: string, deviceID: string, upload: UsageUpload, now: Date): Promise<number> {
  const NONE = "9999-12-31";
  const sentDays = upload.days.map((row) => row.day).sort();
  // Full: days from the window start on. Partial: only the provider-days sent (none for day rows,
  // since every provider-day sent is upserted). "9999-12-31" matches no stored day.
  const dayFrom = upload.replaceFrom ?? NONE;
  const modelFrom = upload.partial ? (sentDays[0] ?? NONE) : dayFrom;
  const modelTo = upload.partial ? (sentDays[sentDays.length - 1] ?? NONE) : NONE;
  const dayRows = JSON.stringify(upload.days.map((row) => [row.provider, row.day, row.scope, row.tokens, row.costUSD, row.accountKey]));
  const modelRows = JSON.stringify(
    upload.models.map((row) => [row.provider, row.day, row.model, row.scope, row.tokens, row.costUSD, row.accountKey]),
  );

  const results = await db.batch([
    db.prepare(
      `INSERT INTO devices (user_id, id, name, updated_at, app_version) VALUES (?1, ?2, ?3, ?4, ?5)
       ON CONFLICT (user_id, id) DO UPDATE SET name = excluded.name, updated_at = excluded.updated_at, app_version = excluded.app_version`,
    ).bind(userID, deviceID, upload.deviceName, now.toISOString(), upload.appVersion),
    db.prepare(
      `DELETE FROM usage_days INDEXED BY usage_days_user_day_cover
       WHERE user_id = ?1 AND scope IN ('device', 'account') AND day >= ?3 AND device_id = ?2
       AND provider || char(0) || day NOT IN
         (SELECT json_extract(value, '$[0]') || char(0) || json_extract(value, '$[1]') FROM json_each(?4))`,
    ).bind(userID, deviceID, dayFrom, dayRows),
    db.prepare(
      `DELETE FROM usage_model_days INDEXED BY usage_model_days_user_day_cover
       WHERE user_id = ?1 AND scope IN ('device', 'account') AND day BETWEEN ?3 AND ?4 AND device_id = ?2
       AND (?5 = 0 OR provider || char(0) || day IN
         (SELECT json_extract(value, '$[0]') || char(0) || json_extract(value, '$[1]') FROM json_each(?6)))
       AND provider || char(0) || day || char(0) || model NOT IN
         (SELECT json_extract(value, '$[0]') || char(0) || json_extract(value, '$[1]') || char(0) || json_extract(value, '$[2]') FROM json_each(?7))`,
    ).bind(userID, deviceID, modelFrom, modelTo, upload.partial ? 1 : 0, dayRows, modelRows),
    // "WHERE true" lets SQLite parse the upsert after a SELECT.
    db.prepare(
      `INSERT INTO usage_days (user_id, device_id, provider, day, scope, tokens, cost_usd, account_key)
       SELECT ?1, ?2, json_extract(value, '$[0]'), json_extract(value, '$[1]'), json_extract(value, '$[2]'), json_extract(value, '$[3]'), json_extract(value, '$[4]'), json_extract(value, '$[5]') FROM json_each(?3) WHERE true
       ON CONFLICT (user_id, device_id, provider, day) DO UPDATE SET
         scope = excluded.scope, tokens = excluded.tokens, cost_usd = excluded.cost_usd, account_key = excluded.account_key
       WHERE usage_days.scope IS NOT excluded.scope OR usage_days.tokens IS NOT excluded.tokens
         OR usage_days.cost_usd IS NOT excluded.cost_usd OR usage_days.account_key IS NOT excluded.account_key`,
    ).bind(userID, deviceID, dayRows),
    db.prepare(
      `INSERT INTO usage_model_days (user_id, device_id, provider, day, model, scope, tokens, cost_usd, account_key)
       SELECT ?1, ?2, json_extract(value, '$[0]'), json_extract(value, '$[1]'), json_extract(value, '$[2]'), json_extract(value, '$[3]'), json_extract(value, '$[4]'), json_extract(value, '$[5]'), json_extract(value, '$[6]') FROM json_each(?3) WHERE true
       ON CONFLICT (user_id, device_id, provider, day, model) DO UPDATE SET
         scope = excluded.scope, tokens = excluded.tokens, cost_usd = excluded.cost_usd, account_key = excluded.account_key
       WHERE usage_model_days.scope IS NOT excluded.scope OR usage_model_days.tokens IS NOT excluded.tokens
         OR usage_model_days.cost_usd IS NOT excluded.cost_usd OR usage_model_days.account_key IS NOT excluded.account_key`,
    ).bind(userID, deviceID, modelRows),
    ...syncAccountKeys(db, userID, dayRows),
  ]);
  let written = results.reduce((total, result) => total + (result.meta.rows_written ?? 0), 0);
  // The device row always changes (its upload time); the usage statements only when usage did.
  if (results.slice(1, 5).some((result) => result.meta.changes > 0)) {
    written += (await bumpUserTeams(db, userID).run()).meta.rows_written ?? 0;
  }
  return written;
}

/**
 * Keeps `account_keys` in step with the user's stored usage: adds the upload's fingerprints and drops
 * any that no stored day carries any more. `dayRows` is an upload's JSON day rows, or "[]".
 */
export function syncAccountKeys(db: D1Database, userID: string, dayRows: string): D1PreparedStatement[] {
  return [
    db.prepare(
      `INSERT OR IGNORE INTO account_keys (user_id, account_key, provider)
       SELECT DISTINCT ?1, json_extract(value, '$[5]'), json_extract(value, '$[0]') FROM json_each(?2)
       WHERE json_extract(value, '$[5]') IS NOT NULL`,
    ).bind(userID, dayRows),
    db.prepare(
      `DELETE FROM account_keys WHERE user_id = ?1 AND NOT EXISTS (
         SELECT 1 FROM usage_days u INDEXED BY usage_days_account_key
         WHERE u.account_key = account_keys.account_key AND u.user_id = ?1 AND u.provider = account_keys.provider)`,
    ).bind(userID),
  ];
}

/** DELETE /v1/devices/:deviceID — removes this Mac and its usage (the user stopped sharing on it). */
export const deleteDevice: Handler = async ({ request, env, params }) => {
  const user = await requireUser(request, env.DB);
  const deviceID = requireDeviceID(params.deviceID);
  const [result] = await env.DB.batch([
    env.DB.prepare("DELETE FROM devices WHERE user_id = ? AND id = ?").bind(user.id, deviceID),
    ...syncAccountKeys(env.DB, user.id, "[]"),
    // The Mac's usage leaves the boards at once (signing out of it is rare).
    forgetUserTeamsCache(env.DB, user.id),
  ]);
  if (result!.meta.changes === 0) throw notFound("Device not found.");
  return noContent();
};

/** GET /v1/devices — the user's Macs that have shared usage. */
export const listDevices: Handler = async ({ request, env }) => {
  const user = await requireUser(request, env.DB);
  const rows = await env.DB.prepare("SELECT id, name, updated_at FROM devices WHERE user_id = ? ORDER BY updated_at DESC")
    .bind(user.id)
    .all<{ id: string; name: string; updated_at: string }>();
  return json({ devices: rows.results.map((row) => ({ id: row.id, name: row.name, updatedAt: row.updated_at })) });
};
