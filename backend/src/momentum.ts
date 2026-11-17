/**
 * Momentum: who is spending fast right now, for the ⚡ on leaderboards.
 *
 * Each upload records how much the Mac's today grew since its previous upload, spread evenly over the
 * time between the two (`spend_pulses`, in five-minute buckets, kept seven days). From those, per member:
 *
 * - `lastHourUSD`: spend in the last 60 minutes.
 * - `level` 0–3: one ⚡ per rule met (`reasons`), once the last hour reached `MIN_USD`:
 *   1. the last hour reached `FAST_HOUR_USD`;
 *   2. the last hour is at least `SELF_MULTIPLIER` × the member's typical active hour (the average of
 *      their hours with any spend in the previous seven days, the last hour left out);
 *   3. nobody in the team spent more in the last hour.
 */
import type { Queryable } from "./db";

export const MIN_USD = 1;
export const FAST_HOUR_USD = 5;
export const SELF_MULTIPLIER = 2;
const BUCKET_MS = 5 * 60_000;
const HOUR_MS = 60 * 60_000;
const KEEP_MS = 7 * 24 * HOUR_MS;

export type MomentumReason = "fast" | "self" | "top";

export interface Momentum {
  lastHourUSD: number;
  level: number;
  /** The rules met: `fast` (≥ FAST_HOUR_USD), `self` (≥ SELF_MULTIPLIER × typical hour), `top` (most in the team). */
  reasons: MomentumReason[];
  /** The member's typical active hour over the previous seven days, or null without history. */
  typicalHourUSD: number | null;
}

/** A recent day row as uploaded or stored. */
export interface PulseRow {
  provider: string;
  day: string;
  scope: "device" | "account";
  accountKey: string | null;
  /** '' for folded accounts, the fingerprint of an account sent on its own (see usagePayload.ts). */
  slot: string;
  costUSD: number | null;
}

/**
 * Records how much this upload grew the member's today: the rows of `localDay` (the Mac's calendar
 * day, the same day its Today board counts; the UTC day from apps that don't send it). Other days,
 * such as yesterday's row still filling in after midnight, never count.
 *
 * Device-scope rows grow from the device's stored row; account-scope rows (Cursor) from the largest
 * any of the user's Macs stored, so two Macs reporting one account count once. A row with nothing
 * stored to grow from (a provider's first row of the day, a row a full upload dropped and brings back,
 * an account moved to its own slot) counts nothing, like a device's first upload: its whole day would
 * look just spent. Shared accounts are left out, as on the boards. Growth is kept per slot, so a team
 * an account is left out of never counts its spend.
 *
 * Growth is spread evenly over the five-minute buckets between the baseline's upload and now, so a
 * Mac that slept, went offline, or failed uploads for hours doesn't put all of it in the last hour.
 * Call before the upload is stored, and only for a device that uploaded before.
 */
export async function recordPulse(tx: Queryable, userID: string, deviceID: string, rows: PulseRow[], localDay: string, now: Date): Promise<void> {
  const today = rows.filter((row) => row.day === localDay && row.costUSD !== null && row.costUSD > 0);
  if (today.length === 0) return;

  const [device, deviceRows, accountRows, sharedRows] = await Promise.all([
    tx.first<{ updated_at: string }>("SELECT updated_at FROM devices WHERE user_id = $1 AND id = $2", [userID, deviceID]),
    tx.query<{ provider: string; slot: string; cost_usd: number }>(
      "SELECT provider, slot, cost_usd FROM usage_days WHERE user_id = $1 AND device_id = $2 AND day = $3 AND scope = 'device' AND cost_usd IS NOT NULL",
      [userID, deviceID, localDay],
    ),
    // Per account row: the largest stored cost, and when the Mac that stored it last uploaded.
    tx.query<{ provider: string; slot: string; cost: number; since: string }>(
      `SELECT provider, slot, cost, since FROM (
         SELECT u.provider, u.slot, u.cost_usd AS cost, d.updated_at AS since,
                ROW_NUMBER() OVER (PARTITION BY u.provider, u.slot ORDER BY u.cost_usd DESC, d.updated_at DESC) AS n
         FROM usage_days u JOIN devices d ON d.user_id = u.user_id AND d.id = u.device_id
         WHERE u.user_id = $1 AND u.day = $2 AND u.scope = 'account' AND u.cost_usd IS NOT NULL
       ) ranked WHERE n = 1`,
      [userID, localDay],
    ),
    tx.query<{ account_key: string }>(
      `SELECT account_key FROM account_keys WHERE account_key = ANY($1::text[])
       GROUP BY account_key HAVING COUNT(DISTINCT user_id) > 1`,
      [[...new Set(today.map((row) => row.accountKey).filter((key): key is string => key !== null))]],
    ),
  ]);
  if (device === null) return;
  const key = (provider: string, slot: string) => `${provider}\u0000${slot}`;
  const deviceSince = Date.parse(device.updated_at);
  const before = new Map(deviceRows.map((row) => [key(row.provider, row.slot), { cost: row.cost_usd, since: deviceSince }]));
  const accountBefore = new Map(accountRows.map((row) => [key(row.provider, row.slot), { cost: row.cost, since: Date.parse(row.since) }]));
  const shared = new Set(sharedRows.map((row) => row.account_key));

  // Cost per slot and bucket start.
  const pulses = new Map<string, Map<number, number>>();
  for (const row of today) {
    if (row.scope === "account" && row.accountKey !== null && shared.has(row.accountKey)) continue;
    const previous = (row.scope === "device" ? before : accountBefore).get(key(row.provider, row.slot));
    if (previous === undefined) continue;
    const growth = row.costUSD! - previous.cost;
    if (growth <= 0) continue;
    const slot = pulses.get(row.slot) ?? new Map<number, number>();
    for (const [bucket, cost] of spread(growth, previous.since, now.getTime())) slot.set(bucket, (slot.get(bucket) ?? 0) + cost);
    pulses.set(row.slot, slot);
  }
  const records = [...pulses].flatMap(([slot, buckets]) =>
    [...buckets].filter(([, cost]) => cost > 0).map(([bucket, cost]) => ({ slot, bucket: new Date(bucket).toISOString(), cost })),
  );
  if (records.length === 0) return;

  await tx.run(
    `INSERT INTO spend_pulses (user_id, device_id, slot, bucket, cost_usd)
     SELECT $1, $2, r.slot, r.bucket, r.cost FROM jsonb_to_recordset($3::jsonb) AS r(slot text, bucket text, cost double precision)
     ON CONFLICT (user_id, device_id, slot, bucket) DO UPDATE SET cost_usd = spend_pulses.cost_usd + excluded.cost_usd`,
    [userID, deviceID, JSON.stringify(records)],
  );
  await tx.run("DELETE FROM spend_pulses WHERE user_id = $1 AND bucket < $2", [userID, new Date(now.getTime() - KEEP_MS).toISOString()]);
}

/**
 * Splits `cost`, spent evenly between `since` and `now` (epoch ms), over the five-minute buckets it
 * overlaps, as [bucket start, cost]. A gap within one bucket (or a baseline from the future) puts it
 * all in the current bucket. The part older than the seven days kept is dropped.
 */
export function spread(cost: number, since: number, now: number): [number, number][] {
  const current = Math.floor(now / BUCKET_MS) * BUCKET_MS;
  if (!Number.isFinite(since) || since >= current) return [[current, cost]];
  const gap = now - since;
  const start = Math.max(since, now - KEEP_MS);
  const result: [number, number][] = [];
  for (let bucket = Math.floor(start / BUCKET_MS) * BUCKET_MS; bucket < now; bucket += BUCKET_MS) {
    const overlap = Math.min(bucket + BUCKET_MS, now) - Math.max(bucket, start);
    if (overlap > 0) result.push([bucket, (cost * overlap) / gap]);
  }
  return result;
}

/** Each member's momentum, by user id. Members with no spend in the last hour are left out. */
export async function teamMomentum(db: Queryable, teamID: string, now: Date): Promise<Record<string, Momentum>> {
  const hourAgo = new Date(now.getTime() - HOUR_MS).toISOString();
  const weekAgo = new Date(now.getTime() - KEEP_MS).toISOString();
  // Pulses of an account a member leaves out of the team don't count for it.
  const members = `JOIN team_members m ON m.user_id = p.user_id AND m.team_id = $1 AND m.counts_usage
    AND NOT EXISTS (SELECT 1 FROM account_exclusions x WHERE x.team_id = $1 AND x.user_id = p.user_id AND x.account_key = p.slot)`;
  const [lastHour, typical] = await Promise.all([
    db.query<{ user_id: string; cost: number }>(
      `SELECT p.user_id, SUM(p.cost_usd) AS cost FROM spend_pulses p ${members} WHERE p.bucket >= $2 GROUP BY p.user_id`,
      [teamID, hourAgo],
    ),
    db.query<{ user_id: string; cost: number }>(
      `SELECT user_id, AVG(cost) AS cost FROM (
         SELECT p.user_id, substr(p.bucket, 1, 13) AS hour, SUM(p.cost_usd) AS cost FROM spend_pulses p ${members}
         WHERE p.bucket >= $2 AND p.bucket < $3 GROUP BY p.user_id, hour
       ) hours WHERE cost > 0 GROUP BY user_id`,
      [teamID, weekAgo, hourAgo],
    ),
  ]);
  return momentumLevels(
    new Map(lastHour.map((row) => [row.user_id, Number(row.cost)])),
    new Map(typical.map((row) => [row.user_id, Number(row.cost)])),
  );
}

/** The rules above, on the last hour's spend and the typical active hour per member. */
export function momentumLevels(lastHour: Map<string, number>, typicalHour: Map<string, number>): Record<string, Momentum> {
  const top = Math.max(0, ...lastHour.values());
  const result: Record<string, Momentum> = {};
  for (const [userID, spent] of lastHour) {
    if (spent <= 0) continue;
    const typical = typicalHour.get(userID);
    const reasons: MomentumReason[] = [];
    if (spent >= MIN_USD) {
      if (spent >= FAST_HOUR_USD) reasons.push("fast");
      if (typical !== undefined && spent >= SELF_MULTIPLIER * typical) reasons.push("self");
      if (spent >= top) reasons.push("top");
    }
    result[userID] = {
      lastHourUSD: round(spent),
      level: reasons.length,
      reasons,
      typicalHourUSD: typical === undefined ? null : round(typical),
    };
  }
  return result;
}

function round(value: number): number {
  return Math.round(value * 100) / 100;
}
