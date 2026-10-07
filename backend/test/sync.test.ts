import { describe, expect, it } from "vitest";
import { syncNote, versionLabel } from "../src/routes/pages";
import { api, teamWith, upload } from "./support";

describe("member sync time", () => {
  it("reports each member's newest upload across their Macs, or null", async () => {
    const { owner, team } = await teamWith(["Bea"]);
    const body = upload([{ provider: "claude", days: [{ date: "2026-10-05", tokens: 1, costUSD: 1 }] }]);
    await api("PUT", "/v1/devices/device-aaaa-0001/usage", { token: owner.token, body, now: new Date("2026-10-03T09:00:00Z") });
    await api("PUT", "/v1/devices/device-bbbb-0002/usage", { token: owner.token, body, now: new Date("2026-10-04T09:00:00Z") });
    const stats = (await api("GET", `/v1/teams/${team.id}/stats?range=today`, { token: owner.token })).body.stats;
    const byName = Object.fromEntries(stats.members.map((m: { displayName: string; lastSyncAt: string | null }) => [m.displayName, m.lastSyncAt]));
    expect(byName).toEqual({ Owner: "2026-10-04T09:00:00.000Z", Bea: null });
  });

  it("reports the GodUsage version of each member's newest upload", async () => {
    const { owner, team, members } = await teamWith(["Bea"]);
    const body = upload([{ provider: "claude", days: [{ date: "2026-10-05", tokens: 1, costUSD: 1 }] }]);
    await api("PUT", "/v1/devices/device-aaaa-0001/usage", { token: owner.token, body: { ...body, appVersion: "1.0.8" }, now: new Date("2026-10-04T09:00:00Z") });
    await api("PUT", "/v1/devices/device-bbbb-0002/usage", { token: owner.token, body: { ...body, appVersion: "1.0.6" }, now: new Date("2026-10-03T09:00:00Z") });
    // An app before 1.0.8 sends no version.
    await api("PUT", "/v1/devices/device-cccc-0003/usage", { token: members[0]!.token, body });
    const stats = (await api("GET", `/v1/teams/${team.id}/stats?range=today`, { token: owner.token })).body.stats;
    const byName = Object.fromEntries(stats.members.map((m: { displayName: string; appVersion: string | null }) => [m.displayName, m.appVersion]));
    expect(byName).toEqual({ Owner: "1.0.8", Bea: null });

    const bad = await api("PUT", "/v1/devices/device-aaaa-0001/usage", { token: owner.token, body: { ...body, appVersion: "<script>" } });
    expect(bad.status).toBe(400);
    expect(versionLabel("1.0.8")).toBe("v1.0.8");
    expect(versionLabel("dev")).toBe("dev");
  });

  it("shows the last update, then warns after 24 hours without a sync", () => {
    const now = new Date("2026-10-05T12:00:00Z");
    expect(syncNote("2026-10-05T11:59:30.000Z", now)).toBe("updated just now");
    expect(syncNote("2026-10-05T11:55:00.000Z", now)).toBe("updated 5m ago");
    expect(syncNote("2026-10-04T13:00:00.000Z", now)).toBe("updated 23h ago");
    expect(syncNote("2026-10-04T11:00:00.000Z", now)).toBe("not synced for 1 day");
    expect(syncNote("2026-10-01T12:00:00.000Z", now)).toBe("not synced for 4 days");
    expect(syncNote(null, now)).toBeNull();
  });
});
