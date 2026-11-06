import { describe, expect, it } from "vitest";
import { windowDays } from "../src/quotaHistory";
import { api, NOW, signIn, teamWith, upload } from "./support";

const A = "a".repeat(64);
const at = (iso: string) => new Date(iso).toISOString();

function weekly(account: string, endsAt: string, days: [string, number][]) {
  return {
    provider: "claude", kind: "limit", account, endsAt: at(endsAt), periodHours: 168,
    percent: Math.max(...days.map(([, percent]) => percent)), observedAt: NOW.toISOString(),
    days: days.map(([day, percent]) => ({ day, percent })),
  };
}

function session(account: string, endsAt: string, percent: number) {
  return { provider: "claude", kind: "session", account, endsAt: at(endsAt), periodHours: 5, percent, observedAt: at(endsAt) };
}

const plan = { provider: "claude", name: "Max", monthlyCostUSD: 100, renewalDay: 1 };

/** Today is Monday Oct 5. The open week started Friday Oct 2 and resets Friday Oct 9 at midnight UTC. */
async function setUp() {
  const { owner, team } = await teamWith([]);
  const response = await api("PUT", "/v1/devices/device-aaaa-0001/usage", {
    token: owner.token,
    body: {
      ...upload([]),
      quotaWindows: [
        weekly(A, "2026-10-02T00:00:00Z", [["2026-09-29", 50], ["2026-10-01", 80]]),
        weekly(A, "2026-10-09T00:00:00Z", [["2026-10-02", 10], ["2026-10-03", 12], ["2026-10-04", 12], ["2026-10-05", 30]]),
        session(A, "2026-10-03T10:00:00Z", 100),
        session(A, "2026-10-05T09:00:00Z", 40),
      ],
    },
  });
  expect(response.status).toBe(200);
  const report = (await api("PUT", `/v1/teams/${team.id}/plans`, { token: owner.token, body: { plans: [plan] } })).body;
  return { owner, team, report };
}

describe("plan budget and weekly history", () => {
  it("spreads what's left of the open week over today and the working days until it resets", async () => {
    const { report } = await setUp();
    expect(report.plans[0].budget).toEqual({
      // 12% was used before today and 30% now; the week resets early Friday, so Thursday is its last day.
      todayPercent: 18,
      affordablePercent: 22,
      leftPercent: 88,
      workingDaysLeft: 4,
      // No time zone in the request: an app from before Live Pace.
      pace: null,
      resetsAt: "2026-10-09T00:00:00.000Z",
      accounts: 1,
      perAccount: [{ people: ["You"], percent: 30, todayPercent: 18, resetsAt: "2026-10-09T00:00:00.000Z", perDevice: false }],
      days: [
        { day: "2026-10-02", percent: 10, working: true, estimated: false },
        { day: "2026-10-03", percent: 2, working: false, estimated: false },
        { day: "2026-10-04", percent: 0, working: false, estimated: false },
        { day: "2026-10-05", percent: 18, working: true, estimated: false },
        { day: "2026-10-06", percent: null, working: true, estimated: false },
        { day: "2026-10-07", percent: null, working: true, estimated: false },
        { day: "2026-10-08", percent: null, working: true, estimated: false },
      ],
    });
  });

  it("returns each plan's weekly windows, reset to reset, with their days and sessions, for members only", async () => {
    const { owner, team } = await setUp();
    const response = await api("GET", `/v1/teams/${team.id}/plans/history?weeks=2&today=2026-10-05`, { token: owner.token });
    expect(response.status).toBe(200);
    const [plan] = response.body.plans;
    expect(plan).toMatchObject({ provider: "claude", name: "Max" });
    const [last, current] = plan.weeks;
    expect(last).toMatchObject({
      // Friday 00:00 to Friday 00:00 UTC: Friday to Thursday.
      from: "2026-09-25",
      to: "2026-10-01",
      endsAt: "2026-10-02T00:00:00.000Z",
      open: false,
      // The window's own share, not a sum of days: it was first read four days in.
      percent: 80,
      estimated: true,
      accounts: 1,
      sessions: null,
    });
    expect(last.days.map((day: { percent: number | null }) => day.percent)).toEqual([null, null, null, null, null, 15, 15]);
    expect(current).toMatchObject({
      from: "2026-10-02", to: "2026-10-08", open: true, percent: 30, estimated: false,
      sessions: { sessions: 2, limitHits: 1, averagePeakPercent: 70 },
    });
    expect(current.days.map((day: { percent: number | null }) => day.percent)).toEqual([10, 2, 0, 18, null, null, null]);

    expect((await api("GET", `/v1/teams/${team.id}/plans/history?weeks=57`, { token: owner.token })).status).toBe(400);
    const stranger = await signIn("Stranger");
    expect((await api("GET", `/v1/teams/${team.id}/plans/history`, { token: stranger.token })).status).toBe(404);
  });

  it("frames a plan of two accounts on the one that resets first, averaging their window shares", async () => {
    const { owner, team } = await teamWith([]);
    const B = "b".repeat(64);
    await api("PUT", "/v1/devices/device-aaaa-0001/usage", {
      token: owner.token,
      body: {
        ...upload([]),
        quotaWindows: [
          weekly(A, "2026-10-09T00:00:00Z", [["2026-10-02", 10], ["2026-10-05", 40]]),
          weekly(B, "2026-10-10T21:00:00Z", [["2026-10-04", 5], ["2026-10-05", 20]]),
        ],
      },
    });
    await api("PUT", `/v1/teams/${team.id}/plans`, { token: owner.token, body: { plans: [plan] } });
    const weeks = (await api("GET", `/v1/teams/${team.id}/plans/history?weeks=1&today=2026-10-05`, { token: owner.token })).body.plans[0].weeks;
    expect(weeks).toHaveLength(1);
    expect(weeks[0]).toMatchObject({ from: "2026-10-02", to: "2026-10-08", open: true, percent: 30, accounts: 2 });
  });

  it("says who reads each of the plan's accounts, you first, soonest reset first", async () => {
    const { owner, team, members } = await teamWith(["Matteo", "Anna"]);
    const B = "b".repeat(64);
    const C = "c".repeat(64);
    await api("PUT", "/v1/devices/device-aaaa-0001/usage", {
      token: owner.token,
      body: { ...upload([]), quotaWindows: [weekly(A, "2026-10-09T00:00:00Z", [["2026-10-02", 10], ["2026-10-05", 40]])] },
    });
    await api("PUT", "/v1/devices/device-bbbb-0002/usage", {
      token: members[0]!.token,
      body: {
        ...upload([]),
        quotaWindows: [
          weekly(A, "2026-10-09T00:00:00Z", [["2026-10-02", 10], ["2026-10-05", 40]]),
          { ...weekly(B, "2026-10-10T21:00:00Z", [["2026-10-04", 5], ["2026-10-05", 20]]), perDevice: true },
        ],
      },
    });
    // Anna's account is left out of the plan: it covers only the owner and Matteo.
    await api("PUT", "/v1/devices/device-cccc-0003/usage", {
      token: members[1]!.token,
      body: { ...upload([]), quotaWindows: [weekly(C, "2026-10-08T00:00:00Z", [["2026-10-05", 90]])] },
    });
    const covered = { ...plan, memberIDs: [owner.userID, members[0]!.userID] };
    const budget = (await api("PUT", `/v1/teams/${team.id}/plans`, { token: owner.token, body: { plans: [covered] } })).body.plans[0].budget;
    expect(budget.accounts).toBe(2);
    expect(budget.perAccount).toEqual([
      { people: ["You", "Matteo"], percent: 40, todayPercent: 30, resetsAt: "2026-10-09T00:00:00.000Z", perDevice: false },
      { people: ["Matteo"], percent: 20, todayPercent: 15, resetsAt: "2026-10-10T21:00:00.000Z", perDevice: true },
    ]);

    const asMatteo = (await api("GET", `/v1/teams/${team.id}/plans?today=2026-10-05`, { token: members[0]!.token })).body.plans[0].budget;
    expect(asMatteo.perAccount.map((account: { people: string[] }) => account.people)).toEqual([["You", "Owner"], ["You"]]);
  });

  it("counts a window's first day when it starts before noon UTC and its last when it ends after", () => {
    expect(windowDays(Date.parse("2026-11-03T03:00:00Z"), Date.parse("2026-11-10T03:00:00Z"))).toEqual({ from: "2026-11-03", to: "2026-11-09" });
    expect(windowDays(Date.parse("2026-10-31T21:00:00Z"), Date.parse("2026-11-07T21:00:00Z"))).toEqual({ from: "2026-11-01", to: "2026-11-07" });
  });
});
