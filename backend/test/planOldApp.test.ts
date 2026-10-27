import { describe, expect, it } from "vitest";
import { api, teamWith } from "./support";

// Today is 2026-10-05 (support.NOW).
describe("saving plans from an app before plan changes", () => {
  const full = {
    provider: "claude", name: "Max 5x", monthlyCostUSD: 100, renewalDay: 1, detectedPlan: "Max 5x", ignoredPlans: ["Pro"],
    changes: [
      { effectiveFrom: "2026-10-03", name: "Max 5x", monthlyCostUSD: 100, previousName: "Max 20x", previousMonthlyCostUSD: 200 },
      { effectiveFrom: "2026-11-01", name: "Team", monthlyCostUSD: 30, previousName: "Max 5x", previousMonthlyCostUSD: 100 },
    ],
  };
  const cursor = { provider: "cursor", name: "Ultra", monthlyCostUSD: 200, renewalDay: 1 };
  /** What an old app sends back: the report's plan without the fields it doesn't know. */
  const old = (plan: { provider: string; name: string; monthlyCostUSD: number; renewalDay: number }) =>
    ({ provider: plan.provider, name: plan.name, monthlyCostUSD: plan.monthlyCostUSD, renewalDay: plan.renewalDay });

  async function saved(plans: unknown[]) {
    const { owner, team } = await teamWith([]);
    const put = (body: unknown[]) => api("PUT", `/v1/teams/${team.id}/plans`, { token: owner.token, body: { plans: body } });
    const response = await put(plans);
    expect(response.status).toBe(200);
    return { first: response.body.plans, put };
  }

  it("keeps the history, link, and ignored plans it doesn't send", async () => {
    const { first, put } = await saved([full]);
    const again = (await put([old(first[0])])).body.plans[0];
    expect(again.changes).toEqual(first[0].changes);
    expect(again).toMatchObject({ detectedPlan: "Max 5x", ignoredPlans: ["Pro"], cycleCostUSD: first[0].cycleCostUSD });
    expect(again.periods[0]).toMatchObject({ name: "Max 20x", monthlyCostUSD: 200 });
  });

  it("takes its name and price as today's terms, not the starting ones", async () => {
    const { first, put } = await saved([full]);
    const again = (await put([{ ...old(first[0]), monthlyCostUSD: 110 }])).body.plans[0];
    expect(again.changes.map((c: { monthlyCostUSD: number }) => c.monthlyCostUSD)).toEqual([110, 30]);
    expect(again.changes[0]).toMatchObject({ previousName: "Max 20x", previousMonthlyCostUSD: 200 });
    expect(again.changes[1]).toMatchObject({ previousMonthlyCostUSD: 110 });
  });

  it("matches plans by provider and current name when reordered, else by position", async () => {
    const { first, put } = await saved([full, cursor]);
    const reordered = (await put([old(first[1]), old(first[0])])).body.plans;
    expect(reordered[1].changes).toHaveLength(2);
    expect(reordered[0].changes).toEqual([]);

    // Renamed in place: no name matches, so the plan at the same position (same provider) does.
    const renamed = (await put([old(reordered[0]), { ...old(reordered[1]), name: "Max Five" }])).body.plans;
    expect(renamed[1].changes.map((c: { name: string }) => c.name)).toEqual(["Max Five", "Team"]);
    expect(renamed[1].detectedPlan).toBe("Max 5x");
  });

  it("starts fresh for a plan with no match", async () => {
    const { put } = await saved([full]);
    const plans = (await put([cursor])).body.plans;
    expect(plans[0]).toMatchObject({ changes: [], detectedPlan: null, ignoredPlans: [] });
  });

  it("replaces them when they are sent, even empty or null", async () => {
    const { first, put } = await saved([full]);
    const cleared = (await put([{ ...old(first[0]), changes: [], detectedPlan: null, ignoredPlans: [] }])).body.plans[0];
    expect(cleared).toMatchObject({ changes: [], detectedPlan: null, ignoredPlans: [], cycleCostUSD: 100 });
    const nulled = (await put([{ ...old(first[0]), changes: null }])).body.plans[0];
    expect(nulled.changes).toEqual([]);
  });
});
