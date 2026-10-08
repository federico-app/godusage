import { describe, expect, it } from "vitest";
import { api, NOW, signIn } from "./support";

async function pairingCode(token: string): Promise<string> {
  const response = await api("POST", "/v1/auth/pairing", { token });
  expect(response.status).toBe(201);
  return response.body.code;
}

async function pair(code: string, deviceName = "Andrea's iPhone", now: Date = NOW) {
  return api("POST", "/v1/auth/pairing/exchange", { body: { code, deviceName }, now });
}

describe("QR pairing", () => {
  it("gives the phone a session of the Mac's account", async () => {
    const mac = await signIn("Andrea");
    const created = await api("POST", "/v1/auth/pairing", { token: mac.token });
    expect(created.status).toBe(201);
    expect(created.body.code).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(created.body.expiresAt).toBe(new Date(NOW.getTime() + 3 * 60 * 1000).toISOString());

    const paired = await pair(created.body.code);
    expect(paired.status).toBe(201);
    expect(paired.body.user).toEqual({ id: mac.userID, displayName: "Andrea" });
    const me = await api("GET", "/v1/me", { token: paired.body.token });
    expect(me.status).toBe(200);
    expect(me.body.user.id).toBe(mac.userID);
  });

  it("refuses a code twice, after it expires, or once a newer one was made", async () => {
    const mac = await signIn();
    const used = await pairingCode(mac.token);
    expect((await pair(used)).status).toBe(201);
    expect((await pair(used)).status).toBe(401);

    const expiring = await pairingCode(mac.token);
    expect((await pair(expiring, "Phone", new Date(NOW.getTime() + 3 * 60 * 1000))).status).toBe(401);

    const replaced = await pairingCode(mac.token);
    const latest = await pairingCode(mac.token);
    expect((await pair(replaced)).status).toBe(401);
    expect((await pair(latest)).status).toBe(201);
  });

  it("refuses malformed codes and missing device names", async () => {
    expect((await pair("not-a-code")).status).toBe(401);
    const mac = await signIn();
    const code = await pairingCode(mac.token);
    expect((await api("POST", "/v1/auth/pairing/exchange", { body: { code } })).status).toBe(400);
    // The failed request did not spend the code.
    expect((await pair(code)).status).toBe(201);
  });

  it("needs a signed-in Mac, not a paired device, to make a code", async () => {
    expect((await api("POST", "/v1/auth/pairing")).status).toBe(401);
    const mac = await signIn();
    const phone = await pair(await pairingCode(mac.token));
    expect((await api("POST", "/v1/auth/pairing", { token: phone.body.token })).status).toBe(403);
  });

  it("lists linked devices and unlinks them", async () => {
    const mac = await signIn();
    const phone = await pair(await pairingCode(mac.token), "iPhone 17");
    const other = await signIn();

    const listed = await api("GET", "/v1/me/linked-devices", { token: mac.token });
    expect(listed.status).toBe(200);
    expect(listed.body.devices).toHaveLength(1);
    const device = listed.body.devices[0];
    expect(device.name).toBe("iPhone 17");
    expect((await api("GET", "/v1/me/linked-devices", { token: other.token })).body.devices).toEqual([]);

    // Another account can't unlink it, and the Mac's own session is not a linked device.
    expect((await api("DELETE", `/v1/me/linked-devices/${device.id}`, { token: other.token })).status).toBe(404);
    expect((await api("DELETE", "/v1/me/linked-devices/nope", { token: mac.token })).status).toBe(404);

    expect((await api("DELETE", `/v1/me/linked-devices/${device.id}`, { token: mac.token })).status).toBe(204);
    expect((await api("GET", "/v1/me", { token: phone.body.token })).status).toBe(401);
    expect((await api("GET", "/v1/me", { token: mac.token })).status).toBe(200);
  });

  it("keeps the phone signed in after the Mac signs out, and includes it in the export", async () => {
    const mac = await signIn();
    const phone = await pair(await pairingCode(mac.token), "iPad");
    const exported = await api("GET", "/v1/me/export", { token: mac.token });
    expect(exported.body.linkedDevices).toEqual([expect.objectContaining({ name: "iPad" })]);

    expect((await api("POST", "/v1/auth/logout", { token: mac.token })).status).toBe(204);
    expect((await api("GET", "/v1/me", { token: phone.body.token })).status).toBe(200);
  });
});
