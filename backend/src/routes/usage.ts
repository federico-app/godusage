import type { Handler } from "../context";
import { badRequest, json, noContent, notFound, readJSONObject } from "../http";
import { requireUser } from "../session";
import { parseUsageUpload } from "../usagePayload";

const DEVICE_ID_PATTERN = /^[A-Za-z0-9-]{8,64}$/;

function requireDeviceID(value: string | undefined): string {
  if (!value || !DEVICE_ID_PATTERN.test(value)) throw badRequest("Invalid device id.");
  return value;
}

/**
 * PUT /v1/devices/:deviceID/usage — replaces everything this device has uploaded with the new
 * window, atomically. All rows go in through `json_each`, so the upload is five statements no
 * matter how many days and models it carries.
 */
export const putDeviceUsage: Handler = async ({ request, env, params, deps }) => {
  const user = await requireUser(request, env.DB);
  const deviceID = requireDeviceID(params.deviceID);
  const now = deps.now();
  const upload = parseUsageUpload(await readJSONObject(request), now);

  const dayRows = JSON.stringify(upload.days.map((row) => [row.provider, row.day, row.scope, row.tokens, row.costUSD]));
  const modelRows = JSON.stringify(
    upload.models.map((row) => [row.provider, row.day, row.model, row.scope, row.tokens, row.costUSD]),
  );

  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO devices (user_id, id, name, updated_at) VALUES (?1, ?2, ?3, ?4)
       ON CONFLICT (user_id, id) DO UPDATE SET name = excluded.name, updated_at = excluded.updated_at`,
    ).bind(user.id, deviceID, upload.deviceName, now.toISOString()),
    env.DB.prepare("DELETE FROM usage_days WHERE user_id = ? AND device_id = ?").bind(user.id, deviceID),
    env.DB.prepare("DELETE FROM usage_model_days WHERE user_id = ? AND device_id = ?").bind(user.id, deviceID),
    env.DB.prepare(
      `INSERT INTO usage_days (user_id, device_id, provider, day, scope, tokens, cost_usd)
       SELECT ?1, ?2, json_extract(value, '$[0]'), json_extract(value, '$[1]'), json_extract(value, '$[2]'), json_extract(value, '$[3]'), json_extract(value, '$[4]') FROM json_each(?3)`,
    ).bind(user.id, deviceID, dayRows),
    env.DB.prepare(
      `INSERT INTO usage_model_days (user_id, device_id, provider, day, model, scope, tokens, cost_usd)
       SELECT ?1, ?2, json_extract(value, '$[0]'), json_extract(value, '$[1]'), json_extract(value, '$[2]'), json_extract(value, '$[3]'), json_extract(value, '$[4]'), json_extract(value, '$[5]') FROM json_each(?3)`,
    ).bind(user.id, deviceID, modelRows),
  ]);

  return json({ deviceID, days: upload.days.length, models: upload.models.length, updatedAt: now.toISOString() });
};

/** DELETE /v1/devices/:deviceID — removes this Mac and its usage (the user stopped sharing on it). */
export const deleteDevice: Handler = async ({ request, env, params }) => {
  const user = await requireUser(request, env.DB);
  const deviceID = requireDeviceID(params.deviceID);
  const result = await env.DB.prepare("DELETE FROM devices WHERE user_id = ? AND id = ?").bind(user.id, deviceID).run();
  if (result.meta.changes === 0) throw notFound("Device not found.");
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
