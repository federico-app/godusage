import { describe, expect, it } from "vitest";
import { api, signIn, teamWith, upload } from "./support";

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
    expect(stats.range).toEqual({ name: "7d", from: "2026-09-29", to: "2026-10-05" });
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

  it("uses the viewer's local day when it is within a day of UTC", async () => {
    const { owner, team } = await teamWith([]);
    const local = (await api("GET", `/v1/teams/${team.id}/stats?range=today&today=2026-10-06`, { token: owner.token })).body.stats;
    expect(local.range).toMatchObject({ from: "2026-10-06", to: "2026-10-06" });
    const far = (await api("GET", `/v1/teams/${team.id}/stats?range=today&today=2026-12-25`, { token: owner.token })).body.stats;
    expect(far.range).toMatchObject({ from: "2026-10-05", to: "2026-10-05" });
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
});
