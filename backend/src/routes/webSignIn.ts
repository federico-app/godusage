import { timingSafeEqual } from "node:crypto";
import { verifyAppleIdentityToken } from "../apple";
import type { Env, Handler, RouteContext } from "../context";
import { ApiError, badRequest, base64url, isRecord, json, randomToken, readJSONObject, requireName, sha256Hex, unauthorized } from "../http";
import { createSession, WEB_SESSION_DAYS, webSessionCookie } from "../session";
import { escapeHTML } from "./pages";
import { DISPLAY_NAME_MAX, findOrCreateUser } from "./account";

/**
 * Sign in with Apple through the web, for app builds that cannot use the native flow (Developer ID
 * builds: their profiles never grant the Sign in with Apple entitlement).
 *
 * 1. The app opens /v1/auth/apple/start in the browser with its own `state`, a PKCE `code_challenge`,
 *    and the `scheme` it listens on; the server redirects to Apple with a server state and nonce.
 * 2. Apple posts the identity token to /v1/auth/apple/callback. The server verifies it (audience =
 *    the Services ID, nonce = this request's), and redirects to <scheme>://auth with a one-time code.
 * 3. The app posts the code and its PKCE verifier to /v1/auth/apple/exchange for a session token.
 */

/** The release app's scheme, and the DEV app's own, so each gets back its own sign-in. */
export const APP_SCHEMES = ["godusage", "godusage-dev"] as const;
type AppScheme = (typeof APP_SCHEMES)[number];
const APPLE_AUTHORIZE_URL = "https://appleid.apple.com/auth/authorize";
const REQUEST_TTL_MS = 10 * 60 * 1000;
const CODE_TTL_MS = 5 * 60 * 1000;
const TOKENISH = /^[A-Za-z0-9_-]{16,128}$/;
const CHALLENGE = /^[A-Za-z0-9_-]{43}$/;

function callbackURL(url: URL): string {
  return `${url.origin}/v1/auth/apple/callback`;
}

function appRedirect(scheme: AppScheme, params: Record<string, string>): Response {
  const location = `${scheme}://auth?${new URLSearchParams(params).toString()}`;
  return new Response(
    `<!doctype html><meta charset="utf-8"><title>Returning to GodUsage</title><p><a href="${escapeHTML(location)}">Return to GodUsage</a></p>`,
    { status: 303, headers: { location, "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } },
  );
}

function seeOther(location: string, cookie?: string): Response {
  const headers = new Headers({ location, "cache-control": "no-store" });
  if (cookie) headers.set("set-cookie", cookie);
  return new Response(null, { status: 303, headers });
}

function errorPage(message: string, status: number): Response {
  return new Response(
    `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Sign In Failed</title>` +
      `<body style="font:16px -apple-system,sans-serif;max-width:480px;margin:48px auto;padding:0 16px"><h1>Sign In Failed</h1><p>${escapeHTML(message)}</p></body>`,
    { status, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } },
  );
}

/** GET /v1/auth/apple/start?state=…&code_challenge=…&scheme=… — the app's sign-in. Apps before 1.1.0 send no scheme. */
export const startWebSignIn: Handler = async ({ env, url, deps }) => {
  const appState = url.searchParams.get("state") ?? "";
  const challenge = url.searchParams.get("code_challenge") ?? "";
  const scheme = url.searchParams.get("scheme") ?? "godusage";
  if (!TOKENISH.test(appState) || !CHALLENGE.test(challenge) || !isAppScheme(scheme)) {
    return errorPage("This sign-in link is incomplete. Go back to GodUsage and try again.", 400);
  }
  return redirectToApple(env, url, deps.now(), { kind: "app", appState, challenge, returnTo: null, appScheme: scheme });
};

function isAppScheme(value: string | null): value is AppScheme {
  return (APP_SCHEMES as readonly string[]).includes(value ?? "");
}

/** Only paths on this site, so a sign-in can never bounce a browser to another site. */
export function safeReturnPath(value: string | null): string {
  return value && /^\/teams\/[A-Za-z0-9-]{1,64}$/.test(value) ? value : "/";
}

/** Starts a browser sign-in for the web leaderboard; Apple returns to `returnTo` afterwards. */
export async function startBrowserSignIn(env: Env, url: URL, now: Date, returnTo: string): Promise<Response> {
  return redirectToApple(env, url, now, { kind: "web", appState: "", challenge: "", returnTo: safeReturnPath(returnTo), appScheme: null });
}

async function redirectToApple(
  env: Env,
  url: URL,
  now: Date,
  request: { kind: "app" | "web"; appState: string; challenge: string; returnTo: string | null; appScheme: AppScheme | null },
): Promise<Response> {
  const state = randomToken(24);
  const nonce = randomToken(24);
  await env.db.transaction(async (tx) => {
    await tx.run("DELETE FROM auth_requests WHERE expires_at < $1", [now.toISOString()]);
    await tx.run(
      "INSERT INTO auth_requests (state, nonce, code_challenge, app_state, expires_at, kind, return_to, app_scheme) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
      [state, nonce, request.challenge, request.appState, new Date(now.getTime() + REQUEST_TTL_MS).toISOString(), request.kind, request.returnTo, request.appScheme],
    );
  });

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
}

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

  const pending = await env.db.first<{ nonce: string; code_challenge: string; app_state: string; expires_at: string; kind: "app" | "web"; return_to: string | null; app_scheme: string | null }>(
    "DELETE FROM auth_requests WHERE state = $1 RETURNING nonce, code_challenge, app_state, expires_at, kind, return_to, app_scheme",
    [field("state")],
  );
  const now = deps.now();
  if (!pending || new Date(pending.expires_at) <= now) {
    return errorPage("This sign-in expired. Go back to GodUsage and try again.", 400);
  }

  const scheme = isAppScheme(pending.app_scheme) ? pending.app_scheme : "godusage";
  const appleError = field("error");
  if (pending.kind === "web" && appleError) {
    return seeOther(safeReturnPath(pending.return_to));
  }
  if (appleError) {
    return appRedirect(scheme, { state: pending.app_state, error: appleError === "user_cancelled_authorize" ? "cancelled" : "apple" });
  }

  let identity: { sub: string };
  try {
    identity = await verifyAppleIdentityToken(field("id_token"), [env.APPLE_WEB_CLIENT_ID], deps.fetchAppleKeys, now, pending.nonce);
  } catch (error) {
    if (!(error instanceof ApiError)) throw error;
    console.warn(JSON.stringify({ event: "web_sign_in_rejected", reason: error.message }));
    if (pending.kind === "web") return errorPage("Apple's response couldn't be verified. Try signing in again.", 401);
    return appRedirect(scheme, { state: pending.app_state, error: "invalid_token" });
  }

  const { user, created } = await findOrCreateUser(env.db, identity.sub, nameFromAppleUser(field("user")));
  if (pending.kind === "web") {
    const token = await createSession(env.db, user.id, WEB_SESSION_DAYS);
    console.log(JSON.stringify({ event: "browser_sign_in", userID: user.id, created }));
    return seeOther(safeReturnPath(pending.return_to), webSessionCookie(token));
  }
  const code = randomToken(32);
  await env.db.run("INSERT INTO login_codes (code_hash, user_id, code_challenge, created, expires_at) VALUES ($1, $2, $3, $4, $5)", [
    await sha256Hex(code),
    user.id,
    pending.code_challenge,
    created ? 1 : 0,
    new Date(now.getTime() + CODE_TTL_MS).toISOString(),
  ]);
  console.log(JSON.stringify({ event: "web_sign_in", userID: user.id, created }));
  return appRedirect(scheme, { state: pending.app_state, code });
};

/** POST /v1/auth/apple/exchange { code, codeVerifier } → { token, user, created } */
export const exchangeWebSignIn: Handler = async ({ request, env, deps }) => {
  const body = await readJSONObject(request);
  if (typeof body.code !== "string" || typeof body.codeVerifier !== "string" || !TOKENISH.test(body.codeVerifier)) {
    throw badRequest("code and codeVerifier are required.");
  }
  const row = await env.db.first<{ user_id: string; code_challenge: string; created: number; expires_at: string }>(
    "DELETE FROM login_codes WHERE code_hash = $1 RETURNING user_id, code_challenge, created, expires_at",
    [await sha256Hex(body.code)],
  );
  if (!row || new Date(row.expires_at) <= deps.now()) throw unauthorized("This sign-in expired. Sign in again.");

  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(body.codeVerifier)));
  const expected = new TextEncoder().encode(row.code_challenge);
  const actual = new TextEncoder().encode(base64url(digest));
  if (expected.byteLength !== actual.byteLength || !timingSafeEqual(expected, actual)) {
    throw unauthorized("This sign-in was started by a different app. Sign in again.");
  }

  const user = await env.db.first<{ id: string; display_name: string }>("SELECT id, display_name FROM users WHERE id = $1", [row.user_id]);
  if (!user) throw unauthorized("This account no longer exists. Sign in again.");
  const token = await createSession(env.db, user.id);
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
