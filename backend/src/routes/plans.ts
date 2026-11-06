import type { Handler } from "../context";
import { badRequest, forbidden, json, notFound, nowISO, readJSONObject } from "../http";
import type { PlanPace } from "../livePace";
import { covers, keepUnsentFields, parsePlans, planReports, type PlanReport, type PlanRow } from "../plans";
import { termsOn } from "../planChanges";
import { teamQuotaReadings, teamQuotaWindows } from "../quota";
import { dayBounds, unionHours } from "../livePace";
import { loadMemberHours, parseTimeZone } from "../schedules";
import { DEFAULT_HISTORY_WEEKS, MAX_HISTORY_WEEKS, planHistory, type AccountWeek } from "../quotaHistory";
import { addDays } from "../usagePayload";
import { teamDetections, type Detection } from "../planDetection";
import { requireUser } from "../session";
import type { Env } from "../context";
import type { Queryable } from "../db";
import { cachedTeamResult } from "../teamCache";
import { viewerToday } from "./challenges";
import { parseWorkingDays, storedWorkingDays, type WorkingDays } from "../workingDays";

type Role = "owner" | "member";

interface Membership {
  role: Role;
  /** False for an owner who left themself out of the team's usage and plans. */
  countsUsage: boolean;
}

async function membership(db: Queryable, teamID: string, userID: string): Promise<Membership> {
  const row = await db.first<{ role: Role; counts_usage: boolean }>("SELECT role, counts_usage FROM team_members WHERE team_id = $1 AND user_id = $2", [
    teamID,
    userID,
  ]);
  if (!row) throw notFound("Team not found.");
  return { role: row.role, countsUsage: row.counts_usage };
}

async function loadPlans(db: Queryable, teamID: string): Promise<PlanRow[]> {
  const [rows, changes] = await Promise.all([
    db.query<{
      id: string; provider: string; name: string; monthly_cost_usd: number; renewal_day: number; member_ids: string | null;
      detected_plan: string | null; ignored_plans: string | null;
    }>(
      `SELECT id, provider, name, monthly_cost_usd, renewal_day, member_ids, detected_plan, ignored_plans
       FROM team_plans WHERE team_id = $1 ORDER BY position`,
      [teamID],
    ),
    db.query<{ plan_id: string; effective_from: string; name: string; monthly_cost_usd: number }>(
      `SELECT c.plan_id, c.effective_from, c.name, c.monthly_cost_usd FROM team_plan_changes c
       JOIN team_plans p ON p.id = c.plan_id WHERE p.team_id = $1 ORDER BY c.plan_id, c.effective_from`,
      [teamID],
    ),
  ]);
  return rows.map((row) => ({
    id: row.id,
    provider: row.provider,
    base: { name: row.name, monthlyCostUSD: row.monthly_cost_usd },
    changes: changes
      .filter((change) => change.plan_id === row.id)
      .map((change) => ({ effectiveFrom: change.effective_from, name: change.name, monthlyCostUSD: change.monthly_cost_usd })),
    renewalDay: row.renewal_day,
    memberIDs: row.member_ids === null ? null : (JSON.parse(row.member_ids) as string[]),
    detectedPlan: row.detected_plan,
    ignoredPlans: row.ignored_plans === null ? [] : (JSON.parse(row.ignored_plans) as string[]),
  }));
}

async function loadWorkingDays(db: Queryable, teamID: string): Promise<WorkingDays> {
  const row = await db.first<{ working_days: string }>("SELECT working_days FROM teams WHERE id = $1", [teamID]);
  return storedWorkingDays(row?.working_days ?? null);
}

/** Readings this old still tell the pace of the last working hour (see livePace.ts). */
const READINGS_LOOKBACK_MS = 36 * 3_600_000;

async function report(db: Queryable, teamID: string, today: string, now: Date, timeZone: string | null = null) {
  const [detections, workingDays, members] = await Promise.all([
    teamDetections(db, teamID),
    loadWorkingDays(db, teamID),
    db.query<{ user_id: string; display_name: string }>(
      "SELECT m.user_id, u.display_name FROM team_members m JOIN users u ON u.id = m.user_id WHERE m.team_id = $1",
      [teamID],
    ),
  ]);
  // Live Pace needs the viewer's time zone; apps from before it send none and get no pace.
  const pace = timeZone === null
    ? null
    : {
        timeZone,
        teamDays: workingDays,
        readings: await teamQuotaReadings(db, teamID, new Date(now.getTime() - READINGS_LOOKBACK_MS).toISOString()),
        hours: await loadMemberHours(db, members.map((member) => member.user_id)),
      };
  const plans = await planReports(db, teamID, await loadPlans(db, teamID), today, detections, now, workingDays, pace);
  // Each member's working hours today, in the viewer's day, for the viewer's own (see `forViewer`).
  const day = timeZone === null ? null : dayBounds(today, timeZone);
  const hoursToday: Record<string, { from: string; to: string }[]> = {};
  if (pace !== null && day !== null) {
    for (const member of members) {
      hoursToday[member.user_id] = unionHours([member.user_id], pace, day.from, day.to)
        .map((interval) => ({ from: new Date(interval.from).toISOString(), to: new Date(interval.to).toISOString() }));
    }
  }
  const names = Object.fromEntries(members.map((member) => [member.user_id, member.display_name]));
  const totals = plans.reduce(
    (sum, plan) => ({
      monthlyCostUSD: sum.monthlyCostUSD + plan.monthlyCostUSD,
      cycleCostUSD: sum.cycleCostUSD + plan.cycleCostUSD,
      valueUSD: sum.valueUSD + plan.valueUSD,
      projectedValueUSD: sum.projectedValueUSD + plan.projectedValueUSD,
    }),
    { monthlyCostUSD: 0, cycleCostUSD: 0, valueUSD: 0, projectedValueUSD: 0 },
  );
  const round = (value: number) => Math.round(value * 100) / 100;
  // The quota share across the plans that have one, each weighted by what its cycle costs.
  const metered = plans.filter((plan) => plan.quota !== null);
  const meteredCost = metered.reduce((sum, plan) => sum + plan.cycleCostUSD, 0);
  const quota =
    metered.length === 0 || meteredCost === 0
      ? null
      : {
          usedPercent: Math.round((metered.reduce((sum, plan) => sum + plan.quota!.usedPercent * plan.cycleCostUSD, 0) / meteredCost) * 10) / 10,
          cycleCostUSD: round(meteredCost),
          wastedUSD: round(metered.reduce((sum, plan) => sum + plan.quota!.wastedUSD, 0)),
        };
  return {
    plans,
    totals: {
      monthlyCostUSD: round(totals.monthlyCostUSD),
      cycleCostUSD: round(totals.cycleCostUSD),
      valueUSD: round(totals.valueUSD),
      projectedValueUSD: round(totals.projectedValueUSD),
      quota,
    },
    detections,
    workingDays,
    hoursToday,
    names,
  };
}

/**
 * The cached report is the same for every member: this marks the plans that cover the viewer, and
 * keeps the members' detected plans (and the mismatches they cause) for owners only. A plan never
 * covers a viewer who doesn't count toward the team.
 */
function forViewer(
  result: {
    plans: PlanReport[]; totals: object; detections: Detection[]; workingDays: WorkingDays;
    hoursToday: Record<string, { from: string; to: string }[]>; names: Record<string, string>;
  },
  userID: string,
  viewer: Membership,
) {
  const owner = viewer.role === "owner";
  return {
    plans: result.plans.map((plan) => ({
      ...plan,
      budget: plan.budget === null ? null : {
        ...plan.budget,
        perAccount: withAccountNames(plan.budget.perAccount, userID, result.names),
        pace: withSharers(plan.budget.pace, userID, result.names),
      },
      mismatches: owner ? plan.mismatches : [],
      includesYou: viewer.countsUsage && covers(plan, userID),
    })),
    yourHours: result.hoursToday[userID] ?? null,
    totals: result.totals,
    detectedPlans: owner ? result.detections.map(({ userID: id, provider, plan, detectedAt, detectedOn }) => ({ userID: id, provider, plan, detectedAt, detectedOn })) : [],
    workingDays: result.workingDays,
    canEdit: owner,
  };
}

/** The other people whose working hours a plan's pace counts, by name, in place of their ids. */
function withSharers(pace: PlanPace | null, userID: string, names: Record<string, string>) {
  if (pace === null) return null;
  const { people, ...rest } = pace;
  return { ...rest, sharedWith: people.filter((id) => id !== userID).map((id) => names[id] ?? "Someone") };
}

/** Who reads each of a plan's accounts, by name in place of their ids: "You" first, then the others. */
function withAccountNames(accounts: AccountWeek[], userID: string, names: Record<string, string>) {
  return accounts.map(({ people, ...rest }) => ({
    ...rest,
    people: [
      ...(people.includes(userID) ? ["You"] : []),
      ...people.filter((id) => id !== userID).map((id) => names[id] ?? "Someone").sort((a, b) => a.localeCompare(b)),
    ],
  }));
}

/**
 * The plan report from the cache (see `teamCache.ts`), recomputed at most every 10 minutes and after
 * every new quota reading. Live Pace depends on the viewer's time zone, so each one has its own entry.
 */
function cachedReport(env: Pick<Env, "db" | "cache">, now: Date, teamID: string, today: string, timeZone: string | null) {
  // The key names the report's shape: a report cached before `perAccount` must not be served.
  return cachedTeamResult(env.cache, now, teamID, `plans|v2|${today}|${timeZone ?? ""}`, 10 * 60_000, () => report(env.db, teamID, today, now, timeZone));
}

/** GET /v1/teams/:teamID/plans?today=&tz= — the team's plans and their report, for any member. */
export const getPlans: Handler = async ({ request, env, url, params, deps }) => {
  const user = await requireUser(request, env.db);
  const viewer = await membership(env.db, params.teamID!, user.id);
  const result = await cachedReport(env, deps.now(), params.teamID!, viewerToday(url, deps.now()), parseTimeZone(url.searchParams.get("tz")));
  return json(forViewer(result.value, user.id, viewer));
};

/**
 * The plans' last `weeks` weekly windows of quota use (see quotaHistory.ts), the same for every member.
 * Plan ids change on every save, so each plan also carries its provider and current name.
 */
async function history(db: Queryable, teamID: string, today: string, now: Date, weeks: number) {
  const [plans, workingDays] = await Promise.all([loadPlans(db, teamID), loadWorkingDays(db, teamID)]);
  // The open window plus `weeks` - 1 before it, with a week to spare for windows cut short by a reset.
  const rows = plans.length === 0 ? [] : await teamQuotaWindows(db, teamID, addDays(today, -7 * weeks));
  return {
    plans: plans.map((plan) => ({
      id: plan.id,
      provider: plan.provider,
      name: termsOn(plan, today).name,
      weeks: planHistory(rows, { provider: plan.provider, covered: (userID) => covers(plan, userID) }, today, now, weeks, workingDays),
    })),
    workingDays,
  };
}

/** GET /v1/teams/:teamID/plans/history?today=&weeks= — the plans' weekly history, for any member. */
export const getPlanHistory: Handler = async ({ request, env, url, params, deps }) => {
  const user = await requireUser(request, env.db);
  await membership(env.db, params.teamID!, user.id);
  const requested = url.searchParams.get("weeks");
  const weeks = requested === null ? DEFAULT_HISTORY_WEEKS : Number(requested);
  if (!Number.isInteger(weeks) || weeks < 1 || weeks > MAX_HISTORY_WEEKS) throw badRequest(`weeks must be a whole number from 1 to ${MAX_HISTORY_WEEKS}.`);
  const now = deps.now();
  const today = viewerToday(url, now);
  const result = await cachedTeamResult(env.cache, now, params.teamID!, `plans|history|${today}|${weeks}`, 10 * 60_000, () => history(env.db, params.teamID!, today, now, weeks));
  return json(result.value);
};

/**
 * PUT /v1/teams/:teamID/plans?today= { plans: [...], workingDays? } — replaces the list, price
 * histories included, and the working days when sent. Owner only.
 */
export const putPlans: Handler = async ({ request, env, url, params, deps }) => {
  const user = await requireUser(request, env.db);
  const teamID = params.teamID!;
  const viewer = await membership(env.db, teamID, user.id);
  if (viewer.role !== "owner") throw forbidden("Only team owners can change plans.");
  const today = viewerToday(url, deps.now());
  const body = await readJSONObject(request);
  const parsed = parsePlans(body, today);
  const workingDays = parseWorkingDays(body.workingDays);
  const members = await env.db.query<{ user_id: string }>("SELECT user_id FROM team_members WHERE team_id = $1 AND counts_usage", [teamID]);
  const memberIDs = new Set(members.map((row) => row.user_id));
  if (parsed.some((plan) => plan.memberIDs?.some((id) => !memberIDs.has(id)))) {
    throw badRequest("A plan covers someone who is not in the team, or who doesn't count toward it.");
  }
  const updatedAt = nowISO();
  await env.db.transaction(async (tx) => {
    // Fields an older app leaves out keep their stored values (see `keepUnsentFields`).
    const plans = keepUnsentFields(parsed, await loadPlans(tx, teamID), today);
    if (workingDays !== null) await tx.run("UPDATE teams SET working_days = $1 WHERE id = $2", [JSON.stringify(workingDays), teamID]);
    // Changes go with their plans (ON DELETE CASCADE).
    await tx.run("DELETE FROM team_plans WHERE team_id = $1", [teamID]);
    for (const [position, plan] of plans.entries()) {
      const id = crypto.randomUUID();
      await tx.run(
        `INSERT INTO team_plans (id, team_id, provider, name, monthly_cost_usd, renewal_day, member_ids, position, updated_at, detected_plan, ignored_plans)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)`,
        [
          id, teamID, plan.provider, plan.base.name, plan.base.monthlyCostUSD, plan.renewalDay,
          plan.memberIDs === null ? null : JSON.stringify(plan.memberIDs), position, updatedAt,
          plan.detectedPlan, plan.ignoredPlans.length === 0 ? null : JSON.stringify(plan.ignoredPlans),
        ],
      );
      if (plan.changes.length > 0) {
        await tx.run(
          `INSERT INTO team_plan_changes (plan_id, effective_from, name, monthly_cost_usd)
           SELECT $1, r."effectiveFrom", r.name, r."monthlyCostUSD"
           FROM jsonb_to_recordset($2::jsonb) AS r("effectiveFrom" text, name text, "monthlyCostUSD" double precision)`,
          [id, JSON.stringify(plan.changes)],
        );
      }
    }
  });
  await env.cache.forgetTeams([teamID], "plans|");
  const fresh = await report(env.db, teamID, today, deps.now(), parseTimeZone(url.searchParams.get("tz")));
  return json(forViewer(fresh, user.id, viewer));
};
