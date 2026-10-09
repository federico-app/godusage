import { describe, expect, it } from "vitest";
import { rangeBounds } from "../src/stats";
import { api, signIn, teamWith, upload } from "./support";

const DEVICE = "device-aaaa-0001";
const put = (token: string, body: unknown, now?: Date) => api("PUT", `/v1/devices/${DEVICE}/usage`, { token, body, now });

describe("month-to-date", () => {
  it("bounds the month so far and the same days of the month before", () => {
    expect(rangeBounds("mtd", "2026-10-05")).toEqual({ from: "2026-10-01", to: "2026-10-05", previousFrom: "2026-09-01", previousTo: "2026-09-05" });
    // March 31st compares with all of February.
    expect(rangeBounds("mtd", "2026-03-31")).toEqual({ from: "2026-03-01", to: "2026-03-31", previousFrom: "2026-02-01", previousTo: "2026-02-28" });
  });
});

describe("reactions", () => {
  it("gives, counts, and takes back reactions, and marks the viewer's own", async () => {
    const { owner, team, members } = await teamWith(["Bea", "Cy"]);
    const [bea, cy] = members as [typeof owner, typeof owner];
    const path = (to: string, emoji: string) => `/v1/teams/${team.id}/members/${to}/reactions/${emoji}`;

    expect((await api("PUT", path(bea.userID, "fire"), { token: owner.token })).status).toBe(200);
    await api("PUT", path(bea.userID, "fire"), { token: owner.token }); // idempotent
    await api("PUT", path(bea.userID, "fire"), { token: cy.token });
    await api("PUT", path(bea.userID, "clown"), { token: cy.token });

    const stats = (await api("GET", `/v1/teams/${team.id}/stats?range=today`, { token: owner.token })).body;
    expect(stats.reactions.day).toBe("2026-10-05");
    expect(stats.reactions.week).toBe("2026-10-05"); // legacy key for installed apps
    expect(stats.reactions.byMember[bea.userID]).toEqual({
      fire: 2,
      clap: 0,
      clown: 1,
      mine: ["fire"],
      from: { fire: [owner.userID, cy.userID], clap: [], clown: [cy.userID] },
    });

    const removed = await api("DELETE", path(bea.userID, "fire"), { token: owner.token });
    expect(removed.body.reactions[bea.userID]).toEqual({ fire: 1, clap: 0, clown: 1, mine: [], from: { fire: [cy.userID], clap: [], clown: [cy.userID] } });
  });

  it("starts each UTC day clean", async () => {
    const { owner, team, members } = await teamWith(["Bea"]);
    const path = `/v1/teams/${team.id}/members/${members[0]!.userID}/reactions/clap`;
    await api("PUT", path, { token: owner.token, now: new Date("2026-10-05T23:59:00Z") });
    const nextDay = await api("GET", `/v1/teams/${team.id}/stats?range=today`, { token: owner.token, now: new Date("2026-10-06T00:01:00Z") });
    expect(nextDay.body.reactions).toEqual({ day: "2026-10-06", week: "2026-10-06", byMember: {} });
    // Yesterday's reaction doesn't count today, so the same one can be given again.
    const again = await api("PUT", path, { token: owner.token, now: new Date("2026-10-06T00:02:00Z") });
    expect(again.body.reactions[members[0]!.userID]).toEqual({ fire: 0, clap: 1, clown: 0, mine: ["clap"], from: { fire: [], clap: [owner.userID], clown: [] } });
  });

  it("refuses self-reactions, unknown emoji, and outsiders", async () => {
    const { owner, team, members } = await teamWith(["Bea"]);
    expect((await api("PUT", `/v1/teams/${team.id}/members/${owner.userID}/reactions/fire`, { token: owner.token })).status).toBe(403);
    expect((await api("PUT", `/v1/teams/${team.id}/members/${members[0]!.userID}/reactions/poop`, { token: owner.token })).status).toBe(400);
    const stranger = await signIn();
    expect((await api("PUT", `/v1/teams/${team.id}/members/${members[0]!.userID}/reactions/fire`, { token: stranger.token })).status).toBe(404);
    expect((await api("PUT", `/v1/teams/${team.id}/members/${stranger.userID}/reactions/fire`, { token: owner.token })).status).toBe(404);
  });
});

describe("champions", () => {
  it("names each complete month's top spender, newest first", async () => {
    const { owner, team, members } = await teamWith(["Bea"]);
    const [bea] = members as [typeof owner];
    await put(owner.token, upload([{ provider: "claude", days: [{ date: "2026-08-10", tokens: 1, costUSD: 50 }, { date: "2026-09-10", tokens: 1, costUSD: 5 }] }]), new Date("2026-09-15T12:00:00Z"));
    await put(bea.token, upload([{ provider: "codex", days: [{ date: "2026-09-12", tokens: 1, costUSD: 30 }] }]), new Date("2026-09-15T12:00:00Z"));
    // This month's usage never counts: October isn't over.
    await put(owner.token, { ...upload([{ provider: "claude", days: [{ date: "2026-10-03", tokens: 1, costUSD: 999 }] }]), windowStart: "2026-10-01" });

    const champions = (await api("GET", `/v1/teams/${team.id}/stats?range=today`, { token: owner.token })).body.champions;
    expect(champions).toEqual([
      { month: "2026-09", userID: bea.userID, displayName: "Bea", costUSD: 30 },
      { month: "2026-08", userID: owner.userID, displayName: "Owner", costUSD: 50 },
    ]);
  });
});

describe("challenges", () => {
  const create = (token: string, teamID: string, kind: string, days = 7) =>
    api("POST", `/v1/teams/${teamID}/challenges`, { token, body: { kind, days } });

  it("ranks members live and fixes the winner after the end", async () => {
    const { owner, team, members } = await teamWith(["Bea", "Cy"]);
    const [bea, cy] = members as [typeof owner, typeof owner];
    const created = await create(bea.token, team.id, "lowest_spend");
    expect(created.status).toBe(201);
    expect(created.body.challenge).toMatchObject({ kind: "lowest_spend", startsOn: "2026-10-05", endsOn: "2026-10-11", daysLeft: 7, finished: false });

    await put(owner.token, upload([{ provider: "claude", days: [{ date: "2026-10-05", tokens: 10, costUSD: 9 }] }]));
    await put(bea.token, upload([{ provider: "claude", days: [{ date: "2026-10-05", tokens: 10, costUSD: 2 }] }]));
    // Cy spent nothing: not a candidate for "lowest spend".

    const live = (await api("GET", `/v1/teams/${team.id}/challenges`, { token: cy.token })).body.challenges[0];
    expect(live.standings.map((s: { displayName: string; rank: number; value: number }) => [s.displayName, s.rank, s.value])).toEqual([["Bea", 1, 2], ["Owner", 2, 9]]);
    expect(live.winners).toEqual([]);

    const after = (await api("GET", `/v1/teams/${team.id}/challenges`, { token: cy.token, now: new Date("2026-10-12T12:00:00Z") })).body.challenges[0];
    expect(after).toMatchObject({ finished: true, daysLeft: 0 });
    expect(after.winners.map((w: { displayName: string }) => w.displayName)).toEqual(["Bea"]);
  });

  it("counts distinct models, tokens, and efficiency", async () => {
    const { owner, team, members } = await teamWith(["Bea"]);
    const [bea] = members as [typeof owner];
    await create(owner.token, team.id, "most_models");
    await create(owner.token, team.id, "most_tokens");
    await create(owner.token, team.id, "best_efficiency");
    await put(owner.token, upload([{ provider: "claude", days: [{ date: "2026-10-05", tokens: 200_000, costUSD: 2, models: [{ model: "opus", tokens: 100_000, costUSD: 1.5 }, { model: "sonnet", tokens: 100_000, costUSD: 0.5 }] }] }]));
    await put(bea.token, upload([{ provider: "codex", days: [{ date: "2026-10-05", tokens: 1_000_000, costUSD: 3, models: [{ model: "gpt-5", tokens: 1_000_000, costUSD: 3 }] }] }]));

    const byKind = Object.fromEntries(
      (await api("GET", `/v1/teams/${team.id}/challenges`, { token: owner.token })).body.challenges.map((c: { kind: string; standings: unknown }) => [c.kind, c.standings]),
    );
    expect(byKind.most_models.map((s: { displayName: string; value: number }) => [s.displayName, s.value])).toEqual([["Owner", 2], ["Bea", 1]]);
    expect(byKind.most_tokens.map((s: { displayName: string }) => s.displayName)).toEqual(["Bea", "Owner"]);
    // $3 per 1M vs $10 per 1M: lower is better.
    expect(byKind.best_efficiency.map((s: { displayName: string; value: number }) => [s.displayName, s.value])).toEqual([["Bea", 3], ["Owner", 10]]);
  });

  it("validates, caps active challenges, and lets only the creator or owner cancel", async () => {
    const { owner, team, members } = await teamWith(["Bea", "Cy"]);
    const [bea, cy] = members as [typeof owner, typeof owner];
    expect((await create(bea.token, team.id, "most_fun")).status).toBe(400);
    expect((await create(bea.token, team.id, "most_tokens", 3)).status).toBe(400);
    const stranger = await signIn();
    expect((await create(stranger.token, team.id, "most_tokens")).status).toBe(404);

    const mine = (await create(bea.token, team.id, "most_tokens")).body.challenge;
    for (let i = 0; i < 4; i++) await create(bea.token, team.id, "most_tokens");
    expect((await create(bea.token, team.id, "most_tokens")).status).toBe(409);

    expect((await api("DELETE", `/v1/teams/${team.id}/challenges/${mine.id}`, { token: cy.token })).status).toBe(403);
    expect((await api("DELETE", `/v1/teams/${team.id}/challenges/${mine.id}`, { token: owner.token })).status).toBe(204);
  });
});
