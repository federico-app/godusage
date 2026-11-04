import type { QuotaRow } from "./quota";
import { daysBetween } from "./stats";
import { addDays } from "./usagePayload";
import { isWorkingDay, type WorkingDays } from "./workingDays";

const HOUR_MS = 3_600_000;
/** Only weekly windows give a daily share of the weekly limit. */
const WEEK_HOURS = 168;
/** The daily chart's days, today included. */
const CHART_DAYS = 7;
/** A session used at least this share (percent) hit its limit. */
const SESSION_LIMIT_PERCENT = 100;
/** The session strip shows at most this many of the latest sessions. */
const MAX_SESSION_PEAKS = 120;

export interface DailyShare {
  day: string;
  /** The mean, over the accounts read that day, of the share of the weekly limit used. Null without data. */
  percent: number | null;
  working: boolean;
  /** Part of the share was spread over days the Macs didn't read the window. */
  estimated: boolean;
}

/** How much of the weekly limit the plan's accounts use per day. */
export interface PlanDaily {
  /** The last seven days, today (not over yet) last. */
  days: DailyShare[];
  /** The mean share per working day, over the finished working days of the chart that have data. */
  averagePercent: number | null;
  /** The share per working day that uses exactly the whole week: 100 ÷ working days per week. */
  pacePercent: number;
  accounts: number;
}

/** How the plan's accounts use their 5-hour sessions in the cycle. */
export interface PlanSessions {
  sessions: number;
  /** Sessions used to their limit. */
  limitHits: number;
  averagePeakPercent: number;
  /** Each session's peak (0–100), oldest first, the latest `MAX_SESSION_PEAKS`. */
  peaks: number[];
  accounts: number;
}

interface Plan {
  provider: string;
  covered: (userID: string) => boolean;
}

const round1 = (value: number) => Math.round(value * 10) / 10;
const mean = (values: number[]) => values.reduce((sum, value) => sum + value, 0) / values.length;

/**
 * The daily share of the weekly limit the plan's covered accounts use, from the share each Mac saw
 * used at the end of each day. A day's use is the growth since the window's previous reading; when
 * the Macs skipped days, the growth is spread evenly over them (estimated). A window that the Macs
 * first read on the day it started or the day after counts from 0; otherwise its first reading only
 * sets the baseline. A window reported by several Macs counts once, at the highest share each day.
 * Null when no covered account reported a weekly window with daily readings.
 */
export function planDaily(rows: QuotaRow[], plan: Plan, today: string, workingDays: WorkingDays): PlanDaily | null {
  const windows = new Map<string, { account: string; startDay: string; covered: boolean; days: Map<string, number> }>();
  for (const row of rows) {
    if (row.provider !== plan.provider || row.kind !== "limit" || row.period_hours !== WEEK_HOURS || !row.days?.length) continue;
    const key = `${row.account_key}|${row.ends_at}`;
    const start = new Date(Date.parse(row.ends_at) - row.period_hours * HOUR_MS).toISOString().slice(0, 10);
    const window = windows.get(key) ?? { account: row.account_key, startDay: start, covered: false, days: new Map<string, number>() };
    window.covered = window.covered || plan.covered(row.user_id);
    for (const reading of row.days) window.days.set(reading.day, Math.max(window.days.get(reading.day) ?? 0, reading.percent));
    windows.set(key, window);
  }

  // Per account and day: the share used, and whether part of it was spread over unread days.
  const used = new Map<string, Map<string, { percent: number; estimated: boolean }>>();
  const add = (account: string, day: string, percent: number, estimated: boolean) => {
    const days = used.get(account) ?? new Map<string, { percent: number; estimated: boolean }>();
    const entry = days.get(day) ?? { percent: 0, estimated: false };
    days.set(day, { percent: entry.percent + percent, estimated: entry.estimated || estimated });
    used.set(account, days);
  };
  for (const window of windows.values()) {
    if (!window.covered) continue;
    const readings = [...window.days.entries()].sort(([a], [b]) => (a < b ? -1 : 1));
    // The Mac's days are local and the start is UTC, so a window can be read the day before it starts.
    const lead = daysBetween(window.startDay, readings[0]![0]);
    let previous = lead <= 1 ? { day: addDays(lead < 0 ? readings[0]![0] : window.startDay, -1), percent: 0 } : undefined;
    for (const [day, percent] of readings) {
      if (previous) {
        const gap = daysBetween(previous.day, day);
        const growth = Math.max(0, percent - previous.percent) / gap;
        for (let step = 1; step <= gap; step += 1) add(window.account, addDays(previous.day, step), growth, gap > 1);
      }
      previous = { day, percent: Math.max(percent, previous?.percent ?? 0) };
    }
  }

  const chart = Array.from({ length: CHART_DAYS }, (_, index) => addDays(today, index - CHART_DAYS + 1));
  const readAccounts = new Set<string>();
  const days = chart.map((day) => {
    const shares: number[] = [];
    let estimated = false;
    for (const [account, accountDays] of used) {
      const entry = accountDays.get(day);
      if (!entry) continue;
      shares.push(entry.percent);
      estimated = estimated || entry.estimated;
      readAccounts.add(account);
    }
    return { day, percent: shares.length === 0 ? null : round1(mean(shares)), working: isWorkingDay(day, workingDays), estimated };
  });
  if (readAccounts.size === 0) return null;
  const finished = days.filter((entry) => entry.day !== today && entry.working && entry.percent !== null).map((entry) => entry.percent!);
  return {
    days,
    averagePercent: finished.length === 0 ? null : round1(mean(finished)),
    pacePercent: round1(100 / workingDays.length),
    accounts: readAccounts.size,
  };
}

/**
 * The covered accounts' 5-hour sessions that end in the cycle, each at its peak. A session reported
 * by several Macs (one account named the same on each) counts once, at the highest peak. Null when
 * no covered account reported a session.
 */
/**
 * The covered accounts the plan's quota, daily, and session figures read from `from` on that a Mac
 * could only name per Mac (no account id: an older app, or no sign-in file to read it from). One
 * such account used on several Macs counts once per Mac, so the figures may be off.
 */
export function perDeviceAccounts(rows: QuotaRow[], plan: Plan, from: string): number {
  const since = Date.parse(`${from}T00:00:00Z`);
  const accounts = new Set<string>();
  for (const row of rows) {
    if (row.provider === plan.provider && row.per_device && Date.parse(row.ends_at) >= since && plan.covered(row.user_id)) accounts.add(row.account_key);
  }
  return accounts.size;
}

export function planSessions(rows: QuotaRow[], plan: Plan & { cycleFrom: string }): PlanSessions | null {
  const from = Date.parse(`${plan.cycleFrom}T00:00:00Z`);
  const byWindow = new Map<string, { account: string; endsAt: string; peak: number; covered: boolean }>();
  for (const row of rows) {
    if (row.provider !== plan.provider || row.kind !== "session" || Date.parse(row.ends_at) < from) continue;
    const key = `${row.account_key}|${row.ends_at}`;
    const session = byWindow.get(key) ?? { account: row.account_key, endsAt: row.ends_at, peak: 0, covered: false };
    session.peak = Math.max(session.peak, Math.min(row.percent, 100));
    session.covered = session.covered || plan.covered(row.user_id);
    byWindow.set(key, session);
  }
  const covered = [...byWindow.values()].filter((session) => session.covered);
  if (covered.length === 0) return null;

  covered.sort((a, b) => (a.endsAt === b.endsAt ? b.peak - a.peak : a.endsAt < b.endsAt ? -1 : 1));
  const peaks = covered.map((session) => round1(session.peak));
  return {
    sessions: covered.length,
    limitHits: peaks.filter((peak) => peak >= SESSION_LIMIT_PERCENT).length,
    averagePeakPercent: round1(mean(peaks)),
    peaks: peaks.slice(-MAX_SESSION_PEAKS),
    accounts: new Set(covered.map((session) => session.account)).size,
  };
}
