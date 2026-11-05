import type { QuotaRow } from "./quota";
import { accountDailyUse, dayShare, round1, sessionsBetween, type Plan } from "./quotaDaily";
import { daysBetween } from "./stats";
import { addDays } from "./usagePayload";
import { isWorkingDay, type WorkingDays } from "./workingDays";

const HOUR_MS = 3_600_000;
/** Only weekly windows give a daily share of the weekly limit. */
const WEEK_HOURS = 168;
/** A window that resets at this UTC hour or later leaves its last day usable. */
const LAST_DAY_HOUR = 12;
export const DEFAULT_HISTORY_WEEKS = 12;
/** The server keeps 13 months of windows (see quota.ts). */
export const MAX_HISTORY_WEEKS = 56;

export interface HistoryDay {
  day: string;
  /** The mean, over the accounts read that day, of the share of the weekly limit used. Null without data. */
  percent: number | null;
  working: boolean;
  estimated: boolean;
  accounts: number;
}

/** One calendar week (Monday first) of a plan's use of its weekly limit. */
export interface HistoryWeek {
  /** The Monday. */
  from: string;
  days: HistoryDay[];
  /** The sum of the days' shares, or null when no day has data. */
  totalPercent: number | null;
  estimated: boolean;
  /** Accounts read on any day of the week. */
  accounts: number;
  /** The 5-hour sessions that ended in the week (UTC days). */
  sessions: { sessions: number; limitHits: number; averagePeakPercent: number } | null;
}

/** How much of the weekly limit today can use and keep the open week on pace. */
export interface PlanBudget {
  /** The share of the weekly limit used today, the mean over the accounts with an open week. */
  todayPercent: number;
  /** The share left at the start of today, spread evenly over today and the working days until the reset. */
  affordablePercent: number;
  /** The share left at the start of today. */
  leftPercent: number;
  /** Today and the working days after it until the soonest reset. */
  workingDaysLeft: number;
  resetsAt: string;
  accounts: number;
  /** The soonest-resetting open week, day by day; days after today have no percent. */
  days: { day: string; percent: number | null; working: boolean; estimated: boolean }[];
}

/** The Monday of a day's week. */
export function mondayOf(day: string): string {
  const weekday = new Date(`${day}T00:00:00Z`).getUTCDay();
  return addDays(day, -((weekday + 6) % 7));
}

/**
 * The plan's last `weeks` calendar weeks up to today's, oldest first, from the share of the weekly limit
 * its covered accounts used each day (see `accountDailyUse`) and the sessions that ended in each.
 */
export function planHistory(rows: QuotaRow[], plan: Plan, today: string, weeks: number, workingDays: WorkingDays): HistoryWeek[] {
  const used = accountDailyUse(rows, plan);
  const first = addDays(mondayOf(today), -7 * (weeks - 1));
  return Array.from({ length: weeks }, (_, index) => {
    const from = addDays(first, 7 * index);
    const accounts = new Set<string>();
    let total = 0;
    let read = false;
    let estimated = false;
    const days = Array.from({ length: 7 }, (_, offset) => {
      const day = addDays(from, offset);
      const share = day > today ? { percent: null, estimated: false, accounts: [] } : dayShare(used, day);
      for (const account of share.accounts) accounts.add(account);
      if (share.percent !== null) {
        total += share.percent;
        read = true;
      }
      estimated = estimated || share.estimated;
      return { day, percent: share.percent, working: isWorkingDay(day, workingDays), estimated: share.estimated, accounts: share.accounts.length };
    });
    const sessions = sessionsBetween(rows, plan, Date.parse(`${from}T00:00:00Z`), Date.parse(`${addDays(from, 7)}T00:00:00Z`));
    return {
      from,
      days,
      totalPercent: read ? round1(total) : null,
      estimated,
      accounts: accounts.size,
      sessions: sessions === null ? null : { sessions: sessions.sessions, limitHits: sessions.limitHits, averagePeakPercent: sessions.averagePeakPercent },
    };
  });
}

/**
 * Today's budget for the plan: for each covered account with an open weekly window, the share left at
 * the start of today (100 minus the last reading before today; without one, a window that started
 * today or yesterday counts from 0 and an older one from its current share) over
 * today and the working days until it resets (its last day counts when it resets at noon UTC or later).
 * The plan takes the mean over its accounts. Null when no covered account has an open weekly window.
 */
export function planBudget(rows: QuotaRow[], plan: Plan, today: string, now: Date, workingDays: WorkingDays): PlanBudget | null {
  const open = new Map<string, { endsAt: string; percent: number; days: Map<string, number>; covered: boolean }>();
  for (const row of rows) {
    if (row.provider !== plan.provider || row.kind !== "limit" || row.period_hours !== WEEK_HOURS || Date.parse(row.ends_at) <= now.getTime()) continue;
    const window = open.get(row.account_key);
    // A claimed reset leaves the account a newer window; the one that resets first is the open one.
    if (window && window.endsAt < row.ends_at) continue;
    const merged = window?.endsAt === row.ends_at ? window : { endsAt: row.ends_at, percent: 0, days: new Map<string, number>(), covered: false };
    merged.percent = Math.max(merged.percent, row.percent);
    merged.covered = merged.covered || plan.covered(row.user_id);
    for (const reading of row.days ?? []) merged.days.set(reading.day, Math.max(merged.days.get(reading.day) ?? 0, reading.percent));
    open.set(row.account_key, merged);
  }
  const accounts = [...open.values()].filter((window) => window.covered);
  if (accounts.length === 0) return null;

  const lastDay = (endsAt: string) => {
    const end = new Date(endsAt);
    const day = endsAt.slice(0, 10);
    return end.getUTCHours() >= LAST_DAY_HOUR ? day : addDays(day, -1);
  };
  const workingLeft = (endsAt: string) => {
    let count = 1;
    for (let day = addDays(today, 1); day <= lastDay(endsAt); day = addDays(day, 1)) if (isWorkingDay(day, workingDays)) count += 1;
    return count;
  };
  const budgets = accounts.map((window) => {
    const startDay = new Date(Date.parse(window.endsAt) - WEEK_HOURS * HOUR_MS).toISOString().slice(0, 10);
    const current = Math.max(window.percent, window.days.get(today) ?? 0);
    const earlier = [...window.days.entries()].filter(([day]) => day < today).map(([, percent]) => percent);
    const before = earlier.length > 0 ? Math.max(...earlier) : daysBetween(startDay, today) <= 1 ? 0 : current;
    const left = Math.max(0, 100 - before);
    return { today: Math.max(0, current - before), left, affordable: left / workingLeft(window.endsAt) };
  });
  const mean = (values: number[]) => values.reduce((sum, value) => sum + value, 0) / values.length;
  const soonest = accounts.reduce((first, window) => (window.endsAt < first.endsAt ? window : first));
  const used = accountDailyUse(rows, plan);
  const start = new Date(Date.parse(soonest.endsAt) - WEEK_HOURS * HOUR_MS).toISOString().slice(0, 10);
  const days: PlanBudget["days"] = [];
  for (let day = start; day <= lastDay(soonest.endsAt); day = addDays(day, 1)) {
    const share = day > today ? { percent: null, estimated: false } : dayShare(used, day);
    days.push({ day, percent: share.percent, working: isWorkingDay(day, workingDays), estimated: share.estimated });
  }
  return {
    todayPercent: round1(mean(budgets.map((budget) => budget.today))),
    affordablePercent: round1(mean(budgets.map((budget) => budget.affordable))),
    leftPercent: round1(mean(budgets.map((budget) => budget.left))),
    workingDaysLeft: workingLeft(soonest.endsAt),
    resetsAt: soonest.endsAt,
    accounts: accounts.length,
    days,
  };
}
