import type { Handler } from "../context";
import { badRequest, forbidden, json, notFound, nowISO } from "../http";
import { requireUser, type SessionUser } from "../session";
import { addDays, dayKey } from "../usagePayload";
import { EFFECTIVE_DAYS } from "../stats";

export const REACTIONS = ["fire", "clap", "clown"] as const;
export type Reaction = (typeof REACTIONS)[number];

export interface MemberReactions {
  fire: number;
  clap: number;
  clown: number;
  /** The viewer's own reactions to this member today. */
  mine: Reaction[];
}

async function requireMember(db: D1Database, teamID: string, userID: string): Promise<void> {
  const found = await db.prepare("SELECT 1 AS found FROM team_members WHERE team_id = ? AND user_id = ?").bind(teamID, userID).first("found");
  if (found !== 1) throw notFound("Team not found.");
}

/** Today's (UTC) reactions per member, with the viewer's own marked. */
export async function reactionSummary(db: D1Database, teamID: string, day: string, viewerID: string): Promise<Record<string, MemberReactions>> {
  const rows = await db.prepare("SELECT from_user, to_user, emoji FROM reactions WHERE team_id = ? AND day = ?")
    .bind(teamID, day)
    .all<{ from_user: string; to_user: string; emoji: Reaction }>();
  const summary: Record<string, MemberReactions> = {};
  for (const row of rows.results) {
    const entry = (summary[row.to_user] ??= { fire: 0, clap: 0, clown: 0, mine: [] });
    entry[row.emoji] += 1;
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
  const user = await requireUser(request, env.DB);
  const { teamID, target, emoji } = parseReaction(context, user);
  await requireMember(env.DB, teamID, user.id);
  await requireMember(env.DB, teamID, target).catch(() => {
    throw notFound("Member not found.");
  });
  const day = dayKey(deps.now());
  await env.DB.prepare(
    "INSERT OR IGNORE INTO reactions (team_id, from_user, to_user, emoji, day, created_at) VALUES (?, ?, ?, ?, ?, ?)",
  )
    .bind(teamID, user.id, target, emoji, day, nowISO())
    .run();
  return json({ day, week: day, reactions: await reactionSummary(env.DB, teamID, day, user.id) });
};

/** DELETE /v1/teams/:teamID/members/:userID/reactions/:emoji — takes it back. */
export const removeReaction: Handler = async (context) => {
  const { request, env, deps } = context;
  const user = await requireUser(request, env.DB);
  const { teamID, target, emoji } = parseReaction(context, user);
  await requireMember(env.DB, teamID, user.id);
  const day = dayKey(deps.now());
  await env.DB.prepare("DELETE FROM reactions WHERE team_id = ? AND from_user = ? AND to_user = ? AND emoji = ? AND day = ?")
    .bind(teamID, user.id, target, emoji, day)
    .run();
  return json({ day, week: day, reactions: await reactionSummary(env.DB, teamID, day, user.id) });
};

export interface Champion {
  month: string;
  userID: string;
  displayName: string;
  costUSD: number;
}

/**
 * The top spender of each of the last 12 complete calendar months (newest first), among the team's
 * current members. A month nobody spent in has no champion.
 */
export async function teamChampions(db: D1Database, teamID: string, today: string): Promise<Champion[]> {
  const thisMonth = `${today.slice(0, 7)}-01`;
  const to = addDays(thisMonth, -1);
  let from = thisMonth;
  for (let i = 0; i < 12; i++) from = `${addDays(from, -1).slice(0, 7)}-01`;

  const [members, days] = await db.batch([
    db.prepare("SELECT u.id, u.display_name FROM team_members m JOIN users u ON u.id = m.user_id WHERE m.team_id = ?").bind(teamID),
    db.prepare(EFFECTIVE_DAYS).bind(teamID, from, to),
  ]);
  const names = new Map((members!.results as { id: string; display_name: string }[]).map((m) => [m.id, m.display_name]));
  const byMonth = new Map<string, Map<string, number>>();
  for (const row of days!.results as { user_id: string; day: string; cost: number }[]) {
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
