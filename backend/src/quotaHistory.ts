import { ESTIMATE_GAP_MS, type QuotaRow } from "./quota";
import { accountDailyUse, dayShare, round1, sessionsBetween, type Plan } from "./quotaDaily";
import { daysBetween } from "./stats";
import { addDays } from "./usagePayload";
import { isWorkingDay, type WorkingDays } from "./workingDays";

const HOUR_MS = 3_600_000;
/** Only weekly windows give a daily share of the weekly limit. */
const WEEK_HOURS = 168;
/** A window's first day counts when it starts before this UTC hour, its last when it ends at it or later. */
const HALF_DAY_HOUR = 12;
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

/** One of the plan's weekly windows, from reset to reset. */
export interface HistoryWeek {
  /** The window's first and last calendar days (see `windowDays`). */
  from: string;
  to: string;
  startsAt: string;
  endsAt: string;
  /** Still running: it resets after now. */
  open: boolean;
  /** The share of the weekly limit used in the window, the mean over its accounts (capped at 100 each). */
  percent: number;
  /** Some account's share is a lower bound (last read well before its reset), or a day was spread. */
  estimated: boolean;
  /** Covered accounts with a window here. */
  accounts: number;
  days: HistoryDay[];
  /** The 5-hour sessions that ended in the window. */
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
  /** Each account with an open week, soonest reset first (see `AccountWeek`). */
  perAccount: AccountWeek[];
  /** The soonest-resetting open week, day by day; days after today have no percent. */
  days: { day: string; percent: number | null; working: boolean; estimated: boolean }[];
}

/** One account in the plan's open week: who reads it, how much of its week it used, when it resets. */
export interface AccountWeek {
  /** The covered members whose Macs read this account's open week, by user id (the route names them). */
  people: string[];
  /** The share of its weekly limit used so far. */
  percent: number;
  /** The share of its weekly limit used today. */
  todayPercent: number;
  resetsAt: string;
  /** A Mac names it per Mac (no account id), so it may be the same login as another account here. */
  perDevice: boolean;
  /** The account's key, for an owner to hide it from the plan. The route sends it to owners only. */
  account: string;
}

export interface Window {
  account: string;
  startsAt: number;
  endsAt: number;
  percent: number;
  observedAt: number;
  days: Map<string, number>;
}

/**
 * The covered accounts' weekly windows, merged across Macs (the highest share), each account's in
 * order. A window that a claimed reset cut short starts where the account's previous one ended.
 */
export function coveredWindows(rows: QuotaRow[], plan: Plan): Map<string, Window[]> {
  const byKey = new Map<string, Window & { covered: boolean }>();
  for (const row of rows) {
    if (row.provider !== plan.provider || row.kind !== "limit" || row.period_hours !== WEEK_HOURS) continue;
    const key = `${row.account_key}|${row.ends_at}`;
    const endsAt = Date.parse(row.ends_at);
    const window = byKey.get(key) ?? {
      account: row.account_key, startsAt: endsAt - WEEK_HOURS * HOUR_MS, endsAt, percent: 0, observedAt: 0, days: new Map<string, number>(), covered: false,
    };
    window.percent = Math.max(window.percent, row.percent);
    window.observedAt = Math.max(window.observedAt, Date.parse(row.observed_at));
    window.covered = window.covered || plan.covered(row.user_id);
    for (const reading of row.days ?? []) window.days.set(reading.day, Math.max(window.days.get(reading.day) ?? 0, reading.percent));
    byKey.set(key, window);
  }
  const accounts = new Map<string, Window[]>();
  for (const window of byKey.values()) {
    if (!window.covered) continue;
    accounts.set(window.account, [...(accounts.get(window.account) ?? []), window]);
  }
  for (const windows of accounts.values()) {
    windows.sort((a, b) => a.endsAt - b.endsAt);
    for (let index = 1; index < windows.length; index += 1) {
      windows[index]!.startsAt = Math.max(windows[index]!.startsAt, windows[index - 1]!.endsAt);
    }
  }
  return accounts;
}

/**
 * A window's calendar days: its first day counts when it starts before noon UTC and its last when it
 * ends at noon UTC or later, so a week from Tuesday 03:00 to Tuesday 03:00 is Tuesday to Monday.
 */
export function windowDays(startsAt: number, endsAt: number): { from: string; to: string } {
  const start = new Date(startsAt);
  const end = new Date(endsAt);
  const startDay = start.toISOString().slice(0, 10);
  const endDay = end.toISOString().slice(0, 10);
  return {
    from: start.getUTCHours() < HALF_DAY_HOUR ? startDay : addDays(startDay, 1),
    to: end.getUTCHours() >= HALF_DAY_HOUR ? endDay : addDays(endDay, -1),
  };
}

/** The account whose windows frame the plan's weeks: the one whose open week resets first, else the latest. */
function frameAccount(accounts: Map<string, Window[]>, now: number): Window[] | undefined {
  let best: { windows: Window[]; open: boolean; endsAt: number } | undefined;
  for (const windows of accounts.values()) {
    const open = windows.find((window) => window.endsAt > now);
    const candidate = open ? { windows, open: true, endsAt: open.endsAt } : { windows, open: false, endsAt: windows[windows.length - 1]!.endsAt };
    if (!best || (candidate.open && !best.open) || (candidate.open === best.open && (candidate.open ? candidate.endsAt < best.endsAt : candidate.endsAt > best.endsAt))) {
      best = candidate;
    }
  }
  return best?.windows;
}

/**
 * The plan's last `weeks` weekly windows, oldest first. With several accounts, the windows of the one
 * whose open week resets first frame the weeks; each other account counts with its window that holds
 * the frame's middle. A week's share is the mean of its accounts' window shares (capped at 100), its
 * days the daily share of the weekly limit (see `accountDailyUse`), and its sessions those that ended
 * in it.
 */
export function planHistory(rows: QuotaRow[], plan: Plan, today: string, now: Date, weeks: number, workingDays: WorkingDays): HistoryWeek[] {
  const accounts = coveredWindows(rows, plan);
  const frame = frameAccount(accounts, now.getTime());
  if (!frame) return [];
  const used = accountDailyUse(rows, plan);
  return frame.slice(-weeks).map((week) => {
    const middle = (week.startsAt + week.endsAt) / 2;
    const matching = [...accounts.values()]
      .map((windows) => windows.find((window) => window.startsAt <= middle && middle < window.endsAt))
      .filter((window): window is Window => window !== undefined);
    const open = week.endsAt > now.getTime();
    const span = windowDays(week.startsAt, week.endsAt);
    const days: HistoryDay[] = [];
    for (let day = span.from; day <= span.to; day = addDays(day, 1)) {
      const share = day > today ? { percent: null, estimated: false, accounts: [] } : dayShare(used, day);
      days.push({ day, percent: share.percent, working: isWorkingDay(day, workingDays), estimated: share.estimated, accounts: share.accounts.length });
    }
    const sessions = sessionsBetween(rows, plan, week.startsAt, week.endsAt);
    const lowerBound = matching.some((window) => window.endsAt <= now.getTime() && window.endsAt - window.observedAt > ESTIMATE_GAP_MS);
    return {
      from: span.from,
      to: span.to,
      startsAt: new Date(week.startsAt).toISOString(),
      endsAt: new Date(week.endsAt).toISOString(),
      open,
      percent: round1(matching.reduce((sum, window) => sum + Math.min(window.percent, 100), 0) / matching.length),
      estimated: lowerBound || days.some((day) => day.estimated),
      accounts: matching.length,
      days,
      sessions: sessions === null ? null : { sessions: sessions.sessions, limitHits: sessions.limitHits, averagePeakPercent: sessions.averagePeakPercent },
    };
  });
}

/**
 * An open window's use today and the share left at the start of today: 100 minus the last reading
 * before today; without one, a window that started today or yesterday counts from 0 and an older one
 * from its current share.
 */
export function todayUse(window: Window, today: string): { today: number; left: number } {
  const startDay = new Date(window.startsAt).toISOString().slice(0, 10);
  const current = Math.max(window.percent, window.days.get(today) ?? 0);
  const earlier = [...window.days.entries()].filter(([day]) => day < today).map(([, percent]) => percent);
  const before = earlier.length > 0 ? Math.max(...earlier) : daysBetween(startDay, today) <= 1 ? 0 : current;
  return { today: Math.max(0, current - before), left: Math.max(0, 100 - before) };
}

/**
 * Today's budget for the plan: for each covered account with an open weekly window, the share left at
 * the start of today (100 minus the last reading before today; without one, a window that started
 * today or yesterday counts from 0 and an older one from its current share) over today and the working
 * days until it resets (see `windowDays` for its last day). The plan takes the mean over its accounts.
 * Null when no covered account has an open weekly window.
 */
export function planBudget(rows: QuotaRow[], plan: Plan, today: string, now: Date, workingDays: WorkingDays): PlanBudget | null {
  const open = [...coveredWindows(rows, plan).values()]
    .map((windows) => windows.find((window) => window.endsAt > now.getTime()))
    .filter((window): window is Window => window !== undefined);
  if (open.length === 0) return null;

  const workingLeft = (window: Window) => {
    let count = 1;
    for (let day = addDays(today, 1); day <= windowDays(window.startsAt, window.endsAt).to; day = addDays(day, 1)) {
      if (isWorkingDay(day, workingDays)) count += 1;
    }
    return count;
  };
  const budgets = open.map((window) => {
    const { today: used, left } = todayUse(window, today);
    return { today: used, left, affordable: left / workingLeft(window) };
  });
  const mean = (values: number[]) => values.reduce((sum, value) => sum + value, 0) / values.length;
  const soonest = open.reduce((first, window) => (window.endsAt < first.endsAt ? window : first));
  const used = accountDailyUse(rows, plan);
  const span = windowDays(soonest.startsAt, soonest.endsAt);
  const days: PlanBudget["days"] = [];
  for (let day = span.from; day <= span.to; day = addDays(day, 1)) {
    const share = day > today ? { percent: null, estimated: false } : dayShare(used, day);
    days.push({ day, percent: share.percent, working: isWorkingDay(day, workingDays), estimated: share.estimated });
  }
  const perAccount = open
    .map((window, index): AccountWeek & { endsAt: number } => {
      const reads = rows.filter((row) =>
        row.provider === plan.provider && row.kind === "limit" && row.period_hours === WEEK_HOURS
        && row.account_key === window.account && Date.parse(row.ends_at) === window.endsAt && plan.covered(row.user_id));
      return {
        people: [...new Set(reads.map((row) => row.user_id))].sort(),
        percent: round1(window.percent),
        todayPercent: round1(budgets[index]!.today),
        resetsAt: new Date(window.endsAt).toISOString(),
        perDevice: reads.some((row) => row.per_device),
        account: window.account,
        endsAt: window.endsAt,
      };
    })
    .sort((a, b) => a.endsAt - b.endsAt || b.percent - a.percent)
    .map(({ endsAt: _endsAt, ...account }) => account);
  return {
    todayPercent: round1(mean(budgets.map((budget) => budget.today))),
    affordablePercent: round1(mean(budgets.map((budget) => budget.affordable))),
    leftPercent: round1(mean(budgets.map((budget) => budget.left))),
    workingDaysLeft: workingLeft(soonest),
    resetsAt: new Date(soonest.endsAt).toISOString(),
    accounts: open.length,
    perAccount,
    days,
  };
}
