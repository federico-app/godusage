import type { Handler } from "../context";
import { json, notFound } from "../http";
import { requireUser } from "../session";
import { parseStatsQuery, teamStats } from "../stats";

/** GET /v1/teams/:teamID/stats?range=today|7d|30d&sort=cost|tokens&today=YYYY-MM-DD — members only. */
export const getTeamStats: Handler = async ({ request, env, url, params, deps }) => {
  const user = await requireUser(request, env.DB);
  const team = await env.DB.prepare(
    `SELECT t.id, t.name FROM teams t JOIN team_members m ON m.team_id = t.id WHERE t.id = ? AND m.user_id = ?`,
  )
    .bind(params.teamID!, user.id)
    .first<{ id: string; name: string }>();
  if (!team) throw notFound("Team not found.");

  const stats = await teamStats(env.DB, team.id, parseStatsQuery(url, deps.now()));
  return json({ team, stats });
};
