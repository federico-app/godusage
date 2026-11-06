import { describe, expect, it } from "vitest";
import { localDay, parseSchedule, union, workingIntervals, zonedTime } from "../src/schedules";
import { api, NOW, teamWith, upload } from "./support";

const A = "a".repeat(64);
const iso = (value: string) => new Date(value).toISOString();
const plan = { provider: "claude", name: "Max", monthlyCostUSD: 100, renewalDay: 1 };

/** The open week resets Friday Oct 9 at midnight UTC; 12% was used before today (Monday Oct 5). */
function weekly(percent: number, observedAt: string) {
  return {
    provider: "claude", kind: "limit", account: A, endsAt: iso("2026-10-09T00:00:00Z"), periodHours: 168, percent, observedAt: iso(observedAt),
    days: [{ day: "2026-10-02", percent: 10 }, { day: "2026-10-04", percent: 12 }, { day: "2026-10-05", percent }],
  };
}

async function send(token: string, device: string, timeZone: string, windows: object[]) {
  const response = await api("PUT", `/v1/devices/${device}/usage`, { token, body: { ...upload([]), timeZone, quotaWindows: windows } });
  expect(response.status).toBe(200);
}

async function pace(teamID: string, token: string, timeZone = "Europe/Rome") {
  const response = await api("GET", `/v1/teams/${teamID}/plans?today=2026-10-05&tz=${encodeURIComponent(timeZone)}`, { token });
  expect(response.status).toBe(200);
  return response.body;
}

describe("time zones and working hours", () => {
  it("turns a wall time in a zone into an instant, daylight saving included", () => {
    expect(iso(new Date(zonedTime("2026-10-05", 9 * 60, "Europe/Rome")).toISOString())).toBe("2026-10-05T07:00:00.000Z");
    expect(iso(new Date(zonedTime("2026-11-02", 9 * 60, "Europe/Rome")).toISOString())).toBe("2026-11-02T08:00:00.000Z");
    expect(iso(new Date(zonedTime("2026-10-05", 9 * 60, "America/New_York")).toISOString())).toBe("2026-10-05T13:00:00.000Z");
    expect(localDay(Date.parse("2026-10-05T23:30:00Z"), "Europe/Rome")).toBe("2026-10-06");
  });

  it("lists working time less the break, and merges overlaps", () => {
    const schedule = parseSchedule({ days: [1, 2, 3, 4, 5], start: 540, end: 1080, breakStart: 780, breakEnd: 840 });
    const monday = workingIntervals(schedule, "Europe/Rome", Date.parse("2026-10-05T00:00:00Z"), Date.parse("2026-10-06T00:00:00Z"));
    expect(monday.map((span) => [new Date(span.from).toISOString(), new Date(span.to).toISOString()])).toEqual([
      ["2026-10-05T07:00:00.000Z", "2026-10-05T11:00:00.000Z"],
      ["2026-10-05T12:00:00.000Z", "2026-10-05T16:00:00.000Z"],
    ]);
    expect(union([{ from: 0, to: 10 }, { from: 5, to: 20 }, { from: 30, to: 40 }])).toEqual([{ from: 0, to: 20 }, { from: 30, to: 40 }]);
  });

  it("rejects hours that end before they start or a break outside them", () => {
    expect(() => parseSchedule({ days: [1], start: 600, end: 540 })).toThrow();
    expect(() => parseSchedule({ days: [1], start: 540, end: 1080, breakStart: 500, breakEnd: 600 })).toThrow();
    expect(() => parseSchedule({ days: [], start: 540, end: 1080 })).toThrow();
  });
});

describe("member schedules", () => {
  it("defaults to the team's days 9 to 18, lets members set their own and owners anyone's", async () => {
    const { owner, team, members } = await teamWith(["Bea"]);
    const bea = members[0]!;
    const listed = (await api("GET", `/v1/teams/${team.id}/schedules`, { token: bea.token })).body;
    expect(listed.defaultSchedule).toEqual({ days: [1, 2, 3, 4, 5], start: 540, end: 1080, breakStart: null, breakEnd: null });
    expect(listed.members.every((member: { isDefault: boolean }) => member.isDefault)).toBe(true);
    expect(listed.canEditOthers).toBe(false);

    const own = { days: [2, 3, 4, 5, 6], start: 840, end: 1320 };
    expect((await api("PUT", `/v1/teams/${team.id}/members/${bea.userID}/schedule`, { token: bea.token, body: { schedule: own } })).status).toBe(200);
    expect((await api("PUT", `/v1/teams/${team.id}/members/${owner.userID}/schedule`, { token: bea.token, body: { schedule: own } })).status).toBe(403);
    expect((await api("PUT", `/v1/teams/${team.id}/members/${bea.userID}/schedule`, { token: owner.token, body: { schedule: null } })).status).toBe(200);
    expect((await api("PUT", `/v1/teams/${team.id}/members/${bea.userID}/schedule`, { token: owner.token, body: { schedule: { days: [1], start: 900, end: 800 } } })).status).toBe(400);

    await api("PUT", `/v1/teams/${team.id}/members/${owner.userID}/schedule`, { token: owner.token, body: { schedule: own } });
    const after = (await api("GET", `/v1/teams/${team.id}/schedules`, { token: owner.token })).body;
    const ownerRow = after.members.find((member: { userID: string }) => member.userID === owner.userID);
    expect(ownerRow).toMatchObject({ isDefault: false, schedule: { ...own, breakStart: null, breakEnd: null } });
    expect(after.members.find((member: { userID: string }) => member.userID === bea.userID).isDefault).toBe(true);
  });

  it("leaves viewers out of the list, but still answers them", async () => {
    const { owner, team, members } = await teamWith(["Bea", "Cy"]);
    const [bea, cy] = members as [typeof members[0], typeof members[0]];
    expect((await api("PATCH", `/v1/teams/${team.id}/members/${cy.userID}`, { token: owner.token, body: { countsUsage: false } })).status).toBe(200);
    const ids = (body: { members: { userID: string }[] }) => body.members.map((member) => member.userID).sort();
    const listed = (await api("GET", `/v1/teams/${team.id}/schedules`, { token: owner.token })).body;
    expect(ids(listed)).toEqual([owner.userID, bea.userID].sort());
    const asViewer = await api("GET", `/v1/teams/${team.id}/schedules`, { token: cy.token });
    expect(asViewer.status).toBe(200);
    expect(ids(asViewer.body)).toEqual([owner.userID, bea.userID].sort());
  });

  it("keeps schedules from people outside the team", async () => {
    const { team } = await teamWith([]);
    const other = await teamWith([]);
    expect((await api("GET", `/v1/teams/${team.id}/schedules`, { token: other.owner.token })).status).toBe(404);
  });
});

describe("Live Pace", () => {
  it("spreads today's budget over working hours in the member's time zone, with the pace of the last working hour", async () => {
    const { owner, team } = await teamWith([]);
    // 20% at 9:30 Rome time, 30% at 14:00 (NOW): Rome is UTC+2 in October.
    await send(owner.token, "device-aaaa-0001", "Europe/Rome", [weekly(20, "2026-10-05T09:30:00Z")]);
    await send(owner.token, "device-aaaa-0001", "Europe/Rome", [weekly(30, NOW.toISOString())]);
    await api("PUT", `/v1/teams/${team.id}/plans`, { token: owner.token, body: { plans: [plan] } });

    const report = await pace(team.id, owner.token);
    expect(report.plans[0].budget.pace).toEqual({
      // 88% left over today and Tuesday to Thursday, 9 hours each: today gets a quarter.
      budgetPercent: 22,
      usedPercent: 18,
      leftPercent: 88,
      // From 20% an hour or more before now (11:00 UTC) to 30% now.
      ratePerHour: 10,
      hours: [{ from: "2026-10-05T07:00:00.000Z", to: "2026-10-05T16:00:00.000Z" }],
      futureDays: [{ day: "2026-10-06", hours: 9 }, { day: "2026-10-07", hours: 9 }, { day: "2026-10-08", hours: 9 }],
      // 12% was used before today.
      today: [{ at: "2026-10-05T09:30:00.000Z", percent: 8 }, { at: "2026-10-05T12:00:00.000Z", percent: 18 }],
      sharedWith: [],
      resetsAt: "2026-10-09T00:00:00.000Z",
    });
    expect(report.yourHours).toEqual([{ from: "2026-10-05T07:00:00.000Z", to: "2026-10-05T16:00:00.000Z" }]);
  });

  it("paces a shared account on the union of everyone's hours, across time zones", async () => {
    const { owner, team, members } = await teamWith(["Bea"]);
    const bea = members[0]!;
    await send(owner.token, "device-aaaa-0001", "Europe/Rome", [weekly(30, NOW.toISOString())]);
    await send(bea.token, "device-bbbb-0001", "America/New_York", [weekly(30, NOW.toISOString())]);
    // The owner takes a break from 13 to 14 Rome time; Bea works 9 to 18 New York time (13 to 22 UTC).
    await api("PUT", `/v1/teams/${team.id}/members/${owner.userID}/schedule`, {
      token: owner.token, body: { schedule: { days: [1, 2, 3, 4, 5], start: 540, end: 1080, breakStart: 780, breakEnd: 840 } },
    });
    await api("PUT", `/v1/teams/${team.id}/plans`, { token: owner.token, body: { plans: [plan] } });

    const report = await pace(team.id, owner.token);
    const result = report.plans[0].budget.pace;
    expect(result.hours).toEqual([
      { from: "2026-10-05T07:00:00.000Z", to: "2026-10-05T11:00:00.000Z" },
      { from: "2026-10-05T12:00:00.000Z", to: "2026-10-05T22:00:00.000Z" },
    ]);
    expect(result.sharedWith).toEqual(["Bea"]);
    // No reading an hour old yet: the app falls back on today's average.
    expect(result.ratePerHour).toBeNull();
    expect(report.yourHours).toEqual([
      { from: "2026-10-05T07:00:00.000Z", to: "2026-10-05T11:00:00.000Z" },
      { from: "2026-10-05T12:00:00.000Z", to: "2026-10-05T16:00:00.000Z" },
    ]);
    // Bea's own view names the owner.
    expect((await pace(team.id, bea.token, "America/New_York")).plans[0].budget.pace.sharedWith).toEqual(["Owner"]);
  });

  it("gives no budget on a day off and spreads the week over the days left", async () => {
    const { owner, team } = await teamWith([]);
    await send(owner.token, "device-aaaa-0001", "Europe/Rome", [weekly(12, NOW.toISOString())]);
    await api("PUT", `/v1/teams/${team.id}/members/${owner.userID}/schedule`, {
      token: owner.token, body: { schedule: { days: [2, 3], start: 540, end: 1080 } },
    });
    await api("PUT", `/v1/teams/${team.id}/plans`, { token: owner.token, body: { plans: [plan] } });
    const result = (await pace(team.id, owner.token)).plans[0].budget.pace;
    expect(result.budgetPercent).toBe(0);
    expect(result.hours).toEqual([]);
    expect(result.futureDays).toEqual([{ day: "2026-10-06", hours: 9 }, { day: "2026-10-07", hours: 9 }]);
  });
});
