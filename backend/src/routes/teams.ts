import type { Handler, RouteContext } from "../context";
import { badRequest, conflict, forbidden, json, noContent, notFound, nowISO, randomToken, readJSONObject, requireName } from "../http";
import { requireUser, type SessionUser } from "../session";
import { forgetChampions } from "./social";

export const TEAM_NAME_MAX = 60;
export const MAX_MEMBERS_PER_TEAM = 50;
export const MAX_TEAMS_PER_USER = 20;

interface TeamRow {
  id: string;
  name: string;
  owner_id: string;
  invite_code: string;
  public_token: string | null;
  created_at: string;
}

type Role = "owner" | "member";

export function inviteURL(origin: string, code: string): string {
  return `${origin}/join/${code}`;
}

export function publicBoardURL(origin: string, token: string): string {
  return `${origin}/t/${token}`;
}

/** Loads a team the user belongs to. Non-members get 404 so team ids do not leak. */
async function requireMembership(db: D1Database, teamID: string, user: SessionUser): Promise<{ team: TeamRow; role: Role }> {
  const row = await db
    .prepare(
      `SELECT t.*, m.role FROM teams t JOIN team_members m ON m.team_id = t.id
       WHERE t.id = ? AND m.user_id = ?`,
    )
    .bind(teamID, user.id)
    .first<TeamRow & { role: Role }>();
  if (!row) throw notFound("Team not found.");
  const { role, ...team } = row;
  return { team, role };
}

async function requireOwner(db: D1Database, teamID: string, user: SessionUser): Promise<TeamRow> {
  const { team, role } = await requireMembership(db, teamID, user);
  if (role !== "owner") throw forbidden("Only team owners can do this.");
  return team;
}

/**
 * `teams.owner_id` is the account whose deletion takes the team with it. After an owner leaves or
 * is made a member, it moves to the earliest-joined remaining owner.
 */
async function keepCreatorAnOwner(db: D1Database, teamID: string): Promise<void> {
  await db
    .prepare(
      `UPDATE teams SET owner_id = (SELECT user_id FROM team_members WHERE team_id = teams.id AND role = 'owner' ORDER BY joined_at, user_id LIMIT 1)
       WHERE id = ? AND owner_id NOT IN (SELECT user_id FROM team_members WHERE team_id = teams.id AND role = 'owner')`,
    )
    .bind(teamID)
    .run();
}

/** Why a change to `targetID` matched no row: the member is missing, or they are the last owner. */
async function explainNoChange(db: D1Database, teamID: string, targetID: string, lastOwnerMessage: string): Promise<never> {
  const exists = await db.prepare("SELECT 1 AS found FROM team_members WHERE team_id = ? AND user_id = ?").bind(teamID, targetID).first<number>("found");
  if (exists) throw conflict(lastOwnerMessage);
  throw notFound("Member not found.");
}

/** Matches a row only if it is a member, or an owner with another owner left in the team. */
const NOT_LAST_OWNER = `(role = 'member' OR (SELECT COUNT(*) FROM team_members o WHERE o.team_id = team_members.team_id AND o.role = 'owner') > 1)`;

async function teamDetail(context: RouteContext, team: TeamRow, role: Role) {
  const members = await context.env.DB.prepare(
    `SELECT u.id, u.display_name, m.role, m.joined_at FROM team_members m JOIN users u ON u.id = m.user_id
     WHERE m.team_id = ? ORDER BY m.role = 'owner' DESC, m.joined_at, u.id`,
  )
    .bind(team.id)
    .all<{ id: string; display_name: string; role: Role; joined_at: string }>();
  const origin = context.url.origin;
  return {
    id: team.id,
    name: team.name,
    role,
    createdAt: team.created_at,
    inviteURL: inviteURL(origin, team.invite_code),
    webBoardURL: `${origin}/teams/${team.id}`,
    publicBoardURL: role === "owner" && team.public_token ? publicBoardURL(origin, team.public_token) : null,
    members: members.results.map((member) => ({
      id: member.id,
      displayName: member.display_name,
      role: member.role,
      joinedAt: member.joined_at,
    })),
  };
}

async function assertCanJoinAnotherTeam(db: D1Database, userID: string): Promise<void> {
  const count = await db.prepare("SELECT COUNT(*) AS n FROM team_members WHERE user_id = ?").bind(userID).first<number>("n");
  if ((count ?? 0) >= MAX_TEAMS_PER_USER) throw conflict(`You can be in at most ${MAX_TEAMS_PER_USER} teams.`);
}

/** GET /v1/teams */
export const listTeams: Handler = async ({ request, env }) => {
  const user = await requireUser(request, env.DB);
  const rows = await env.DB.prepare(
    `SELECT t.id, t.name, m.role,
       (SELECT COUNT(*) FROM team_members c WHERE c.team_id = t.id) AS member_count
     FROM teams t JOIN team_members m ON m.team_id = t.id
     WHERE m.user_id = ? ORDER BY t.name COLLATE NOCASE, t.id`,
  )
    .bind(user.id)
    .all<{ id: string; name: string; role: Role; member_count: number }>();
  return json({
    teams: rows.results.map((row) => ({ id: row.id, name: row.name, role: row.role, memberCount: row.member_count })),
  });
};

/** POST /v1/teams { name } */
export const createTeam: Handler = async (context) => {
  const { request, env } = context;
  const user = await requireUser(request, env.DB);
  const body = await readJSONObject(request);
  const name = requireName(body.name, "name", TEAM_NAME_MAX);
  await assertCanJoinAnotherTeam(env.DB, user.id);

  const team: TeamRow = {
    id: crypto.randomUUID(),
    name,
    owner_id: user.id,
    invite_code: randomToken(16),
    public_token: null,
    created_at: nowISO(),
  };
  await env.DB.batch([
    env.DB.prepare("INSERT INTO teams (id, name, owner_id, invite_code, public_token, created_at) VALUES (?, ?, ?, ?, NULL, ?)")
      .bind(team.id, team.name, team.owner_id, team.invite_code, team.created_at),
    env.DB.prepare("INSERT INTO team_members (team_id, user_id, role, joined_at) VALUES (?, ?, 'owner', ?)")
      .bind(team.id, user.id, team.created_at),
  ]);
  return json({ team: await teamDetail(context, team, "owner") }, 201);
};

/** GET /v1/teams/:teamID */
export const getTeam: Handler = async (context) => {
  const user = await requireUser(context.request, context.env.DB);
  const { team, role } = await requireMembership(context.env.DB, context.params.teamID!, user);
  return json({ team: await teamDetail(context, team, role) });
};

/** PATCH /v1/teams/:teamID { name?, publicBoard? } — owner only. */
export const updateTeam: Handler = async (context) => {
  const { request, env } = context;
  const user = await requireUser(request, env.DB);
  const team = await requireOwner(env.DB, context.params.teamID!, user);
  const body = await readJSONObject(request);

  if (body.name !== undefined) team.name = requireName(body.name, "name", TEAM_NAME_MAX);
  if (body.publicBoard !== undefined) {
    if (typeof body.publicBoard !== "boolean") throw badRequest("publicBoard must be true or false.");
    if (body.publicBoard && !team.public_token) team.public_token = randomToken(16);
    if (!body.publicBoard) team.public_token = null;
  }
  await env.DB.prepare("UPDATE teams SET name = ?, public_token = ? WHERE id = ?")
    .bind(team.name, team.public_token, team.id)
    .run();
  return json({ team: await teamDetail(context, team, "owner") });
};

/** DELETE /v1/teams/:teamID — owner only. */
export const deleteTeam: Handler = async ({ request, env, params }) => {
  const user = await requireUser(request, env.DB);
  const team = await requireOwner(env.DB, params.teamID!, user);
  await env.DB.prepare("DELETE FROM teams WHERE id = ?").bind(team.id).run();
  return noContent();
};

/** POST /v1/teams/:teamID/invite — owner only. Replaces the invite link; the old one stops working. */
export const rotateInvite: Handler = async (context) => {
  const user = await requireUser(context.request, context.env.DB);
  const team = await requireOwner(context.env.DB, context.params.teamID!, user);
  team.invite_code = randomToken(16);
  await context.env.DB.prepare("UPDATE teams SET invite_code = ? WHERE id = ?").bind(team.invite_code, team.id).run();
  return json({ team: await teamDetail(context, team, "owner") });
};

/**
 * DELETE /v1/teams/:teamID/members/:userID
 * Anyone can remove themself (leave). Owners can remove anyone else. The last owner cannot leave;
 * they make someone else an owner first, or delete the team.
 */
export const removeMember: Handler = async ({ request, env, params }) => {
  const user = await requireUser(request, env.DB);
  const { team, role } = await requireMembership(env.DB, params.teamID!, user);
  const targetID = params.userID!;
  if (targetID !== user.id && role !== "owner") throw forbidden("Only team owners can remove members.");

  const result = await env.DB.prepare(`DELETE FROM team_members WHERE team_id = ? AND user_id = ? AND ${NOT_LAST_OWNER}`)
    .bind(team.id, targetID)
    .run();
  if (result.meta.changes === 0) {
    await explainNoChange(env.DB, team.id, targetID, "The last owner cannot leave. Make someone else an owner, or delete the team.");
  }
  await keepCreatorAnOwner(env.DB, team.id);
  await forgetChampions(env.DB, team.id);
  return noContent();
};

/**
 * PATCH /v1/teams/:teamID/members/:userID { role: "owner" | "member" } — owners only. A team keeps at
 * least one owner.
 */
export const setMemberRole: Handler = async (context) => {
  const { request, env, params } = context;
  const user = await requireUser(request, env.DB);
  const team = await requireOwner(env.DB, params.teamID!, user);
  const body = await readJSONObject(request);
  if (body.role !== "owner" && body.role !== "member") throw badRequest('role must be "owner" or "member".');
  const targetID = params.userID!;

  const result =
    body.role === "owner"
      ? await env.DB.prepare("UPDATE team_members SET role = 'owner' WHERE team_id = ? AND user_id = ?").bind(team.id, targetID).run()
      : await env.DB.prepare(`UPDATE team_members SET role = 'member' WHERE team_id = ? AND user_id = ? AND ${NOT_LAST_OWNER}`)
          .bind(team.id, targetID)
          .run();
  if (result.meta.changes === 0) {
    await explainNoChange(env.DB, team.id, targetID, "A team needs at least one owner.");
  }
  await keepCreatorAnOwner(env.DB, team.id);
  // The caller may have just made themself a member.
  const { team: updated, role } = await requireMembership(env.DB, team.id, user);
  return json({ team: await teamDetail(context, updated, role) });
};

async function teamForInvite(db: D1Database, code: string): Promise<TeamRow> {
  const team = await db.prepare("SELECT * FROM teams WHERE invite_code = ?").bind(code).first<TeamRow>();
  if (!team) throw notFound("This invite link is no longer valid.");
  return team;
}

export async function invitePreview(db: D1Database, code: string) {
  const team = await teamForInvite(db, code);
  const memberCount = await db.prepare("SELECT COUNT(*) AS n FROM team_members WHERE team_id = ?").bind(team.id).first<number>("n");
  return { id: team.id, name: team.name, memberCount: memberCount ?? 0 };
}

/** GET /v1/invites/:code — what the app shows before the user confirms joining. */
export const getInvite: Handler = async ({ request, env, params }) => {
  const user = await requireUser(request, env.DB);
  const team = await invitePreview(env.DB, params.code!);
  const member = await env.DB.prepare("SELECT 1 AS found FROM team_members WHERE team_id = ? AND user_id = ?")
    .bind(team.id, user.id)
    .first<number>("found");
  return json({ team, alreadyMember: member === 1 });
};

/** POST /v1/invites/:code/accept — joins the team. Joining a team you are in already is a no-op. */
export const acceptInvite: Handler = async (context) => {
  const { request, env, params } = context;
  const user = await requireUser(request, env.DB);
  const team = await teamForInvite(env.DB, params.code!);

  const existing = await env.DB.prepare("SELECT role FROM team_members WHERE team_id = ? AND user_id = ?")
    .bind(team.id, user.id)
    .first<Role>("role");
  if (existing) return json({ team: await teamDetail(context, team, existing) });

  await assertCanJoinAnotherTeam(env.DB, user.id);
  const memberCount = await env.DB.prepare("SELECT COUNT(*) AS n FROM team_members WHERE team_id = ?").bind(team.id).first<number>("n");
  if ((memberCount ?? 0) >= MAX_MEMBERS_PER_TEAM) throw conflict(`This team is full (${MAX_MEMBERS_PER_TEAM} members).`);

  await env.DB.prepare("INSERT INTO team_members (team_id, user_id, role, joined_at) VALUES (?, ?, 'member', ?)")
    .bind(team.id, user.id, nowISO())
    .run();
  await forgetChampions(env.DB, team.id);
  return json({ team: await teamDetail(context, team, "member") }, 201);
};
