import type { Queryable } from "./db";
import { badRequest, isRecord } from "./http";
import { addDays } from "./usagePayload";
import { DEFAULT_WORKING_DAYS, type WorkingDays } from "./workingDays";

const MINUTE_MS = 60_000;
const DAY_MINUTES = 24 * 60;
const DAY_MS = DAY_MINUTES * MINUTE_MS;

/**
 * A member's working hours, in their own time zone: the weekdays they work (ISO, 1 = Monday) and, on
 * each, from `start` to `end` (minutes after midnight), less an optional break. One per person, shared
 * by all their teams. Live Pace spreads today's budget over these hours (see livePace.ts).
 */
export interface WorkSchedule {
  days: WorkingDays;
  start: number;
  end: number;
  breakStart: number | null;
  breakEnd: number | null;
}

/** A span of absolute time, in epoch milliseconds, `from` included and `to` not. */
export interface Interval {
  from: number;
  to: number;
}

export const DEFAULT_START = 9 * 60;
export const DEFAULT_END = 18 * 60;

/** A member who never set their hours works the team's working days, 9:00 to 18:00. */
export function defaultSchedule(teamDays: WorkingDays = DEFAULT_WORKING_DAYS): WorkSchedule {
  return { days: teamDays, start: DEFAULT_START, end: DEFAULT_END, breakStart: null, breakEnd: null };
}

function minute(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0 || value > DAY_MINUTES) {
    throw badRequest(`${field} must be a whole number of minutes from 0 to 1440.`);
  }
  return value;
}

/** Validates a schedule sent by the app (the system boundary). */
export function parseSchedule(value: unknown): WorkSchedule {
  if (!isRecord(value)) throw badRequest("The working hours must be an object.");
  const { days } = value;
  if (!Array.isArray(days) || !days.every((day) => Number.isInteger(day) && day >= 1 && day <= 7)) {
    throw badRequest("days must be a list of weekdays from 1 (Monday) to 7 (Sunday).");
  }
  const sorted = [...new Set(days as number[])].sort((a, b) => a - b);
  if (sorted.length === 0) throw badRequest("At least one day of the week must be a working day.");
  const start = minute(value.start, "start");
  const end = minute(value.end, "end");
  if (end <= start) throw badRequest("The working hours must end after they start.");
  const hasBreak = value.breakStart !== undefined && value.breakStart !== null;
  if (hasBreak !== (value.breakEnd !== undefined && value.breakEnd !== null)) throw badRequest("A break needs both a start and an end.");
  if (!hasBreak) return { days: sorted, start, end, breakStart: null, breakEnd: null };
  const breakStart = minute(value.breakStart, "breakStart");
  const breakEnd = minute(value.breakEnd, "breakEnd");
  if (breakStart <= start || breakEnd >= end || breakEnd <= breakStart) throw badRequest("The break must fall inside the working hours.");
  return { days: sorted, start, end, breakStart, breakEnd };
}

/** An IANA time zone the server's clock knows, else null. */
export function parseTimeZone(value: unknown): string | null {
  if (typeof value !== "string" || value.length === 0 || value.length > 64) return null;
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: value });
    return value;
  } catch {
    return null;
  }
}

const formatters = new Map<string, Intl.DateTimeFormat>();

function parts(time: number, timeZone: string): { year: number; month: number; day: number; hour: number; minute: number; second: number } {
  let format = formatters.get(timeZone);
  if (!format) {
    format = new Intl.DateTimeFormat("en-US", {
      timeZone, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit",
    });
    formatters.set(timeZone, format);
  }
  const values: Record<string, number> = {};
  for (const part of format.formatToParts(new Date(time))) {
    if (part.type !== "literal") values[part.type] = Number(part.value);
  }
  return { year: values.year!, month: values.month!, day: values.day!, hour: values.hour!, minute: values.minute!, second: values.second! };
}

/** How far `timeZone` is ahead of UTC at `time`, in milliseconds. */
function offset(time: number, timeZone: string): number {
  const local = parts(time, timeZone);
  const asUTC = Date.UTC(local.year, local.month - 1, local.day, local.hour, local.minute, local.second);
  return asUTC - Math.floor(time / 1000) * 1000;
}

/** The calendar day (YYYY-MM-DD) it is in `timeZone` at `time`. */
export function localDay(time: number, timeZone: string): string {
  const local = parts(time, timeZone);
  return `${local.year}-${String(local.month).padStart(2, "0")}-${String(local.day).padStart(2, "0")}`;
}

/**
 * The instant it is `minutes` after midnight of `day` in `timeZone`. Around a daylight-saving change
 * the wall time may not exist or happen twice; the offset from just before is used.
 */
export function zonedTime(day: string, minutes: number, timeZone: string): number {
  const guess = Date.parse(`${day}T00:00:00Z`) + minutes * MINUTE_MS;
  const first = guess - offset(guess, timeZone);
  return guess - offset(first, timeZone);
}

function isoWeekday(day: string): number {
  const weekday = new Date(`${day}T00:00:00Z`).getUTCDay();
  return weekday === 0 ? 7 : weekday;
}

/** The schedule's working time from `from` to `to`, in absolute time, in order. */
export function workingIntervals(schedule: WorkSchedule, timeZone: string, from: number, to: number): Interval[] {
  const intervals: Interval[] = [];
  const last = localDay(to, timeZone);
  for (let day = localDay(from - DAY_MS, timeZone); day <= last; day = addDays(day, 1)) {
    if (!schedule.days.includes(isoWeekday(day))) continue;
    const spans: [number, number][] = schedule.breakStart === null || schedule.breakEnd === null
      ? [[schedule.start, schedule.end]]
      : [[schedule.start, schedule.breakStart], [schedule.breakEnd, schedule.end]];
    for (const [start, end] of spans) {
      const span = { from: Math.max(from, zonedTime(day, start, timeZone)), to: Math.min(to, zonedTime(day, end, timeZone)) };
      if (span.to > span.from) intervals.push(span);
    }
  }
  return intervals;
}

/** The time covered by any of `intervals`, merged and in order. */
export function union(intervals: Interval[]): Interval[] {
  const sorted = [...intervals].sort((a, b) => a.from - b.from);
  const merged: Interval[] = [];
  for (const interval of sorted) {
    const last = merged[merged.length - 1];
    if (last && interval.from <= last.to) last.to = Math.max(last.to, interval.to);
    else merged.push({ ...interval });
  }
  return merged;
}

/** How much of `intervals` falls between `from` and `to`, in milliseconds. */
export function overlap(intervals: Interval[], from: number, to: number): number {
  return intervals.reduce((sum, interval) => sum + Math.max(0, Math.min(to, interval.to) - Math.max(from, interval.from)), 0);
}

/** A member's stored hours (null when never set) and their Mac's time zone (null before any upload sent one). */
export interface MemberHours {
  schedule: WorkSchedule | null;
  timeZone: string | null;
}

/** The hours `userIDs` keep in `teamID` and their time zones. */
export async function loadMemberHours(db: Queryable, teamID: string, userIDs: string[]): Promise<Map<string, MemberHours>> {
  if (userIDs.length === 0) return new Map();
  const rows = await db.query<{
    id: string; time_zone: string | null; days: string | null; start_minute: number | null; end_minute: number | null;
    break_start_minute: number | null; break_end_minute: number | null;
  }>(
    `SELECT u.id, u.time_zone, s.days, s.start_minute, s.end_minute, s.break_start_minute, s.break_end_minute
     FROM users u LEFT JOIN team_work_schedules s ON s.user_id = u.id AND s.team_id = $1 WHERE u.id = ANY($2::text[])`,
    [teamID, userIDs],
  );
  return new Map(rows.map((row) => [row.id, {
    timeZone: parseTimeZone(row.time_zone),
    schedule: row.days === null
      ? null
      : { days: JSON.parse(row.days) as WorkingDays, start: row.start_minute!, end: row.end_minute!, breakStart: row.break_start_minute, breakEnd: row.break_end_minute },
  }]));
}

/** Saves a member's hours in one team; null goes back to the team's default. */
export async function storeSchedule(db: Queryable, teamID: string, userID: string, schedule: WorkSchedule | null, now: Date): Promise<void> {
  if (schedule === null) {
    await db.run("DELETE FROM team_work_schedules WHERE team_id = $1 AND user_id = $2", [teamID, userID]);
    return;
  }
  await db.run(
    `INSERT INTO team_work_schedules (team_id, user_id, days, start_minute, end_minute, break_start_minute, break_end_minute, updated_at)
     VALUES ($8, $1, $2, $3, $4, $5, $6, $7)
     ON CONFLICT (team_id, user_id) DO UPDATE SET days = excluded.days, start_minute = excluded.start_minute, end_minute = excluded.end_minute,
       break_start_minute = excluded.break_start_minute, break_end_minute = excluded.break_end_minute, updated_at = excluded.updated_at`,
    [userID, JSON.stringify(schedule.days), schedule.start, schedule.end, schedule.breakStart, schedule.breakEnd, now.toISOString(), teamID],
  );
}
