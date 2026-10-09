import { describe, expect, it } from "vitest";
import { momentumLevels } from "../src/momentum";
import { env } from "./env";
import { api, NOW, teamWith, upload } from "./support";

const DAY = "2026-10-05";
const at = (minutes: number) => new Date(NOW.getTime() + minutes * 60_000);

async function put(token: string, deviceID: string, providers: Parameters<typeof upload>[0], now: Date) {
  const response = await api("PUT", `/v1/devices/${deviceID}/usage`, { token, body: upload(providers), now });
  expect(response.status).toBe(200);
}

async function momentum(token: string, teamID: string, now: Date) {
  const response = await api("GET", `/v1/teams/${teamID}/stats?range=today&today=${DAY}`, { token, now });
  expect(response.status).toBe(200);
  return response.body.momentum as Record<string, { lastHourUSD: number; level: number; reasons: string[] }>;
}

describe("momentumLevels", () => {
  it("gives one bolt per rule met, from $1 in the last hour", () => {
    const levels = momentumLevels(
      new Map([["fast", 12], ["usual", 3], ["slow", 0.5]]),
      new Map([["fast", 2], ["usual", 2.5]]),
    );
    // fast: ≥ $5, ≥ 2× its typical hour, top of the team.
    expect(levels.fast).toEqual({ lastHourUSD: 12, level: 3, reasons: ["fast", "self", "top"], typicalHourUSD: 2 });
    // usual: under $5, under 2× its typical $2.50, not on top.
    expect(levels.usual).toEqual({ lastHourUSD: 3, level: 0, reasons: [], typicalHourUSD: 2.5 });
    // Under $1 never earns a bolt, even on top of the team.
    expect(momentumLevels(new Map([["slow", 0.5]]), new Map()).slow).toEqual({ lastHourUSD: 0.5, level: 0, reasons: [], typicalHourUSD: null });
  });
});

describe("momentum in team stats", () => {
  it("counts what each upload added in the last hour, never a device's first upload", async () => {
    const { owner, team, members } = await teamWith(["Fede"]);
    const fede = members[0]!;
    // First uploads: the day so far is not "just spent".
    await put(owner.token, "device-aaaa-0001", [{ provider: "claude", days: [{ date: DAY, tokens: 100, costUSD: 40 }] }], at(0));
    await put(fede.token, "device-bbbb-0002", [{ provider: "codex", days: [{ date: DAY, tokens: 100, costUSD: 10 }] }], at(0));
    expect(await momentum(owner.token, team.id, at(1))).toEqual({});

    // The owner spends $8 more in two uploads, Fede $2 more.
    await put(owner.token, "device-aaaa-0001", [{ provider: "claude", days: [{ date: DAY, tokens: 200, costUSD: 45 }] }], at(10));
    await put(owner.token, "device-aaaa-0001", [{ provider: "claude", days: [{ date: DAY, tokens: 300, costUSD: 48 }] }], at(20));
    await put(fede.token, "device-bbbb-0002", [{ provider: "codex", days: [{ date: DAY, tokens: 150, costUSD: 12 }] }], at(20));

    const now = await momentum(owner.token, team.id, at(25));
    // Owner: ≥ $5 and top of the team (no history for the typical hour).
    expect(now[owner.userID]).toEqual({ lastHourUSD: 8, level: 2, reasons: ["fast", "top"], typicalHourUSD: null });
    expect(now[fede.userID]).toEqual({ lastHourUSD: 2, level: 0, reasons: [], typicalHourUSD: null });

    // An hour and more later, that spend no longer counts (stats are recomputed after ten minutes).
    expect(await momentum(owner.token, team.id, at(95))).toEqual({});
  });

  it("compares the last hour with the member's typical active hour", async () => {
    const { owner, team } = await teamWith([]);
    await put(owner.token, "device-aaaa-0003", [{ provider: "claude", days: [{ date: DAY, tokens: 1, costUSD: 1 }] }], at(0));
    // Two earlier active hours at $1.50 each.
    for (const hoursAgo of [5, 30]) {
      await env.db.run("INSERT INTO spend_pulses (user_id, device_id, bucket, cost_usd) VALUES ($1, $2, $3, $4)", [
        owner.userID,
        "device-aaaa-0003",
        new Date(NOW.getTime() - hoursAgo * 3_600_000).toISOString(),
        1.5,
      ]);
    }
    await put(owner.token, "device-aaaa-0003", [{ provider: "claude", days: [{ date: DAY, tokens: 2, costUSD: 4.5 }] }], at(5));
    // $3.50: under $5, at least 2 × $1.50, and alone on top.
    expect((await momentum(owner.token, team.id, at(6)))[owner.userID]).toEqual({ lastHourUSD: 3.5, level: 2, reasons: ["self", "top"], typicalHourUSD: 1.5 });
  });

  it("counts an account two Macs report once", async () => {
    const { owner, team } = await teamWith([]);
    const cursor = (cost: number) => [{ provider: "cursor", scope: "account" as const, days: [{ date: DAY, tokens: 1, costUSD: cost }] }];
    await put(owner.token, "device-aaaa-0004", cursor(10), at(0));
    await put(owner.token, "device-bbbb-0005", cursor(10), at(0));
    await put(owner.token, "device-aaaa-0004", cursor(13), at(10));
    await put(owner.token, "device-bbbb-0005", cursor(13), at(12));
    expect((await momentum(owner.token, team.id, at(15)))[owner.userID]?.lastHourUSD).toBe(3);
  });
});
