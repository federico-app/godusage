import type { Handler } from "../context";
import { json, notFound } from "../http";
import { requireUser } from "../session";
import { parseStatsQuery, teamStats } from "../stats";
import { dayKey } from "../usagePayload";
import { reactionSummary, teamChampions } from "./social";

/**
 * GET /v1/teams/:teamID/stats?range=today|7d|30d|365d|mtd&sort=cost|tokens&today=YYYY-MM-DD — members
 * only. Besides the stats: today's (UTC) reactions per member and the last 12 months' champions.
 */
export const getTeamStats: Handler = async ({ request, env, url, params, deps }) => {
  const user = await requireUser(request, env.DB);
  const team = await env.DB.prepare(
    `SELECT t.id, t.name FROM teams t JOIN team_members m ON m.team_id = t.id WHERE t.id = ? AND m.user_id = ?`,
  )
    .bind(params.teamID!, user.id)
    .first<{ id: string; name: string }>();
  if (!team) throw notFound("Team not found.");

  const query = parseStatsQuery(url, deps.now());
  const day = dayKey(deps.now());
  const [stats, reactions, champions] = await Promise.all([
    teamStats(env.DB, team.id, query),
    reactionSummary(env.DB, team.id, day, user.id),
    teamChampions(env.DB, team.id, query.today, deps.now()),
  ]);
  return json({ team, stats, reactions: { day, week: day, byMember: reactions }, champions });
};
