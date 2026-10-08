import type { Handler } from "../context";
import { badRequest, json, notFound } from "../http";
import { readGuard } from "../readGuard";
import { requireUser } from "../session";
import { cachedTeamStats, parseStatsQuery, type TeamStats } from "../stats";
import { dayKey } from "../usagePayload";
import { reactionSummary, teamChampions } from "./social";

/** Extra boards the app shows beside the one asked for, so it needs one request instead of three. */
const EXTRA_RANGES = ["today", "mtd"] as const;

/**
 * GET /v1/teams/:teamID/stats?range=today|7d|30d|365d|mtd&sort=cost|tokens&today=YYYY-MM-DD&include=today,mtd
 * — members only. Besides the stats: today's (UTC) reactions per member, the last 12 months'
 * champions, and with `include` the Today and Month to Date spend boards. Stats come from the cache:
 * `computedAt` says when they were computed, and `paused` that the day's read budget is spent, so
 * they stay as they are until midnight UTC.
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
  const include = (url.searchParams.get("include") ?? "").split(",").filter((name) => name !== "");
  for (const name of include) {
    if (!(EXTRA_RANGES as readonly string[]).includes(name)) throw badRequest("include may list today and mtd.");
  }
  const guard = readGuard(env, deps.now());
  const day = dayKey(deps.now());
  const [stats, reactions, champions, ...extras] = await Promise.all([
    cachedTeamStats(guard, team.id, query),
    reactionSummary(env.DB, team.id, day, user.id),
    teamChampions(guard, team.id, query.today),
    ...include.map((range) => cachedTeamStats(guard, team.id, { range: range as (typeof EXTRA_RANGES)[number], sort: "cost", today: query.today })),
  ]);
  const extra: Record<string, TeamStats> = {};
  include.forEach((range, index) => (extra[range] = extras[index]!.value));
  return json({
    team,
    stats: stats.value,
    computedAt: stats.computedAt,
    paused: stats.paused || extras.some((result) => result.paused),
    reactions: { day, week: day, byMember: reactions },
    champions,
    ...(include.length > 0 ? { extra } : {}),
  });
};
