import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { safeReturnPath } from "../src/routes/webSignIn";
import { api, appleToken, makeApp, NOW } from "./support";

const WEB_CLIENT = "com.montinovo.godusage.web";

async function raw(request: Request): Promise<Response> {
  return makeApp(NOW).fetch(request, env);
}

/** A native (app) account with a known Apple subject that owns a team. */
async function ownerWithTeam(sub: string, name = "Owner") {
  const signIn = await api("POST", "/v1/auth/apple", { body: { identityToken: await appleToken({ sub }), displayName: name } });
  const team = (await api("POST", "/v1/teams", { token: signIn.body.token, body: { name: "Crew" } })).body.team;
  return { token: signIn.body.token as string, team };
}

/** Runs the browser sign-in for `sub` against a board and returns the session cookie. */
async function browserSignIn(teamID: string, sub: string): Promise<{ response: Response; cookie: string | null }> {
  const start = await raw(new Request(`https://api.test/teams/${teamID}/sign-in`));
  expect(start.status).toBe(302);
  const apple = new URL(start.headers.get("location")!);
  expect(apple.searchParams.get("client_id")).toBe(WEB_CLIENT);
  const response = await raw(
    new Request("https://api.test/v1/auth/apple/callback", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        state: apple.searchParams.get("state")!,
        id_token: await appleToken({ aud: WEB_CLIENT, nonce: apple.searchParams.get("nonce")!, sub }),
      }).toString(),
    }),
  );
  const cookie = response.headers.get("set-cookie");
  return { response, cookie: cookie ? cookie.split(";")[0]! : null };
}

describe("members-only web leaderboard", () => {
  it("asks visitors to sign in", async () => {
    const { team } = await ownerWithTeam("board-owner-1");
    const page = await raw(new Request(`https://api.test/teams/${team.id}`));
    expect(page.status).toBe(200);
    const html = await page.text();
    expect(html).toContain("Sign In with Apple");
    expect(html).toContain(`href="/teams/${team.id}/sign-in"`);
    expect(html).not.toContain("Crew");
  });

  it("signs a member in with a secure 30-day cookie and shows the board", async () => {
    const { team } = await ownerWithTeam("board-owner-2", "Ada");
    const { response, cookie } = await browserSignIn(team.id, "board-owner-2");
    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toBe(`/teams/${team.id}`);
    const setCookie = response.headers.get("set-cookie")!;
    expect(setCookie).toMatch(/HttpOnly/);
    expect(setCookie).toMatch(/Secure/);
    expect(setCookie).toMatch(/SameSite=Lax/);
    expect(setCookie).toMatch(/Max-Age=2592000/);

    const board = await raw(new Request(`https://api.test/teams/${team.id}?range=today`, { headers: { cookie: cookie! } }));
    expect(board.status).toBe(200);
    const html = await board.text();
    expect(html).toContain("Crew");
    expect(html).toContain("Signed in as Ada");

    const lifetime = await env.DB.prepare("SELECT lifetime_days FROM sessions ORDER BY created_at DESC LIMIT 1").first("lifetime_days");
    expect(lifetime).toBe(30);
  });

  it("refuses signed-in people who are not members", async () => {
    const { team } = await ownerWithTeam("board-owner-3");
    const { cookie } = await browserSignIn(team.id, "outsider-3");
    const page = await raw(new Request(`https://api.test/teams/${team.id}`, { headers: { cookie: cookie! } }));
    expect(page.status).toBe(404);
    const html = await page.text();
    expect(html).toContain("Not a Member");
    expect(html).not.toContain("Crew");
  });

  it("returns to the board without a cookie when sign-in is cancelled", async () => {
    const { team } = await ownerWithTeam("board-owner-4");
    const start = await raw(new Request(`https://api.test/teams/${team.id}/sign-in`));
    const state = new URL(start.headers.get("location")!).searchParams.get("state")!;
    const cancelled = await raw(
      new Request("https://api.test/v1/auth/apple/callback", {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ state, error: "user_cancelled_authorize" }).toString(),
      }),
    );
    expect(cancelled.status).toBe(303);
    expect(cancelled.headers.get("location")).toBe(`/teams/${team.id}`);
    expect(cancelled.headers.get("set-cookie")).toBeNull();
  });

  it("signs out on a same-site post and refuses cross-site ones", async () => {
    const { team } = await ownerWithTeam("board-owner-5");
    const { cookie } = await browserSignIn(team.id, "board-owner-5");

    const crossSite = await raw(new Request("https://api.test/sign-out", { method: "POST", headers: { cookie: cookie!, origin: "https://evil.example" } }));
    expect(crossSite.status).toBe(403);

    const signOut = await raw(new Request("https://api.test/sign-out", { method: "POST", headers: { cookie: cookie!, origin: "https://api.test" } }));
    expect(signOut.status).toBe(303);
    expect(signOut.headers.get("set-cookie")).toMatch(/Max-Age=0/);
    expect((await raw(new Request("https://api.test/"))).status).toBe(200);
    const after = await raw(new Request(`https://api.test/teams/${team.id}`, { headers: { cookie: cookie! } }));
    expect(await after.text()).toContain("Sign In with Apple");
  });

  it("gives every member the web board link", async () => {
    const { token, team } = await ownerWithTeam("board-owner-6");
    expect(team.webBoardURL).toBe(`https://api.test/teams/${team.id}`);
    expect((await api("GET", `/v1/teams/${team.id}`, { token })).body.team.webBoardURL).toBe(team.webBoardURL);
  });

  it("only ever returns browsers to a team board on this site", () => {
    expect(safeReturnPath("/teams/abc-123")).toBe("/teams/abc-123");
    expect(safeReturnPath("https://evil.example/teams/x")).toBe("/");
    expect(safeReturnPath("//evil.example")).toBe("/");
    expect(safeReturnPath("/teams/../admin")).toBe("/");
    expect(safeReturnPath(null)).toBe("/");
  });
});
