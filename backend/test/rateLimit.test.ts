import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { createApp } from "../src/index";
import { rateLimitKind } from "../src/rateLimit";
import { NOW, publicJWK, signIn } from "./support";

describe("rate limits", () => {
  it("limits sign-in routes and pages per IP and API routes per session", () => {
    expect(rateLimitKind("/v1/auth/apple/start")).toBe("auth");
    expect(rateLimitKind("/teams/abc/sign-in")).toBe("auth");
    expect(rateLimitKind("/v1/teams")).toBe("api");
    expect(rateLimitKind("/v1/health")).toBeNull();
    expect(rateLimitKind("/join/abc")).toBe("page");
    expect(rateLimitKind("/t/abc")).toBe("page");
    expect(rateLimitKind("/teams/abc")).toBe("page");
    expect(rateLimitKind("/")).toBeNull();
    expect(rateLimitKind("/privacy")).toBeNull();
  });

  it("answers 429 with Retry-After once a client is over its limit", async () => {
    const { token } = await signIn();
    const seen: string[] = [];
    let allowed = 2;
    const app = createApp({
      fetchAppleKeys: async () => [publicJWK],
      now: () => NOW,
      rateLimiter: async (kind, key) => {
        seen.push(`${kind} ${key.split(":")[0]}`);
        return allowed-- > 0;
      },
    });
    const get = () => app.fetch(new Request("https://api.test/v1/teams", { headers: { authorization: `Bearer ${token}` } }), env);
    expect((await get()).status).toBe(200);
    expect((await get()).status).toBe(200);
    const limited = await get();
    expect(limited.status).toBe(429);
    expect(limited.headers.get("retry-after")).toBe("60");
    expect(((await limited.json()) as { error: { code: string } }).error.code).toBe("rate_limited");
    expect(seen).toEqual(["api session", "api session", "api session"]);
  });

  it("uses the real binding by default", async () => {
    const app = createApp({ fetchAppleKeys: async () => [publicJWK], now: () => NOW });
    const statuses: number[] = [];
    for (let i = 0; i < 25; i++) {
      const response = await app.fetch(
        new Request("https://api.test/v1/auth/apple/start?state=x&code_challenge=y", { headers: { "cf-connecting-ip": "203.0.113.9" } }),
        env,
      );
      statuses.push(response.status);
    }
    expect(statuses.filter((status) => status === 429).length).toBeGreaterThan(0);
  });
});
