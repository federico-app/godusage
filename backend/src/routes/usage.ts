import type { Handler } from "../context";
import { badRequest, json, noContent, notFound, readJSONObject } from "../http";
import { requireUser } from "../session";
import type { Env } from "../context";
import type { Queryable } from "../db";
import { userTeamIDs } from "../teamCache";
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
  const user = await requireUser(request, env.db);
  const deviceID = requireDeviceID(params.deviceID);
  const now = deps.now();
  const upload = parseUsageUpload(await readJSONObject(request), now);
  await storeDeviceUsage(env, user.id, deviceID, upload, now);
  // `partialUploads` tells the app it may send partial uploads (older servers would drop the days a
  // partial upload leaves out).
  return json({ deviceID, days: upload.days.length, models: upload.models.length, updatedAt: now.toISOString(), partialUploads: true });
};

/**
 * Writes one upload in one transaction and returns the rows it changed. Only rows that changed are
 * written: rows the upload no longer has are deleted, and the rest are upserted, skipping any that are
 * identical (most of an upload repeats the last one; only today moves). All rows go in through
 * `jsonb_to_recordset`, so the upload is a fixed handful of statements however many days and models
 * it carries. A full upload replaces its window; a partial one only the provider-days it carries.
 * When stored usage changed, the user's teams' cached stats count as stale.
 */
export async function storeDeviceUsage(env: Pick<Env, "db" | "cache">, userID: string, deviceID: string, upload: UsageUpload, now: Date): Promise<number> {
  const NONE = "9999-12-31";
  const sentDays = upload.days.map((row) => row.day).sort();
  // Full: days from the window start on. Partial: only the provider-days sent (none for day rows,
  // since every provider-day sent is upserted). "9999-12-31" matches no stored day.
  const dayFrom = upload.replaceFrom ?? NONE;
  const modelFrom = upload.partial ? (sentDays[0] ?? NONE) : dayFrom;
  const modelTo = upload.partial ? (sentDays[sentDays.length - 1] ?? NONE) : NONE;
  const dayRows = JSON.stringify(
    upload.days.map((row) => ({ provider: row.provider, day: row.day, scope: row.scope, tokens: row.tokens, cost_usd: row.costUSD, account_key: row.accountKey })),
  );
  const modelRows = JSON.stringify(
    upload.models.map((row) => ({
      provider: row.provider,
      day: row.day,
      model: row.model,
      scope: row.scope,
      tokens: row.tokens,
      cost_usd: row.costUSD,
      account_key: row.accountKey,
    })),
  );

  const { written, usageChanged } = await env.db.transaction(async (tx) => {
    const device = await tx.run(
      `INSERT INTO devices (user_id, id, name, updated_at, app_version) VALUES ($1, $2, $3, $4, $5)
       ON CONFLICT (user_id, id) DO UPDATE SET name = excluded.name, updated_at = excluded.updated_at, app_version = excluded.app_version`,
      [userID, deviceID, upload.deviceName, now.toISOString(), upload.appVersion],
    );
    const usage = [
      await tx.run(
        `DELETE FROM usage_days u WHERE u.user_id = $1 AND u.device_id = $2 AND u.day >= $3
         AND NOT EXISTS (SELECT 1 FROM jsonb_to_recordset($4::jsonb) AS r(provider text, day text) WHERE r.provider = u.provider AND r.day = u.day)`,
        [userID, deviceID, dayFrom, dayRows],
      ),
      await tx.run(
        `DELETE FROM usage_model_days u WHERE u.user_id = $1 AND u.device_id = $2 AND u.day BETWEEN $3 AND $4
         AND (NOT $5::boolean OR EXISTS (SELECT 1 FROM jsonb_to_recordset($6::jsonb) AS r(provider text, day text) WHERE r.provider = u.provider AND r.day = u.day))
         AND NOT EXISTS (SELECT 1 FROM jsonb_to_recordset($7::jsonb) AS r(provider text, day text, model text)
                         WHERE r.provider = u.provider AND r.day = u.day AND r.model = u.model)`,
        [userID, deviceID, modelFrom, modelTo, upload.partial, dayRows, modelRows],
      ),
      await tx.run(
        `INSERT INTO usage_days (user_id, device_id, provider, day, scope, tokens, cost_usd, account_key)
         SELECT $1, $2, r.provider, r.day, r.scope, r.tokens, r.cost_usd, r.account_key
         FROM jsonb_to_recordset($3::jsonb) AS r(provider text, day text, scope text, tokens bigint, cost_usd double precision, account_key text)
         ON CONFLICT (user_id, device_id, provider, day) DO UPDATE SET
           scope = excluded.scope, tokens = excluded.tokens, cost_usd = excluded.cost_usd, account_key = excluded.account_key
         WHERE (usage_days.scope, usage_days.tokens, usage_days.cost_usd, usage_days.account_key)
           IS DISTINCT FROM (excluded.scope, excluded.tokens, excluded.cost_usd, excluded.account_key)`,
        [userID, deviceID, dayRows],
      ),
      await tx.run(
        `INSERT INTO usage_model_days (user_id, device_id, provider, day, model, scope, tokens, cost_usd, account_key)
         SELECT $1, $2, r.provider, r.day, r.model, r.scope, r.tokens, r.cost_usd, r.account_key
         FROM jsonb_to_recordset($3::jsonb) AS r(provider text, day text, model text, scope text, tokens bigint, cost_usd double precision, account_key text)
         ON CONFLICT (user_id, device_id, provider, day, model) DO UPDATE SET
           scope = excluded.scope, tokens = excluded.tokens, cost_usd = excluded.cost_usd, account_key = excluded.account_key
         WHERE (usage_model_days.scope, usage_model_days.tokens, usage_model_days.cost_usd, usage_model_days.account_key)
           IS DISTINCT FROM (excluded.scope, excluded.tokens, excluded.cost_usd, excluded.account_key)`,
        [userID, deviceID, modelRows],
      ),
    ];
    const keys = await syncAccountKeys(tx, userID, dayRows);
    const changed = usage.reduce((total, count) => total + count, 0);
    return { written: device + changed + keys, usageChanged: changed > 0 };
  });
  if (usageChanged) await env.cache.bumpTeams(await userTeamIDs(env.db, userID));
  return written;
}

/**
 * Keeps `account_keys` in step with the user's stored usage: adds the upload's fingerprints and drops
 * any that no stored day carries any more. `dayRows` is an upload's JSON day rows, or "[]". Returns
 * the rows it changed.
 */
export async function syncAccountKeys(tx: Queryable, userID: string, dayRows: string): Promise<number> {
  const added = await tx.run(
    `INSERT INTO account_keys (user_id, account_key, provider)
     SELECT DISTINCT $1, r.account_key, r.provider FROM jsonb_to_recordset($2::jsonb) AS r(provider text, account_key text)
     WHERE r.account_key IS NOT NULL
     ON CONFLICT DO NOTHING`,
    [userID, dayRows],
  );
  const removed = await tx.run(
    `DELETE FROM account_keys k WHERE k.user_id = $1 AND NOT EXISTS (
       SELECT 1 FROM usage_days u WHERE u.account_key = k.account_key AND u.user_id = $1 AND u.provider = k.provider)`,
    [userID],
  );
  return added + removed;
}

/** DELETE /v1/devices/:deviceID — removes this Mac and its usage (the user stopped sharing on it). */
export const deleteDevice: Handler = async ({ request, env, params }) => {
  const user = await requireUser(request, env.db);
  const deviceID = requireDeviceID(params.deviceID);
  const removed = await env.db.transaction(async (tx) => {
    const count = await tx.run("DELETE FROM devices WHERE user_id = $1 AND id = $2", [user.id, deviceID]);
    await syncAccountKeys(tx, user.id, "[]");
    return count;
  });
  if (removed === 0) throw notFound("Device not found.");
  // The Mac's usage leaves the boards at once (signing out of it is rare).
  await env.cache.forgetTeams(await userTeamIDs(env.db, user.id));
  return noContent();
};

/** GET /v1/devices — the user's Macs that have shared usage. */
export const listDevices: Handler = async ({ request, env }) => {
  const user = await requireUser(request, env.db);
  const rows = await env.db.query<{ id: string; name: string; updated_at: string }>(
    "SELECT id, name, updated_at FROM devices WHERE user_id = $1 ORDER BY updated_at DESC",
    [user.id],
  );
  return json({ devices: rows.map((row) => ({ id: row.id, name: row.name, updatedAt: row.updated_at })) });
};
