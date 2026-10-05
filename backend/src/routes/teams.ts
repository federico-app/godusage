import type { Handler, RouteContext } from "../context";
import { badRequest, conflict, forbidden, json, noContent, notFound, nowISO, randomToken, readJSONObject, requireName } from "../http";
import { requireUser, type SessionUser } from "../session";

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
  if (role !== "owner") throw forbidden("Only the team owner can do this.");
  return team;
}

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
 * A member can remove themself (leave). The owner can remove anyone else. The owner cannot leave;
 * they delete the team instead.
 */
export const removeMember: Handler = async ({ request, env, params }) => {
  const user = await requireUser(request, env.DB);
  const { team, role } = await requireMembership(env.DB, params.teamID!, user);
  const targetID = params.userID!;
  if (targetID === team.owner_id) throw conflict("The owner cannot leave the team. Delete the team instead.");
  if (targetID !== user.id && role !== "owner") throw forbidden("Only the team owner can remove members.");

  const result = await env.DB.prepare("DELETE FROM team_members WHERE team_id = ? AND user_id = ?").bind(team.id, targetID).run();
  if (result.meta.changes === 0) throw notFound("Member not found.");
  return noContent();
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
  return json({ team: await teamDetail(context, team, "member") }, 201);
};
