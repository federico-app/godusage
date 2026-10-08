import { describe, expect, it } from "vitest";
import { api, signIn, upload } from "./support";

async function put(token: string, deviceID: string, body: unknown, now?: Date) {
  const response = await api("PUT", `/v1/devices/${deviceID}/usage`, { token, body, now });
  expect(response.status).toBe(200);
}

describe("GET /v1/me/usage", () => {
  it("sums Macs, keeps the newest Mac's account-wide usage, and fills every day of the window", async () => {
    const me = await signIn();
    await put(me.token, "device-aaaa-0001", upload([
      { provider: "claude", days: [{ date: "2026-10-05", tokens: 100, costUSD: 1.5 }] },
      { provider: "cursor", scope: "account", days: [{ date: "2026-10-05", tokens: 50, costUSD: 2 }] },
    ]), new Date("2026-10-05T12:00:00Z"));
    await put(me.token, "device-bbbb-0002", upload([
      { provider: "claude", days: [{ date: "2026-10-05", tokens: 10, costUSD: 0.5 }, { date: "2026-10-04", tokens: 7, costUSD: 0.25 }] },
      { provider: "cursor", scope: "account", days: [{ date: "2026-10-05", tokens: 60, costUSD: 3 }] },
    ], "Mac mini"), new Date("2026-10-05T12:30:00Z"));

    const response = await api("GET", "/v1/me/usage?today=2026-10-05", { token: me.token });
    expect(response.status).toBe(200);
    const body = response.body;
    expect(body.from).toBe("2026-09-06");
    expect(body.to).toBe("2026-10-05");
    expect(body.days).toHaveLength(30);
    expect(body.days[0]).toEqual({ day: "2026-09-06", tokens: 0, costUSD: 0 });
    expect(body.days[28]).toEqual({ day: "2026-10-04", tokens: 7, costUSD: 0.25 });
    expect(body.days[29]).toEqual({ day: "2026-10-05", tokens: 170, costUSD: 5 });
    expect(body.providers).toEqual([
      { provider: "cursor", tokens: 60, costUSD: 3 },
      { provider: "claude", tokens: 117, costUSD: 2.25 },
    ]);
    expect(body.lastSyncAt).toBe("2026-10-05T12:30:00.000Z");
  });

  it("is empty for an account whose Macs never uploaded, and needs a session", async () => {
    const me = await signIn();
    const response = await api("GET", "/v1/me/usage", { token: me.token });
    expect(response.status).toBe(200);
    expect(response.body.providers).toEqual([]);
    expect(response.body.lastSyncAt).toBeNull();
    expect((await api("GET", "/v1/me/usage")).status).toBe(401);
  });
});
