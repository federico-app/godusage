import { verifyAppleIdentityToken } from "../apple";
import type { Handler } from "../context";
import { badRequest, json, noContent, nowISO, readJSONObject, requireName } from "../http";
import type { Queryable } from "../db";
import { userTeamIDs } from "../teamCache";
import { createSession, deleteSession, requireUser } from "../session";

export const DISPLAY_NAME_MAX = 40;

/**
 * POST /v1/auth/apple { identityToken, displayName? }
 * Verifies the Apple token, creates the account on first sign-in, and returns a session token.
 * `displayName` is used only when the account is new; later sign-ins keep the chosen name.
 */
export const signInWithApple: Handler = async ({ request, env, deps }) => {
  const body = await readJSONObject(request);
  if (typeof body.identityToken !== "string" || body.identityToken.length === 0) {
    throw badRequest("identityToken is required.");
  }
  const audiences = env.APPLE_AUDIENCES.split(",").map((value) => value.trim()).filter(Boolean);
  const identity = await verifyAppleIdentityToken(body.identityToken, audiences, deps.fetchAppleKeys, deps.now());

  const displayName = body.displayName === undefined ? undefined : requireName(body.displayName, "displayName", DISPLAY_NAME_MAX);
  const { user, created } = await findOrCreateUser(env.db, identity.sub, displayName);
  const token = await createSession(env.db, user.id);
  console.log(JSON.stringify({ event: "sign_in", userID: user.id, created }));
  return json({ token, user, created }, created ? 201 : 200);
};

/**
 * The account for an Apple user, created on first sign-in. `displayName` is used only for a new
 * account; later sign-ins keep the chosen name.
 */
export async function findOrCreateUser(
  db: Queryable,
  appleSub: string,
  displayName: string | undefined,
): Promise<{ user: { id: string; displayName: string }; created: boolean }> {
  const existing = () => db.first<{ id: string; display_name: string }>("SELECT id, display_name FROM users WHERE apple_sub = $1", [appleSub]);
  const found = await existing();
  if (found) return { user: { id: found.id, displayName: found.display_name }, created: false };

  const id = crypto.randomUUID();
  const name = displayName ?? "GodUsage User";
  const inserted = await db.run(
    "INSERT INTO users (id, apple_sub, display_name, created_at) VALUES ($1, $2, $3, $4) ON CONFLICT (apple_sub) DO NOTHING",
    [id, appleSub, name, nowISO()],
  );
  if (inserted === 1) return { user: { id, displayName: name }, created: true };
  // Two sign-ins of a new account raced: the other one created it.
  const winner = await existing();
  if (!winner) throw new Error(`findOrCreateUser: no user for ${appleSub} after a conflicting insert`);
  return { user: { id: winner.id, displayName: winner.display_name }, created: false };
}

/** POST /v1/auth/logout — ends this session only. */
export const signOut: Handler = async ({ request, env }) => {
  await deleteSession(request, env.db);
  return noContent();
};

/** GET /v1/me */
export const getMe: Handler = async ({ request, env }) => {
  const user = await requireUser(request, env.db);
  return json({ user });
};

/** PATCH /v1/me { displayName } */
export const updateMe: Handler = async ({ request, env }) => {
  const user = await requireUser(request, env.db);
  const body = await readJSONObject(request);
  const displayName = requireName(body.displayName, "displayName", DISPLAY_NAME_MAX);
  await env.db.run("UPDATE users SET display_name = $1 WHERE id = $2", [displayName, user.id]);
  // Cached boards show the old name: drop them.
  await env.cache.forgetTeams(await userTeamIDs(env.db, user.id));
  return json({ user: { id: user.id, displayName } });
};

/**
 * DELETE /v1/me — deletes the account and everything tied to it: sessions, devices, usage,
 * memberships, and the teams where this user is the only owner (their members lose those teams).
 * Teams with another owner stay, and pass to it.
 */
export const deleteMe: Handler = async ({ request, env }) => {
  const user = await requireUser(request, env.db);
  // Champions and cached boards are among current members: they are recomputed without this account.
  const teamIDs = await userTeamIDs(env.db, user.id);
  await env.db.transaction(async (tx) => {
    await tx.run(
      `DELETE FROM teams WHERE id IN (
         SELECT m.team_id FROM team_members m WHERE m.user_id = $1 AND m.role = 'owner'
         AND NOT EXISTS (SELECT 1 FROM team_members o WHERE o.team_id = m.team_id AND o.role = 'owner' AND o.user_id <> $1))`,
      [user.id],
    );
    // teams.owner_id cascades on delete, so it moves to another owner first.
    await tx.run(
      `UPDATE teams SET owner_id = (SELECT user_id FROM team_members WHERE team_id = teams.id AND role = 'owner' AND user_id <> $1 ORDER BY joined_at, user_id LIMIT 1)
       WHERE owner_id = $1`,
      [user.id],
    );
    await tx.run("DELETE FROM users WHERE id = $1", [user.id]);
  });
  await env.cache.forgetTeams(teamIDs);
  console.log(JSON.stringify({ event: "account_deleted", userID: user.id }));
  return noContent();
};

/**
 * GET /v1/me/export — everything the server keeps about the signed-in user, as one JSON document:
 * the account, Macs, phones linked by QR pairing, daily usage per provider and per model, team memberships, reactions given and
 * received, and challenges started. Session tokens are never included (only their count).
 */
export const exportMe: Handler = async ({ request, env, deps }) => {
  const user = await requireUser(request, env.db);
  const id = [user.id];
  // One transaction, so the document is one consistent snapshot.
  const [account, sessions, linkedDevices, devices, days, models, teams, given, received, challenges] = await env.db.transaction((tx) =>
    Promise.all([
      tx.query("SELECT id, apple_sub, display_name, created_at FROM users WHERE id = $1", id),
      tx.query("SELECT COUNT(*) AS n FROM sessions WHERE user_id = $1", id),
      tx.query("SELECT paired_device AS name, created_at FROM sessions WHERE user_id = $1 AND paired_device IS NOT NULL ORDER BY created_at", id),
      tx.query("SELECT id, name, updated_at FROM devices WHERE user_id = $1 ORDER BY updated_at DESC", id),
      tx.query("SELECT device_id, provider, day, scope, tokens, cost_usd FROM usage_days WHERE user_id = $1 ORDER BY day, provider", id),
      tx.query("SELECT device_id, provider, day, model, scope, tokens, cost_usd FROM usage_model_days WHERE user_id = $1 ORDER BY day, provider, model", id),
      tx.query("SELECT t.id, t.name, m.role, m.joined_at FROM team_members m JOIN teams t ON t.id = m.team_id WHERE m.user_id = $1 ORDER BY t.name", id),
      tx.query("SELECT team_id, to_user, emoji, day, created_at FROM reactions WHERE from_user = $1 ORDER BY created_at", id),
      tx.query("SELECT team_id, from_user, emoji, day, created_at FROM reactions WHERE to_user = $1 ORDER BY created_at", id),
      tx.query("SELECT id, team_id, kind, starts_on, ends_on, created_at FROM challenges WHERE created_by = $1 ORDER BY created_at", id),
    ]),
  );
  const row = account[0] as { id: string; apple_sub: string; display_name: string; created_at: string };
  const body = {
    schema: "godusage.export.v1",
    exportedAt: deps.now().toISOString(),
    account: { id: row.id, appleUserID: row.apple_sub, displayName: row.display_name, createdAt: row.created_at },
    activeSessions: (sessions[0] as { n: number }).n,
    linkedDevices,
    devices,
    usageDays: days,
    usageModelDays: models,
    teams,
    reactionsGiven: given,
    reactionsReceived: received,
    challengesStarted: challenges,
  };
  return new Response(JSON.stringify(body, null, 2), {
    headers: {
      "content-type": "application/json; charset=utf-8",
      "content-disposition": 'attachment; filename="godusage-export.json"',
      "cache-control": "no-store",
    },
  });
};
