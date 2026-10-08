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
  /** The team's usage of this provider in the cycle so far, at API prices. */
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
    return { provider: entry.provider, name, monthlyCostUSD: Math.round(cost * 100) / 100, renewalDay: day };
  });
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
 * Each plan against the team's usage of its provider in its current cycle, counted like the
 * leaderboard (shared accounts once). Several plans of one provider split its value by cost.
 */
export async function planReports(db: Queryable, teamID: string, plans: PlanRow[], today: string): Promise<PlanReport[]> {
  if (plans.length === 0) return [];
  const cycles = plans.map((plan) => currentCycle(plan.renewalDay, today));
  const earliest = cycles.reduce((min, cycle) => (cycle.from < min ? cycle.from : min), today);
  const usage = await teamUsage(db, teamID, earliest, today, { models: false });
  const days = [...usage.days, ...usage.sharedDays];
  const providerCost = new Map<string, number>();
  for (const plan of plans) providerCost.set(plan.provider, (providerCost.get(plan.provider) ?? 0) + plan.monthlyCostUSD);

  return plans.map((plan, index) => {
    const cycle = cycles[index]!;
    const providerValue = days
      .filter((row) => row.provider === plan.provider && row.day >= cycle.from && row.day <= today)
      .reduce((sum, row) => sum + row.cost, 0);
    const share = plan.monthlyCostUSD / providerCost.get(plan.provider)!;
    const value = providerValue * share;
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
