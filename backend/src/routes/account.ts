import { verifyAppleIdentityToken } from "../apple";
import type { Handler } from "../context";
import { badRequest, json, noContent, nowISO, readJSONObject, requireName } from "../http";
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
  const { user, created } = await findOrCreateUser(env.DB, identity.sub, displayName);
  const token = await createSession(env.DB, user.id);
  console.log(JSON.stringify({ event: "sign_in", userID: user.id, created }));
  return json({ token, user, created }, created ? 201 : 200);
};

/**
 * The account for an Apple user, created on first sign-in. `displayName` is used only for a new
 * account; later sign-ins keep the chosen name.
 */
export async function findOrCreateUser(
  db: D1Database,
  appleSub: string,
  displayName: string | undefined,
): Promise<{ user: { id: string; displayName: string }; created: boolean }> {
  const existing = await db.prepare("SELECT id, display_name FROM users WHERE apple_sub = ?")
    .bind(appleSub)
    .first<{ id: string; display_name: string }>();
  if (existing) return { user: { id: existing.id, displayName: existing.display_name }, created: false };

  const id = crypto.randomUUID();
  const name = displayName ?? "GodUsage User";
  await db.prepare("INSERT INTO users (id, apple_sub, display_name, created_at) VALUES (?, ?, ?, ?)")
    .bind(id, appleSub, name, nowISO())
    .run();
  return { user: { id, displayName: name }, created: true };
}

/** POST /v1/auth/logout — ends this session only. */
export const signOut: Handler = async ({ request, env }) => {
  await deleteSession(request, env.DB);
  return noContent();
};

/** GET /v1/me */
export const getMe: Handler = async ({ request, env }) => {
  const user = await requireUser(request, env.DB);
  return json({ user });
};

/** PATCH /v1/me { displayName } */
export const updateMe: Handler = async ({ request, env }) => {
  const user = await requireUser(request, env.DB);
  const body = await readJSONObject(request);
  const displayName = requireName(body.displayName, "displayName", DISPLAY_NAME_MAX);
  await env.DB.prepare("UPDATE users SET display_name = ? WHERE id = ?").bind(displayName, user.id).run();
  return json({ user: { id: user.id, displayName } });
};

/**
 * DELETE /v1/me — deletes the account and everything tied to it: sessions, devices, usage,
 * memberships, and the teams this user owns (their members lose those teams).
 */
export const deleteMe: Handler = async ({ request, env }) => {
  const user = await requireUser(request, env.DB);
  await env.DB.prepare("DELETE FROM users WHERE id = ?").bind(user.id).run();
  console.log(JSON.stringify({ event: "account_deleted", userID: user.id }));
  return noContent();
};

/**
 * GET /v1/me/export — everything the server keeps about the signed-in user, as one JSON document:
 * the account, Macs, daily usage per provider and per model, team memberships, reactions given and
 * received, and challenges started. Session tokens are never included (only their count).
 */
export const exportMe: Handler = async ({ request, env, deps }) => {
  const user = await requireUser(request, env.DB);
  const [account, sessions, devices, days, models, teams, given, received, challenges] = await env.DB.batch([
    env.DB.prepare("SELECT id, apple_sub, display_name, created_at FROM users WHERE id = ?").bind(user.id),
    env.DB.prepare("SELECT COUNT(*) AS n FROM sessions WHERE user_id = ?").bind(user.id),
    env.DB.prepare("SELECT id, name, updated_at FROM devices WHERE user_id = ? ORDER BY updated_at DESC").bind(user.id),
    env.DB.prepare("SELECT device_id, provider, day, scope, tokens, cost_usd FROM usage_days WHERE user_id = ? ORDER BY day, provider").bind(user.id),
    env.DB.prepare("SELECT device_id, provider, day, model, scope, tokens, cost_usd FROM usage_model_days WHERE user_id = ? ORDER BY day, provider, model").bind(user.id),
    env.DB.prepare("SELECT t.id, t.name, m.role, m.joined_at FROM team_members m JOIN teams t ON t.id = m.team_id WHERE m.user_id = ? ORDER BY t.name").bind(user.id),
    env.DB.prepare("SELECT team_id, to_user, emoji, week, created_at FROM reactions WHERE from_user = ? ORDER BY created_at").bind(user.id),
    env.DB.prepare("SELECT team_id, from_user, emoji, week, created_at FROM reactions WHERE to_user = ? ORDER BY created_at").bind(user.id),
    env.DB.prepare("SELECT id, team_id, kind, starts_on, ends_on, created_at FROM challenges WHERE created_by = ? ORDER BY created_at").bind(user.id),
  ]);
  const row = account!.results[0] as { id: string; apple_sub: string; display_name: string; created_at: string };
  const body = {
    schema: "godusage.export.v1",
    exportedAt: deps.now().toISOString(),
    account: { id: row.id, appleUserID: row.apple_sub, displayName: row.display_name, createdAt: row.created_at },
    activeSessions: (sessions!.results[0] as { n: number }).n,
    devices: devices!.results,
    usageDays: days!.results,
    usageModelDays: models!.results,
    teams: teams!.results,
    reactionsGiven: given!.results,
    reactionsReceived: received!.results,
    challengesStarted: challenges!.results,
  };
  return new Response(JSON.stringify(body, null, 2), {
    headers: {
      "content-type": "application/json; charset=utf-8",
      "content-disposition": 'attachment; filename="godusage-export.json"',
      "cache-control": "no-store",
    },
  });
};
