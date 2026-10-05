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

  let user = await env.DB.prepare("SELECT id, display_name FROM users WHERE apple_sub = ?")
    .bind(identity.sub)
    .first<{ id: string; display_name: string }>();
  let created = false;
  if (!user) {
    const displayName = body.displayName === undefined ? "GodUsage User" : requireName(body.displayName, "displayName", DISPLAY_NAME_MAX);
    const id = crypto.randomUUID();
    await env.DB.prepare("INSERT INTO users (id, apple_sub, display_name, created_at) VALUES (?, ?, ?, ?)")
      .bind(id, identity.sub, displayName, nowISO())
      .run();
    user = { id, display_name: displayName };
    created = true;
  }

  const token = await createSession(env.DB, user.id);
  console.log(JSON.stringify({ event: "sign_in", userID: user.id, created }));
  return json({ token, user: { id: user.id, displayName: user.display_name }, created }, created ? 201 : 200);
};

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
