import { describe, expect, it } from "vitest";
import { verifyAppleIdentityToken } from "../src/apple";
import { env } from "cloudflare:test";
import { sha256Hex } from "../src/http";
import { api, appleToken, makeApp, NOW, otherKey, publicJWK, RELEASE_AUDIENCE, signIn } from "./support";

const audiences = [RELEASE_AUDIENCE, `${RELEASE_AUDIENCE}.dev`];

describe("Apple identity token", () => {
  const keys = async () => [publicJWK];

  it("accepts a valid token for either bundle id", async () => {
    await expect(verifyAppleIdentityToken(await appleToken({ sub: "abc" }), audiences, keys, NOW)).resolves.toEqual({ sub: "abc" });
    const dev = await appleToken({ aud: `${RELEASE_AUDIENCE}.dev` });
    await expect(verifyAppleIdentityToken(dev, audiences, keys, NOW)).resolves.toBeTruthy();
  });

  it.each([
    ["another app", { aud: "com.example.other" }, /different app/],
    ["an expired token", { exp: Math.floor(NOW.getTime() / 1000) - 1 }, /expired/],
    ["a forged signature", { key: otherKey.privateKey }, /signature is invalid/],
    ["an unknown key", { kid: "rotated-away" }, /unknown key/],
    ["the wrong issuer", { iss: "https://evil.example" }, /wrong issuer/],
    ["an unsigned token", { alg: "none" }, /unsupported algorithm/],
  ])("rejects %s", async (_label, claims, message) => {
    await expect(verifyAppleIdentityToken(await appleToken(claims), audiences, keys, NOW)).rejects.toThrow(message);
  });

  it("rejects garbage", async () => {
    await expect(verifyAppleIdentityToken("not-a-jwt", audiences, keys, NOW)).rejects.toThrow(/malformed/);
  });
});

describe("sign in and account", () => {
  it("creates the account once and keeps the chosen name on later sign-ins", async () => {
    const identityToken = await appleToken({ sub: "returning-user" });
    const first = await api("POST", "/v1/auth/apple", { body: { identityToken, displayName: "  Fede  " } });
    expect(first.status).toBe(201);
    expect(first.body.user.displayName).toBe("Fede");

    const second = await api("POST", "/v1/auth/apple", { body: { identityToken, displayName: "Someone Else" } });
    expect(second.status).toBe(200);
    expect(second.body.user).toEqual(first.body.user);
    expect(second.body.token).not.toBe(first.body.token);
  });

  it("returns 401 for a bad Apple token and never creates an account", async () => {
    const response = await api("POST", "/v1/auth/apple", { body: { identityToken: await appleToken({ aud: "x" }) } });
    expect(response.status).toBe(401);
    expect(response.body.error.code).toBe("unauthorized");
  });

  it("requires a session for account routes", async () => {
    expect((await api("GET", "/v1/me")).status).toBe(401);
    expect((await api("GET", "/v1/me", { token: "x".repeat(43) })).status).toBe(401);
  });

  it("renames, signs out, and deletes the account", async () => {
    const { token } = await signIn("Before");
    const renamed = await api("PATCH", "/v1/me", { token, body: { displayName: "After" } });
    expect(renamed.body.user.displayName).toBe("After");
    expect((await api("PATCH", "/v1/me", { token, body: { displayName: "" } })).status).toBe(400);
    expect((await api("PATCH", "/v1/me", { token, body: { displayName: "x".repeat(41) } })).status).toBe(400);

    const second = await signIn("Other");
    expect((await api("POST", "/v1/auth/logout", { token: second.token })).status).toBe(204);
    expect((await api("GET", "/v1/me", { token: second.token })).status).toBe(401);

    expect((await api("DELETE", "/v1/me", { token })).status).toBe(204);
    expect((await api("GET", "/v1/me", { token })).status).toBe(401);
  });

  it("rejects an expired session and deletes it", async () => {
    const { token } = await signIn();
    const tokenHash = await sha256Hex(token);
    await env.DB.prepare("UPDATE sessions SET expires_at = ? WHERE token_hash = ?")
      .bind(new Date(Date.now() - 1000).toISOString(), tokenHash)
      .run();
    const response = await api("GET", "/v1/me", { token });
    expect(response.status).toBe(401);
    expect(response.body.error.message).toMatch(/expired/);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM sessions WHERE token_hash = ?").bind(tokenHash).first("n")).toBe(0);
  });
});

describe("routing", () => {
  it("answers health, 404, and 405", async () => {
    expect((await api("GET", "/v1/health")).body).toEqual({ ok: true });
    expect((await api("GET", "/nope")).status).toBe(404);
    expect((await api("PUT", "/v1/me")).status).toBe(405);
  });

  it("rejects non-JSON and oversized bodies", async () => {
    const { token } = await signIn();
    const send = (body: string) =>
      makeApp().fetch(
        new Request("https://api.test/v1/teams", { method: "POST", headers: { authorization: `Bearer ${token}` }, body }),
        env,
      );
    expect((await send("{nope")).status).toBe(400);
    expect((await send("[]")).status).toBe(400);
    expect((await send(JSON.stringify({ name: "x".repeat(600 * 1024) }))).status).toBe(413);
  });
});
