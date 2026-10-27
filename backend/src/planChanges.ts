import { badRequest, isRecord, requireName } from "./http";
import { addDays, isValidDay } from "./usagePayload";

export const MAX_CHANGES = 100;
export const MAX_MONTHLY_COST = 100_000;
const MAX_IGNORED = 20;
const LABEL_MAX = 60;

/** What a plan is called and costs. */
export interface Terms {
  name: string;
  monthlyCostUSD: number;
}

/** From `effectiveFrom` (inclusive) the plan has these terms. */
export interface PlanChange extends Terms {
  effectiveFrom: string;
}

/** A change as the API shows it: the terms it moves from, too. */
export interface WireChange extends PlanChange {
  previousName: string;
  previousMonthlyCostUSD: number;
}

/** A plan's price history: its terms before the first change, then its changes in date order. */
export interface PriceHistory {
  base: Terms;
  changes: PlanChange[];
}

/** One stretch of a cycle at one price. */
export interface Period extends Terms {
  from: string;
  to: string;
  days: number;
}

/** The plan's terms on `day`. */
export function termsOn(history: PriceHistory, day: string): Terms {
  let terms = history.base;
  for (const change of history.changes) {
    if (change.effectiveFrom > day) break;
    terms = change;
  }
  return { name: terms.name, monthlyCostUSD: terms.monthlyCostUSD };
}

/** Each change with the terms it replaces. */
export function wireChanges(history: PriceHistory): WireChange[] {
  let previous = history.base;
  return history.changes.map((change) => {
    const wire = { ...change, previousName: previous.name, previousMonthlyCostUSD: previous.monthlyCostUSD };
    previous = change;
    return wire;
  });
}

/** The stretches of the cycle `from`…`to` (inclusive) at one price each, in order. */
export function cyclePeriods(history: PriceHistory, from: string, to: string): Period[] {
  const starts = [from, ...history.changes.map((change) => change.effectiveFrom).filter((day) => day > from && day <= to)];
  return starts.map((start, index) => {
    const end = index + 1 < starts.length ? addDays(starts[index + 1]!, -1) : to;
    return { ...termsOn(history, start), from: start, to: end, days: dayCount(start, end) };
  });
}

function dayCount(from: string, to: string): number {
  return Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000) + 1;
}

export function parseCost(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0 || value > MAX_MONTHLY_COST) {
    throw badRequest(`${field} must be a positive number.`);
  }
  return Math.round(value * 100) / 100;
}

/**
 * A plan's price history from the API's shape (the system boundary): `name`/`monthlyCostUSD` are the
 * terms in effect `today`, and `changes` lists every change with the terms it moves to. The first
 * change's `previousName`/`previousMonthlyCostUSD` give the terms before it; later ones' are derived.
 * The terms in effect today always win, so editing a plan's name or price edits its current terms.
 */
export function parsePriceHistory(current: Terms, value: unknown, today: string): PriceHistory {
  if (value === undefined || value === null) return { base: current, changes: [] };
  if (!Array.isArray(value)) throw badRequest("changes must be an array.");
  if (value.length > MAX_CHANGES) throw badRequest(`At most ${MAX_CHANGES} changes per plan.`);
  const changes = value.map((entry): PlanChange => {
    if (!isRecord(entry)) throw badRequest("Each change must be an object.");
    if (!isValidDay(entry.effectiveFrom)) throw badRequest("effectiveFrom must be a YYYY-MM-DD date.");
    return { effectiveFrom: entry.effectiveFrom, name: requireName(entry.name, "name", LABEL_MAX), monthlyCostUSD: parseCost(entry.monthlyCostUSD, "monthlyCostUSD") };
  });
  for (let index = 1; index < changes.length; index += 1) {
    if (changes[index]!.effectiveFrom <= changes[index - 1]!.effectiveFrom) throw badRequest("Changes must be in date order, one per day.");
  }
  if (changes.length === 0) return { base: current, changes };
  const first = value[0] as Record<string, unknown>;
  let base: Terms = {
    name: requireName(first.previousName, "previousName", LABEL_MAX),
    monthlyCostUSD: parseCost(first.previousMonthlyCostUSD, "previousMonthlyCostUSD"),
  };
  const inEffect = changes.filter((change) => change.effectiveFrom <= today).length - 1;
  if (inEffect >= 0) changes[inEffect] = { ...changes[inEffect]!, ...current };
  else base = current;
  return { base, changes };
}

/** The linked detected-plan label: missing or null for none. */
export function parseDetectedPlan(value: unknown): string | null {
  if (value === undefined || value === null) return null;
  return requireName(value, "detectedPlan", LABEL_MAX);
}

/** The detected-plan labels the owner ignores for a plan, deduplicated. */
export function parseIgnoredPlans(value: unknown): string[] {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value)) throw badRequest("ignoredPlans must be a list of plan names.");
  if (value.length > MAX_IGNORED) throw badRequest(`At most ${MAX_IGNORED} ignored plans per plan.`);
  const labels = value.map((label) => requireName(label, "ignoredPlans", LABEL_MAX));
  return labels.filter((label, index) => labels.findIndex((other) => sameLabel(other, label)) === index);
}

/** Detected labels compare without case or surrounding space. */
export function sameLabel(lhs: string, rhs: string): boolean {
  return lhs.trim().toLowerCase() === rhs.trim().toLowerCase();
}
