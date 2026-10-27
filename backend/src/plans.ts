import type { Queryable } from "./db";
import { badRequest, isRecord, requireName } from "./http";
import {
  cyclePeriods, parseCost, parseDetectedPlan, parseIgnoredPlans, parsePriceHistory, termsOn, wireChanges,
  type PriceHistory, type Terms, type WireChange,
} from "./planChanges";
import { planMismatches, type Detection, type Mismatch } from "./planDetection";
import { daysBetween } from "./stats";
import { teamUsage } from "./teamUsage";
import { addDays } from "./usagePayload";

export const MAX_PLANS = 30;
const PROVIDER_PATTERN = /^[a-z0-9][a-z0-9-]{0,39}$/;

export interface PlanInput extends PriceHistory {
  provider: string;
  renewalDay: number;
  /** The members the plan covers. Null covers every member. */
  memberIDs: string[] | null;
  /** The detected plan label this plan stands for, e.g. "Max 20x". */
  detectedPlan: string | null;
  /** Detected labels the owner chose not to be told about for this plan. */
  ignoredPlans: string[];
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

/** One stretch of the cycle at one price, with its share of the cycle's cost and value. */
export interface ReportPeriod extends Terms {
  from: string;
  to: string;
  costUSD: number;
  valueUSD: number;
}

export interface PlanReport extends Terms {
  id: string;
  provider: string;
  renewalDay: number;
  memberIDs: string[] | null;
  detectedPlan: string | null;
  ignoredPlans: string[];
  /** Every price change, past and future, with the terms each replaces. */
  changes: WireChange[];
  cycle: Cycle;
  /** What the cycle costs: each price prorated by the days it applies in the cycle. */
  cycleCostUSD: number;
  /** The cycle at one price per stretch; more than one when a change falls inside it. */
  periods: ReportPeriod[];
  /** The covered members' usage of this provider in the cycle so far, at API prices. */
  valueUSD: number;
  /** `valueUSD` stretched over the whole cycle at the current pace. */
  projectedValueUSD: number;
  /** Projected value per dollar the cycle costs, e.g. 9.2 means $9.20 of API value per $1. */
  projectedMultiple: number;
  /** Projected to be worth less than it costs. */
  underused: boolean;
  /** Covered members whose Mac detects another plan. Shown to owners only. */
  mismatches: Mismatch[];
}

/**
 * Validates the owner's plan list (the system boundary). `name` and `monthlyCostUSD` are the terms in
 * effect `today`; `changes` carries the price history (see `parsePriceHistory`).
 */
export function parsePlans(body: Record<string, unknown>, today: string): PlanInput[] {
  if (!Array.isArray(body.plans)) throw badRequest("plans must be an array.");
  if (body.plans.length > MAX_PLANS) throw badRequest(`At most ${MAX_PLANS} plans per team.`);
  return body.plans.map((entry) => {
    if (!isRecord(entry)) throw badRequest("Each plan must be an object.");
    if (typeof entry.provider !== "string" || !PROVIDER_PATTERN.test(entry.provider)) throw badRequest("Invalid provider id.");
    const current = { name: requireName(entry.name, "name", 60), monthlyCostUSD: parseCost(entry.monthlyCostUSD, "monthlyCostUSD") };
    const day = entry.renewalDay;
    if (typeof day !== "number" || !Number.isInteger(day) || day < 1 || day > 31) throw badRequest("renewalDay must be 1 to 31.");
    return {
      provider: entry.provider,
      renewalDay: day,
      memberIDs: parseMemberIDs(entry.memberIDs),
      ...parsePriceHistory(current, entry.changes, today),
      detectedPlan: parseDetectedPlan(entry.detectedPlan),
      ignoredPlans: parseIgnoredPlans(entry.ignoredPlans),
    };
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
export function covers(plan: { memberIDs: string[] | null }, userID: string): boolean {
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
 * covered. Several plans of one provider split their common usage by what each costs that day. A
 * cycle with a price change costs each price for the days it applies (daily rate = monthly price /
 * the cycle's days), and its usage counts against the price in effect the day it was spent.
 */
export async function planReports(db: Queryable, teamID: string, plans: PlanRow[], today: string, detections: Detection[]): Promise<PlanReport[]> {
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

  return plans.map((plan, index) => {
    const cycle = cycles[index]!;
    const periods = cyclePeriods(plan, cycle.from, cycle.to);
    const values = periods.map(() => 0);
    for (const row of days) {
      if (row.provider !== plan.provider || row.day < cycle.from || row.day > today || !row.users.some((user) => covers(plan, user))) continue;
      // Split the day's usage between the plans of the provider that cover it, by that day's prices.
      const sharing = plans.filter((other) => other.provider === plan.provider && row.users.some((user) => covers(other, user)));
      const cost = sharing.reduce((total, other) => total + termsOn(other, row.day).monthlyCostUSD, 0);
      const period = periods.findIndex((stretch) => row.day >= stretch.from && row.day <= stretch.to);
      values[period] = values[period]! + (row.cost * termsOn(plan, row.day).monthlyCostUSD) / cost;
    }
    const value = values.reduce((sum, amount) => sum + amount, 0);
    const periodCost = (stretch: { monthlyCostUSD: number; days: number }) => (stretch.monthlyCostUSD * stretch.days) / cycle.daysTotal;
    const cycleCost = periods.reduce((sum, stretch) => sum + periodCost(stretch), 0);
    const projected = (value / cycle.daysElapsed) * cycle.daysTotal;
    const multiple = projected / cycleCost;
    return {
      id: plan.id,
      provider: plan.provider,
      ...termsOn(plan, today),
      renewalDay: plan.renewalDay,
      memberIDs: plan.memberIDs,
      detectedPlan: plan.detectedPlan,
      ignoredPlans: plan.ignoredPlans,
      changes: wireChanges(plan),
      cycle,
      cycleCostUSD: round2(cycleCost),
      periods: periods.map((stretch, at) => ({
        name: stretch.name,
        monthlyCostUSD: stretch.monthlyCostUSD,
        from: stretch.from,
        to: stretch.to,
        costUSD: round2(periodCost(stretch)),
        valueUSD: round2(values[at]!),
      })),
      valueUSD: round2(value),
      projectedValueUSD: round2(projected),
      projectedMultiple: Math.round(multiple * 100) / 100,
      underused: multiple < 1,
      mismatches: planMismatches(plan, (userID) => covers(plan, userID), cycle.from, detections),
    };
  });
}

function round2(value: number): number {
  return Math.round(value * 100) / 100;
}
