import { describe, expect, it } from "vitest";
import { currentCycle } from "../src/plans";
import { api, teamWith, upload } from "./support";

describe("plan cycles", () => {
  it("runs from the last renewal to the day before the next", () => {
    expect(currentCycle(12, "2026-10-05")).toEqual({ from: "2026-09-12", to: "2026-10-11", daysElapsed: 24, daysTotal: 30, daysLeft: 6 });
    expect(currentCycle(5, "2026-10-05")).toMatchObject({ from: "2026-10-05", to: "2026-11-04", daysElapsed: 1 });
    expect(currentCycle(1, "2026-12-31")).toMatchObject({ from: "2026-12-01", to: "2026-12-31", daysLeft: 0 });
  });

  it("renews on the last day of shorter months", () => {
    expect(currentCycle(31, "2026-02-28")).toMatchObject({ from: "2026-02-28", to: "2026-03-30" });
    expect(currentCycle(31, "2026-03-15")).toMatchObject({ from: "2026-02-28", to: "2026-03-30" });
    expect(currentCycle(30, "2026-01-05")).toMatchObject({ from: "2025-12-30", to: "2026-01-29" });
  });
});

describe("team plans", () => {
  const plans = [
    { provider: "claude", name: "Claude Max", monthlyCostUSD: 200, renewalDay: 1 },
    { provider: "cursor", name: "Cursor Ultra", monthlyCostUSD: 200, renewalDay: 1 },
  ];

  it("lets only the owner change plans and every member read the report", async () => {
    const { owner, team, members } = await teamWith(["Bea"]);
    const denied = await api("PUT", `/v1/teams/${team.id}/plans`, { token: members[0]!.token, body: { plans } });
    expect(denied.status).toBe(403);
    const saved = await api("PUT", `/v1/teams/${team.id}/plans`, { token: owner.token, body: { plans } });
    expect(saved.status).toBe(200);
    expect(saved.body.canEdit).toBe(true);
    const read = await api("GET", `/v1/teams/${team.id}/plans`, { token: members[0]!.token });
    expect(read.body.canEdit).toBe(false);
    expect(read.body.plans.map((p: { name: string }) => p.name)).toEqual(["Claude Max", "Cursor Ultra"]);
  });

  it("compares each plan with the team's API value in its cycle, counting shared accounts once", async () => {
    const { owner, team, members } = await teamWith(["Bea"]);
    const shared = "c".repeat(64);
    // Cycle Oct 1–31; today is Oct 5, so 5 of 31 days have passed.
    await api("PUT", `/v1/devices/device-aaaa-0001/usage`, {
      token: owner.token,
      body: upload([
        { provider: "claude", days: [{ date: "2026-10-03", tokens: 10, costUSD: 40 }, { date: "2026-09-30", tokens: 10, costUSD: 999 }] },
        { provider: "cursor", scope: "account", account: shared, days: [{ date: "2026-10-04", tokens: 10, costUSD: 10 }] },
      ]),
    });
    await api("PUT", `/v1/devices/device-bbbb-0002/usage`, {
      token: members[0]!.token,
      body: upload([
        { provider: "claude", days: [{ date: "2026-10-05", tokens: 10, costUSD: 10 }] },
        { provider: "cursor", scope: "account", account: shared, days: [{ date: "2026-10-04", tokens: 10, costUSD: 10 }] },
      ]),
    });
    const report = (await api("PUT", `/v1/teams/${team.id}/plans`, { token: owner.token, body: { plans } })).body;
    const [claude, cursor] = report.plans;
    expect(claude).toMatchObject({ valueUSD: 50, projectedValueUSD: 310, projectedMultiple: 1.55, underused: false });
    expect(claude.cycle).toMatchObject({ from: "2026-10-01", to: "2026-10-31", daysElapsed: 5, daysLeft: 26 });
    expect(cursor).toMatchObject({ valueUSD: 10, projectedValueUSD: 62, projectedMultiple: 0.31, underused: true });
    expect(report.totals).toEqual({ monthlyCostUSD: 400, valueUSD: 60, projectedValueUSD: 372 });
  });

  it("splits a provider's value between its plans by cost", async () => {
    const { owner, team } = await teamWith([]);
    await api("PUT", `/v1/devices/device-aaaa-0001/usage`, {
      token: owner.token,
      body: upload([{ provider: "claude", days: [{ date: "2026-10-02", tokens: 10, costUSD: 30 }] }]),
    });
    const body = {
      plans: [
        { provider: "claude", name: "Max", monthlyCostUSD: 200, renewalDay: 1 },
        { provider: "claude", name: "Pro", monthlyCostUSD: 100, renewalDay: 1 },
      ],
    };
    const report = (await api("PUT", `/v1/teams/${team.id}/plans`, { token: owner.token, body })).body;
    expect(report.plans.map((p: { valueUSD: number }) => p.valueUSD)).toEqual([20, 10]);
  });

  it.each([
    ["no plans array", {}],
    ["bad provider", { plans: [{ provider: "Claude!", name: "x", monthlyCostUSD: 1, renewalDay: 1 }] }],
    ["zero cost", { plans: [{ provider: "claude", name: "x", monthlyCostUSD: 0, renewalDay: 1 }] }],
    ["day 32", { plans: [{ provider: "claude", name: "x", monthlyCostUSD: 1, renewalDay: 32 }] }],
    ["empty name", { plans: [{ provider: "claude", name: "", monthlyCostUSD: 1, renewalDay: 1 }] }],
  ])("rejects %s", async (_label, body) => {
    const { owner, team } = await teamWith([]);
    expect((await api("PUT", `/v1/teams/${team.id}/plans`, { token: owner.token, body })).status).toBe(400);
  });

  it("hides another team's plans", async () => {
    const { team } = await teamWith([]);
    const { owner: stranger } = await teamWith([], "Stranger");
    expect((await api("GET", `/v1/teams/${team.id}/plans`, { token: stranger.token })).status).toBe(404);
  });
});
