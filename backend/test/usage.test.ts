import { env } from "./env";
import { describe, expect, it } from "vitest";
import { storeDeviceUsage } from "../src/routes/usage";
import { addDays, parseUsageUpload } from "../src/usagePayload";
import { api, NOW, signIn, teamWith, upload } from "./support";

const DEVICE_A = "device-aaaa-0001";
const DEVICE_B = "device-bbbb-0002";

async function put(token: string, deviceID: string, body: unknown) {
  return api("PUT", `/v1/devices/${deviceID}/usage`, { token, body });
}

describe("usage upload", () => {
  it("stores days and models and lists the device", async () => {
    const { token } = await signIn();
    const response = await put(
      token,
      DEVICE_A,
      upload([
        {
          provider: "claude",
          days: [
            { date: "2026-10-05", tokens: 1000, costUSD: 2.5, models: [{ model: "claude-opus-4-1", tokens: 1000, costUSD: 2.5 }] },
            { date: "2026-10-04", tokens: 500, costUSD: null },
          ],
        },
      ]),
    );
    expect(response.status).toBe(200);
    expect(response.body).toMatchObject({ deviceID: DEVICE_A, days: 2, models: 1 });

    const devices = await api("GET", "/v1/devices", { token });
    expect(devices.body.devices).toEqual([{ id: DEVICE_A, name: "MacBook", updatedAt: "2026-10-05T12:00:00.000Z" }]);
  });

  it.each([
    ["wrong schema", { ...upload([]), schema: "v0" }],
    ["bad provider id", upload([{ provider: "Claude!", days: [] }])],
    ["duplicate provider", upload([{ provider: "codex", days: [] }, { provider: "codex", days: [] }])],
    ["bad scope", { ...upload([]), providers: [{ provider: "codex", scope: "global", days: [] }] }],
    ["bad date", upload([{ provider: "codex", days: [{ date: "2026-02-30", tokens: 1 }] }])],
    ["duplicate date", upload([{ provider: "codex", days: [{ date: "2026-10-05", tokens: 1 }, { date: "2026-10-05", tokens: 2 }] }])],
    ["negative tokens", upload([{ provider: "codex", days: [{ date: "2026-10-05", tokens: -1 }] }])],
    ["fractional tokens", upload([{ provider: "codex", days: [{ date: "2026-10-05", tokens: 1.5 }] }])],
    ["negative cost", upload([{ provider: "codex", days: [{ date: "2026-10-05", tokens: 1, costUSD: -2 }] }])],
    [
      "duplicate model",
      upload([{ provider: "codex", days: [{ date: "2026-10-05", tokens: 2, models: [{ model: "GPT-5", tokens: 1 }, { model: "gpt-5", tokens: 1 }] }] }]),
    ],
    ["missing device name", { ...upload([]), deviceName: "" }],
    ["account on device scope", upload([{ provider: "codex", account: "a".repeat(32), days: [] }])],
    ["malformed account", upload([{ provider: "cursor", scope: "account", account: "not-a-hash", days: [] }])],
  ])("rejects %s", async (_label, body) => {
    const { token } = await signIn();
    const response = await put(token, DEVICE_A, body);
    expect(response.status).toBe(400);
    expect(response.body.error.code).toBe("bad_request");
  });

  it("rejects bad device ids and requires sign-in", async () => {
    const { token } = await signIn();
    expect((await put(token, "short", upload([]))).status).toBe(400);
    expect((await put("", DEVICE_A, upload([]))).status).toBe(401);
  });

  it("drops days outside the upload window instead of failing", async () => {
    const { token } = await signIn();
    const response = await put(
      token,
      DEVICE_A,
      upload([{ provider: "codex", days: [{ date: "2026-01-01", tokens: 1 }, { date: "2026-10-05", tokens: 2 }, { date: "2026-10-09", tokens: 3 }] }]),
    );
    expect(response.body.days).toBe(1);
  });

  it("replaces the device's previous upload and can be deleted", async () => {
    const { owner, team } = await teamWith([]);
    await put(owner.token, DEVICE_A, upload([{ provider: "codex", days: [{ date: "2026-10-05", tokens: 10, costUSD: 1 }] }]));
    await put(owner.token, DEVICE_A, upload([{ provider: "claude", days: [{ date: "2026-10-05", tokens: 7, costUSD: 3 }] }]));

    const stats = (await api("GET", `/v1/teams/${team.id}/stats?range=today`, { token: owner.token })).body.stats;
    expect(stats.members[0].providers).toEqual([{ provider: "claude", tokens: 7, costUSD: 3 }]);

    expect((await api("DELETE", `/v1/devices/${DEVICE_A}`, { token: owner.token })).status).toBe(204);
    expect((await api("DELETE", `/v1/devices/${DEVICE_A}`, { token: owner.token })).status).toBe(404);
    const after = (await api("GET", `/v1/teams/${team.id}/stats?range=today`, { token: owner.token })).body.stats;
    expect(after.totals).toEqual({ tokens: 0, costUSD: 0 });
  });
});

describe("team stats", () => {
  it("ranks members, splits by provider, and fills every day of the range", async () => {
    const { owner, team, members } = await teamWith(["Bea", "Cy"]);
    const [bea] = members as [typeof owner];
    await put(
      owner.token,
      DEVICE_A,
      upload([
        { provider: "claude", days: [{ date: "2026-10-05", tokens: 100, costUSD: 1 }] },
        { provider: "codex", days: [{ date: "2026-10-03", tokens: 900, costUSD: 0.5 }] },
      ]),
    );
    await put(bea.token, DEVICE_A, upload([{ provider: "claude", days: [{ date: "2026-10-04", tokens: 50, costUSD: 4 }] }]));

    const response = await api("GET", `/v1/teams/${team.id}/stats?range=7d`, { token: owner.token });
    expect(response.status).toBe(200);
    const { stats } = response.body;
    expect(stats.range).toEqual({ name: "7d", from: "2026-09-29", to: "2026-10-05", previousFrom: "2026-09-22", previousTo: "2026-09-28" });
    expect(stats.members.map((m: { displayName: string; rank: number; costUSD: number }) => [m.displayName, m.rank, m.costUSD])).toEqual([
      ["Bea", 1, 4],
      ["Owner", 2, 1.5],
      ["Cy", 3, 0],
    ]);
    expect(stats.members[1].providers).toEqual([
      { provider: "claude", tokens: 100, costUSD: 1 },
      { provider: "codex", tokens: 900, costUSD: 0.5 },
    ]);
    expect(stats.providers).toEqual([
      { provider: "claude", tokens: 150, costUSD: 5 },
      { provider: "codex", tokens: 900, costUSD: 0.5 },
    ]);
    expect(stats.totals).toEqual({ tokens: 1050, costUSD: 5.5 });
    expect(stats.daily).toHaveLength(7);
    expect(stats.daily.find((d: { day: string }) => d.day === "2026-10-04").members).toEqual([{ userID: bea.userID, tokens: 50, costUSD: 4 }]);
    expect(stats.daily.find((d: { day: string }) => d.day === "2026-10-05").providers).toEqual([{ provider: "claude", tokens: 100, costUSD: 1 }]);
    expect(stats.daily.find((d: { day: string }) => d.day === "2026-10-03").providers).toEqual([{ provider: "codex", tokens: 900, costUSD: 0.5 }]);

    const byTokens = (await api("GET", `/v1/teams/${team.id}/stats?range=7d&sort=tokens`, { token: owner.token })).body.stats;
    expect(byTokens.members.map((m: { displayName: string }) => m.displayName)).toEqual(["Owner", "Bea", "Cy"]);
    expect(byTokens.providers[0].provider).toBe("codex");
  });

  it("gives tied members the same rank", async () => {
    const { owner, team, members } = await teamWith(["Bea"]);
    await put(owner.token, DEVICE_A, upload([{ provider: "codex", days: [{ date: "2026-10-05", tokens: 1, costUSD: 2 }] }]));
    await put(members[0]!.token, DEVICE_A, upload([{ provider: "claude", days: [{ date: "2026-10-05", tokens: 9, costUSD: 2 }] }]));
    const stats = (await api("GET", `/v1/teams/${team.id}/stats?range=today`, { token: owner.token })).body.stats;
    expect(stats.members.map((m: { rank: number }) => m.rank)).toEqual([1, 1]);
  });

  it("sums device-scope usage across a user's Macs but counts account-scope usage once", async () => {
    const { owner, team } = await teamWith([]);
    await put(
      owner.token,
      DEVICE_A,
      upload([
        { provider: "claude", days: [{ date: "2026-10-05", tokens: 100, costUSD: 1, models: [{ model: "opus", tokens: 100, costUSD: 1 }] }] },
        { provider: "cursor", scope: "account", days: [{ date: "2026-10-05", tokens: 40, costUSD: 4, models: [{ model: "auto", tokens: 40, costUSD: 4 }] }] },
      ]),
    );
    // The second Mac uploads later, so its account-wide Cursor numbers are the newest.
    await api("PUT", `/v1/devices/${DEVICE_B}/usage`, {
      token: owner.token,
      now: new Date("2026-10-05T13:00:00Z"),
      body: upload(
        [
          { provider: "claude", days: [{ date: "2026-10-05", tokens: 30, costUSD: 0.3, models: [{ model: "opus", tokens: 30, costUSD: 0.3 }] }] },
          { provider: "cursor", scope: "account", days: [{ date: "2026-10-05", tokens: 50, costUSD: 5, models: [{ model: "auto", tokens: 50, costUSD: 5 }] }] },
        ],
        "iMac",
      ),
    });

    const stats = (await api("GET", `/v1/teams/${team.id}/stats?range=today`, { token: owner.token })).body.stats;
    expect(stats.members[0].providers).toEqual([
      { provider: "cursor", tokens: 50, costUSD: 5 },
      { provider: "claude", tokens: 130, costUSD: 1.3 },
    ]);
    expect(stats.models).toEqual([
      { model: "auto", provider: "cursor", tokens: 50, costUSD: 5, members: [{ userID: owner.userID, tokens: 50, costUSD: 5 }] },
      { model: "opus", provider: "claude", tokens: 130, costUSD: 1.3, members: [{ userID: owner.userID, tokens: 130, costUSD: 1.3 }] },
    ]);
  });

  it("counts a shared account once for the team and for no member", async () => {
    const SHARED = "a".repeat(64);
    const { owner, team, members } = await teamWith(["Bea"]);
    const cursor = (cost: number) => ({
      provider: "cursor",
      scope: "account" as const,
      account: SHARED,
      days: [{ date: "2026-10-05", tokens: cost * 10, costUSD: cost, models: [{ model: "auto", tokens: cost * 10, costUSD: cost }] }],
    });
    await put(owner.token, DEVICE_A, upload([cursor(8), { provider: "claude", days: [{ date: "2026-10-05", tokens: 10, costUSD: 1 }] }]));
    // Bea uploads the same Cursor account later, so her copy is the newest.
    await api("PUT", `/v1/devices/${DEVICE_B}/usage`, { token: members[0]!.token, now: new Date("2026-10-05T13:00:00Z"), body: upload([cursor(9)]) });

    const stats = (await api("GET", `/v1/teams/${team.id}/stats?range=today`, { token: owner.token })).body.stats;
    expect(stats.totals).toEqual({ tokens: 100, costUSD: 10 });
    expect(stats.members.map((m: { displayName: string; costUSD: number }) => [m.displayName, m.costUSD])).toEqual([
      ["Owner", 1],
      ["Bea", 0],
    ]);
    expect(stats.shared).toEqual([{ provider: "cursor", tokens: 90, costUSD: 9, members: [owner.userID, members[0]!.userID].sort() }]);
    expect(stats.providers).toEqual([
      { provider: "cursor", tokens: 90, costUSD: 9 },
      { provider: "claude", tokens: 10, costUSD: 1 },
    ]);
    expect(stats.models[0]).toEqual({ model: "auto", provider: "cursor", tokens: 90, costUSD: 9, members: [] });
    expect(stats.daily[0].providers[0]).toEqual({ provider: "cursor", tokens: 90, costUSD: 9 });
  });

  it("keeps an account fingerprint only one member uploaded as theirs", async () => {
    const { owner, team } = await teamWith(["Bea"]);
    await put(owner.token, DEVICE_A, upload([{ provider: "cursor", scope: "account", account: "b".repeat(32), days: [{ date: "2026-10-05", tokens: 5, costUSD: 3 }] }]));
    const stats = (await api("GET", `/v1/teams/${team.id}/stats?range=today`, { token: owner.token })).body.stats;
    expect(stats.members[0]).toMatchObject({ displayName: "Owner", costUSD: 3 });
    expect(stats.shared).toEqual([]);
  });

  it("uses the viewer's local day when it is within a day of UTC", async () => {
    const { owner, team } = await teamWith([]);
    const local = (await api("GET", `/v1/teams/${team.id}/stats?range=today&today=2026-10-06`, { token: owner.token })).body.stats;
    expect(local.range).toMatchObject({ from: "2026-10-06", to: "2026-10-06" });
    const future = (await api("GET", `/v1/teams/${team.id}/stats?range=today&today=2026-12-25`, { token: owner.token })).body.stats;
    expect(future.range).toMatchObject({ from: "2026-10-05", to: "2026-10-05" });
    const lastWeek = (await api("GET", `/v1/teams/${team.id}/stats?range=7d&today=2026-10-04`, { token: owner.token })).body.stats;
    expect(lastWeek.range).toMatchObject({ from: "2026-09-28", to: "2026-10-04" });
    const tooOld = (await api("GET", `/v1/teams/${team.id}/stats?range=today&today=2024-01-01`, { token: owner.token })).body.stats;
    expect(tooOld.range).toMatchObject({ from: "2026-10-05", to: "2026-10-05" });
    expect((await api("GET", `/v1/teams/${team.id}/stats?range=1y`, { token: owner.token })).status).toBe(400);
    expect((await api("GET", `/v1/teams/${team.id}/stats?sort=fun`, { token: owner.token })).status).toBe(400);
  });

  it("ignores usage of people who are not in the team", async () => {
    const { owner, team } = await teamWith([]);
    const stranger = await signIn("Stranger");
    await put(stranger.token, DEVICE_A, upload([{ provider: "claude", days: [{ date: "2026-10-05", tokens: 5, costUSD: 50 }] }]));
    const stats = (await api("GET", `/v1/teams/${team.id}/stats?range=today`, { token: owner.token })).body.stats;
    expect(stats.members.map((m: { displayName: string }) => m.displayName)).toEqual(["Owner"]);
    expect(stats.totals.costUSD).toBe(0);
  });

  it("reports each member's rank and totals in the previous period", async () => {
    const { owner, team, members } = await teamWith(["Bea"]);
    const [bea] = members as [typeof owner];
    // Last week Owner led; this week Bea overtook.
    await put(owner.token, DEVICE_A, upload([{ provider: "claude", days: [
      { date: "2026-09-25", tokens: 10, costUSD: 9 },
      { date: "2026-10-05", tokens: 10, costUSD: 1 },
    ] }]));
    await put(bea.token, DEVICE_A, upload([{ provider: "claude", days: [{ date: "2026-10-04", tokens: 10, costUSD: 5 }] }]));

    const stats = (await api("GET", `/v1/teams/${team.id}/stats?range=7d`, { token: owner.token })).body.stats;
    const byName = Object.fromEntries(stats.members.map((m: { displayName: string }) => [m.displayName, m]));
    expect(byName.Bea.rank).toBe(1);
    expect(byName.Bea.previous).toBeNull();
    expect(byName.Owner.rank).toBe(2);
    expect(byName.Owner.previous).toEqual({ rank: 1, tokens: 10, costUSD: 9 });
  });

  it("offers a year range", async () => {
    const { owner, team } = await teamWith([]);
    const stats = (await api("GET", `/v1/teams/${team.id}/stats?range=365d`, { token: owner.token })).body.stats;
    expect(stats.range).toMatchObject({ name: "365d", from: "2025-10-06", to: "2026-10-05" });
    expect(stats.daily).toHaveLength(365);
  });
});

describe("usage history", () => {
  it("keeps days older than the upload's window", async () => {
    const { owner, team } = await teamWith([]);
    // Uploaded a month ago, when the app still had these days in its window.
    await api("PUT", `/v1/devices/${DEVICE_A}/usage`, {
      token: owner.token,
      now: new Date("2026-09-01T12:00:00Z"),
      body: upload([{ provider: "claude", days: [{ date: "2026-08-25", tokens: 100, costUSD: 10 }] }]),
    });
    // Today's upload only covers the last 30 days.
    await put(owner.token, DEVICE_A, {
      ...upload([{ provider: "claude", days: [{ date: "2026-10-05", tokens: 1, costUSD: 1 }] }]),
      windowStart: "2026-09-05",
    });

    const year = (await api("GET", `/v1/teams/${team.id}/stats?range=365d`, { token: owner.token })).body.stats;
    expect(year.totals).toEqual({ tokens: 101, costUSD: 11 });
  });

  it("replaces every day from the window start, even ones the new upload no longer has", async () => {
    const { owner, team } = await teamWith([]);
    await put(owner.token, DEVICE_A, upload([{ provider: "codex", days: [{ date: "2026-09-20", tokens: 5, costUSD: 5 }] }]));
    // Codex was turned off: the new upload has no Codex days, but its window covers 2026-09-20.
    await put(owner.token, DEVICE_A, { ...upload([]), windowStart: "2026-09-05" });
    const month = (await api("GET", `/v1/teams/${team.id}/stats?range=30d`, { token: owner.token })).body.stats;
    expect(month.totals).toEqual({ tokens: 0, costUSD: 0 });
  });

  it("rejects a window start that is not recent", async () => {
    const { token } = await signIn();
    expect((await put(token, DEVICE_A, { ...upload([]), windowStart: "2025-01-01" })).status).toBe(400);
    expect((await put(token, DEVICE_A, { ...upload([]), windowStart: "nope" })).status).toBe(400);
  });
});

describe("upload writes", () => {
  // A month of Claude days with two models each, as a Mac sends every 15 minutes.
  function month(todayTokens: number, todayModels = ["claude-opus-4-1", "claude-sonnet-4-5"]) {
    const days = Array.from({ length: 30 }, (_, index) => {
      const date = addDays("2026-10-05", -index);
      const tokens = index === 0 ? todayTokens : 100;
      const models = index === 0 ? todayModels : ["claude-opus-4-1", "claude-sonnet-4-5"];
      return { date, tokens, costUSD: tokens / 100, models: models.map((model) => ({ model, tokens: tokens / 2, costUSD: tokens / 200 })) };
    });
    return parseUsageUpload({ ...upload([{ provider: "claude", days }]), windowStart: "2026-09-06" }, NOW);
  }

  it("writes only the device row when the upload repeats the last one", async () => {
    const { userID } = await signIn();
    const first = await storeDeviceUsage(env, userID, DEVICE_A, month(200), NOW);
    expect(first).toBeGreaterThan(90);
    expect(await storeDeviceUsage(env, userID, DEVICE_A, month(200), NOW)).toBe(1);
  });

  it("rewrites only the rows that changed and deletes the ones that are gone", async () => {
    const { owner, team } = await teamWith([]);
    await storeDeviceUsage(env, owner.userID, DEVICE_A, month(200), NOW);
    // Today grew and dropped Sonnet: one day row and one model row change, one model row goes.
    const written = await storeDeviceUsage(env, owner.userID, DEVICE_A, month(400, ["claude-opus-4-1"]), NOW);
    expect(written).toBeLessThan(15);

    const today = (await api("GET", `/v1/teams/${team.id}/stats?range=today`, { token: owner.token })).body.stats;
    expect(today.totals).toEqual({ tokens: 400, costUSD: 4 });
    expect(today.models.map((model: { model: string }) => model.model)).toEqual(["claude-opus-4-1"]);
    const recent = (await api("GET", `/v1/teams/${team.id}/stats?range=30d`, { token: owner.token })).body.stats;
    expect(recent.totals).toEqual({ tokens: 400 + 29 * 100, costUSD: 4 + 29 });
  });
});
