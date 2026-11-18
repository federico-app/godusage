import { describe, expect, it } from "vitest";
import { CLIENT_HEADER_MAX } from "../src/clientHeader";
import { sha256Hex } from "../src/http";
import { env } from "./env";
import { api, signIn } from "./support";

const CLIENT = "ios; app=1.10.1; model=iPhone 13; os=26.1";

async function linkPhone(client?: string) {
  const mac = await signIn();
  const code = (await api("POST", "/v1/auth/pairing", { token: mac.token })).body.code;
  const headers = client === undefined ? undefined : { "x-godusage-client": client };
  const phone = await api("POST", "/v1/auth/pairing/exchange", { body: { code, deviceName: "iPhone" }, headers });
  expect(phone.status).toBe(201);
  return { mac, phoneToken: phone.body.token as string };
}

async function device(macToken: string) {
  const listed = await api("GET", "/v1/me/linked-devices", { token: macToken });
  expect(listed.status).toBe(200);
  return listed.body.devices[0];
}

async function sessionRow(token: string) {
  return env.db.first<{ last_seen_at: string | null; device_model: string | null; os_version: string | null; app_version: string | null }>(
    "SELECT last_seen_at, device_model, os_version, app_version FROM sessions WHERE token_hash = $1",
    [await sha256Hex(token)],
  );
}

async function setLastSeen(token: string, at: Date) {
  await env.db.run("UPDATE sessions SET last_seen_at = $1 WHERE token_hash = $2", [at.toISOString(), await sha256Hex(token)]);
}

describe("linked device details", () => {
  it("records the model, OS and app version when the phone links", async () => {
    const before = Date.now();
    const { mac } = await linkPhone(CLIENT);
    const listed = await device(mac.token);
    expect(listed).toMatchObject({ name: "iPhone", model: "iPhone 13", osVersion: "26.1", appVersion: "1.10.1" });
    expect(new Date(listed.lastSeenAt).getTime()).toBeGreaterThanOrEqual(before - 1000);
    expect(listed.linkedAt).toEqual(expect.any(String));
  });

  it("keeps working for phones that never send the header", async () => {
    const { mac, phoneToken } = await linkPhone();
    expect((await api("GET", "/v1/me", { token: phoneToken })).status).toBe(200);
    const listed = await device(mac.token);
    expect(listed).toMatchObject({ name: "iPhone", model: null, osVersion: null, appVersion: null });
    expect(listed.lastSeenAt).toEqual(expect.any(String));
  });

  it("updates the last access at most once an hour, and at once when the details change", async () => {
    const { mac, phoneToken } = await linkPhone(CLIENT);
    const headers = { "x-godusage-client": CLIENT };

    // Seen 30 minutes ago with the same details: no write.
    const recent = new Date(Date.now() - 30 * 60 * 1000);
    await setLastSeen(phoneToken, recent);
    expect((await api("GET", "/v1/me", { token: phoneToken, headers })).status).toBe(200);
    expect((await sessionRow(phoneToken))?.last_seen_at).toBe(recent.toISOString());

    // Over an hour ago: written.
    await setLastSeen(phoneToken, new Date(Date.now() - 61 * 60 * 1000));
    const before = Date.now();
    expect((await api("GET", "/v1/me", { token: phoneToken, headers })).status).toBe(200);
    expect(new Date((await sessionRow(phoneToken))!.last_seen_at!).getTime()).toBeGreaterThanOrEqual(before - 1000);

    // A new app version is written even inside the hour; a request without the header keeps the details.
    await setLastSeen(phoneToken, recent);
    const updated = "ios; app=1.11.0; model=iPhone 13; os=26.2";
    expect((await api("GET", "/v1/me", { token: phoneToken, headers: { "x-godusage-client": updated } })).status).toBe(200);
    expect(await sessionRow(phoneToken)).toMatchObject({ app_version: "1.11.0", os_version: "26.2", device_model: "iPhone 13" });
    expect((await sessionRow(phoneToken))?.last_seen_at).not.toBe(recent.toISOString());
    await setLastSeen(phoneToken, new Date(Date.now() - 2 * 60 * 60 * 1000));
    expect((await api("GET", "/v1/me", { token: phoneToken })).status).toBe(200);
    expect(await device(mac.token)).toMatchObject({ model: "iPhone 13", osVersion: "26.2", appVersion: "1.11.0" });
  });

  it("never records anything for the Mac's own session", async () => {
    const { mac } = await linkPhone(CLIENT);
    expect((await api("GET", "/v1/me", { token: mac.token, headers: { "x-godusage-client": CLIENT } })).status).toBe(200);
    expect(await sessionRow(mac.token)).toEqual({ last_seen_at: null, device_model: null, os_version: null, app_version: null });
  });

  it("ignores a bad or oversized header instead of failing", async () => {
    const oversized = `ios; model=${"x".repeat(CLIENT_HEADER_MAX)}`;
    const { mac: first } = await linkPhone(oversized);
    expect(await device(first.token)).toMatchObject({ model: null, osVersion: null, appVersion: null });

    const { mac: second } = await linkPhone(`ios; model=${"y".repeat(61)}; os=26.1; app=; junk; =x; extra=1`);
    expect(await device(second.token)).toMatchObject({ model: null, osVersion: "26.1", appVersion: null });

    const { mac: third } = await linkPhone("not a platform!; model=iPhone 13");
    expect(await device(third.token)).toMatchObject({ model: null });
  });

  it("includes the details in the export", async () => {
    const { mac } = await linkPhone(CLIENT);
    const exported = await api("GET", "/v1/me/export", { token: mac.token });
    expect(exported.body.linkedDevices).toEqual([
      expect.objectContaining({ name: "iPhone", model: "iPhone 13", os_version: "26.1", app_version: "1.10.1", last_seen_at: expect.any(String) }),
    ]);
  });
});
