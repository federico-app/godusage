import { verifyAppleIdentityToken } from "../apple";
import type { Handler, RouteContext } from "../context";
import { ApiError, badRequest, base64url, isRecord, json, randomToken, readJSONObject, requireName, sha256Hex, unauthorized } from "../http";
import { createSession } from "../session";
import { escapeHTML } from "./pages";
import { DISPLAY_NAME_MAX, findOrCreateUser } from "./account";

/**
 * Sign in with Apple through the web, for app builds that cannot use the native flow (Developer ID
 * builds: their profiles never grant the Sign in with Apple entitlement).
 *
 * 1. The app opens /v1/auth/apple/start in an ASWebAuthenticationSession with its own `state` and a
 *    PKCE `code_challenge`; the Worker redirects to Apple with a server state and nonce.
 * 2. Apple posts the identity token to /v1/auth/apple/callback. The Worker verifies it (audience =
 *    the Services ID, nonce = this request's), and redirects to godusage://auth with a one-time code.
 * 3. The app posts the code and its PKCE verifier to /v1/auth/apple/exchange for a session token.
 */

export const APP_CALLBACK = "godusage://auth";
const APPLE_AUTHORIZE_URL = "https://appleid.apple.com/auth/authorize";
const REQUEST_TTL_MS = 10 * 60 * 1000;
const CODE_TTL_MS = 5 * 60 * 1000;
const TOKENISH = /^[A-Za-z0-9_-]{16,128}$/;
const CHALLENGE = /^[A-Za-z0-9_-]{43}$/;

function callbackURL(url: URL): string {
  return `${url.origin}/v1/auth/apple/callback`;
}

function appRedirect(params: Record<string, string>): Response {
  const location = `${APP_CALLBACK}?${new URLSearchParams(params).toString()}`;
  return new Response(
    `<!doctype html><meta charset="utf-8"><title>Returning to GodUsage</title><p><a href="${escapeHTML(location)}">Return to GodUsage</a></p>`,
    { status: 303, headers: { location, "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } },
  );
}

function errorPage(message: string, status: number): Response {
  return new Response(
    `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Sign In Failed</title>` +
      `<body style="font:16px -apple-system,sans-serif;max-width:480px;margin:48px auto;padding:0 16px"><h1>Sign In Failed</h1><p>${escapeHTML(message)}</p></body>`,
    { status, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } },
  );
}

/** GET /v1/auth/apple/start?state=…&code_challenge=… */
export const startWebSignIn: Handler = async ({ env, url, deps }) => {
  const appState = url.searchParams.get("state") ?? "";
  const challenge = url.searchParams.get("code_challenge") ?? "";
  if (!TOKENISH.test(appState) || !CHALLENGE.test(challenge)) {
    return errorPage("This sign-in link is incomplete. Go back to GodUsage and try again.", 400);
  }
  const now = deps.now();
  const state = randomToken(24);
  const nonce = randomToken(24);
  await env.DB.batch([
    env.DB.prepare("DELETE FROM auth_requests WHERE expires_at < ?").bind(now.toISOString()),
    env.DB.prepare("INSERT INTO auth_requests (state, nonce, code_challenge, app_state, expires_at) VALUES (?, ?, ?, ?, ?)")
      .bind(state, nonce, challenge, appState, new Date(now.getTime() + REQUEST_TTL_MS).toISOString()),
  ]);

  const apple = new URL(APPLE_AUTHORIZE_URL);
  apple.search = new URLSearchParams({
    client_id: env.APPLE_WEB_CLIENT_ID,
    redirect_uri: callbackURL(url),
    response_type: "code id_token",
    response_mode: "form_post",
    scope: "name",
    state,
    nonce,
  }).toString();
  return new Response(null, { status: 302, headers: { location: apple.toString(), "cache-control": "no-store" } });
};

/** POST /v1/auth/apple/callback — Apple's form post. */
export const finishWebSignIn: Handler = async (context: RouteContext) => {
  const { request, env, deps } = context;
  let form: FormData;
  try {
    form = await request.formData();
  } catch {
    return errorPage("Apple sent an unreadable response. Go back to GodUsage and try again.", 400);
  }
  const field = (name: string) => {
    const value = form.get(name);
    return typeof value === "string" ? value : "";
  };

  const pending = await env.DB.prepare("DELETE FROM auth_requests WHERE state = ? RETURNING nonce, code_challenge, app_state, expires_at")
    .bind(field("state"))
    .first<{ nonce: string; code_challenge: string; app_state: string; expires_at: string }>();
  const now = deps.now();
  if (!pending || new Date(pending.expires_at) <= now) {
    return errorPage("This sign-in expired. Go back to GodUsage and try again.", 400);
  }

  const appleError = field("error");
  if (appleError) {
    return appRedirect({ state: pending.app_state, error: appleError === "user_cancelled_authorize" ? "cancelled" : "apple" });
  }

  let identity: { sub: string };
  try {
    identity = await verifyAppleIdentityToken(field("id_token"), [env.APPLE_WEB_CLIENT_ID], deps.fetchAppleKeys, now, pending.nonce);
  } catch (error) {
    if (!(error instanceof ApiError)) throw error;
    console.warn(JSON.stringify({ event: "web_sign_in_rejected", reason: error.message }));
    return appRedirect({ state: pending.app_state, error: "invalid_token" });
  }

  const { user, created } = await findOrCreateUser(env.DB, identity.sub, nameFromAppleUser(field("user")));
  const code = randomToken(32);
  await env.DB.prepare("INSERT INTO login_codes (code_hash, user_id, code_challenge, created, expires_at) VALUES (?, ?, ?, ?, ?)")
    .bind(await sha256Hex(code), user.id, pending.code_challenge, created ? 1 : 0, new Date(now.getTime() + CODE_TTL_MS).toISOString())
    .run();
  console.log(JSON.stringify({ event: "web_sign_in", userID: user.id, created }));
  return appRedirect({ state: pending.app_state, code });
};

/** POST /v1/auth/apple/exchange { code, codeVerifier } → { token, user, created } */
export const exchangeWebSignIn: Handler = async ({ request, env, deps }) => {
  const body = await readJSONObject(request);
  if (typeof body.code !== "string" || typeof body.codeVerifier !== "string" || !TOKENISH.test(body.codeVerifier)) {
    throw badRequest("code and codeVerifier are required.");
  }
  const row = await env.DB.prepare("DELETE FROM login_codes WHERE code_hash = ? RETURNING user_id, code_challenge, created, expires_at")
    .bind(await sha256Hex(body.code))
    .first<{ user_id: string; code_challenge: string; created: number; expires_at: string }>();
  if (!row || new Date(row.expires_at) <= deps.now()) throw unauthorized("This sign-in expired. Sign in again.");

  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(body.codeVerifier)));
  const expected = new TextEncoder().encode(row.code_challenge);
  const actual = new TextEncoder().encode(base64url(digest));
  if (expected.byteLength !== actual.byteLength || !crypto.subtle.timingSafeEqual(expected, actual)) {
    throw unauthorized("This sign-in was started by a different app. Sign in again.");
  }

  const user = await env.DB.prepare("SELECT id, display_name FROM users WHERE id = ?")
    .bind(row.user_id)
    .first<{ id: string; display_name: string }>();
  if (!user) throw unauthorized("This account no longer exists. Sign in again.");
  const token = await createSession(env.DB, user.id);
  const created = row.created === 1;
  return json({ token, user: { id: user.id, displayName: user.display_name }, created }, created ? 201 : 200);
};

/** Apple sends the name only on the first authorization, as JSON in the `user` form field. */
function nameFromAppleUser(raw: string): string | undefined {
  if (!raw) return undefined;
  try {
    const parsed: unknown = JSON.parse(raw);
    if (!isRecord(parsed) || !isRecord(parsed.name)) return undefined;
    const parts = [parsed.name.firstName, parsed.name.lastName].filter((part): part is string => typeof part === "string");
    return requireName(parts.join(" "), "displayName", DISPLAY_NAME_MAX);
  } catch {
    return undefined;
  }
}
