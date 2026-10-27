import { describe, expect, it } from "vitest";
import { cyclePeriods, parsePriceHistory, termsOn } from "../src/planChanges";
import { api, teamWith, upload } from "./support";

// Today is 2026-10-05 (support.NOW). A plan renewing on the 1st is in its Oct 1–31 cycle: 31 days.
const history = {
  base: { name: "Max 20x", monthlyCostUSD: 200 },
  changes: [
    { effectiveFrom: "2026-10-03", name: "Max 5x", monthlyCostUSD: 100 },
    { effectiveFrom: "2026-11-01", name: "Pro", monthlyCostUSD: 20 },
  ],
};

describe("price history", () => {
  it("knows the terms on any day", () => {
    expect(termsOn(history, "2026-10-02")).toEqual({ name: "Max 20x", monthlyCostUSD: 200 });
    expect(termsOn(history, "2026-10-03")).toEqual({ name: "Max 5x", monthlyCostUSD: 100 });
    expect(termsOn(history, "2026-12-01")).toEqual({ name: "Pro", monthlyCostUSD: 20 });
  });

  it("splits a cycle at each change inside it", () => {
    expect(cyclePeriods(history, "2026-10-01", "2026-10-31")).toEqual([
      { name: "Max 20x", monthlyCostUSD: 200, from: "2026-10-01", to: "2026-10-02", days: 2 },
      { name: "Max 5x", monthlyCostUSD: 100, from: "2026-10-03", to: "2026-10-31", days: 29 },
    ]);
    expect(cyclePeriods(history, "2026-11-01", "2026-11-30")).toEqual([
      { name: "Pro", monthlyCostUSD: 20, from: "2026-11-01", to: "2026-11-30", days: 30 },
    ]);
  });

  it("takes the plan's own terms as the ones in effect today", () => {
    const wire = [
      { effectiveFrom: "2026-10-03", name: "Max 5x", monthlyCostUSD: 100, previousName: "Max 20x", previousMonthlyCostUSD: 200 },
      { effectiveFrom: "2026-11-01", name: "Pro", monthlyCostUSD: 20, previousName: "ignored", previousMonthlyCostUSD: 1 },
    ];
    // The owner renamed the current terms: the change in effect today takes the edit.
    expect(parsePriceHistory({ name: "Max 5x Team", monthlyCostUSD: 110 }, wire, "2026-10-05")).toEqual({
      base: { name: "Max 20x", monthlyCostUSD: 200 },
      changes: [
        { effectiveFrom: "2026-10-03", name: "Max 5x Team", monthlyCostUSD: 110 },
        { effectiveFrom: "2026-11-01", name: "Pro", monthlyCostUSD: 20 },
      ],
    });
    // Before any change applies, they are the plan's starting terms.
    expect(parsePriceHistory({ name: "Max", monthlyCostUSD: 180 }, wire, "2026-10-02").base).toEqual({ name: "Max", monthlyCostUSD: 180 });
  });
});

describe("plan changes", () => {
  const base = { provider: "claude", name: "Max 20x", monthlyCostUSD: 200, renewalDay: 1 };
  const change = (effectiveFrom: string, name: string, monthlyCostUSD: number) => ({
    effectiveFrom, name, monthlyCostUSD, previousName: "Max 20x", previousMonthlyCostUSD: 200,
  });

  async function teamWithUsage() {
    const ctx = await teamWith([]);
    await api("PUT", `/v1/devices/device-aaaa-0001/usage`, {
      token: ctx.owner.token,
      body: upload([{ provider: "claude", days: [{ date: "2026-10-02", tokens: 1, costUSD: 31 }, { date: "2026-10-04", tokens: 1, costUSD: 31 }] }]),
    });
    return ctx;
  }

  it("keeps the current cycle unchanged until a change from the next renewal", async () => {
    const { owner, team } = await teamWithUsage();
    const body = { plans: [{ ...base, changes: [change("2026-11-01", "Max 5x", 100)] }] };
    const saved = (await api("PUT", `/v1/teams/${team.id}/plans`, { token: owner.token, body })).body;
    expect(saved.plans[0]).toMatchObject({ name: "Max 20x", monthlyCostUSD: 200, cycleCostUSD: 200, valueUSD: 62 });
    expect(saved.plans[0].periods).toHaveLength(1);
    expect(saved.plans[0].changes).toEqual([change("2026-11-01", "Max 5x", 100)]);

    // From the renewal, the plan has its new terms.
    const later = (await api("GET", `/v1/teams/${team.id}/plans`, { token: owner.token, now: new Date("2026-11-02T12:00:00Z") })).body;
    expect(later.plans[0]).toMatchObject({ name: "Max 5x", monthlyCostUSD: 100, cycleCostUSD: 100 });
  });

  it("prorates a cycle with a change inside it and counts usage against the price of its day", async () => {
    const { owner, team } = await teamWithUsage();
    const body = { plans: [{ ...base, name: "Max 5x", monthlyCostUSD: 100, changes: [change("2026-10-03", "Max 5x", 100)] }] };
    const plan = (await api("PUT", `/v1/teams/${team.id}/plans`, { token: owner.token, body })).body.plans[0];
    // $200 for 2 of 31 days plus $100 for 29 of 31 days.
    expect(plan).toMatchObject({ name: "Max 5x", monthlyCostUSD: 100, cycleCostUSD: 106.45, valueUSD: 62, projectedValueUSD: 384.4, projectedMultiple: 3.61 });
    expect(plan.periods).toEqual([
      { name: "Max 20x", monthlyCostUSD: 200, from: "2026-10-01", to: "2026-10-02", costUSD: 12.9, valueUSD: 31 },
      { name: "Max 5x", monthlyCostUSD: 100, from: "2026-10-03", to: "2026-10-31", costUSD: 93.55, valueUSD: 31 },
    ]);
    const report = (await api("GET", `/v1/teams/${team.id}/plans`, { token: owner.token })).body;
    expect(report.totals).toMatchObject({ monthlyCostUSD: 100, cycleCostUSD: 106.45 });
  });

  it("ignores a change from an earlier cycle", async () => {
    const { owner, team } = await teamWithUsage();
    const body = { plans: [{ ...base, name: "Max 5x", monthlyCostUSD: 100, changes: [change("2026-09-15", "Max 5x", 100)] }] };
    const plan = (await api("PUT", `/v1/teams/${team.id}/plans`, { token: owner.token, body })).body.plans[0];
    expect(plan).toMatchObject({ cycleCostUSD: 100, periods: [{ name: "Max 5x", from: "2026-10-01" }] });
  });

  it("splits a provider's value by each plan's price on the day", async () => {
    const { owner, team } = await teamWithUsage();
    const body = {
      plans: [
        { ...base, name: "Max 5x", monthlyCostUSD: 100, changes: [change("2026-10-03", "Max 5x", 100)] },
        { provider: "claude", name: "Pro", monthlyCostUSD: 100, renewalDay: 1 },
      ],
    };
    const plans = (await api("PUT", `/v1/teams/${team.id}/plans`, { token: owner.token, body })).body.plans;
    // Oct 2: 200:100 → 20.67 and 10.33. Oct 4: 100:100 → 15.5 each.
    expect(plans.map((p: { valueUSD: number }) => p.valueUSD)).toEqual([36.17, 25.83]);
  });

  it("round-trips the price history, and cancelling a change removes it", async () => {
    const { owner, team } = await teamWithUsage();
    const body = { plans: [{ ...base, name: "Max 5x", monthlyCostUSD: 100, changes: [change("2026-10-03", "Max 5x", 100), { ...change("2026-11-01", "Pro", 20), previousName: "x" }] }] };
    const first = (await api("PUT", `/v1/teams/${team.id}/plans`, { token: owner.token, body })).body.plans[0];
    expect(first.changes[1]).toMatchObject({ previousName: "Max 5x", previousMonthlyCostUSD: 100, name: "Pro" });
    const again = (await api("PUT", `/v1/teams/${team.id}/plans`, { token: owner.token, body: { plans: [first] } })).body.plans[0];
    expect(again.changes).toEqual(first.changes);
    expect(again.cycleCostUSD).toBe(first.cycleCostUSD);

    const cancelled = { ...first, changes: first.changes.slice(0, 1) };
    const after = (await api("PUT", `/v1/teams/${team.id}/plans`, { token: owner.token, body: { plans: [cancelled] } })).body.plans[0];
    expect(after.changes.map((c: { name: string }) => c.name)).toEqual(["Max 5x"]);
  });

  it.each([
    ["changes not an array", { changes: "soon" }],
    ["a bad date", { changes: [change("2026-13-01", "x", 1)] }],
    ["changes out of order", { changes: [change("2026-11-01", "x", 1), change("2026-10-03", "y", 1)] }],
    ["two changes on one day", { changes: [change("2026-11-01", "x", 1), change("2026-11-01", "y", 1)] }],
    ["a free change", { changes: [change("2026-11-01", "x", 0)] }],
    ["no previous terms", { changes: [{ effectiveFrom: "2026-11-01", name: "x", monthlyCostUSD: 1 }] }],
    ["a long detected plan", { detectedPlan: "x".repeat(61) }],
    ["ignored plans not a list", { ignoredPlans: "Pro" }],
  ])("rejects %s", async (_label, extra) => {
    const { owner, team } = await teamWith([]);
    const body = { plans: [{ ...base, ...extra }] };
    expect((await api("PUT", `/v1/teams/${team.id}/plans`, { token: owner.token, body })).status).toBe(400);
  });
});
