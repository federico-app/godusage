import type { QuotaReading, QuotaRow } from "./quota";
import { coveredWindows, todayUse, type Window } from "./quotaHistory";
import type { Plan } from "./quotaDaily";
import { defaultSchedule, overlap, union, workingIntervals, zonedTime, type Interval, type MemberHours } from "./schedules";
import { addDays } from "./usagePayload";
import type { WorkingDays } from "./workingDays";

const HOUR_MS = 3_600_000;
const WEEK_HOURS = 168;
/** The pace is the growth over this much working time before now. */
const PACE_WINDOW_MS = HOUR_MS;
/** The day chart needs no more points than this. */
const MAX_SERIES = 96;

/** What Live Pace needs beyond the plan report: the viewer's time zone, the readings, and everyone's hours. */
export interface PaceContext {
  /** The viewer's IANA time zone: their "today" runs midnight to midnight in it. */
  timeZone: string;
  readings: QuotaReading[];
  hours: Map<string, MemberHours>;
  /** The team's working days, for members who never set their hours. */
  teamDays: WorkingDays;
}

/**
 * Today's budget spread over working hours, for Live Pace. The working hours are the union of the
 * hours of every covered member who uses the plan's accounts, each in their own time zone, so a
 * shared account is paced on everyone who uses it. The app turns this into the time-dependent figures
 * (where you should be now, minutes ahead or behind, the projection) as the clock moves.
 */
export interface PlanPace {
  /** The share left at the start of today times today's share of the working hours until the reset (mean over accounts). */
  budgetPercent: number;
  /** The share of the weekly limit used today (mean over accounts). */
  usedPercent: number;
  /** The share left at the start of today (mean over accounts). */
  leftPercent: number;
  /**
   * The growth of the share over the last working hour (mean over the accounts with readings to tell),
   * in points per working hour. Null in the first working hour of the day or without readings that old.
   */
  ratePerHour: number | null;
  /** Today's working hours (the viewer's day, until the soonest reset), ISO 8601. */
  hours: { from: string; to: string }[];
  /** The viewer's days after today until the soonest reset that have working hours, and how many. */
  futureDays: { day: string; hours: number }[];
  /**
   * Today's use over time, from the readings: the mean over the accounts of each one's latest share
   * used today (0 before its first reading), at most `MAX_SERIES` points, oldest first.
   */
  today: { at: string; percent: number }[];
  /** The covered members whose hours make the union. */
  people: string[];
  /** When the soonest-resetting account's week resets. */
  resetsAt: string;
}

/** The viewer's day `day` as an absolute span. */
export function dayBounds(day: string, timeZone: string): Interval {
  return { from: zonedTime(day, 0, timeZone), to: zonedTime(addDays(day, 1), 0, timeZone) };
}

/** Everyone in `people`'s working time from `from` to `to`, merged. */
export function unionHours(people: string[], context: Pick<PaceContext, "hours" | "teamDays" | "timeZone">, from: number, to: number): Interval[] {
  return union(people.flatMap((user) => {
    const hours = context.hours.get(user);
    return workingIntervals(hours?.schedule ?? defaultSchedule(context.teamDays), hours?.timeZone ?? context.timeZone, from, to);
  }));
}

/** The instant `span` of working time before `now`, or null when there isn't that much since `since`. */
function workingTimeBefore(intervals: Interval[], now: number, span: number, since: number): number | null {
  let needed = span;
  for (const interval of [...intervals].reverse()) {
    const to = Math.min(interval.to, now);
    const from = Math.max(interval.from, since);
    if (to <= from) continue;
    if (to - from >= needed) return to - needed;
    needed -= to - from;
  }
  return null;
}

/** An account's growth over the last working hour, from its readings, in points per hour. */
function accountRate(window: Window, readings: QuotaReading[], intervals: Interval[], day: Interval, now: number): number | null {
  const start = workingTimeBefore(intervals, now, PACE_WINDOW_MS, day.from);
  if (start === null) return null;
  const endsAt = new Date(window.endsAt).toISOString();
  const own = readings.filter((reading) => reading.account_key === window.account && reading.ends_at === endsAt && Date.parse(reading.observed_at) <= now);
  const before = own.filter((reading) => Date.parse(reading.observed_at) <= start);
  if (before.length === 0) return null;
  const then = Math.max(...before.map((reading) => reading.percent));
  const latest = Math.max(window.percent, ...own.map((reading) => reading.percent));
  return Math.max(0, latest - then) / (PACE_WINDOW_MS / HOUR_MS);
}

/** Today's use over time across `open` accounts (see `PlanPace.today`). */
function todaySeries(open: Window[], readings: QuotaReading[], today: string, day: Interval, now: number): PlanPace["today"] {
  const before = new Map(open.map((window) => [window.account, todayUse(window, today)]));
  const latest = new Map(open.map((window) => [window.account, 0]));
  const endsAt = new Map(open.map((window) => [window.account, new Date(window.endsAt).toISOString()]));
  const points: PlanPace["today"] = [];
  for (const reading of readings) {
    const time = Date.parse(reading.observed_at);
    if (time < day.from || time > now || endsAt.get(reading.account_key) !== reading.ends_at) continue;
    const use = before.get(reading.account_key)!;
    const used = Math.max(0, reading.percent - (100 - use.left));
    latest.set(reading.account_key, Math.max(latest.get(reading.account_key)!, used));
    points.push({ at: reading.observed_at, percent: round1([...latest.values()].reduce((sum, value) => sum + value, 0) / latest.size) });
  }
  if (points.length <= MAX_SERIES) return points;
  const step = points.length / MAX_SERIES;
  return [...Array.from({ length: MAX_SERIES - 1 }, (_, index) => points[Math.floor(index * step)]!), points[points.length - 1]!];
}

/** The plan's Live Pace for the viewer's `today`, or null when no covered account has an open weekly window. */
export function planPace(rows: QuotaRow[], plan: Plan, today: string, now: Date, context: PaceContext): PlanPace | null {
  const time = now.getTime();
  const open = [...coveredWindows(rows, plan).values()]
    .map((windows) => windows.find((window) => window.endsAt > time))
    .filter((window): window is Window => window !== undefined);
  if (open.length === 0) return null;

  const accounts = new Set(open.map((window) => window.account));
  const people = [...new Set(rows
    .filter((row) => row.provider === plan.provider && row.kind === "limit" && row.period_hours === WEEK_HOURS && accounts.has(row.account_key) && plan.covered(row.user_id))
    .map((row) => row.user_id))].sort();
  const day = dayBounds(today, context.timeZone);
  const latestReset = Math.max(...open.map((window) => window.endsAt));
  const intervals = unionHours(people, context, day.from, latestReset);

  const paces = open.map((window) => {
    const { today: used, left } = todayUse(window, today);
    const todayHours = overlap(intervals, day.from, Math.min(day.to, window.endsAt));
    const totalHours = overlap(intervals, day.from, window.endsAt);
    return {
      used,
      left,
      budget: todayHours === 0 ? 0 : (left * todayHours) / totalHours,
      rate: accountRate(window, context.readings, intervals, day, time),
    };
  });
  const mean = (values: number[]) => values.reduce((sum, value) => sum + value, 0) / values.length;
  const rates = paces.map((pace) => pace.rate).filter((rate): rate is number => rate !== null);
  const soonest = Math.min(...open.map((window) => window.endsAt));

  const futureDays: PlanPace["futureDays"] = [];
  for (let next = addDays(today, 1); ; next = addDays(next, 1)) {
    const bounds = dayBounds(next, context.timeZone);
    if (bounds.from >= soonest) break;
    const hours = overlap(intervals, bounds.from, Math.min(bounds.to, soonest)) / HOUR_MS;
    if (hours > 0) futureDays.push({ day: next, hours: round2(hours) });
  }
  return {
    budgetPercent: round1(mean(paces.map((pace) => pace.budget))),
    usedPercent: round1(mean(paces.map((pace) => pace.used))),
    leftPercent: round1(mean(paces.map((pace) => pace.left))),
    ratePerHour: rates.length === 0 ? null : round2(mean(rates)),
    hours: intervals
      .map((interval) => ({ from: Math.max(interval.from, day.from), to: Math.min(interval.to, day.to, soonest) }))
      .filter((interval) => interval.to > interval.from)
      .map((interval) => ({ from: new Date(interval.from).toISOString(), to: new Date(interval.to).toISOString() })),
    futureDays,
    today: todaySeries(open, context.readings, today, day, time),
    people,
    resetsAt: new Date(soonest).toISOString(),
  };
}

function round1(value: number): number {
  return Math.round(value * 10) / 10;
}

function round2(value: number): number {
  return Math.round(value * 100) / 100;
}
