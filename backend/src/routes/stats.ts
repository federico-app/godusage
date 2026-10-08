import type { Handler } from "../context";
import { badRequest, json, notFound } from "../http";
import { requireUser } from "../session";
import { teamMomentum } from "../momentum";
import { cachedTeamStats, parseStatsQuery, type TeamStats } from "../stats";
import { cachedTeamResult } from "../teamCache";
import { dayKey } from "../usagePayload";
import { reactionSummary, teamChampions } from "./social";

/** Extra boards the app shows beside the one asked for, so it needs one request instead of three. */
const EXTRA_RANGES = ["today", "mtd"] as const;

/**
 * GET /v1/teams/:teamID/stats?range=today|7d|30d|365d|mtd&sort=cost|tokens&today=YYYY-MM-DD&include=today,mtd
 * — members only. Besides the stats: today's (UTC) reactions per member, the last 12 months'
 * champions, each member's momentum (spend in the last hour and 0–3 ⚡, see `momentum.ts`), and with
 * `include` the Today and Month to Date spend boards. Stats come from the cache:
 * `computedAt` says when they were computed (at most 10 minutes ago).
 */
export const getTeamStats: Handler = async ({ request, env, url, params, deps }) => {
  const user = await requireUser(request, env.db);
  const team = await env.db.first<{ id: string; name: string }>(
    `SELECT t.id, t.name FROM teams t JOIN team_members m ON m.team_id = t.id WHERE t.id = $1 AND m.user_id = $2`,
    [params.teamID!, user.id],
  );
  if (!team) throw notFound("Team not found.");

  const query = parseStatsQuery(url, deps.now());
  const include = (url.searchParams.get("include") ?? "").split(",").filter((name) => name !== "");
  for (const name of include) {
    if (!(EXTRA_RANGES as readonly string[]).includes(name)) throw badRequest("include may list today and mtd.");
  }
  const now = deps.now();
  const day = dayKey(now);
  const [stats, momentum, reactions, champions, ...extras] = await Promise.all([
    cachedTeamStats(env, now, team.id, query),
    // Momentum is about the last hour, whatever the range: recomputed at most once a minute.
    cachedTeamResult(env.cache, now, team.id, "momentum", 60_000, () => teamMomentum(env.db, team.id, now)),
    reactionSummary(env.db, team.id, day, user.id),
    teamChampions(env, now, team.id, query.today),
    ...include.map((range) => cachedTeamStats(env, now, team.id, { range: range as (typeof EXTRA_RANGES)[number], sort: "cost", today: query.today })),
  ]);
  const extra: Record<string, TeamStats> = {};
  include.forEach((range, index) => (extra[range] = extras[index]!.value));
  return json({
    team,
    stats: stats.value,
    computedAt: stats.computedAt,
    momentum: momentum.value,
    reactions: { day, week: day, byMember: reactions },
    champions,
    ...(include.length > 0 ? { extra } : {}),
  });
};
