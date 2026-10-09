import type { Handler } from "../context";
import { badRequest, forbidden, json, notFound, nowISO, readJSONObject } from "../http";
import { covers, parsePlans, planReports, type PlanReport, type PlanRow } from "../plans";
import { requireUser } from "../session";
import type { Env } from "../context";
import type { Queryable } from "../db";
import { cachedTeamResult } from "../teamCache";
import { viewerToday } from "./challenges";

async function memberRole(db: Queryable, teamID: string, userID: string): Promise<"owner" | "member"> {
  const row = await db.first<{ role: "owner" | "member" }>("SELECT role FROM team_members WHERE team_id = $1 AND user_id = $2", [teamID, userID]);
  if (!row) throw notFound("Team not found.");
  return row.role;
}

async function loadPlans(db: Queryable, teamID: string): Promise<PlanRow[]> {
  const rows = await db.query<{ id: string; provider: string; name: string; monthly_cost_usd: number; renewal_day: number; member_ids: string | null }>(
    "SELECT id, provider, name, monthly_cost_usd, renewal_day, member_ids FROM team_plans WHERE team_id = $1 ORDER BY position",
    [teamID],
  );
  return rows.map((row) => ({
    id: row.id,
    provider: row.provider,
    name: row.name,
    monthlyCostUSD: row.monthly_cost_usd,
    renewalDay: row.renewal_day,
    memberIDs: row.member_ids === null ? null : (JSON.parse(row.member_ids) as string[]),
  }));
}

async function report(db: Queryable, teamID: string, today: string) {
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

/** The plan report from the cache (see `teamCache.ts`), recomputed at most every 10 minutes. */
function cachedReport(env: Pick<Env, "db" | "cache">, now: Date, teamID: string, today: string) {
  return cachedTeamResult(env.cache, now, teamID, `plans|${today}`, 10 * 60_000, () => report(env.db, teamID, today));
}

/** GET /v1/teams/:teamID/plans?today= — the team's plans and their report, for any member. */
export const getPlans: Handler = async ({ request, env, url, params, deps }) => {
  const user = await requireUser(request, env.db);
  const role = await memberRole(env.db, params.teamID!, user.id);
  const result = await cachedReport(env, deps.now(), params.teamID!, viewerToday(url, deps.now()));
  return json({ ...result.value, plans: forViewer(result.value.plans, user.id), canEdit: role === "owner" });
};

/** PUT /v1/teams/:teamID/plans?today= { plans: [...] } — replaces the list. Owner only. */
export const putPlans: Handler = async ({ request, env, url, params, deps }) => {
  const user = await requireUser(request, env.db);
  const teamID = params.teamID!;
  const role = await memberRole(env.db, teamID, user.id);
  if (role !== "owner") throw forbidden("Only team owners can change plans.");
  const plans = parsePlans(await readJSONObject(request));
  const members = await env.db.query<{ user_id: string }>("SELECT user_id FROM team_members WHERE team_id = $1", [teamID]);
  const memberIDs = new Set(members.map((row) => row.user_id));
  if (plans.some((plan) => plan.memberIDs?.some((id) => !memberIDs.has(id)))) throw badRequest("A plan covers someone who is not in the team.");
  const updatedAt = nowISO();
  await env.db.transaction(async (tx) => {
    await tx.run("DELETE FROM team_plans WHERE team_id = $1", [teamID]);
    for (const [position, plan] of plans.entries()) {
      await tx.run(
        "INSERT INTO team_plans (id, team_id, provider, name, monthly_cost_usd, renewal_day, member_ids, position, updated_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
        [
          crypto.randomUUID(), teamID, plan.provider, plan.name, plan.monthlyCostUSD, plan.renewalDay,
          plan.memberIDs === null ? null : JSON.stringify(plan.memberIDs), position, updatedAt,
        ],
      );
    }
  });
  await env.cache.forgetTeams([teamID], "plans|");
  const fresh = await report(env.db, teamID, viewerToday(url, deps.now()));
  return json({ ...fresh, plans: forViewer(fresh.plans, user.id), canEdit: true });
};
