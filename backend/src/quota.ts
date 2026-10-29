import type { Queryable } from "./db";
import { badRequest, isRecord } from "./http";

const PROVIDER_PATTERN = /^[a-z0-9][a-z0-9-]{0,39}$/;
const ACCOUNT_KEY_PATTERN = /^[a-f0-9]{32,64}$/;
const MAX_WINDOWS = 100;
const HOUR_MS = 3_600_000;
const DAY_MS = 24 * HOUR_MS;
/** Windows that reset longer ago than this, or further ahead, are not taken. */
const PAST_DAYS = 45;
const FUTURE_DAYS = 40;
/** An open window is projected only once this share of it has passed; earlier the pace is noise. */
const MIN_PROJECTION_SHARE = 0.2;
/** A window last read more than this before its reset counts as estimated: its share is a lower bound. */
const ESTIMATE_GAP_MS = 6 * HOUR_MS;
/** A plan whose quota is on pace to be used less than this share (percent) is underused. */
export const UNDERUSED_PERCENT = 50;

/** One account's quota window, as a Mac reported it. */
export interface QuotaWindowInput {
  provider: string;
  accountKey: string;
  /** When the window resets (ISO 8601), rounded to the hour. */
  endsAt: string;
  periodHours: number;
  /** The highest share of the window the Mac saw used, 0–100 (more when over the limit). */
  percent: number;
  /** The Mac's last reading of the window (ISO 8601). */
  observedAt: string;
}

/** How much of a plan's quota its covered accounts use in the plan's cycle. */
export interface PlanQuota {
  /** The mean, over the covered accounts, of each account's mean window share (0–100). */
  usedPercent: number;
  accounts: number;
  windows: number;
  /** Windows the Mac last read well before they reset, so their share is a lower bound. */
  estimatedWindows: number;
  /** What the cycle costs times the share left unused. */
  wastedUSD: number;
}

function roundToHour(time: number): string {
  return new Date(Math.round(time / HOUR_MS) * HOUR_MS).toISOString();
}

function parseInstant(value: unknown, field: string): number {
  const time = typeof value === "string" && value.length <= 40 ? Date.parse(value) : Number.NaN;
  if (Number.isNaN(time)) throw badRequest(`${field} must be an ISO 8601 date and time.`);
  return time;
}

/**
 * Validates an upload's quota windows (the system boundary). Missing means the app doesn't send them,
 * and the stored windows stay as they are.
 */
export function parseQuotaWindows(value: unknown, now: Date): QuotaWindowInput[] | null {
  if (value === undefined) return null;
  if (!Array.isArray(value)) throw badRequest("quotaWindows must be an array.");
  if (value.length > MAX_WINDOWS) throw badRequest(`At most ${MAX_WINDOWS} quota windows per upload.`);
  const seen = new Set<string>();
  const windows: QuotaWindowInput[] = [];
  for (const entry of value) {
    if (!isRecord(entry)) throw badRequest("Each quota window must be an object.");
    const { provider, account, periodHours, percent } = entry;
    if (typeof provider !== "string" || !PROVIDER_PATTERN.test(provider)) throw badRequest("Invalid provider id.");
    if (typeof account !== "string" || !ACCOUNT_KEY_PATTERN.test(account)) throw badRequest(`Invalid account for ${provider}.`);
    if (typeof periodHours !== "number" || !Number.isInteger(periodHours) || periodHours < 1 || periodHours > 1000) {
      throw badRequest("periodHours must be a whole number of hours.");
    }
    if (typeof percent !== "number" || !Number.isFinite(percent) || percent < 0 || percent > 1000) {
      throw badRequest("percent must be a number from 0.");
    }
    const endsAt = parseInstant(entry.endsAt, "endsAt");
    const observedAt = parseInstant(entry.observedAt, "observedAt");
    if (observedAt > now.getTime() + DAY_MS) throw badRequest("observedAt is in the future.");
    // Windows outside the range are dropped, not rejected, like days outside the upload window.
    if (endsAt < now.getTime() - PAST_DAYS * DAY_MS || endsAt > now.getTime() + FUTURE_DAYS * DAY_MS) continue;
    const window = { provider, accountKey: account, endsAt: roundToHour(endsAt), periodHours, percent, observedAt: new Date(observedAt).toISOString() };
    const key = `${provider}|${account}|${window.endsAt}`;
    if (seen.has(key)) throw badRequest(`Duplicate quota window for ${provider}.`);
    seen.add(key);
    windows.push(window);
  }
  return windows;
}

/** Replaces the Mac's quota windows with the upload's, writing only rows that changed. Returns how many. */
export async function storeQuotaWindows(tx: Queryable, userID: string, deviceID: string, windows: QuotaWindowInput[]): Promise<number> {
  const rows = JSON.stringify(
    windows.map((window) => ({
      provider: window.provider,
      account_key: window.accountKey,
      ends_at: window.endsAt,
      period_hours: window.periodHours,
      percent: window.percent,
      observed_at: window.observedAt,
    })),
  );
  const removed = await tx.run(
    `DELETE FROM quota_windows q WHERE q.user_id = $1 AND q.device_id = $2
     AND NOT EXISTS (SELECT 1 FROM jsonb_to_recordset($3::jsonb) AS r(provider text, account_key text, ends_at text)
                     WHERE r.provider = q.provider AND r.account_key = q.account_key AND r.ends_at = q.ends_at)`,
    [userID, deviceID, rows],
  );
  const upserted = await tx.run(
    `INSERT INTO quota_windows (user_id, device_id, provider, account_key, ends_at, period_hours, percent, observed_at)
     SELECT $1, $2, r.provider, r.account_key, r.ends_at, r.period_hours, r.percent, r.observed_at
     FROM jsonb_to_recordset($3::jsonb) AS r(provider text, account_key text, ends_at text, period_hours integer, percent double precision, observed_at text)
     ON CONFLICT (user_id, device_id, provider, account_key, ends_at) DO UPDATE SET
       period_hours = excluded.period_hours, percent = excluded.percent, observed_at = excluded.observed_at
     WHERE (quota_windows.period_hours, quota_windows.percent, quota_windows.observed_at)
       IS DISTINCT FROM (excluded.period_hours, excluded.percent, excluded.observed_at)`,
    [userID, deviceID, rows],
  );
  return removed + upserted;
}

export interface QuotaRow {
  user_id: string;
  provider: string;
  account_key: string;
  ends_at: string;
  period_hours: number;
  percent: number;
  observed_at: string;
}

/** The counted members' quota windows that reset after `from` (a calendar day). */
export async function teamQuotaWindows(db: Queryable, teamID: string, from: string): Promise<QuotaRow[]> {
  return db.query<QuotaRow>(
    `SELECT q.user_id, q.provider, q.account_key, q.ends_at, q.period_hours, q.percent, q.observed_at
     FROM quota_windows q JOIN team_members m ON m.user_id = q.user_id AND m.team_id = $1 AND m.counts_usage
     WHERE q.ends_at >= $2`,
    [teamID, from],
  );
}

/**
 * How much of a plan's quota the accounts it covers use in its cycle. An account counts when any
 * member who reported it is covered, and each window counts once however many Macs reported it (at
 * the highest share any saw). A window that reset in the cycle counts at its final share; the open
 * one at its pace to the reset, once a fifth of it has passed. Shares over 100 count as 100. Null
 * when no covered account reported a window, like for providers GodUsage reads no quota for.
 */
export function planQuota(
  rows: QuotaRow[],
  plan: { provider: string; covered: (userID: string) => boolean; cycleFrom: string; cycleCostUSD: number },
  now: Date,
): PlanQuota | null {
  const windows = new Map<string, { account: string; endsAt: number; periodMs: number; percent: number; observedAt: number; covered: boolean }>();
  for (const row of rows) {
    if (row.provider !== plan.provider) continue;
    const key = `${row.account_key}|${row.ends_at}`;
    const observedAt = Date.parse(row.observed_at);
    const window = windows.get(key) ?? {
      account: row.account_key, endsAt: Date.parse(row.ends_at), periodMs: row.period_hours * HOUR_MS, percent: 0, observedAt, covered: false,
    };
    window.percent = Math.max(window.percent, row.percent);
    window.observedAt = Math.max(window.observedAt, observedAt);
    window.covered = window.covered || plan.covered(row.user_id);
    windows.set(key, window);
  }

  const shares = new Map<string, number[]>();
  let count = 0;
  let estimated = 0;
  for (const window of windows.values()) {
    if (!window.covered || window.endsAt < Date.parse(`${plan.cycleFrom}T00:00:00Z`)) continue;
    let share: number;
    if (window.endsAt <= now.getTime()) {
      share = window.percent;
      if (window.endsAt - window.observedAt > ESTIMATE_GAP_MS) estimated += 1;
    } else {
      // Paced from the last reading, so a Mac that has been off doesn't drag the projection down.
      const passed = (window.observedAt - (window.endsAt - window.periodMs)) / window.periodMs;
      if (passed < MIN_PROJECTION_SHARE) continue;
      share = window.percent / Math.min(passed, 1);
    }
    shares.set(window.account, [...(shares.get(window.account) ?? []), Math.min(share, 100)]);
    count += 1;
  }
  if (shares.size === 0) return null;
  const mean = (values: number[]) => values.reduce((sum, value) => sum + value, 0) / values.length;
  const used = mean([...shares.values()].map(mean));
  return {
    usedPercent: Math.round(used * 10) / 10,
    accounts: shares.size,
    windows: count,
    estimatedWindows: estimated,
    wastedUSD: Math.round(plan.cycleCostUSD * (100 - used)) / 100,
  };
}
