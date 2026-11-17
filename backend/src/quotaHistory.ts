import { ESTIMATE_GAP_MS, type QuotaRow } from "./quota";
import { accountWindows, latestClaimBetween, shareOfCapacity, type MergedWindow } from "./quotaClaims";
import { accountDailyUse, dayShare, round1, sessionsBetween, type Plan } from "./quotaDaily";
import { zonedTime } from "./schedules";
import { daysBetween } from "./stats";
import { addDays } from "./usagePayload";
import { isWorkingDay, type WorkingDays } from "./workingDays";

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
  /** Limit resets claimed that day (the claiming Mac's day). Omitted when none. */
  resets?: number;
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
  /**
   * The share of the window's capacity used, the mean over its accounts (capped at 100 each). Without
   * claimed resets the capacity is the weekly limit; a claim adds another limit (see `capacityPercent`).
   */
  percent: number;
  /** With a claimed reset in the window: the share of the weekly limit used in all (135 of 200), the mean over its accounts. */
  usedPercent?: number;
  /** With a claimed reset: the window's capacity, 100 per limit (200 after one claim), the mean over its accounts. */
  capacityPercent?: number;
  /** With a claimed reset: how many were claimed in the window, over its accounts. */
  resets?: number;
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
  /** The soonest-resetting open week, day by day; days after today have no percent. `resets`: claims that day, omitted when none. */
  days: { day: string; percent: number | null; working: boolean; estimated: boolean; resets?: number }[];
  /** With a claimed reset in an open week: what the open weeks used of their capacity (see `WeekCapacity`). Omitted otherwise. */
  week?: WeekCapacity;
}

/** An open week with claimed resets: what it used of its capacity. Means over the accounts with an open week. */
export interface WeekCapacity {
  /** The share of the weekly limit used so far in all, every stretch between resets counted (135). */
  usedPercent: number;
  /** 100 per limit: 100 plus 100 per claimed reset (200). */
  capacityPercent: number;
  /** With one account: the share used in each stretch, before each claim then since the last ([95, 40]). */
  segments?: number[];
  resets: number;
}

/** One account in the plan's open week: who reads it, how much of its week it used, when it resets. */
export interface AccountWeek {
  /** The covered members whose Macs read this account's open week, by user id (the route names them). */
  people: string[];
  /** The share of its week's capacity used so far (the weekly limit, plus one per claimed reset). */
  percent: number;
  /** With a claimed reset: the share of the weekly limit used in all, its capacity, and each stretch's share. */
  usedPercent?: number;
  capacityPercent?: number;
  segments?: number[];
  /** The share of its weekly limit used today. */
  todayPercent: number;
  resetsAt: string;
  /** A Mac names it per Mac (no account id), so it may be the same login as another account here. */
  perDevice: boolean;
  /** The account's key, for an owner to hide it from the plan. The route sends it to owners only. */
  account: string;
}

export type Window = MergedWindow;

/** The covered accounts' weekly windows, merged across Macs, each account's in order (see `accountWindows`). */
export function coveredWindows(rows: QuotaRow[], plan: Plan): Map<string, Window[]> {
  return accountWindows(rows, plan, { weekly: true });
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

/** Claimed resets per day over `windows` (the claiming Mac's day). */
function resetsByDay(windows: Window[]): Map<string, number> {
  const resets = new Map<string, number>();
  for (const claim of windows.flatMap((window) => window.claims)) resets.set(claim.day, (resets.get(claim.day) ?? 0) + 1);
  return resets;
}

const mean = (values: number[]) => values.reduce((sum, value) => sum + value, 0) / values.length;

/**
 * The plan's last `weeks` weekly windows, oldest first. With several accounts, the windows of the one
 * whose open week resets first frame the weeks; each other account counts with its window that holds
 * the frame's middle. A week's share is the mean of its accounts' shares of their capacity (capped at
 * 100; a claimed reset adds a limit to its window), its days the daily share of the weekly limit (see
 * `accountDailyUse`), and its sessions those that ended in it.
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
    const resets = resetsByDay(matching);
    const days: HistoryDay[] = [];
    for (let day = span.from; day <= span.to; day = addDays(day, 1)) {
      const share = day > today ? { percent: null, estimated: false, accounts: [] } : dayShare(used, day);
      days.push({
        day, percent: share.percent, working: isWorkingDay(day, workingDays), estimated: share.estimated, accounts: share.accounts.length,
        ...(resets.has(day) ? { resets: resets.get(day) } : {}),
      });
    }
    const sessions = sessionsBetween(rows, plan, week.startsAt, week.endsAt);
    const lowerBound = matching.some((window) => window.endsAt <= now.getTime() && window.endsAt - window.observedAt > ESTIMATE_GAP_MS);
    const claims = matching.reduce((sum, window) => sum + window.claims.length, 0);
    return {
      from: span.from,
      to: span.to,
      startsAt: new Date(week.startsAt).toISOString(),
      endsAt: new Date(week.endsAt).toISOString(),
      open,
      percent: round1(mean(matching.map((window) => Math.min(shareOfCapacity(window), 100)))),
      ...(claims === 0 ? {} : {
        usedPercent: round1(mean(matching.map((window) => Math.min(window.used, window.capacity)))),
        capacityPercent: round1(mean(matching.map((window) => window.capacity))),
        resets: claims,
      }),
      estimated: lowerBound || days.some((day) => day.estimated),
      accounts: matching.length,
      days,
      sessions: sessions === null ? null : { sessions: sessions.sessions, limitHits: sessions.limitHits, averagePeakPercent: sessions.averagePeakPercent },
    };
  });
}

/**
 * An open window's use today, the share used before today (`before`), and the share left at the start
 * of today: the window's capacity (100, plus 100 per claimed reset so far) minus the last reading before
 * today. Without one, a window that started today or yesterday counts from 0 and an older one from its
 * current share. Readings count every stretch between claims, so they only grow and today is never
 * negative: a claim today counts the use before it and the use after it.
 */
export function todayUse(window: Window, today: string): { today: number; left: number; before: number } {
  const startDay = new Date(window.startsAt).toISOString().slice(0, 10);
  const current = Math.max(window.used, window.days.get(today) ?? 0);
  const earlier = [...window.days.entries()].filter(([day]) => day < today).map(([, percent]) => percent);
  const before = Math.min(earlier.length > 0 ? Math.max(...earlier) : daysBetween(startDay, today) <= 1 ? 0 : current, current);
  return { today: current - before, left: Math.max(0, window.capacity - before), before };
}

/** The viewer's day `day` in `timeZone` as an absolute span (UTC without a zone). */
export function dayBounds(day: string, timeZone: string | null): { from: number; to: number } {
  const zone = timeZone ?? "UTC";
  return { from: zonedTime(day, 0, zone), to: zonedTime(addDays(day, 1), 0, zone) };
}

/**
 * A reset claimed today restarts today's budget from the claim: the use before it counts as spent, and
 * what's left after it (capacity minus the share used at the claim) is spread from then on. "Today" is
 * the viewer's day up to now, by the claim's time; Live Pace uses the same rule. Null without one.
 */
export function claimToday(
  window: Window, day: { from: number; to: number }, now: number, before: number,
): { at: number; usedBefore: number; leftAfter: number } | null {
  const claim = latestClaimBetween(window, day.from, Math.min(day.to, now));
  if (claim === null) return null;
  return { at: claim.claim.at, usedBefore: Math.max(0, claim.usedAt - before), leftAfter: Math.max(0, window.capacity - claim.usedAt) };
}

/** What the open weeks used of their capacity, when one of them had a reset claimed (see `WeekCapacity`). */
function weekCapacity(open: Window[]): WeekCapacity | undefined {
  const resets = open.reduce((sum, window) => sum + window.claims.length, 0);
  if (resets === 0) return undefined;
  return {
    usedPercent: round1(mean(open.map((window) => window.used))),
    capacityPercent: round1(mean(open.map((window) => window.capacity))),
    ...(open.length === 1 ? { segments: open[0]!.segments.map(round1) } : {}),
    resets,
  };
}

/**
 * Today's budget for the plan: for each covered account with an open weekly window, the share left at
 * the start of today (see `todayUse`) over today and the working days until it resets (see `windowDays`
 * for its last day). A reset claimed today restarts the budget at the claim (see `claimToday`). The
 * plan takes the mean over its accounts. Null when no covered account has an open weekly window.
 */
export function planBudget(
  rows: QuotaRow[], plan: Plan, today: string, now: Date, workingDays: WorkingDays, timeZone: string | null = null,
): PlanBudget | null {
  const day = dayBounds(today, timeZone);
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
    const { today: used, left, before } = todayUse(window, today);
    const claim = claimToday(window, day, now.getTime(), before);
    const affordable = claim === null ? left / workingLeft(window) : claim.usedBefore + claim.leftAfter / workingLeft(window);
    return { today: used, left, affordable };
  });
  const soonest = open.reduce((first, window) => (window.endsAt < first.endsAt ? window : first));
  const used = accountDailyUse(rows, plan);
  const resets = resetsByDay(open);
  const span = windowDays(soonest.startsAt, soonest.endsAt);
  const days: PlanBudget["days"] = [];
  for (let day = span.from; day <= span.to; day = addDays(day, 1)) {
    const share = day > today ? { percent: null, estimated: false } : dayShare(used, day);
    days.push({
      day, percent: share.percent, working: isWorkingDay(day, workingDays), estimated: share.estimated,
      ...(resets.has(day) ? { resets: resets.get(day) } : {}),
    });
  }
  const perAccount = open
    .map((window, index): AccountWeek & { endsAt: number } => {
      const reads = window.rows.filter((row) => plan.covered(row.user_id));
      return {
        people: [...new Set(reads.map((row) => row.user_id))].sort(),
        percent: round1(shareOfCapacity(window)),
        ...(window.claims.length === 0 ? {} : {
          usedPercent: round1(window.used), capacityPercent: window.capacity, segments: window.segments.map(round1),
        }),
        todayPercent: round1(budgets[index]!.today),
        resetsAt: new Date(window.endsAt).toISOString(),
        perDevice: reads.some((row) => row.per_device),
        account: window.account,
        endsAt: window.endsAt,
      };
    })
    .sort((a, b) => a.endsAt - b.endsAt || b.percent - a.percent)
    .map(({ endsAt: _endsAt, ...account }) => account);
  const week = weekCapacity(open);
  return {
    todayPercent: round1(mean(budgets.map((budget) => budget.today))),
    affordablePercent: round1(mean(budgets.map((budget) => budget.affordable))),
    leftPercent: round1(mean(budgets.map((budget) => budget.left))),
    workingDaysLeft: workingLeft(soonest),
    resetsAt: new Date(soonest.endsAt).toISOString(),
    accounts: open.length,
    perAccount,
    days,
    ...(week === undefined ? {} : { week }),
  };
}
