import { describe, expect, it } from "vitest";
import { api, teamWith, upload } from "./support";

describe("owners who don't count", () => {
  const patch = (teamID: string, userID: string, token: string, body: object) =>
    api("PATCH", `/v1/teams/${teamID}/members/${userID}`, { token, body });

  it("leaves the owner out of the board and plans, but lets them run the team", async () => {
    const { owner, team, members } = await teamWith(["Bea"]);
    const bea = members[0]!;
    await api("PUT", "/v1/devices/device-aaaa-0001/usage", {
      token: owner.token,
      body: upload([{ provider: "claude", days: [{ date: "2026-10-04", tokens: 100, costUSD: 40 }] }]),
    });
    await api("PUT", "/v1/devices/device-bbbb-0002/usage", {
      token: bea.token,
      body: upload([{ provider: "claude", days: [{ date: "2026-10-04", tokens: 10, costUSD: 10 }] }]),
    });
    await api("PUT", `/v1/teams/${team.id}/plans`, {
      token: owner.token,
      body: { plans: [{ provider: "claude", name: "Claude Max", monthlyCostUSD: 200, renewalDay: 1 }] },
    });

    const changed = await patch(team.id, owner.userID, owner.token, { countsUsage: false });
    expect(changed.status).toBe(200);
    expect(changed.body.team.role).toBe("owner");
    expect(changed.body.team.members.map((m: { countsUsage: boolean }) => m.countsUsage)).toEqual([false, true]);

    const stats = (await api("GET", `/v1/teams/${team.id}/stats?range=7d`, { token: owner.token })).body.stats;
    expect(stats.members.map((m: { userID: string }) => m.userID)).toEqual([bea.userID]);
    expect(stats.totals).toMatchObject({ costUSD: 10 });

    const plans = (await api("GET", `/v1/teams/${team.id}/plans`, { token: owner.token })).body;
    expect(plans.canEdit).toBe(true);
    expect(plans.plans[0]).toMatchObject({ valueUSD: 10, includesYou: false });

    // Counting again brings the usage back at once.
    await patch(team.id, owner.userID, owner.token, { countsUsage: true });
    const back = (await api("GET", `/v1/teams/${team.id}/stats?range=7d`, { token: owner.token })).body.stats;
    expect(back.totals).toMatchObject({ costUSD: 50 });
  });

  it("is each owner's own choice, and members always count", async () => {
    const { owner, team, members } = await teamWith(["Bea"]);
    const bea = members[0]!;
    expect((await patch(team.id, bea.userID, owner.token, { countsUsage: false })).status).toBe(403);
    expect((await patch(team.id, bea.userID, bea.token, { countsUsage: false })).status).toBe(403);
    expect((await patch(team.id, owner.userID, owner.token, { countsUsage: "no" })).status).toBe(400);

    // Making a non-counting owner a member makes them count again.
    await patch(team.id, bea.userID, owner.token, { role: "owner" });
    await patch(team.id, bea.userID, bea.token, { countsUsage: false });
    const demoted = await patch(team.id, bea.userID, owner.token, { role: "member" });
    expect(demoted.body.team.members.find((m: { id: string }) => m.id === bea.userID)).toMatchObject({ role: "member", countsUsage: true });
  });

  it("takes the owner off the plans that list them, and refuses when a plan covers only them", async () => {
    const { owner, team, members } = await teamWith(["Bea"]);
    const bea = members[0]!;
    const save = (plans: object[]) => api("PUT", `/v1/teams/${team.id}/plans`, { token: owner.token, body: { plans } });
    await save([{ provider: "claude", name: "Solo", monthlyCostUSD: 20, renewalDay: 1, memberIDs: [owner.userID] }]);
    const refused = await patch(team.id, owner.userID, owner.token, { countsUsage: false });
    expect(refused.status).toBe(409);
    expect(refused.body.error.message).toMatch(/Solo/);

    await save([{ provider: "claude", name: "Both", monthlyCostUSD: 20, renewalDay: 1, memberIDs: [owner.userID, bea.userID] }]);
    expect((await patch(team.id, owner.userID, owner.token, { countsUsage: false })).status).toBe(200);
    const plans = (await api("GET", `/v1/teams/${team.id}/plans`, { token: owner.token })).body;
    expect(plans.plans[0].memberIDs).toEqual([bea.userID]);
    const covering = await save([{ provider: "claude", name: "Both", monthlyCostUSD: 20, renewalDay: 1, memberIDs: [owner.userID] }]);
    expect(covering.status).toBe(400);
  });
});
