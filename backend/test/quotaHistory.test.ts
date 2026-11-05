import { describe, expect, it } from "vitest";
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
      resetsAt: "2026-10-09T00:00:00.000Z",
      accounts: 1,
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

  it("returns each plan's calendar weeks with their days and sessions, for members only", async () => {
    const { owner, team } = await setUp();
    const response = await api("GET", `/v1/teams/${team.id}/plans/history?weeks=2&today=2026-10-05`, { token: owner.token });
    expect(response.status).toBe(200);
    const [plan] = response.body.plans;
    expect(plan).toMatchObject({ provider: "claude", name: "Max" });
    const [last, current] = plan.weeks;
    expect(last).toMatchObject({
      from: "2026-09-28",
      // The older week was first read four days in: Tuesday is its baseline, Thursday's growth spreads.
      totalPercent: 42,
      estimated: true,
      accounts: 1,
      sessions: { sessions: 1, limitHits: 1, averagePeakPercent: 100 },
    });
    expect(last.days.map((day: { percent: number | null }) => day.percent)).toEqual([null, null, 15, 15, 10, 2, 0]);
    expect(current).toMatchObject({ from: "2026-10-05", totalPercent: 18, estimated: false, sessions: { sessions: 1, limitHits: 0 } });
    expect(current.days.map((day: { percent: number | null }) => day.percent)).toEqual([18, null, null, null, null, null, null]);

    expect((await api("GET", `/v1/teams/${team.id}/plans/history?weeks=57`, { token: owner.token })).status).toBe(400);
    const stranger = await signIn("Stranger");
    expect((await api("GET", `/v1/teams/${team.id}/plans/history`, { token: stranger.token })).status).toBe(404);
  });
});
