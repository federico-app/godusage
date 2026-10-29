import { describe, expect, it } from "vitest";
import { api, NOW, teamWith, upload } from "./support";

const A = "a".repeat(64);
const B = "b".repeat(64);
const SHARED = "c".repeat(64);
const HOUR = 3_600_000;

/** A weekly window that resets `hoursFromNow` after the test clock (Oct 5, 12:00 UTC). */
function weekly(account: string, hoursFromNow: number, percent: number, observedHoursFromNow = Math.min(hoursFromNow, 0), provider = "claude") {
  return {
    provider,
    account,
    endsAt: new Date(NOW.getTime() + hoursFromNow * HOUR).toISOString(),
    periodHours: 168,
    percent,
    observedAt: new Date(NOW.getTime() + observedHoursFromNow * HOUR).toISOString(),
  };
}

async function send(token: string, device: string, quotaWindows: unknown[]) {
  return api("PUT", `/v1/devices/${device}/usage`, { token, body: { ...upload([]), quotaWindows } });
}

async function savePlans(token: string, teamID: string, plans: object[]) {
  return (await api("PUT", `/v1/teams/${teamID}/plans`, { token, body: { plans } })).body;
}

describe("plan quota", () => {
  it("averages each covered account's windows in the cycle and prices what's left unused", async () => {
    const { owner, team, members } = await teamWith(["Bea"]);
    // Cycle Oct 1–31. The owner's account used 80% of the week that reset Oct 2 and is on pace
    // for 60% of the open one (30% at its midpoint); Bea's used 20%. A September window is left out.
    expect((await send(owner.token, "device-aaaa-0001", [
      weekly(A, -24 * 10, 99),
      weekly(A, -24 * 3, 80),
      weekly(A, 84, 30, 0),
    ])).status).toBe(200);
    await send(members[0]!.token, "device-bbbb-0002", [weekly(B, -24 * 3, 20)]);
    const report = await savePlans(owner.token, team.id, [{ provider: "claude", name: "Max", monthlyCostUSD: 200, renewalDay: 1 }]);
    // Owner's account: (80 + 60) / 2 = 70; Bea's: 20; plan: 45%.
    expect(report.plans[0].quota).toEqual({ usedPercent: 45, accounts: 2, windows: 3, estimatedWindows: 0, wastedUSD: 110 });
    expect(report.plans[0].underused).toBe(true);
    expect(report.totals.quota).toEqual({ usedPercent: 45, cycleCostUSD: 200, wastedUSD: 110 });
  });

  it("counts an account once however many members share it, and only for plans that cover one of them", async () => {
    const { owner, team, members } = await teamWith(["Bea", "Cy"]);
    const [bea, cy] = members as [{ token: string; userID: string }, { token: string; userID: string }];
    await send(bea.token, "device-bbbb-0002", [weekly(SHARED, -24, 70, -30, "cursor")]);
    await send(cy.token, "device-cccc-0003", [weekly(SHARED, -24, 90, -24, "cursor")]);
    await send(owner.token, "device-aaaa-0001", [weekly(A, -24, 10, -24, "cursor")]);
    const report = await savePlans(owner.token, team.id, [
      { provider: "cursor", name: "Teams", monthlyCostUSD: 40, renewalDay: 1, memberIDs: [cy.userID] },
    ]);
    expect(report.plans[0].quota).toMatchObject({ usedPercent: 90, accounts: 1, windows: 1 });
    expect(report.plans[0].underused).toBe(false);
  });

  it("flags windows read long before they reset, skips young open windows, and caps shares at 100", async () => {
    const { owner, team } = await teamWith([]);
    await send(owner.token, "device-aaaa-0001", [
      weekly(A, -48, 40, -60),
      weekly(A, 160, 50, 0),
      weekly(B, -48, 130, -48),
    ]);
    const report = await savePlans(owner.token, team.id, [{ provider: "claude", name: "Max", monthlyCostUSD: 100, renewalDay: 1 }]);
    expect(report.plans[0].quota).toEqual({ usedPercent: 70, accounts: 2, windows: 2, estimatedWindows: 1, wastedUSD: 30 });
  });

  it("keeps the value test when no quota is reported, and replaces a Mac's windows on each upload", async () => {
    const { owner, team } = await teamWith([]);
    const plans = [{ provider: "claude", name: "Max", monthlyCostUSD: 100, renewalDay: 1 }];
    let report = await savePlans(owner.token, team.id, plans);
    expect(report.plans[0]).toMatchObject({ quota: null, underused: true });
    await send(owner.token, "device-aaaa-0001", [weekly(A, -24, 90)]);
    report = (await api("GET", `/v1/teams/${team.id}/plans`, { token: owner.token })).body;
    expect(report.plans[0]).toMatchObject({ quota: { usedPercent: 90 }, underused: false });
    await send(owner.token, "device-aaaa-0001", []);
    report = (await api("GET", `/v1/teams/${team.id}/plans`, { token: owner.token })).body;
    expect(report.plans[0].quota).toBeNull();
  });

  it("leaves stored windows alone for apps that don't send them, exports them, and drops them with the Mac", async () => {
    const { owner, team } = await teamWith([]);
    await send(owner.token, "device-aaaa-0001", [weekly(A, -24, 90)]);
    await api("PUT", "/v1/devices/device-aaaa-0001/usage", { token: owner.token, body: upload([]) });
    const plans = [{ provider: "claude", name: "Max", monthlyCostUSD: 100, renewalDay: 1 }];
    expect((await savePlans(owner.token, team.id, plans)).plans[0].quota).toMatchObject({ usedPercent: 90 });

    const exported = (await api("GET", "/v1/me/export", { token: owner.token })).body;
    expect(exported.quotaWindows).toEqual([
      { device_id: "device-aaaa-0001", provider: "claude", account_key: A, ends_at: "2026-10-04T12:00:00.000Z", period_hours: 168, percent: 90, observed_at: "2026-10-04T12:00:00.000Z" },
    ]);

    expect((await api("DELETE", "/v1/devices/device-aaaa-0001", { token: owner.token })).status).toBe(204);
    expect((await savePlans(owner.token, team.id, plans)).plans[0].quota).toBeNull();
  });

  it.each([
    ["not an array", { provider: "claude" }],
    ["bad account", [{ ...weekly(A, -24, 50), account: "nope" }]],
    ["bad endsAt", [{ ...weekly(A, -24, 50), endsAt: "soon" }]],
    ["fractional period", [{ ...weekly(A, -24, 50), periodHours: 1.5 }]],
    ["negative percent", [weekly(A, -24, -1)]],
    ["future reading", [weekly(A, 24, 50, 48)]],
    ["duplicate window", [weekly(A, -24, 50), weekly(A, -24, 60)]],
  ])("rejects %s", async (_label, quotaWindows) => {
    const { owner } = await teamWith([]);
    const response = await api("PUT", "/v1/devices/device-aaaa-0001/usage", { token: owner.token, body: { ...upload([]), quotaWindows } });
    expect(response.status).toBe(400);
  });
});
