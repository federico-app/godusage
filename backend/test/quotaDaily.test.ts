import { describe, expect, it } from "vitest";
import { workingShare } from "../src/workingDays";
import { api, NOW, teamWith, upload } from "./support";

const A = "a".repeat(64);
const B = "b".repeat(64);
const HOUR = 3_600_000;
const at = (iso: string) => new Date(iso).toISOString();

/** A weekly window ending `endsAt`, with the share seen at the end of each listed day. */
function weekly(account: string, endsAt: string, days: [string, number][]) {
  return {
    provider: "claude", kind: "limit", account, endsAt: at(endsAt), periodHours: 168,
    percent: Math.max(...days.map(([, percent]) => percent)), observedAt: NOW.toISOString(),
    days: days.map(([day, percent]) => ({ day, percent })),
  };
}

function session(account: string, endsAt: string, percent: number, perDevice?: boolean) {
  return { provider: "claude", kind: "session", account, endsAt: at(endsAt), periodHours: 5, percent, observedAt: at(endsAt), perDevice };
}

async function send(token: string, device: string, quotaWindows: unknown[]) {
  const response = await api("PUT", `/v1/devices/${device}/usage`, { token, body: { ...upload([]), quotaWindows } });
  expect(response.status).toBe(200);
}

const plan = { provider: "claude", name: "Max", monthlyCostUSD: 100, renewalDay: 1 };

describe("plan daily quota and sessions", () => {
  it("turns each day's reading into that day's share of the weekly limit, spreading skipped days", async () => {
    const { owner, team, members } = await teamWith(["Bea"]);
    // Today is Monday Oct 5. The owner's open week started Friday Oct 2 (read from its first day);
    // the week before was first read four days in, so that reading only sets the baseline.
    await send(owner.token, "device-aaaa-0001", [
      weekly(A, "2026-10-02T00:00:00Z", [["2026-09-29", 50], ["2026-10-01", 80]]),
      weekly(A, "2026-10-09T00:00:00Z", [["2026-10-02", 10], ["2026-10-03", 12], ["2026-10-04", 12], ["2026-10-05", 30]]),
    ]);
    // Bea's Mac was off over the weekend: Monday's growth spreads over Saturday to Monday.
    await send(members[0]!.token, "device-bbbb-0002", [weekly(B, "2026-10-09T00:00:00Z", [["2026-10-02", 20], ["2026-10-05", 26]])]);
    const report = (await api("PUT", `/v1/teams/${team.id}/plans`, { token: owner.token, body: { plans: [plan] } })).body;
    expect(report.workingDays).toEqual([1, 2, 3, 4, 5]);
    expect(report.plans[0].daily).toEqual({
      days: [
        { day: "2026-09-29", percent: null, working: true, estimated: false },
        { day: "2026-09-30", percent: 15, working: true, estimated: true },
        { day: "2026-10-01", percent: 15, working: true, estimated: true },
        { day: "2026-10-02", percent: 15, working: true, estimated: false },
        { day: "2026-10-03", percent: 2, working: false, estimated: true },
        { day: "2026-10-04", percent: 1, working: false, estimated: true },
        { day: "2026-10-05", percent: 10, working: true, estimated: true },
      ],
      // Wednesday to Friday; the weekend and today (not over) are left out.
      averagePercent: 15,
      pacePercent: 20,
      accounts: 2,
    });
  });

  it("counts each session in the cycle once, even when two Macs read one shared account", async () => {
    const { owner, team, members } = await teamWith(["Bea"]);
    await send(owner.token, "device-aaaa-0001", [
      session(A, "2026-09-30T10:00:00Z", 100),
      session(A, "2026-10-03T10:00:00Z", 100),
      session(A, "2026-10-04T15:00:00Z", 40),
    ]);
    // Bea's Mac reads the same account (same key): its 97% reading of Saturday's session is the same
    // session. Sunday's 80% is her own account's session, ending the same hour as the owner's.
    await send(members[0]!.token, "device-bbbb-0002", [session(A, "2026-10-03T10:00:00Z", 97), session(B, "2026-10-04T15:00:00Z", 80)]);
    const report = (await api("PUT", `/v1/teams/${team.id}/plans`, { token: owner.token, body: { plans: [plan] } })).body;
    expect(report.plans[0].sessions).toEqual({ sessions: 3, limitHits: 1, averagePeakPercent: 73.3, peaks: [100, 80, 40], accounts: 2 });
    expect(report.plans[0].perDeviceAccounts).toBe(0);
    // Sessions are not the plan's limit: they leave its quota alone.
    expect(report.plans[0].quota).toBeNull();
    expect(report.plans[0].daily).toBeNull();
  });

  it("counts the accounts a Mac could only name per Mac, and treats old apps' windows as such", async () => {
    const { owner, team } = await teamWith([]);
    const old = { provider: "claude", account: B, endsAt: at("2026-10-09T00:00:00Z"), periodHours: 168, percent: 30, observedAt: NOW.toISOString() };
    await send(owner.token, "device-aaaa-0001", [session(A, "2026-10-03T10:00:00Z", 50, true), old]);
    const report = (await api("PUT", `/v1/teams/${team.id}/plans`, { token: owner.token, body: { plans: [plan] } })).body;
    expect(report.plans[0].perDeviceAccounts).toBe(2);
  });

  it("lets the owner change the working days and keeps them when a save leaves them out", async () => {
    const { owner, team, members } = await teamWith(["Bea"]);
    const put = (token: string, body: object) => api("PUT", `/v1/teams/${team.id}/plans`, { token, body: { plans: [plan], ...body } });
    expect((await put(owner.token, { workingDays: [7, 1, 1, 6, 2, 3, 4, 5] })).body.workingDays).toEqual([1, 2, 3, 4, 5, 6, 7]);
    expect((await put(owner.token, {})).body.workingDays).toEqual([1, 2, 3, 4, 5, 6, 7]);
    const read = (await api("GET", `/v1/teams/${team.id}/plans`, { token: members[0]!.token })).body;
    expect(read.workingDays).toEqual([1, 2, 3, 4, 5, 6, 7]);
    // Every day working: the pace is the plain calendar's again.
    expect(read.plans[0].cycle).toMatchObject({ workingDaysElapsed: 5, workingDaysLeft: 26 });
    expect((await put(owner.token, { workingDays: [] })).status).toBe(400);
    expect((await put(owner.token, { workingDays: [0] })).status).toBe(400);
    expect((await put(members[0]!.token, { workingDays: [1] })).status).toBe(403);
  });

  it("paces an open window on working time only", () => {
    const friday = Date.parse("2026-10-02T00:00:00Z");
    const weekdays = [1, 2, 3, 4, 5];
    // Friday, then the weekend: one of five working days gone by Sunday night.
    expect(workingShare(friday, friday + 72 * HOUR, friday + 168 * HOUR, weekdays)).toBeCloseTo(0.2);
    expect(workingShare(friday, friday + 84 * HOUR, friday + 168 * HOUR, weekdays)).toBeCloseTo(0.3);
    // A span with no working time falls back to plain time.
    const saturday = friday + 24 * HOUR;
    expect(workingShare(saturday, saturday + 12 * HOUR, saturday + 48 * HOUR, weekdays)).toBeCloseTo(0.25);
  });

  it.each([
    ["bad kind", [{ ...session(A, "2026-10-03T10:00:00Z", 50), kind: "daily" }]],
    ["bad day", [weekly(A, "2026-10-09T00:00:00Z", [["2026-13-01", 5]])]],
    ["duplicate day", [weekly(A, "2026-10-09T00:00:00Z", [["2026-10-02", 5], ["2026-10-02", 6]])]],
    ["negative day share", [weekly(A, "2026-10-09T00:00:00Z", [["2026-10-02", 5], ["2026-10-03", -1]])]],
  ])("rejects %s", async (_label, quotaWindows) => {
    const { owner } = await teamWith([]);
    const response = await api("PUT", "/v1/devices/device-aaaa-0001/usage", { token: owner.token, body: { ...upload([]), quotaWindows } });
    expect(response.status).toBe(400);
  });
});
