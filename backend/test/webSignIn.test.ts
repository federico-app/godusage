import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { base64url } from "../src/http";
import { appleToken, makeApp, NOW } from "./support";

const WEB_CLIENT = "com.montinovo.godusage.web";

async function pkce() {
  const verifier = base64url(crypto.getRandomValues(new Uint8Array(32)));
  const challenge = base64url(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))));
  return { verifier, challenge };
}

async function raw(request: Request, now: Date = NOW): Promise<Response> {
  return makeApp(now).fetch(request, env);
}

/** Runs /start and returns the server state and nonce Apple would receive. */
async function start(appState: string, challenge: string) {
  const response = await raw(new Request(`https://api.test/v1/auth/apple/start?state=${appState}&code_challenge=${challenge}`));
  expect(response.status).toBe(302);
  const apple = new URL(response.headers.get("location")!);
  return { apple, state: apple.searchParams.get("state")!, nonce: apple.searchParams.get("nonce")! };
}

async function callback(fields: Record<string, string>, now: Date = NOW): Promise<Response> {
  return raw(
    new Request("https://api.test/v1/auth/apple/callback", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams(fields).toString(),
    }),
    now,
  );
}

async function exchange(code: string, codeVerifier: string) {
  const response = await raw(
    new Request("https://api.test/v1/auth/apple/exchange", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ code, codeVerifier }),
    }),
  );
  return { status: response.status, body: (await response.json()) as any };
}

function appCallback(response: Response): URL {
  expect(response.status).toBe(303);
  const location = new URL(response.headers.get("location")!);
  expect(`${location.protocol}//${location.host}`).toBe("godusage://auth");
  return location;
}

describe("web sign in with Apple", () => {
  it("redirects to Apple with the Services ID, callback, and a fresh state and nonce", async () => {
    const { challenge } = await pkce();
    const { apple, state, nonce } = await start("app-state-0123456789", challenge);
    expect(apple.origin + apple.pathname).toBe("https://appleid.apple.com/auth/authorize");
    expect(apple.searchParams.get("client_id")).toBe(WEB_CLIENT);
    expect(apple.searchParams.get("redirect_uri")).toBe("https://api.test/v1/auth/apple/callback");
    expect(apple.searchParams.get("response_mode")).toBe("form_post");
    expect(apple.searchParams.get("scope")).toBe("name");
    expect(state).not.toBe("app-state-0123456789");
    expect(nonce.length).toBeGreaterThan(20);
  });

  it("signs in end to end, using the name Apple shares on first sign-in", async () => {
    const { verifier, challenge } = await pkce();
    const { state, nonce } = await start("app-state-aaaaaaaaaa", challenge);
    const back = appCallback(
      await callback({
        state,
        code: "apple-code",
        id_token: await appleToken({ aud: WEB_CLIENT, nonce, sub: "web-user-1" }),
        user: JSON.stringify({ name: { firstName: "Ada", lastName: "Lovelace" } }),
      }),
    );
    expect(back.searchParams.get("state")).toBe("app-state-aaaaaaaaaa");
    const code = back.searchParams.get("code")!;

    const signedIn = await exchange(code, verifier);
    expect(signedIn.status).toBe(201);
    expect(signedIn.body.user.displayName).toBe("Ada Lovelace");
    expect(signedIn.body.created).toBe(true);

    const me = await raw(new Request("https://api.test/v1/me", { headers: { authorization: `Bearer ${signedIn.body.token}` } }));
    expect(((await me.json()) as any).user.displayName).toBe("Ada Lovelace");

    // The code is single-use.
    expect((await exchange(code, verifier)).status).toBe(401);
  });

  it("refuses a code redeemed with the wrong verifier", async () => {
    const { challenge } = await pkce();
    const { state, nonce } = await start("app-state-bbbbbbbbbb", challenge);
    const back = appCallback(await callback({ state, id_token: await appleToken({ aud: WEB_CLIENT, nonce, sub: "web-user-2" }) }));
    const other = await pkce();
    const result = await exchange(back.searchParams.get("code")!, other.verifier);
    expect(result.status).toBe(401);
    expect(result.body.error.message).toMatch(/different app/);
  });

  it("returns an error to the app for a token from another sign-in or app", async () => {
    const { challenge } = await pkce();
    const first = await start("app-state-cccccccccc", challenge);
    const wrongNonce = appCallback(
      await callback({ state: first.state, id_token: await appleToken({ aud: WEB_CLIENT, nonce: "someone-else" }) }),
    );
    expect(wrongNonce.searchParams.get("error")).toBe("invalid_token");
    expect(wrongNonce.searchParams.get("code")).toBeNull();

    const second = await start("app-state-dddddddddd", challenge);
    const wrongAudience = appCallback(
      await callback({ state: second.state, id_token: await appleToken({ aud: "com.montinovo.godusage", nonce: second.nonce }) }),
    );
    expect(wrongAudience.searchParams.get("error")).toBe("invalid_token");
  });

  it("passes a cancel back to the app", async () => {
    const { challenge } = await pkce();
    const { state } = await start("app-state-eeeeeeeeee", challenge);
    const back = appCallback(await callback({ state, error: "user_cancelled_authorize" }));
    expect(back.searchParams.get("error")).toBe("cancelled");
    expect(back.searchParams.get("state")).toBe("app-state-eeeeeeeeee");
  });

  it("shows an error page for an unknown, reused, or expired request", async () => {
    expect((await callback({ state: "nope" })).status).toBe(400);

    const { challenge } = await pkce();
    const used = await start("app-state-ffffffffff", challenge);
    await callback({ state: used.state, error: "user_cancelled_authorize" });
    expect((await callback({ state: used.state, error: "user_cancelled_authorize" })).status).toBe(400);

    const late = await start("app-state-gggggggggg", challenge);
    const expired = await callback({ state: late.state }, new Date(NOW.getTime() + 11 * 60 * 1000));
    expect(expired.status).toBe(400);
    expect(await expired.text()).toContain("expired");
  });

  it("rejects a start without a proper state or challenge", async () => {
    expect((await raw(new Request("https://api.test/v1/auth/apple/start?state=x&code_challenge=y"))).status).toBe(400);
  });

  it("keeps the existing account and name on later sign-ins", async () => {
    const first = await pkce();
    const a = await start("app-state-hhhhhhhhhh", first.challenge);
    const codeA = appCallback(
      await callback({
        state: a.state,
        id_token: await appleToken({ aud: WEB_CLIENT, nonce: a.nonce, sub: "web-user-3" }),
        user: JSON.stringify({ name: { firstName: "Grace" } }),
      }),
    ).searchParams.get("code")!;
    const signedA = await exchange(codeA, first.verifier);

    const second = await pkce();
    const b = await start("app-state-iiiiiiiiii", second.challenge);
    const codeB = appCallback(
      await callback({ state: b.state, id_token: await appleToken({ aud: WEB_CLIENT, nonce: b.nonce, sub: "web-user-3" }) }),
    ).searchParams.get("code")!;
    const signedB = await exchange(codeB, second.verifier);

    expect(signedB.status).toBe(200);
    expect(signedB.body.user).toEqual(signedA.body.user);
    expect(signedB.body.created).toBe(false);
  });
});
