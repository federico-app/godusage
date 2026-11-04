import { badRequest } from "./http";

/** ISO weekdays (1 = Monday … 7 = Sunday), sorted. A team's forecasts are paced on them. */
export type WorkingDays = number[];

export const DEFAULT_WORKING_DAYS: WorkingDays = [1, 2, 3, 4, 5];

const DAY_MS = 86_400_000;

/** Validates the owner's working days. Missing keeps the stored ones (null). */
export function parseWorkingDays(value: unknown): WorkingDays | null {
  if (value === undefined) return null;
  if (!Array.isArray(value) || !value.every((day) => Number.isInteger(day) && day >= 1 && day <= 7)) {
    throw badRequest("workingDays must be a list of weekdays from 1 (Monday) to 7 (Sunday).");
  }
  const days = [...new Set(value as number[])].sort((a, b) => a - b);
  if (days.length === 0) throw badRequest("At least one day of the week must be a working day.");
  return days;
}

/** The stored column (a JSON array), read back. */
export function storedWorkingDays(value: string | null): WorkingDays {
  return value === null ? DEFAULT_WORKING_DAYS : (JSON.parse(value) as WorkingDays);
}

function isoWeekday(time: number): number {
  const day = new Date(time).getUTCDay();
  return day === 0 ? 7 : day;
}

/** Whether a calendar day (YYYY-MM-DD) is a working day. */
export function isWorkingDay(day: string, workingDays: WorkingDays): boolean {
  return workingDays.includes(isoWeekday(Date.parse(`${day}T00:00:00Z`)));
}

/** How many working days there are from `from` to `to`, both included. */
export function workingDaysBetween(from: string, to: string, workingDays: WorkingDays): number {
  let count = 0;
  for (let time = Date.parse(`${from}T00:00:00Z`), end = Date.parse(`${to}T00:00:00Z`); time <= end; time += DAY_MS) {
    if (workingDays.includes(isoWeekday(time))) count += 1;
  }
  return count;
}

/** Working milliseconds between two instants, counting UTC calendar days. */
function workingTime(from: number, to: number, workingDays: WorkingDays): number {
  let total = 0;
  for (let start = Math.floor(from / DAY_MS) * DAY_MS; start < to; start += DAY_MS) {
    if (!workingDays.includes(isoWeekday(start))) continue;
    total += Math.max(0, Math.min(to, start + DAY_MS) - Math.max(from, start));
  }
  return total;
}

/**
 * The share of the working time from `start` to `end` that has passed at `at` (0–1). A span with no
 * working time at all falls back to plain time.
 */
export function workingShare(start: number, at: number, end: number, workingDays: WorkingDays): number {
  const total = workingTime(start, end, workingDays);
  if (total === 0) return (at - start) / (end - start);
  return workingTime(start, Math.min(at, end), workingDays) / total;
}
