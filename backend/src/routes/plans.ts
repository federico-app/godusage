import type { Handler } from "../context";
import { badRequest, forbidden, json, notFound, nowISO, readJSONObject } from "../http";
import { covers, parsePlans, planReports, type PlanReport, type PlanRow } from "../plans";
import { requireUser } from "../session";
import { cachedTeamResult, forgetTeamCache, guardedWork, readGuard, type ReadGuard } from "../readGuard";
import { viewerToday } from "./challenges";

async function memberRole(db: D1Database, teamID: string, userID: string): Promise<"owner" | "member"> {
  const role = await db.prepare("SELECT role FROM team_members WHERE team_id = ? AND user_id = ?").bind(teamID, userID).first<"owner" | "member">("role");
  if (!role) throw notFound("Team not found.");
  return role;
}

async function loadPlans(db: D1Database, teamID: string): Promise<PlanRow[]> {
  const rows = await db
    .prepare("SELECT id, provider, name, monthly_cost_usd, renewal_day, member_ids FROM team_plans WHERE team_id = ? ORDER BY position")
    .bind(teamID)
    .all<{ id: string; provider: string; name: string; monthly_cost_usd: number; renewal_day: number; member_ids: string | null }>();
  return rows.results.map((row) => ({
    id: row.id,
    provider: row.provider,
    name: row.name,
    monthlyCostUSD: row.monthly_cost_usd,
    renewalDay: row.renewal_day,
    memberIDs: row.member_ids === null ? null : (JSON.parse(row.member_ids) as string[]),
  }));
}

async function report(db: D1Database, teamID: string, today: string) {
  const plans = await planReports(db, teamID, await loadPlans(db, teamID), today);
  const totals = plans.reduce(
    (sum, plan) => ({
      monthlyCostUSD: sum.monthlyCostUSD + plan.monthlyCostUSD,
      valueUSD: sum.valueUSD + plan.valueUSD,
      projectedValueUSD: sum.projectedValueUSD + plan.projectedValueUSD,
    }),
    { monthlyCostUSD: 0, valueUSD: 0, projectedValueUSD: 0 },
  );
  const round = (value: number) => Math.round(value * 100) / 100;
  return {
    plans,
    totals: { monthlyCostUSD: round(totals.monthlyCostUSD), valueUSD: round(totals.valueUSD), projectedValueUSD: round(totals.projectedValueUSD) },
  };
}

/** Marks the plans that cover the viewer; the cached report is the same for every member. */
function forViewer(plans: PlanReport[], userID: string) {
  return plans.map((plan) => ({ ...plan, includesYou: covers(plan, userID) }));
}

/** The plan report from the cache (see `readGuard.ts`), recomputed at most every 10 minutes. */
function cachedReport(guard: ReadGuard, teamID: string, today: string) {
  return cachedTeamResult(guard, teamID, `plans|${today}`, 10 * 60_000, (db) => report(db, teamID, today));
}

/** GET /v1/teams/:teamID/plans?today= — the team's plans and their report, for any member. */
export const getPlans: Handler = async ({ request, env, url, params, deps }) => {
  const user = await requireUser(request, env.DB);
  const role = await memberRole(env.DB, params.teamID!, user.id);
  const result = await cachedReport(readGuard(env, deps.now()), params.teamID!, viewerToday(url, deps.now()));
  return json({ ...result.value, plans: forViewer(result.value.plans, user.id), canEdit: role === "owner", paused: result.paused });
};

/** PUT /v1/teams/:teamID/plans?today= { plans: [...] } — replaces the list. Owner only. */
export const putPlans: Handler = async ({ request, env, url, params, deps }) => {
  const user = await requireUser(request, env.DB);
  const teamID = params.teamID!;
  const role = await memberRole(env.DB, teamID, user.id);
  if (role !== "owner") throw forbidden("Only team owners can change plans.");
  const plans = parsePlans(await readJSONObject(request));
  const members = await env.DB.prepare("SELECT user_id FROM team_members WHERE team_id = ?").bind(teamID).all<{ user_id: string }>();
  const memberIDs = new Set(members.results.map((row) => row.user_id));
  if (plans.some((plan) => plan.memberIDs?.some((id) => !memberIDs.has(id)))) throw badRequest("A plan covers someone who is not in the team.");
  const updatedAt = nowISO();
  await env.DB.batch([
    forgetTeamCache(env.DB, teamID, "plans|"),
    env.DB.prepare("DELETE FROM team_plans WHERE team_id = ?").bind(teamID),
    ...plans.map((plan, position) =>
      env.DB.prepare(
        "INSERT INTO team_plans (id, team_id, provider, name, monthly_cost_usd, renewal_day, member_ids, position, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      ).bind(
        crypto.randomUUID(), teamID, plan.provider, plan.name, plan.monthlyCostUSD, plan.renewalDay,
        plan.memberIDs === null ? null : JSON.stringify(plan.memberIDs), position, updatedAt,
      ),
    ),
  ]);
  const fresh = await guardedWork(readGuard(env, deps.now()), (db) => report(db, teamID, viewerToday(url, deps.now())));
  return json({ ...fresh, plans: forViewer(fresh.plans, user.id), canEdit: true, paused: false });
};
