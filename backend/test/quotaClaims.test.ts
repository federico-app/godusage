import { describe, expect, it } from "vitest";
import { planPace, type PaceContext } from "../src/livePace";
import { planQuota, type QuotaReading, type QuotaRow } from "../src/quota";
import { accountWindows, mergeRows, type QuotaClaim } from "../src/quotaClaims";
import { claimToday, planBudget, planHistory } from "../src/quotaHistory";
import { api, NOW, teamWith, upload } from "./support";

const A = "a".repeat(64);
const WEEKDAYS = [1, 2, 3, 4, 5];
const plan = { provider: "claude", covered: () => true };
const iso = (value: string) => new Date(value).toISOString();

/** A Mac's row for A's week from Friday Oct 2 to Friday Oct 9, 00:00 UTC. Today is Monday Oct 5. */
function row(overrides: Partial<QuotaRow> = {}): QuotaRow {
  return {
    user_id: "u1", device_id: "d1", provider: "claude", kind: "limit", account_key: A, ends_at: iso("2026-10-09T00:00:00Z"),
    period_hours: 168, percent: 0, observed_at: iso("2026-10-05T12:00:00Z"), days: null, per_device: false, claims: [], stretch_since: null, ...overrides,
  };
}

function claim(at: string, percent: number, overrides: Partial<QuotaClaim> = {}): QuotaClaim {
  return { at: iso(at), after: iso(at), percent, day: at.slice(0, 10), recorded: true, ...overrides };
}

const days = (entries: [string, number][]) => entries.map(([day, percent]) => ({ day, percent }));

describe("claimed resets in one window", () => {
  it("adds a limit per claim and counts the peak before each claim plus the use since", () => {
    const merged = mergeRows([row({ percent: 40, claims: [claim("2026-10-05T10:00:00Z", 95)] })]);
    expect(merged).toMatchObject({ segments: [95, 40], used: 135, capacity: 200 });
    expect(merged.claims).toHaveLength(1);
  });

  it("counts two claims in one week", () => {
    const merged = mergeRows([row({ percent: 20, claims: [claim("2026-10-03T10:00:00Z", 95), claim("2026-10-05T09:00:00Z", 100)] })]);
    expect(merged).toMatchObject({ segments: [95, 100, 20], used: 215, capacity: 300 });
  });

  it("counts a claim GodUsage made and the same claim another Mac inferred from the drop once", () => {
    const merged = mergeRows([
      row({ percent: 40, claims: [claim("2026-10-05T10:00:00Z", 95)] }),
      // Asleep from 9:30 to 11:00: it saw 90, then 40.
      row({ device_id: "d2", percent: 40, claims: [claim("2026-10-05T11:00:00Z", 90, { after: iso("2026-10-05T09:30:00Z"), recorded: false })] }),
    ]);
    expect(merged.claims).toEqual([{ at: Date.parse("2026-10-05T10:00:00Z"), after: Date.parse("2026-10-05T10:00:00Z"), percent: 95, day: "2026-10-05", recorded: true }]);
    expect(merged).toMatchObject({ used: 135, capacity: 200 });
  });

  it("keeps two claims apart when one Mac saw both, even if another Mac's gap spans them", () => {
    const merged = mergeRows([
      row({ percent: 10, claims: [claim("2026-10-05T10:00:00Z", 95), claim("2026-10-05T14:00:00Z", 100)] }),
      row({ device_id: "d2", percent: 10, claims: [claim("2026-10-05T15:00:00Z", 60, { after: iso("2026-10-05T08:00:00Z"), recorded: false })] }),
    ]);
    expect(merged).toMatchObject({ capacity: 300, segments: [95, 100, 10], used: 205 });
  });

  it("fills in a claim one Mac of a shared account saw and another missed", () => {
    const rows = [
      // Mac 1 claimed at 10:00 with 95 used, read 0 after, and was turned off.
      row({ percent: 0, observed_at: iso("2026-10-05T10:00:00Z"), claims: [claim("2026-10-05T10:00:00Z", 95)], days: days([["2026-10-04", 60], ["2026-10-05", 95]]) }),
      // Mac 2 was off during the claim: it only read the new stretch, which never fell below what it last saw.
      row({
        device_id: "d2", user_id: "u2", percent: 40, observed_at: iso("2026-10-06T15:00:00Z"), stretch_since: iso("2026-10-05T14:00:00Z"),
        days: days([["2026-10-05", 30], ["2026-10-06", 40]]),
      }),
    ];
    const merged = mergeRows(rows);
    expect(merged).toMatchObject({ segments: [95, 40], used: 135, capacity: 200 });
    // The claim day keeps Mac 1's 95 (Mac 2's 30 may be from before the claim); the next day adds the claim's 95 to Mac 2's 40.
    expect(Object.fromEntries(merged.days)).toEqual({ "2026-10-04": 60, "2026-10-05": 95, "2026-10-06": 135 });
    expect(merged.correct("u2|d2", Date.parse("2026-10-06T12:00:00Z"), 38)).toBe(133);
    expect(merged.correct("u1|d1", Date.parse("2026-10-06T12:00:00Z"), 133)).toBe(133);
  });

  it("only takes an older app's share as a floor once a claim is known", () => {
    const merged = mergeRows([
      row({ percent: 40, claims: [claim("2026-10-05T10:00:00Z", 95)] }),
      // An app before claims reports the highest share it saw in the whole window, with no claims.
      row({ device_id: "d2", percent: 95, claims: null, observed_at: iso("2026-10-05T16:00:00Z") }),
    ]);
    expect(merged).toMatchObject({ used: 135, capacity: 200 });
    expect(merged.correct("u1|d2", Date.parse("2026-10-05T16:00:00Z"), 95)).toBe(95);
    // Without claims anywhere, rows merge at the highest share, as before.
    expect(mergeRows([row({ percent: 30, claims: null }), row({ device_id: "d2", percent: 45 })])).toMatchObject({ used: 45, capacity: 100 });
  });
});

describe("review fixes", () => {
  it("doesn't count twice a Mac that read the share before a claim it never saw", () => {
    const merged = mergeRows([
      row({ percent: 40, claims: [claim("2026-10-05T10:00:00Z", 95)], days: days([["2026-10-05", 100], ["2026-10-06", 135]]) }),
      // Read 95 before the claim and 80 after: no drop big enough to see, so it still holds the 95.
      row({
        device_id: "d2", percent: 95, observed_at: iso("2026-10-06T12:00:00Z"), stretch_since: iso("2026-10-04T09:00:00Z"),
        days: days([["2026-10-04", 60], ["2026-10-06", 95]]),
      }),
    ]);
    expect(merged).toMatchObject({ segments: [95, 40], used: 135, capacity: 200 });
    expect(merged.days.get("2026-10-06")).toBe(135);
    expect(merged.correct("u1|d2", Date.parse("2026-10-06T12:00:00Z"), 95)).toBe(95);
  });

  it("doesn't take a plan with claimed resets as underused: the claimed limits were free", () => {
    const twoClaims = row({
      ends_at: iso("2026-10-02T00:00:00Z"), observed_at: iso("2026-10-01T23:00:00Z"), percent: 0,
      claims: [claim("2026-09-29T15:00:00Z", 95), claim("2026-09-30T15:00:00Z", 40)],
    });
    const quota = planQuota([twoClaims], { ...plan, cycleFrom: "2026-10-01", cycleCostUSD: 100 }, NOW, WEEKDAYS)!;
    expect(quota).toMatchObject({ usedPercent: 45, paidPercent: 100, wastedUSD: 0, resets: 2 });
    const under = planQuota([row({ ends_at: iso("2026-10-02T00:00:00Z"), observed_at: iso("2026-10-01T23:00:00Z"), percent: 40 })],
      { ...plan, cycleFrom: "2026-10-01", cycleCostUSD: 100 }, NOW, WEEKDAYS)!;
    expect(under).toEqual({ usedPercent: 40, accounts: 1, windows: 1, estimatedWindows: 0, wastedUSD: 60 });
  });

  it("takes today's claim by its time in the viewer's day, ignoring one from a clock ahead of now", () => {
    const window = [...accountWindows([row({ percent: 5, claims: [claim("2026-10-05T10:00:00Z", 90), claim("2026-10-05T16:00:00Z", 20)] })], plan, { weekly: true }).values()][0]![0]!;
    const day = { from: Date.parse("2026-10-05T00:00:00Z"), to: Date.parse("2026-10-06T00:00:00Z") };
    expect(claimToday(window, day, Date.parse("2026-10-05T15:00:00Z"), 0)).toEqual({ at: Date.parse("2026-10-05T10:00:00Z"), usedBefore: 90, leftAfter: 210 });
    // In Rome the Mac's 00:30 claim is today; by UTC it was yesterday.
    const early = [...accountWindows([row({ percent: 5, claims: [claim("2026-10-04T22:30:00Z", 50, { day: "2026-10-05" })] })], plan, { weekly: true }).values()][0]![0]!;
    expect(claimToday(early, { from: Date.parse("2026-10-04T22:00:00Z"), to: Date.parse("2026-10-05T22:00:00Z") }, Date.parse("2026-10-05T12:00:00Z"), 0)).not.toBeNull();
    expect(claimToday(early, day, Date.parse("2026-10-05T12:00:00Z"), 0)).toBeNull();
  });
});

describe("a Codex reset that starts a new week", () => {
  it("ends the old week where the new one starts, even for a Mac that never saw the new one", () => {
    const rows = [
      // Mac 1 never saw the reset: its week still ends Friday.
      row({ provider: "codex", percent: 70, observed_at: iso("2026-10-05T08:00:00Z") }),
      // Mac 2 saw it at Monday 10:00: it ended the old week there and read the new one.
      row({ provider: "codex", device_id: "d2", ends_at: iso("2026-10-05T10:00:00Z"), percent: 72, observed_at: iso("2026-10-05T09:00:00Z") }),
      row({ provider: "codex", device_id: "d2", ends_at: iso("2026-10-12T10:00:00Z"), percent: 5, observed_at: iso("2026-10-05T12:00:00Z"), days: days([["2026-10-05", 5]]) }),
    ];
    const [windows] = [...accountWindows(rows, { provider: "codex", covered: () => true }, { weekly: true }).values()];
    expect(windows!.map((window) => [new Date(window.startsAt).toISOString(), new Date(window.endsAt).toISOString(), window.used])).toEqual([
      // One week however each Mac named its end, from its real start.
      ["2026-10-02T00:00:00.000Z", "2026-10-05T10:00:00.000Z", 72],
      ["2026-10-05T10:00:00.000Z", "2026-10-12T10:00:00.000Z", 5],
    ]);
    const budget = planBudget(rows, { provider: "codex", covered: () => true }, "2026-10-05", NOW, WEEKDAYS)!;
    // The new week's budget, never a negative today.
    expect(budget).toMatchObject({ todayPercent: 5, leftPercent: 100, resetsAt: "2026-10-12T10:00:00.000Z" });
    expect(budget.week).toBeUndefined();
  });
});

describe("budget, history, and quota with claims", () => {
  // Used 12 by Monday, 95 at the 10:00 claim (83 today, far over today's budget), 10 since.
  const claimed = row({
    percent: 10, claims: [claim("2026-10-05T10:00:00Z", 95)],
    days: days([["2026-10-02", 10], ["2026-10-03", 12], ["2026-10-04", 12], ["2026-10-05", 105]]),
  });

  it("restarts today's budget at a claim made while over it, with today's use before and after the claim", () => {
    const budget = planBudget([claimed], plan, "2026-10-05", NOW, WEEKDAYS)!;
    expect(budget).toMatchObject({
      todayPercent: 93,
      // 83 spent before the claim, plus the 105 left after it over Monday to Thursday.
      affordablePercent: 109.3,
      leftPercent: 188,
      week: { usedPercent: 105, capacityPercent: 200, segments: [95, 10], resets: 1 },
    });
    expect(budget.days.find((day) => day.day === "2026-10-05")).toEqual({ day: "2026-10-05", percent: 93, working: true, estimated: false, resets: 1 });
    expect(budget.perAccount[0]).toMatchObject({ percent: 52.5, usedPercent: 105, capacityPercent: 200, segments: [95, 10] });
  });

  it("leaves the whole rest of the capacity to the last day when the claim comes on it", () => {
    const lastDay = row({ percent: 0, claims: [claim("2026-10-08T09:00:00Z", 100)], observed_at: iso("2026-10-08T09:00:00Z"), days: days([["2026-10-07", 90], ["2026-10-08", 100]]) });
    const budget = planBudget([lastDay], plan, "2026-10-08", new Date("2026-10-08T10:00:00Z"), WEEKDAYS)!;
    expect(budget).toMatchObject({ workingDaysLeft: 1, todayPercent: 10, affordablePercent: 110, leftPercent: 110 });
  });

  it("shows a week with a claim against its capacity in the history and the plan's quota", () => {
    const closed = row({
      ends_at: iso("2026-10-02T00:00:00Z"), observed_at: iso("2026-10-01T23:00:00Z"), percent: 40,
      claims: [claim("2026-09-29T15:00:00Z", 95)], days: days([["2026-09-28", 60], ["2026-09-29", 100], ["2026-10-01", 135]]),
    });
    const [week] = planHistory([closed], plan, "2026-10-05", NOW, 1, WEEKDAYS);
    expect(week).toMatchObject({ percent: 67.5, usedPercent: 135, capacityPercent: 200, resets: 1 });
    expect(week!.days.find((day) => day.day === "2026-09-29")).toMatchObject({ percent: 40, resets: 1 });
    const quota = planQuota([closed], { ...plan, cycleFrom: "2026-10-01", cycleCostUSD: 100 }, NOW, WEEKDAYS);
    // The claimed limit was free: the paid limit is fully used, nothing wasted.
    expect(quota).toEqual({ usedPercent: 67.5, paidPercent: 100, accounts: 1, windows: 1, estimatedWindows: 0, wastedUSD: 0, resets: 1 });
  });

  it("paces today from the claim on, with the readings of a Mac that missed it filled in", () => {
    const now = new Date("2026-10-05T15:00:00Z");
    const window = row({ ...claimed, claims: [claim("2026-10-05T13:00:00Z", 95)], observed_at: iso("2026-10-05T15:00:00Z") });
    const reading = (device: string, at: string, percent: number): QuotaReading => ({
      user_id: "u1", device_id: device, provider: "claude", account_key: A, ends_at: window.ends_at, observed_at: iso(at), percent,
    });
    const other = row({ device_id: "d2", percent: 8, observed_at: iso("2026-10-05T14:00:00Z"), stretch_since: iso("2026-10-05T13:30:00Z") });
    const context: PaceContext = {
      timeZone: "UTC", teamDays: WEEKDAYS, hours: new Map(),
      readings: [
        reading("d1", "2026-10-05T12:00:00Z", 90),
        reading("d1", "2026-10-05T14:00:00Z", 100),
        reading("d2", "2026-10-05T14:30:00Z", 8),
        reading("d1", "2026-10-05T15:00:00Z", 105),
      ],
    };
    const pace = planPace([window, other], plan, "2026-10-05", now, context)!;
    expect(pace).toMatchObject({
      usedPercent: 93,
      leftPercent: 188,
      // 83 before the claim, plus 105 × the 5 working hours left today of the 32 until Friday.
      budgetPercent: 99.4,
      ratePerHour: 5,
      rebase: { at: "2026-10-05T13:00:00.000Z", usedPercent: 83 },
    });
    expect(pace.today.map((point) => point.percent)).toEqual([78, 88, 91, 93]);
  });
});

describe("claims over the API", () => {
  it("stores each window's claims, exports them, and keeps older apps' windows without", async () => {
    const { owner, team } = await teamWith([]);
    const window = {
      provider: "claude", account: A, endsAt: "2026-10-09T00:00:00Z", periodHours: 168, percent: 10, observedAt: NOW.toISOString(),
      days: days([["2026-10-04", 12], ["2026-10-05", 105]]),
      claims: [{ at: "2026-10-05T10:00:00Z", after: "2026-10-05T09:00:00Z", percent: 95, day: "2026-10-05", recorded: true }],
    };
    const sent = await api("PUT", "/v1/devices/device-aaaa-0001/usage", { token: owner.token, body: { ...upload([]), quotaWindows: [window] } });
    expect(sent.status).toBe(200);
    const exported = (await api("GET", "/v1/me/export", { token: owner.token })).body;
    expect(exported.quotaWindows[0].claims).toEqual([{ at: "2026-10-05T10:00:00.000Z", after: "2026-10-05T09:00:00.000Z", percent: 95, day: "2026-10-05", recorded: true }]);
    // Live Pace's reading is the share used so far, the claim's 95 included.
    expect(exported.quotaReadings[0].percent).toBe(105);
    const report = (await api("PUT", `/v1/teams/${team.id}/plans`, { token: owner.token, body: { plans: [{ provider: "claude", name: "Max", monthlyCostUSD: 100, renewalDay: 1 }] } })).body;
    expect(report.plans[0].budget.week).toEqual({ usedPercent: 105, capacityPercent: 200, segments: [95, 10], resets: 1 });

    const bad = await api("PUT", "/v1/devices/device-aaaa-0001/usage", {
      token: owner.token, body: { ...upload([]), quotaWindows: [{ ...window, claims: [{ at: "nope", percent: 5, day: "2026-10-05" }] }] },
    });
    expect(bad.status).toBe(400);

    // Too many claims keep the latest 20 rather than refusing the upload.
    const many = Array.from({ length: 25 }, (_, index) => ({
      at: new Date(Date.parse("2026-10-03T00:00:00Z") + index * 3_600_000).toISOString(), percent: 1, day: "2026-10-03", recorded: false,
    }));
    const capped = await api("PUT", "/v1/devices/device-aaaa-0001/usage", {
      token: owner.token, body: { ...upload([]), quotaWindows: [{ ...window, claims: many, since: "2026-10-05T10:00:00Z" }] },
    });
    expect(capped.status).toBe(200);
    const stored = (await api("GET", "/v1/me/export", { token: owner.token })).body.quotaWindows[0];
    expect(stored.claims).toHaveLength(20);
    expect(stored.claims[0].at).toBe("2026-10-03T05:00:00.000Z");
    expect(stored.stretch_since).toBe("2026-10-05T10:00:00.000Z");
  });

  it("measures a plan's waste and underuse against its paid limit", async () => {
    const { owner, team } = await teamWith([]);
    const week = {
      provider: "claude", account: A, endsAt: "2026-10-02T00:00:00Z", periodHours: 168, percent: 0, observedAt: "2026-10-01T23:00:00Z",
      claims: [
        { at: "2026-09-29T15:00:00Z", percent: 95, day: "2026-09-29", recorded: true },
        { at: "2026-09-30T15:00:00Z", percent: 40, day: "2026-09-30", recorded: true },
      ],
    };
    await api("PUT", "/v1/devices/device-aaaa-0001/usage", { token: owner.token, body: { ...upload([]), quotaWindows: [week] } });
    const report = (await api("PUT", `/v1/teams/${team.id}/plans`, { token: owner.token, body: { plans: [{ provider: "claude", name: "Max", monthlyCostUSD: 100, renewalDay: 1 }] } })).body;
    // 135 of 300 is 45% of the capacity, but all of the paid limit: not underused, nothing wasted.
    expect(report.plans[0].quota).toMatchObject({ usedPercent: 45, paidPercent: 100, wastedUSD: 0, resets: 2 });
    expect(report.plans[0].underused).toBe(false);
    expect(report.totals.quota.wastedUSD).toBe(0);
  });
});
