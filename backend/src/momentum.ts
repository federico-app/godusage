/**
 * Momentum: who is spending fast right now, for the ⚡ on leaderboards.
 *
 * Each upload records how much the Mac's recent days grew since its last upload (`spend_pulses`, in
 * five-minute buckets, kept seven days). From those, per member:
 *
 * - `lastHourUSD`: spend in the last 60 minutes.
 * - `level` 0–3: one ⚡ per rule met (`reasons`), once the last hour reached `MIN_USD`:
 *   1. the last hour reached `FAST_HOUR_USD`;
 *   2. the last hour is at least `SELF_MULTIPLIER` × the member's typical active hour (the average of
 *      their hours with any spend in the previous seven days, the last hour left out);
 *   3. nobody in the team spent more in the last hour.
 */
import type { Queryable } from "./db";
import { addDays, dayKey } from "./usagePayload";

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
 * Records how much this upload grew the device's recent days (yesterday and today, UTC, which covers
 * every time zone's today). Device-scope rows grow from the device's stored row; account-scope rows
 * (Cursor) from the largest any of the user's Macs stored, so two Macs reporting one account count
 * once. Shared accounts are left out, as on the boards. Growth is kept per slot, so a team an account
 * is left out of never counts its spend. Call before the upload is stored, and only
 * for a device that uploaded before: a first upload would count a whole day as just spent.
 */
export async function recordPulse(tx: Queryable, userID: string, deviceID: string, rows: PulseRow[], now: Date): Promise<void> {
  const from = addDays(dayKey(now), -1);
  const recent = rows.filter((row) => row.day >= from && row.costUSD !== null && row.costUSD > 0);
  if (recent.length === 0) return;

  const [deviceRows, accountRows, sharedRows] = await Promise.all([
    tx.query<{ provider: string; slot: string; day: string; cost_usd: number | null }>(
      "SELECT provider, slot, day, cost_usd FROM usage_days WHERE user_id = $1 AND device_id = $2 AND day >= $3 AND scope = 'device'",
      [userID, deviceID, from],
    ),
    tx.query<{ provider: string; slot: string; day: string; cost: number | null }>(
      "SELECT provider, slot, day, MAX(cost_usd) AS cost FROM usage_days WHERE user_id = $1 AND day >= $2 AND scope = 'account' GROUP BY provider, slot, day",
      [userID, from],
    ),
    tx.query<{ account_key: string }>(
      `SELECT account_key FROM account_keys WHERE account_key = ANY($1::text[])
       GROUP BY account_key HAVING COUNT(DISTINCT user_id) > 1`,
      [[...new Set(recent.map((row) => row.accountKey).filter((key): key is string => key !== null))]],
    ),
  ]);
  const key = (provider: string, slot: string, day: string) => `${provider}\u0000${slot}\u0000${day}`;
  const before = new Map(deviceRows.map((row) => [key(row.provider, row.slot, row.day), row.cost_usd ?? 0]));
  const accountBefore = new Map(accountRows.map((row) => [key(row.provider, row.slot, row.day), row.cost ?? 0]));
  const shared = new Set(sharedRows.map((row) => row.account_key));

  const grown = new Map<string, number>();
  for (const row of recent) {
    if (row.scope === "account" && row.accountKey !== null && shared.has(row.accountKey)) continue;
    const previous = (row.scope === "device" ? before : accountBefore).get(key(row.provider, row.slot, row.day)) ?? 0;
    const growth = Math.max(0, row.costUSD! - previous);
    if (growth > 0) grown.set(row.slot, (grown.get(row.slot) ?? 0) + growth);
  }
  if (grown.size === 0) return;

  const bucket = new Date(Math.floor(now.getTime() / BUCKET_MS) * BUCKET_MS).toISOString();
  await tx.run(
    `INSERT INTO spend_pulses (user_id, device_id, slot, bucket, cost_usd)
     SELECT $1, $2, r.slot, $3, r.cost FROM jsonb_to_recordset($4::jsonb) AS r(slot text, cost double precision)
     ON CONFLICT (user_id, device_id, slot, bucket) DO UPDATE SET cost_usd = spend_pulses.cost_usd + excluded.cost_usd`,
    [userID, deviceID, bucket, JSON.stringify([...grown].map(([slot, cost]) => ({ slot, cost })))],
  );
  await tx.run("DELETE FROM spend_pulses WHERE user_id = $1 AND bucket < $2", [userID, new Date(now.getTime() - KEEP_MS).toISOString()]);
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
