import type { Handler } from "../context";
import { badRequest, forbidden, json, notFound, nowISO } from "../http";
import { requireUser, type SessionUser } from "../session";
import { addDays, dayKey } from "../usagePayload";
import type { Env } from "../context";
import type { Queryable } from "../db";
import { cachedTeamResult } from "../teamCache";
import { teamUsage } from "../teamUsage";

export const REACTIONS = ["fire", "clap", "clown"] as const;
export type Reaction = (typeof REACTIONS)[number];

export interface MemberReactions {
  fire: number;
  clap: number;
  clown: number;
  /** The viewer's own reactions to this member today. */
  mine: Reaction[];
  /** Who gave each reaction today (user ids, oldest first), for the member's detail. */
  from: Record<Reaction, string[]>;
}

async function requireMember(db: Queryable, teamID: string, userID: string): Promise<void> {
  const found = await db.first("SELECT 1 AS found FROM team_members WHERE team_id = $1 AND user_id = $2", [teamID, userID]);
  if (!found) throw notFound("Team not found.");
}

/** Today's (UTC) reactions per member, with the viewer's own marked. */
export async function reactionSummary(db: Queryable, teamID: string, day: string, viewerID: string): Promise<Record<string, MemberReactions>> {
  const rows = await db.query<{ from_user: string; to_user: string; emoji: Reaction }>(
    "SELECT from_user, to_user, emoji FROM reactions WHERE team_id = $1 AND day = $2 ORDER BY created_at, from_user, emoji",
    [teamID, day],
  );
  const summary: Record<string, MemberReactions> = {};
  for (const row of rows) {
    const entry = (summary[row.to_user] ??= { fire: 0, clap: 0, clown: 0, mine: [], from: { fire: [], clap: [], clown: [] } });
    entry[row.emoji] += 1;
    entry.from[row.emoji].push(row.from_user);
    if (row.from_user === viewerID) entry.mine.push(row.emoji);
  }
  return summary;
}

function parseReaction(context: { params: Record<string, string> }, user: SessionUser): { teamID: string; target: string; emoji: Reaction } {
  const emoji = context.params.emoji as Reaction;
  if (!REACTIONS.includes(emoji)) throw badRequest("emoji must be fire, clap, or clown.");
  const target = context.params.userID!;
  if (target === user.id) throw forbidden("You can't react to yourself.");
  return { teamID: context.params.teamID!, target, emoji };
}

/** PUT /v1/teams/:teamID/members/:userID/reactions/:emoji — gives a reaction (idempotent). */
export const addReaction: Handler = async (context) => {
  const { request, env, deps } = context;
  const user = await requireUser(request, env.db);
  const { teamID, target, emoji } = parseReaction(context, user);
  await requireMember(env.db, teamID, user.id);
  await requireMember(env.db, teamID, target).catch(() => {
    throw notFound("Member not found.");
  });
  const day = dayKey(deps.now());
  await env.db.run(
    `INSERT INTO reactions (team_id, from_user, to_user, emoji, day, created_at) VALUES ($1, $2, $3, $4, $5, $6)
     ON CONFLICT DO NOTHING`,
    [teamID, user.id, target, emoji, day, nowISO()],
  );
  return json({ day, week: day, reactions: await reactionSummary(env.db, teamID, day, user.id) });
};

/** DELETE /v1/teams/:teamID/members/:userID/reactions/:emoji — takes it back. */
export const removeReaction: Handler = async (context) => {
  const { request, env, deps } = context;
  const user = await requireUser(request, env.db);
  const { teamID, target, emoji } = parseReaction(context, user);
  await requireMember(env.db, teamID, user.id);
  const day = dayKey(deps.now());
  await env.db.run("DELETE FROM reactions WHERE team_id = $1 AND from_user = $2 AND to_user = $3 AND emoji = $4 AND day = $5", [
    teamID,
    user.id,
    target,
    emoji,
    day,
  ]);
  return json({ day, week: day, reactions: await reactionSummary(env.db, teamID, day, user.id) });
};

export interface Champion {
  month: string;
  userID: string;
  displayName: string;
  costUSD: number;
}

/**
 * How long computed champions are reused. They only move when a month ends or a late upload lands, and
 * computing them reads a year of every member's daily totals.
 */
const CHAMPIONS_MIN_AGE_MS = 10 * 60_000;

/**
 * The top spender of each of the last 12 complete calendar months (newest first), among the team's
 * current members. A month nobody spent in has no champion. Every stats request asks for it, so the
 * result is cached (see `teamCache.ts`) for 10 minutes, and dropped when the team's members change.
 */
export async function teamChampions(env: Pick<Env, "db" | "cache">, now: Date, teamID: string, today: string): Promise<Champion[]> {
  const month = today.slice(0, 7);
  const result = await cachedTeamResult(env.cache, now, teamID, `champions|${month}`, CHAMPIONS_MIN_AGE_MS, () => computeChampions(env.db, teamID, today));
  return result.value;
}

/** Drops a team's cached champions and stats, after its members change. */
export async function forgetChampions(env: Pick<Env, "cache">, teamID: string): Promise<void> {
  await env.cache.forgetTeams([teamID]);
}

export async function computeChampions(db: Queryable, teamID: string, today: string): Promise<Champion[]> {
  const thisMonth = `${today.slice(0, 7)}-01`;
  const to = addDays(thisMonth, -1);
  let from = thisMonth;
  for (let i = 0; i < 12; i++) from = `${addDays(from, -1).slice(0, 7)}-01`;

  const [members, usage] = await Promise.all([
    db.query<{ id: string; display_name: string }>("SELECT u.id, u.display_name FROM team_members m JOIN users u ON u.id = m.user_id WHERE m.team_id = $1", [teamID]),
    teamUsage(db, teamID, from, to, { models: false }),
  ]);
  const names = new Map(members.map((m) => [m.id, m.display_name]));
  const byMonth = new Map<string, Map<string, number>>();
  for (const row of usage.days) {
    const month = row.day.slice(0, 7);
    const totals = byMonth.get(month) ?? new Map<string, number>();
    totals.set(row.user_id, (totals.get(row.user_id) ?? 0) + row.cost);
    byMonth.set(month, totals);
  }
  return [...byMonth.entries()]
    .flatMap(([month, totals]) => {
      const [winner] = [...totals.entries()]
        .filter(([, cost]) => cost > 0)
        .sort((a, b) => b[1] - a[1] || (names.get(a[0]) ?? "").localeCompare(names.get(b[0]) ?? ""));
      if (!winner) return [];
      return [{ month, userID: winner[0], displayName: names.get(winner[0]) ?? "Former Member", costUSD: Math.round(winner[1] * 100) / 100 }];
    })
    .sort((a, b) => b.month.localeCompare(a.month));
}
