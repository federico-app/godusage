import type { Queryable } from "./db";
import { badRequest, isRecord, requireName } from "./http";
import { daysBetween } from "./stats";
import { teamUsage } from "./teamUsage";
import { addDays } from "./usagePayload";

export const MAX_PLANS = 30;
const MAX_MONTHLY_COST = 100_000;
const PROVIDER_PATTERN = /^[a-z0-9][a-z0-9-]{0,39}$/;

export interface PlanInput {
  provider: string;
  name: string;
  monthlyCostUSD: number;
  renewalDay: number;
  /** The members the plan covers. Null covers every member. */
  memberIDs: string[] | null;
}

export interface PlanRow extends PlanInput {
  id: string;
}

export interface Cycle {
  /** The last renewal on or before today. */
  from: string;
  /** The day before the next renewal. */
  to: string;
  daysElapsed: number;
  daysTotal: number;
  daysLeft: number;
}

export interface PlanReport extends PlanRow {
  cycle: Cycle;
  /** The covered members' usage of this provider in the cycle so far, at API prices. */
  valueUSD: number;
  /** `valueUSD` stretched over the whole cycle at the current pace. */
  projectedValueUSD: number;
  /** Value per dollar paid (projected), e.g. 9.2 means $9.20 of API value per $1. */
  projectedMultiple: number;
  /** Projected to be worth less than it costs. */
  underused: boolean;
}

/** Validates the owner's plan list (the system boundary). */
export function parsePlans(body: Record<string, unknown>): PlanInput[] {
  if (!Array.isArray(body.plans)) throw badRequest("plans must be an array.");
  if (body.plans.length > MAX_PLANS) throw badRequest(`At most ${MAX_PLANS} plans per team.`);
  return body.plans.map((entry) => {
    if (!isRecord(entry)) throw badRequest("Each plan must be an object.");
    if (typeof entry.provider !== "string" || !PROVIDER_PATTERN.test(entry.provider)) throw badRequest("Invalid provider id.");
    const name = requireName(entry.name, "name", 60);
    const cost = entry.monthlyCostUSD;
    if (typeof cost !== "number" || !Number.isFinite(cost) || cost <= 0 || cost > MAX_MONTHLY_COST) {
      throw badRequest("monthlyCostUSD must be a positive number.");
    }
    const day = entry.renewalDay;
    if (typeof day !== "number" || !Number.isInteger(day) || day < 1 || day > 31) throw badRequest("renewalDay must be 1 to 31.");
    return { provider: entry.provider, name, monthlyCostUSD: Math.round(cost * 100) / 100, renewalDay: day, memberIDs: parseMemberIDs(entry.memberIDs) };
  });
}

/** Missing or null covers everyone; otherwise a non-empty list of distinct ids. */
function parseMemberIDs(value: unknown): string[] | null {
  if (value === undefined || value === null) return null;
  if (!Array.isArray(value) || !value.every((id) => typeof id === "string" && id.length > 0 && id.length <= 64)) {
    throw badRequest("memberIDs must be a list of member ids.");
  }
  if (value.length === 0) throw badRequest("A plan must cover at least one member.");
  return [...new Set(value as string[])];
}

/** Whether `plan` covers `userID`. */
export function covers(plan: PlanInput, userID: string): boolean {
  return plan.memberIDs === null || plan.memberIDs.includes(userID);
}

/** A renewal on day 31 falls on the last day of shorter months. */
function renewalIn(year: number, month: number, day: number): string {
  const last = new Date(Date.UTC(year, month + 1, 0)).getUTCDate();
  return new Date(Date.UTC(year, month, Math.min(day, last))).toISOString().slice(0, 10);
}

/** The billing cycle that contains `today`. */
export function currentCycle(renewalDay: number, today: string): Cycle {
  const year = Number(today.slice(0, 4));
  const month = Number(today.slice(5, 7)) - 1;
  const thisMonth = renewalIn(year, month, renewalDay);
  const from = thisMonth <= today ? thisMonth : renewalIn(year, month - 1, renewalDay);
  const fromMonth = Number(from.slice(5, 7)) - 1;
  const fromYear = Number(from.slice(0, 4));
  const next = renewalIn(fromYear, fromMonth + 1, renewalDay);
  const to = addDays(next, -1);
  const daysTotal = daysBetween(from, next);
  const daysElapsed = daysBetween(from, today) + 1;
  return { from, to, daysElapsed, daysTotal, daysLeft: daysTotal - daysElapsed };
}

/**
 * Each plan against its covered members' usage of its provider in its current cycle, counted like
 * the leaderboard (shared accounts once). A shared account counts when any member who shares it is
 * covered. Several plans of one provider split their common usage by cost.
 */
export async function planReports(db: Queryable, teamID: string, plans: PlanRow[], today: string): Promise<PlanReport[]> {
  if (plans.length === 0) return [];
  const cycles = plans.map((plan) => currentCycle(plan.renewalDay, today));
  const earliest = cycles.reduce((min, cycle) => (cycle.from < min ? cycle.from : min), today);
  const usage = await teamUsage(db, teamID, earliest, today, { models: false });
  const sharers = new Map<string, string[]>();
  for (const row of usage.sharedMembers) sharers.set(row.account_key, [...(sharers.get(row.account_key) ?? []), row.user_id]);
  const days = [
    ...usage.days.map((row) => ({ ...row, users: [row.user_id] })),
    ...usage.sharedDays.map((row) => ({ ...row, users: sharers.get(row.account_key) ?? [] })),
  ];
  const coveredDays = (plan: PlanRow, from: string) =>
    days.filter((row) => row.provider === plan.provider && row.day >= from && row.day <= today && row.users.some((user) => covers(plan, user)));

  return plans.map((plan, index) => {
    const cycle = cycles[index]!;
    // Split each day's usage between the plans of the provider that cover it, by cost.
    const value = coveredDays(plan, cycle.from).reduce((sum, row) => {
      const sharing = plans.filter((other) => other.provider === plan.provider && row.users.some((user) => covers(other, user)));
      const cost = sharing.reduce((total, other) => total + other.monthlyCostUSD, 0);
      return sum + (row.cost * plan.monthlyCostUSD) / cost;
    }, 0);
    const projected = (value / cycle.daysElapsed) * cycle.daysTotal;
    const multiple = projected / plan.monthlyCostUSD;
    return {
      ...plan,
      cycle,
      valueUSD: round2(value),
      projectedValueUSD: round2(projected),
      projectedMultiple: Math.round(multiple * 100) / 100,
      underused: multiple < 1,
    };
  });
}

function round2(value: number): number {
  return Math.round(value * 100) / 100;
}
