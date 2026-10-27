import type { Handler } from "../context";
import { badRequest, forbidden, json, notFound, nowISO, readJSONObject } from "../http";
import { covers, keepUnsentFields, parsePlans, planReports, type PlanReport, type PlanRow } from "../plans";
import { teamDetections, type Detection } from "../planDetection";
import { requireUser } from "../session";
import type { Env } from "../context";
import type { Queryable } from "../db";
import { cachedTeamResult } from "../teamCache";
import { viewerToday } from "./challenges";

type Role = "owner" | "member";

async function memberRole(db: Queryable, teamID: string, userID: string): Promise<Role> {
  const row = await db.first<{ role: Role }>("SELECT role FROM team_members WHERE team_id = $1 AND user_id = $2", [teamID, userID]);
  if (!row) throw notFound("Team not found.");
  return row.role;
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

async function report(db: Queryable, teamID: string, today: string) {
  const detections = await teamDetections(db, teamID);
  const plans = await planReports(db, teamID, await loadPlans(db, teamID), today, detections);
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
  return {
    plans,
    totals: {
      monthlyCostUSD: round(totals.monthlyCostUSD),
      cycleCostUSD: round(totals.cycleCostUSD),
      valueUSD: round(totals.valueUSD),
      projectedValueUSD: round(totals.projectedValueUSD),
    },
    detections,
  };
}

/**
 * The cached report is the same for every member: this marks the plans that cover the viewer, and
 * keeps the members' detected plans (and the mismatches they cause) for owners only.
 */
function forViewer(result: { plans: PlanReport[]; totals: object; detections: Detection[] }, userID: string, role: Role) {
  const owner = role === "owner";
  return {
    plans: result.plans.map((plan) => ({ ...plan, mismatches: owner ? plan.mismatches : [], includesYou: covers(plan, userID) })),
    totals: result.totals,
    detectedPlans: owner ? result.detections.map(({ userID: id, provider, plan, detectedAt, detectedOn }) => ({ userID: id, provider, plan, detectedAt, detectedOn })) : [],
    canEdit: owner,
  };
}

/** The plan report from the cache (see `teamCache.ts`), recomputed at most every 10 minutes. */
function cachedReport(env: Pick<Env, "db" | "cache">, now: Date, teamID: string, today: string) {
  return cachedTeamResult(env.cache, now, teamID, `plans|${today}`, 10 * 60_000, () => report(env.db, teamID, today));
}

/** GET /v1/teams/:teamID/plans?today= — the team's plans and their report, for any member. */
export const getPlans: Handler = async ({ request, env, url, params, deps }) => {
  const user = await requireUser(request, env.db);
  const role = await memberRole(env.db, params.teamID!, user.id);
  const result = await cachedReport(env, deps.now(), params.teamID!, viewerToday(url, deps.now()));
  return json(forViewer(result.value, user.id, role));
};

/**
 * PUT /v1/teams/:teamID/plans?today= { plans: [...] } — replaces the list, price histories included.
 * Owner only.
 */
export const putPlans: Handler = async ({ request, env, url, params, deps }) => {
  const user = await requireUser(request, env.db);
  const teamID = params.teamID!;
  const role = await memberRole(env.db, teamID, user.id);
  if (role !== "owner") throw forbidden("Only team owners can change plans.");
  const today = viewerToday(url, deps.now());
  const parsed = parsePlans(await readJSONObject(request), today);
  const members = await env.db.query<{ user_id: string }>("SELECT user_id FROM team_members WHERE team_id = $1", [teamID]);
  const memberIDs = new Set(members.map((row) => row.user_id));
  if (parsed.some((plan) => plan.memberIDs?.some((id) => !memberIDs.has(id)))) throw badRequest("A plan covers someone who is not in the team.");
  const updatedAt = nowISO();
  await env.db.transaction(async (tx) => {
    // Fields an older app leaves out keep their stored values (see `keepUnsentFields`).
    const plans = keepUnsentFields(parsed, await loadPlans(tx, teamID), today);
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
  const fresh = await report(env.db, teamID, today);
  return json(forViewer(fresh, user.id, "owner"));
};
