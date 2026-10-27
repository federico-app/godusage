import { describe, expect, it } from "vitest";
import { api, NOW, teamWith, upload } from "./support";

function withPlans(plans: { provider: string; plan: string }[] | undefined, localDay?: string) {
  return {
    ...upload([{ provider: "claude", days: [{ date: "2026-10-04", tokens: 1, costUSD: 1 }] }]),
    ...(plans === undefined ? {} : { detectedPlans: plans }),
    ...(localDay === undefined ? {} : { localDay }),
  };
}

describe("detected plans", () => {
  const plan = { provider: "claude", name: "Claude Max 200", monthlyCostUSD: 200, renewalDay: 1, detectedPlan: "Max 20x" };

  async function flaggedTeam() {
    const ctx = await teamWith(["Bea"]);
    const bea = ctx.members[0]!;
    await api("PUT", `/v1/devices/device-bbbb-0002/usage`, { token: bea.token, body: withPlans([{ provider: "claude", plan: "Max 5x" }], "2026-10-04") });
    await api("PUT", `/v1/devices/device-aaaa-0001/usage`, { token: ctx.owner.token, body: withPlans([{ provider: "claude", plan: "Max 20x" }]) });
    return { ...ctx, bea };
  }

  it("flags a plan when a covered member's Mac detects another plan, for owners only", async () => {
    const { owner, team, bea } = await flaggedTeam();
    const saved = (await api("PUT", `/v1/teams/${team.id}/plans`, { token: owner.token, body: { plans: [plan] } })).body;
    expect(saved.plans[0].mismatches).toEqual([
      { userID: bea.userID, displayName: "Bea", detectedPlan: "Max 5x", detectedAt: NOW.toISOString(), detectedOn: "2026-10-04" },
    ]);
    expect(saved.detectedPlans.map((d: { plan: string }) => d.plan).sort()).toEqual(["Max 20x", "Max 5x"]);

    const forBea = (await api("GET", `/v1/teams/${team.id}/plans`, { token: bea.token })).body;
    expect(forBea.plans[0].mismatches).toEqual([]);
    expect(forBea.detectedPlans).toEqual([]);
  });

  it("doesn't flag a plan with no linked label, an ignored label, a marked change, or an uncovered member", async () => {
    const { owner, team } = await flaggedTeam();
    const cases = [
      { ...plan, detectedPlan: null },
      { ...plan, ignoredPlans: ["max 5X"] },
      { ...plan, changes: [{ effectiveFrom: "2026-11-01", name: "Max 5x", monthlyCostUSD: 100, previousName: "Claude Max 200", previousMonthlyCostUSD: 200 }] },
      { ...plan, memberIDs: [owner.userID] },
    ];
    const saved = (await api("PUT", `/v1/teams/${team.id}/plans`, { token: owner.token, body: { plans: cases } })).body;
    expect(saved.plans.map((p: { mismatches: unknown[] }) => p.mismatches)).toEqual([[], [], [], []]);
    expect(saved.plans[1].ignoredPlans).toEqual(["max 5X"]);
  });

  it("keeps when a label was first seen, and shows a new one at once", async () => {
    const { owner, team, bea } = await flaggedTeam();
    await api("PUT", `/v1/teams/${team.id}/plans`, { token: owner.token, body: { plans: [plan] } });
    const later = new Date("2026-10-05T18:00:00Z");
    await api("PUT", `/v1/devices/device-bbbb-0002/usage`, { token: bea.token, now: later, body: withPlans([{ provider: "claude", plan: "Max 5x" }]) });
    let report = (await api("GET", `/v1/teams/${team.id}/plans`, { token: owner.token, now: later })).body;
    expect(report.plans[0].mismatches[0].detectedAt).toBe(NOW.toISOString());

    await api("PUT", `/v1/devices/device-bbbb-0002/usage`, { token: bea.token, now: later, body: withPlans([{ provider: "claude", plan: "Pro" }]) });
    report = (await api("GET", `/v1/teams/${team.id}/plans`, { token: owner.token, now: later })).body;
    expect(report.plans[0].mismatches[0]).toMatchObject({ detectedPlan: "Pro", detectedAt: later.toISOString(), detectedOn: "2026-10-05" });
  });

  it("leaves detections alone for apps that don't send them, and drops them with the Mac", async () => {
    const { owner, team, bea } = await flaggedTeam();
    await api("PUT", `/v1/devices/device-bbbb-0002/usage`, { token: bea.token, body: withPlans(undefined) });
    let report = (await api("PUT", `/v1/teams/${team.id}/plans`, { token: owner.token, body: { plans: [plan] } })).body;
    expect(report.plans[0].mismatches).toHaveLength(1);

    const exported = (await api("GET", "/v1/me/export", { token: bea.token })).body;
    expect(exported.detectedPlans).toEqual([
      { device_id: "device-bbbb-0002", provider: "claude", plan: "Max 5x", detected_at: NOW.toISOString(), detected_on: "2026-10-04" },
    ]);

    expect((await api("DELETE", "/v1/devices/device-bbbb-0002", { token: bea.token })).status).toBe(204);
    report = (await api("PUT", `/v1/teams/${team.id}/plans`, { token: owner.token, body: { plans: [plan] } })).body;
    expect(report.plans[0].mismatches).toEqual([]);
  });

  it("drops a provider's detection when the Mac stops sending it", async () => {
    const { owner, team, bea } = await flaggedTeam();
    await api("PUT", `/v1/devices/device-bbbb-0002/usage`, { token: bea.token, body: withPlans([]) });
    const report = (await api("PUT", `/v1/teams/${team.id}/plans`, { token: owner.token, body: { plans: [plan] } })).body;
    expect(report.plans[0].mismatches).toEqual([]);
  });

  it.each([
    ["not an array", { provider: "claude", plan: "x" }],
    ["a bad provider", [{ provider: "Claude!", plan: "x" }]],
    ["an empty plan", [{ provider: "claude", plan: " " }]],
    ["a duplicate provider", [{ provider: "claude", plan: "a" }, { provider: "claude", plan: "b" }]],
  ])("rejects detected plans that are %s", async (_label, detectedPlans) => {
    const { owner } = await teamWith([]);
    const body = { ...withPlans(undefined), detectedPlans };
    expect((await api("PUT", `/v1/devices/device-aaaa-0001/usage`, { token: owner.token, body })).status).toBe(400);
  });

  it("rejects a local day far from today", async () => {
    const { owner } = await teamWith([]);
    const body = withPlans([], "2026-09-01");
    expect((await api("PUT", `/v1/devices/device-aaaa-0001/usage`, { token: owner.token, body })).status).toBe(400);
  });
});
