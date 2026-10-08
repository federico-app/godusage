import type { Handler } from "../context";
import { badRequest, conflict, forbidden, json, noContent, notFound, nowISO, readJSONObject } from "../http";
import { requireUser, type SessionUser } from "../session";
import type { Env } from "../context";
import type { Queryable } from "../db";
import { cachedTeamResult } from "../teamCache";
import { teamUsage } from "../teamUsage";
import { addDays, dayKey, isValidDay } from "../usagePayload";

/**
 * Timed challenges: any member starts one for 7, 14, or 30 days; standings come from the members'
 * usage in that window, and once it has ended the leader is the winner.
 *
 * - lowest_spend: least spend, among members who spent anything (otherwise not using AI would win)
 * - most_models: the most different models used
 * - most_tokens: the most tokens
 * - best_efficiency: the lowest cost per million tokens, among members with at least 100K tokens
 */
export const CHALLENGE_KINDS = ["lowest_spend", "most_models", "most_tokens", "best_efficiency"] as const;
export type ChallengeKind = (typeof CHALLENGE_KINDS)[number];
const DURATIONS = [7, 14, 30];
const MAX_ACTIVE = 5;
const RECENT_FINISHED = 5;
const EFFICIENCY_MIN_TOKENS = 100_000;

interface ChallengeRow {
  id: string;
  kind: ChallengeKind;
  starts_on: string;
  ends_on: string;
  created_by: string | null;
}

export interface Standing {
  userID: string;
  displayName: string;
  rank: number;
  /** The challenge's own measure: dollars, model count, tokens, or dollars per 1M tokens. */
  value: number;
}

async function requireMembership(db: Queryable, teamID: string, user: SessionUser): Promise<"owner" | "member"> {
  const row = await db.first<{ role: "owner" | "member" }>("SELECT role FROM team_members WHERE team_id = $1 AND user_id = $2", [teamID, user.id]);
  if (!row) throw notFound("Team not found.");
  return row.role;
}

/** The viewer's "today": their local day when within a day of UTC, else the UTC date. */
export function viewerToday(url: URL, now: Date): string {
  const utc = dayKey(now);
  const requested = url.searchParams.get("today");
  return requested && isValidDay(requested) && requested >= addDays(utc, -1) && requested <= addDays(utc, 1) ? requested : utc;
}

export async function challengeStandings(db: Queryable, teamID: string, challenge: ChallengeRow): Promise<Standing[]> {
  const [members, usage] = await Promise.all([
    db.query<{ id: string; display_name: string }>("SELECT u.id, u.display_name FROM team_members m JOIN users u ON u.id = m.user_id WHERE m.team_id = $1", [teamID]),
    teamUsage(db, teamID, challenge.starts_on, challenge.ends_on, { models: true }),
  ]);
  const totals = new Map<string, { tokens: number; cost: number; models: Set<string> }>();
  const entry = (id: string) => {
    let value = totals.get(id);
    if (!value) totals.set(id, (value = { tokens: 0, cost: 0, models: new Set() }));
    return value;
  };
  for (const row of usage.days) {
    const value = entry(row.user_id);
    value.tokens += row.tokens;
    value.cost += row.cost;
  }
  for (const row of usage.models) {
    if (row.tokens > 0) entry(row.user_id).models.add(`${row.provider}/${row.model.toLowerCase()}`);
  }

  const candidates = members.flatMap((member) => {
    const value = totals.get(member.id);
    switch (challenge.kind) {
      case "lowest_spend":
        return value && value.cost > 0 ? [{ member, value: value.cost }] : [];
      case "most_models":
        return [{ member, value: value?.models.size ?? 0 }];
      case "most_tokens":
        return [{ member, value: value?.tokens ?? 0 }];
      case "best_efficiency":
        return value && value.tokens >= EFFICIENCY_MIN_TOKENS ? [{ member, value: (value.cost / value.tokens) * 1_000_000 }] : [];
    }
  });
  const ascending = challenge.kind === "lowest_spend" || challenge.kind === "best_efficiency";
  candidates.sort((a, b) => (ascending ? a.value - b.value : b.value - a.value) || a.member.display_name.localeCompare(b.member.display_name));

  const standings: Standing[] = [];
  for (const [index, candidate] of candidates.entries()) {
    const previous = standings[index - 1];
    const value = Math.round(candidate.value * 10_000) / 10_000;
    standings.push({
      userID: candidate.member.id,
      displayName: candidate.member.display_name,
      rank: previous && previous.value === value ? previous.rank : index + 1,
      value,
    });
  }
  return standings;
}

async function describe(db: Queryable, teamID: string, challenge: ChallengeRow, today: string) {
  const standings = await challengeStandings(db, teamID, challenge);
  const finished = challenge.ends_on < today;
  const leaders = standings.filter((s) => s.rank === 1 && (challenge.kind === "lowest_spend" || challenge.kind === "best_efficiency" || s.value > 0));
  return {
    id: challenge.id,
    kind: challenge.kind,
    startsOn: challenge.starts_on,
    endsOn: challenge.ends_on,
    createdBy: challenge.created_by,
    finished,
    /** Days left including today; 0 once finished. */
    daysLeft: finished ? 0 : Math.round((Date.parse(`${challenge.ends_on}T00:00:00Z`) - Date.parse(`${today}T00:00:00Z`)) / 86_400_000) + 1,
    standings,
    winners: finished ? leaders : [],
  };
}

/** Active challenges (soonest to end first) and the last five finished, with standings. */
export async function teamChallengeList(db: Queryable, teamID: string, today: string) {
  const [active, finished] = await Promise.all([
    db.query<ChallengeRow>("SELECT id, kind, starts_on, ends_on, created_by FROM challenges WHERE team_id = $1 AND ends_on >= $2 ORDER BY ends_on, id", [teamID, today]),
    db.query<ChallengeRow>(
      "SELECT id, kind, starts_on, ends_on, created_by FROM challenges WHERE team_id = $1 AND ends_on < $2 ORDER BY ends_on DESC, id LIMIT $3",
      [teamID, today, RECENT_FINISHED],
    ),
  ]);
  const rows = [...active, ...finished];
  const challenges = [];
  for (const row of rows) challenges.push(await describe(db, teamID, row, today));
  return challenges;
}

/** The team's challenges from the cache (see `teamCache.ts`), recomputed at most every 5 minutes. */
export function cachedChallengeList(env: Pick<Env, "db" | "cache">, now: Date, teamID: string, today: string) {
  return cachedTeamResult(env.cache, now, teamID, `challenges|${today}`, 5 * 60_000, () => teamChallengeList(env.db, teamID, today));
}

/** GET /v1/teams/:teamID/challenges?today=… — active challenges and the last five finished. */
export const listChallenges: Handler = async ({ request, env, url, params, deps }) => {
  const user = await requireUser(request, env.db);
  await requireMembership(env.db, params.teamID!, user);
  const result = await cachedChallengeList(env, deps.now(), params.teamID!, viewerToday(url, deps.now()));
  return json({ challenges: result.value });
};

/** POST /v1/teams/:teamID/challenges { kind, days, today? } — starts today, any member. */
export const createChallenge: Handler = async ({ request, env, url, params, deps }) => {
  const user = await requireUser(request, env.db);
  const teamID = params.teamID!;
  await requireMembership(env.db, teamID, user);
  const body = await readJSONObject(request);
  if (typeof body.kind !== "string" || !CHALLENGE_KINDS.includes(body.kind as ChallengeKind)) {
    throw badRequest("kind must be lowest_spend, most_models, most_tokens, or best_efficiency.");
  }
  if (typeof body.days !== "number" || !DURATIONS.includes(body.days)) throw badRequest("days must be 7, 14, or 30.");

  const today = viewerToday(new URL(`${url.origin}${url.pathname}?today=${typeof body.today === "string" ? body.today : ""}`), deps.now());
  const active = await env.db.first<{ n: number }>("SELECT COUNT(*) AS n FROM challenges WHERE team_id = $1 AND ends_on >= $2", [teamID, today]);
  if ((active?.n ?? 0) >= MAX_ACTIVE) throw conflict(`A team can run at most ${MAX_ACTIVE} challenges at once.`);

  const row: ChallengeRow = {
    id: crypto.randomUUID(),
    kind: body.kind as ChallengeKind,
    starts_on: today,
    ends_on: addDays(today, body.days - 1),
    created_by: user.id,
  };
  await env.db.run(
    "INSERT INTO challenges (id, team_id, kind, starts_on, ends_on, created_by, created_at) VALUES ($1, $2, $3, $4, $5, $6, $7)",
    [row.id, teamID, row.kind, row.starts_on, row.ends_on, row.created_by, nowISO()],
  );
  await env.cache.forgetTeams([teamID], "challenges|");
  return json({ challenge: await describe(env.db, teamID, row, today) }, 201);
};

/** DELETE /v1/teams/:teamID/challenges/:challengeID — the creator or the owner. */
export const deleteChallenge: Handler = async ({ request, env, params }) => {
  const user = await requireUser(request, env.db);
  const role = await requireMembership(env.db, params.teamID!, user);
  const row = await env.db.first<{ created_by: string | null }>("SELECT created_by FROM challenges WHERE id = $1 AND team_id = $2", [
    params.challengeID!,
    params.teamID!,
  ]);
  if (!row) throw notFound("Challenge not found.");
  if (row.created_by !== user.id && role !== "owner") throw forbidden("Only the creator or a team owner can cancel a challenge.");
  await env.db.run("DELETE FROM challenges WHERE id = $1", [params.challengeID!]);
  await env.cache.forgetTeams([params.teamID!], "challenges|");
  return noContent();
};
