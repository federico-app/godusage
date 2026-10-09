import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { proxyRequest, type ProxyEnv } from "../proxy/src/proxy";
import { PROXY_CLIENT_IP_HEADER, PROXY_HOST_HEADER, PROXY_SECRET_HEADER, ProxyRejected, requestListener, toFetchRequest } from "../server/http";
import { CLIENT_IP_HEADER } from "../src/rateLimit";
import { env } from "./env";
import { makeApp, signIn, upload } from "./support";

const PUBLIC = "https://godusage-api.federico-c80.workers.dev";
const SECRET = "test-proxy-secret-0123456789";

describe("proxy Worker", () => {
  const proxyEnv: ProxyEnv = { ORIGIN_URL: "https://origin.example", PROXY_SECRET: SECRET };

  it("forwards method, path, query, headers, and body, and says who the client is", async () => {
    let seen: { url: string; init: RequestInit } | undefined;
    const response = await proxyRequest(
      new Request(`${PUBLIC}/v1/devices/abc/usage?x=1`, {
        method: "PUT",
        headers: { authorization: "Bearer t", "cf-connecting-ip": "198.51.100.7", [PROXY_HOST_HEADER]: "evil.example", [PROXY_SECRET_HEADER]: "forged" },
        body: "{}",
      }),
      proxyEnv,
      async (url, init) => {
        seen = { url: String(url), init: init! };
        return new Response(null, { status: 302, headers: { location: "https://elsewhere.example/", "set-cookie": "a=b" } });
      },
    );
    expect(seen!.url).toBe("https://origin.example/v1/devices/abc/usage?x=1");
    expect(seen!.init.method).toBe("PUT");
    expect(seen!.init.redirect).toBe("manual");
    expect(new TextDecoder().decode(seen!.init.body as ArrayBuffer)).toBe("{}");
    const headers = new Headers(seen!.init.headers);
    expect(headers.get("authorization")).toBe("Bearer t");
    expect(headers.get(PROXY_SECRET_HEADER)).toBe(SECRET);
    expect(headers.get(PROXY_HOST_HEADER)).toBe("godusage-api.federico-c80.workers.dev");
    expect(headers.get(PROXY_CLIENT_IP_HEADER)).toBe("198.51.100.7");
    // Redirects and cookies go back to the client as they are.
    expect(response.status).toBe(302);
    expect(response.headers.get("set-cookie")).toBe("a=b");
  });

  it("exports only the handler from its entry module (Workers reject other named exports)", async () => {
    const entry = await import("../proxy/src/index");
    expect(Object.keys(entry)).toEqual(["default"]);
  });

  it("answers 502 when the origin is down and 500 when it is not configured", async () => {
    const down = await proxyRequest(new Request(`${PUBLIC}/v1/health`), proxyEnv, async () => {
      throw new TypeError("fetch failed");
    });
    expect(down.status).toBe(502);
    expect((await proxyRequest(new Request(`${PUBLIC}/v1/health`), { ORIGIN_URL: "", PROXY_SECRET: SECRET })).status).toBe(500);
  });
});

describe("the server behind a proxy", () => {
  it("takes the public host and client IP from the proxy only with the right secret", () => {
    const headers = { host: "api.coolify.example", [PROXY_SECRET_HEADER]: SECRET, [PROXY_HOST_HEADER]: "godusage-api.federico-c80.workers.dev", [PROXY_CLIENT_IP_HEADER]: "198.51.100.7" };
    const proxied = toFetchRequest("GET", "/v1/me", headers, undefined, "10.0.0.2", SECRET);
    expect(proxied.url).toBe(`${PUBLIC}/v1/me`);
    expect(proxied.headers.get(CLIENT_IP_HEADER)).toBe("198.51.100.7");
    expect(proxied.headers.get(PROXY_SECRET_HEADER)).toBeNull();

    expect(() => toFetchRequest("GET", "/v1/me", { ...headers, [PROXY_SECRET_HEADER]: "wrong" }, undefined, "10.0.0.2", SECRET)).toThrow(ProxyRejected);
    expect(() => toFetchRequest("GET", "/v1/me", headers, undefined, "10.0.0.2", undefined)).toThrow(ProxyRejected);
  });

  it("uses Coolify's forwarded headers for direct requests, and the address Traefik appended", () => {
    const direct = toFetchRequest(
      "GET",
      "/v1/me",
      { host: "api.coolify.example", "x-forwarded-proto": "https", "x-forwarded-for": "203.0.113.1, 192.0.2.44", [CLIENT_IP_HEADER]: "spoofed" },
      undefined,
      "10.0.0.2",
      SECRET,
    );
    expect(direct.url).toBe("https://api.coolify.example/v1/me");
    expect(direct.headers.get(CLIENT_IP_HEADER)).toBe("192.0.2.44");
    const local = toFetchRequest("GET", "/v1/me", { host: "127.0.0.1:8787" }, undefined, "127.0.0.1", undefined);
    expect(local.url).toBe("http://127.0.0.1:8787/v1/me");
    expect(local.headers.get(CLIENT_IP_HEADER)).toBe("127.0.0.1");
  });

  describe("end to end", () => {
    let server: Server;
    let origin: string;
    beforeAll(async () => {
      server = createServer(requestListener(makeApp(), env, SECRET, () => {}));
      await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
      origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
    });
    afterAll(() => new Promise<void>((resolve) => server.close(() => resolve())));

    const viaProxy = (path: string, init: RequestInit = {}) =>
      proxyRequest(new Request(`${PUBLIC}${path}`, init), { ORIGIN_URL: origin, PROXY_SECRET: SECRET });

    it("keeps Sign in with Apple's return URL on the workers.dev host", async () => {
      const state = "app-state-0123456789";
      const challenge = "a".repeat(43);
      const response = await viaProxy(`/v1/auth/apple/start?state=${state}&code_challenge=${challenge}`);
      expect(response.status).toBe(302);
      const apple = new URL(response.headers.get("location")!);
      expect(apple.host).toBe("appleid.apple.com");
      expect(apple.searchParams.get("redirect_uri")).toBe(`${PUBLIC}/v1/auth/apple/callback`);
    });

    it("builds invite and board links on the public host, and carries uploads", async () => {
      const { token } = await signIn("Proxy");
      const auth = { authorization: `Bearer ${token}`, "content-type": "application/json" };
      const created = await viaProxy("/v1/teams", { method: "POST", headers: auth, body: JSON.stringify({ name: "Via Proxy" }) });
      expect(created.status).toBe(201);
      const team = ((await created.json()) as { team: { id: string; inviteURL: string; webBoardURL: string } }).team;
      expect(team.inviteURL.startsWith(`${PUBLIC}/join/`)).toBe(true);
      expect(team.webBoardURL).toBe(`${PUBLIC}/teams/${team.id}`);

      const put = await viaProxy("/v1/devices/device-proxy-0001/usage", {
        method: "PUT",
        headers: auth,
        body: JSON.stringify(upload([{ provider: "claude", days: [{ date: "2026-10-05", tokens: 7, costUSD: 1 }] }])),
      });
      expect(put.status).toBe(200);
      const health = await viaProxy("/v1/health");
      expect(await health.json()).toEqual({ ok: true });
    });

    it("refuses a forged proxy secret", async () => {
      const response = await proxyRequest(new Request(`${PUBLIC}/v1/health`), { ORIGIN_URL: origin, PROXY_SECRET: "not-the-secret" });
      expect(response.status).toBe(403);
    });
  });
});
