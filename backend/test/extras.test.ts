import { describe, expect, it } from "vitest";
import { api, signIn, teamWith, upload } from "./support";

describe("data export", () => {
  it("returns everything the server keeps about the user, and nothing about others", async () => {
    const { owner, team, members } = await teamWith(["Bea"]);
    const [bea] = members as [typeof owner];
    await api("PUT", "/v1/devices/device-aaaa-0001/usage", {
      token: owner.token,
      body: upload([{ provider: "claude", days: [{ date: "2026-10-05", tokens: 7, costUSD: 1, models: [{ model: "opus", tokens: 7, costUSD: 1 }] }] }], "Office Mac"),
    });
    await api("PUT", `/v1/teams/${team.id}/members/${bea.userID}/reactions/fire`, { token: owner.token });
    await api("PUT", `/v1/teams/${team.id}/members/${owner.userID}/reactions/clap`, { token: bea.token });
    await api("POST", `/v1/teams/${team.id}/challenges`, { token: owner.token, body: { kind: "most_tokens", days: 7 } });

    const exported = await api("GET", "/v1/me/export", { token: owner.token });
    expect(exported.status).toBe(200);
    const body = exported.body;
    expect(body.schema).toBe("godusage.export.v1");
    expect(body.account).toMatchObject({ id: owner.userID, displayName: "Owner" });
    expect(body.devices).toEqual([expect.objectContaining({ id: "device-aaaa-0001", name: "Office Mac" })]);
    expect(body.usageDays).toEqual([expect.objectContaining({ provider: "claude", day: "2026-10-05", tokens: 7, cost_usd: 1 })]);
    expect(body.usageModelDays).toHaveLength(1);
    expect(body.teams).toEqual([expect.objectContaining({ id: team.id, role: "owner" })]);
    expect(body.reactionsGiven).toEqual([expect.objectContaining({ to_user: bea.userID, emoji: "fire" })]);
    expect(body.reactionsReceived).toEqual([expect.objectContaining({ from_user: bea.userID, emoji: "clap" })]);
    expect(body.challengesStarted).toHaveLength(1);
    expect(JSON.stringify(body)).not.toContain(owner.token);
  });

  it("requires sign-in", async () => {
    expect((await api("GET", "/v1/me/export")).status).toBe(401);
  });
});

describe("legal pages", () => {
  it("serves the privacy policy and terms, linked from every page", async () => {
    const privacy = await api("GET", "/privacy");
    expect(privacy.status).toBe(200);
    expect(privacy.body).toContain("Privacy Policy");
    expect(privacy.body).toContain("Export My Data");
    expect((await api("GET", "/terms")).body).toContain("Terms of Use");
    expect((await api("GET", "/")).body).toContain(`href="/privacy"`);
  });
});

describe("web board extras", () => {
  it("shows crowns, reactions, the projection, challenges, and champions", async () => {
    const { owner, team, members } = await teamWith(["Bea"]);
    const [bea] = members as [typeof owner];
    await api("PUT", "/v1/devices/device-aaaa-0001/usage", {
      token: owner.token,
      now: new Date("2026-09-15T12:00:00Z"),
      body: upload([{ provider: "claude", days: [{ date: "2026-09-10", tokens: 1, costUSD: 40 }] }]),
    });
    await api("PUT", "/v1/devices/device-aaaa-0001/usage", {
      token: bea.token,
      body: upload([{ provider: "codex", days: [{ date: "2026-10-05", tokens: 1, costUSD: 5 }] }]),
    });
    await api("PUT", `/v1/teams/${team.id}/members/${bea.userID}/reactions/fire`, { token: owner.token });
    await api("POST", `/v1/teams/${team.id}/challenges`, { token: owner.token, body: { kind: "lowest_spend", days: 7 } });

    const shared = await api("PATCH", `/v1/teams/${team.id}`, { token: owner.token, body: { publicBoard: true } });
    const html = (await api("GET", `${new URL(shared.body.team.publicBoardURL).pathname}?range=7d`)).body as string;
    expect(html).toContain("👑"); // Bea leads today
    expect(html).toContain("🏆 September 2026");
    expect(html).toContain("🔥1");
    // $5 in the first 5 of October's 31 days.
    expect(html).toContain("Team on pace for $31.00 in October");
    expect(html).toContain("Lowest Spend");
    expect(html).toContain("Leading: Bea");
    expect(html).toContain(">Year<");
  });
});
