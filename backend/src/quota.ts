import type { Queryable } from "./db";
import { badRequest, isRecord } from "./http";
import { isValidDay } from "./usagePayload";
import { workingShare, type WorkingDays } from "./workingDays";

const PROVIDER_PATTERN = /^[a-z0-9][a-z0-9-]{0,39}$/;
const ACCOUNT_KEY_PATTERN = /^[a-f0-9]{32,64}$/;
/** Limit windows (a few per account) plus session windows (up to a few a day per account). */
const MAX_WINDOWS = 600;
const MAX_DAYS = 10;
const HOUR_MS = 3_600_000;
const DAY_MS = 24 * HOUR_MS;
/** Windows that reset longer ago than this, or further ahead, are not taken. */
const PAST_DAYS = 45;
const FUTURE_DAYS = 40;
/**
 * A Mac keeps its limit windows 40 days and its sessions 32 (see TeamQuotaLog), so a window it stops
 * sending within these days was renamed or reset early, and goes. Older ones it only aged out of its
 * log: they stay as the plan's history, a day short of the Mac's horizon so a clock off by hours
 * can't drop one.
 */
const OWNED_DAYS = { limit: 39, session: 31 } as const;
/** How long a window that ended stays as history: 13 months, to compare a month with a year before. */
const HISTORY_DAYS = 395;
/** An open window is projected only once this share of it has passed; earlier the pace is noise. */
const MIN_PROJECTION_SHARE = 0.2;
/** A window last read more than this before its reset counts as estimated: its share is a lower bound. */
export const ESTIMATE_GAP_MS = 6 * HOUR_MS;
/** A plan whose quota is on pace to be used less than this share (percent) is underused. */
export const UNDERUSED_PERCENT = 50;

/** `limit`: the window a plan is limited by (weekly, Cursor's cycle). `session`: the 5-hour session. */
export type QuotaKind = "limit" | "session";

/** The share of a window seen used at the end of a calendar day (the Mac's local day). */
export interface QuotaDay {
  day: string;
  percent: number;
}

/** One account's quota window, as a Mac reported it. */
export interface QuotaWindowInput {
  provider: string;
  kind: QuotaKind;
  accountKey: string;
  /** When the window resets (ISO 8601), rounded to the hour. */
  endsAt: string;
  periodHours: number;
  /** The highest share of the window the Mac saw used, 0–100 (more when over the limit). */
  percent: number;
  /** The Mac's last reading of the window (ISO 8601). */
  observedAt: string;
  /** The share used at the end of each day the Mac read the window, in day order. */
  days: QuotaDay[];
  /** The account is named per Mac (no account id), so the same account on two Macs looks like two. */
  perDevice: boolean;
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
    const kind = entry.kind ?? "limit";
    // Apps from before sessions send no kind and name Claude's and Codex's accounts per Mac.
    const perDevice = entry.perDevice ?? (entry.kind === undefined && (provider === "claude" || provider === "codex"));
    if (typeof perDevice !== "boolean") throw badRequest("perDevice must be true or false.");
    if (kind !== "limit" && kind !== "session") throw badRequest("kind must be limit or session.");
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
    const window: QuotaWindowInput = {
      provider, kind, accountKey: account, endsAt: roundToHour(endsAt), periodHours, percent,
      observedAt: new Date(observedAt).toISOString(), days: parseDays(entry.days), perDevice,
    };
    const key = `${provider}|${kind}|${account}|${window.endsAt}`;
    if (seen.has(key)) throw badRequest(`Duplicate quota window for ${provider}.`);
    seen.add(key);
    windows.push(window);
  }
  return windows;
}

function parseDays(value: unknown): QuotaDay[] {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.length > MAX_DAYS) throw badRequest(`days must be a list of at most ${MAX_DAYS} days.`);
  const days = value.map((entry) => {
    if (!isRecord(entry) || typeof entry.day !== "string" || !isValidDay(entry.day)) throw badRequest("Each day must have a day (YYYY-MM-DD).");
    if (typeof entry.percent !== "number" || !Number.isFinite(entry.percent) || entry.percent < 0 || entry.percent > 1000) {
      throw badRequest("A day's percent must be a number from 0.");
    }
    return { day: entry.day, percent: entry.percent };
  });
  days.sort((a, b) => (a.day < b.day ? -1 : 1));
  if (days.some((entry, index) => index > 0 && entry.day === days[index - 1]!.day)) throw badRequest("Duplicate day in a quota window.");
  return days;
}

/**
 * Replaces the Mac's recent quota windows with the upload's, writing only rows that changed, and keeps
 * the ones it aged out of its log as history (see `OWNED_DAYS`) until `HISTORY_DAYS`. Returns how many
 * rows changed.
 */
export async function storeQuotaWindows(
  tx: Queryable, userID: string, deviceID: string, windows: QuotaWindowInput[], now: Date,
): Promise<number> {
  const since = (days: number) => new Date(now.getTime() - days * DAY_MS).toISOString();
  const rows = JSON.stringify(
    windows.map((window) => ({
      provider: window.provider,
      kind: window.kind,
      account_key: window.accountKey,
      ends_at: window.endsAt,
      period_hours: window.periodHours,
      percent: window.percent,
      observed_at: window.observedAt,
      days: window.days.length === 0 ? null : window.days,
      per_device: window.perDevice,
    })),
  );
  const removed = await tx.run(
    `DELETE FROM quota_windows q WHERE q.user_id = $1 AND q.device_id = $2
     AND (q.ends_at < $4
          OR (q.ends_at >= CASE q.kind WHEN 'session' THEN $5 ELSE $6 END
              AND NOT EXISTS (SELECT 1 FROM jsonb_to_recordset($3::jsonb) AS r(provider text, kind text, account_key text, ends_at text)
                              WHERE r.provider = q.provider AND r.kind = q.kind AND r.account_key = q.account_key AND r.ends_at = q.ends_at)))`,
    [userID, deviceID, rows, since(HISTORY_DAYS), since(OWNED_DAYS.session), since(OWNED_DAYS.limit)],
  );
  const upserted = await tx.run(
    `INSERT INTO quota_windows (user_id, device_id, provider, kind, account_key, ends_at, period_hours, percent, observed_at, days, per_device)
     SELECT $1, $2, r.provider, r.kind, r.account_key, r.ends_at, r.period_hours, r.percent, r.observed_at, r.days, r.per_device
     FROM jsonb_to_recordset($3::jsonb)
       AS r(provider text, kind text, account_key text, ends_at text, period_hours integer, percent double precision, observed_at text,
            days jsonb, per_device boolean)
     ON CONFLICT (user_id, device_id, provider, kind, account_key, ends_at) DO UPDATE SET
       period_hours = excluded.period_hours, percent = excluded.percent, observed_at = excluded.observed_at, days = excluded.days,
       per_device = excluded.per_device
     WHERE (quota_windows.period_hours, quota_windows.percent, quota_windows.observed_at, quota_windows.days, quota_windows.per_device)
       IS DISTINCT FROM (excluded.period_hours, excluded.percent, excluded.observed_at, excluded.days, excluded.per_device)`,
    [userID, deviceID, rows],
  );
  await storeReadings(tx, userID, deviceID, windows, now);
  return removed + upserted;
}

/** Readings of open weekly windows are kept this long, for Live Pace's pace of the last working hour. */
const READINGS_MS = 36 * HOUR_MS;
const WEEK_HOURS = 168;

/**
 * Adds this upload's readings of open weekly windows to the Mac's recent ones and drops those older
 * than `READINGS_MS`. They don't count as changes: a new reading already changes its window's row.
 */
async function storeReadings(tx: Queryable, userID: string, deviceID: string, windows: QuotaWindowInput[], now: Date): Promise<void> {
  const since = new Date(now.getTime() - READINGS_MS).toISOString();
  const readings = windows
    .filter((window) => window.kind === "limit" && window.periodHours === WEEK_HOURS && Date.parse(window.endsAt) > now.getTime() && window.observedAt >= since)
    .map((window) => ({ provider: window.provider, account_key: window.accountKey, ends_at: window.endsAt, observed_at: window.observedAt, percent: window.percent }));
  await tx.run("DELETE FROM quota_readings WHERE user_id = $1 AND device_id = $2 AND observed_at < $3", [userID, deviceID, since]);
  if (readings.length === 0) return;
  await tx.run(
    `INSERT INTO quota_readings (user_id, device_id, provider, account_key, ends_at, observed_at, percent)
     SELECT $1, $2, r.provider, r.account_key, r.ends_at, r.observed_at, r.percent
     FROM jsonb_to_recordset($3::jsonb) AS r(provider text, account_key text, ends_at text, observed_at text, percent double precision)
     ON CONFLICT DO NOTHING`,
    [userID, deviceID, JSON.stringify(readings)],
  );
}

/** One Mac's reading of an account's open weekly window. */
export interface QuotaReading {
  user_id: string;
  provider: string;
  account_key: string;
  ends_at: string;
  observed_at: string;
  percent: number;
}

/** The counted members' readings since `since` (ISO 8601), without the accounts a member leaves out of the team. */
export async function teamQuotaReadings(db: Queryable, teamID: string, since: string): Promise<QuotaReading[]> {
  return db.query<QuotaReading>(
    `SELECT q.user_id, q.provider, q.account_key, q.ends_at, q.observed_at, q.percent
     FROM quota_readings q JOIN team_members m ON m.user_id = q.user_id AND m.team_id = $1 AND m.counts_usage
     WHERE q.observed_at >= $2
     AND NOT EXISTS (SELECT 1 FROM account_exclusions x WHERE x.team_id = $1 AND x.user_id = q.user_id AND x.account_key = q.account_key)
     ORDER BY q.observed_at`,
    [teamID, since],
  );
}

export interface QuotaRow {
  user_id: string;
  provider: string;
  kind: QuotaKind;
  account_key: string;
  ends_at: string;
  period_hours: number;
  percent: number;
  observed_at: string;
  days: QuotaDay[] | null;
  per_device: boolean;
}

/**
 * The counted members' quota windows that reset after `from` (a calendar day), without the accounts
 * a member leaves out of the team.
 */
export async function teamQuotaWindows(db: Queryable, teamID: string, from: string): Promise<QuotaRow[]> {
  return db.query<QuotaRow>(
    `SELECT q.user_id, q.provider, q.kind, q.account_key, q.ends_at, q.period_hours, q.percent, q.observed_at, q.days, q.per_device
     FROM quota_windows q JOIN team_members m ON m.user_id = q.user_id AND m.team_id = $1 AND m.counts_usage
     WHERE q.ends_at >= $2
     AND NOT EXISTS (SELECT 1 FROM account_exclusions x WHERE x.team_id = $1 AND x.user_id = q.user_id AND x.account_key = q.account_key)`,
    [teamID, from],
  );
}

/**
 * How much of a plan's quota the accounts it covers use in its cycle. An account counts when any
 * member who reported it is covered, and each window counts once however many Macs reported it (at
 * the highest share any saw). A window that reset in the cycle counts at its final share; the open
 * one at its pace to the reset, once a fifth of it has passed, counting only the team's working
 * days (weekends use no quota by default). Shares over 100 count as 100. Null
 * when no covered account reported a window, like for providers GodUsage reads no quota for.
 */
export function planQuota(
  rows: QuotaRow[],
  plan: { provider: string; covered: (userID: string) => boolean; cycleFrom: string; cycleCostUSD: number },
  now: Date,
  workingDays: WorkingDays,
): PlanQuota | null {
  const windows = new Map<string, { account: string; endsAt: number; periodMs: number; percent: number; observedAt: number; covered: boolean }>();
  for (const row of rows) {
    if (row.provider !== plan.provider || row.kind !== "limit") continue;
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
      const passed = workingShare(window.endsAt - window.periodMs, window.observedAt, window.endsAt, workingDays);
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
