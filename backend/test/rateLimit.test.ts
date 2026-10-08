import { env } from "./env";
import { describe, expect, it } from "vitest";
import { createApp } from "../src/index";
import { CLIENT_IP_HEADER, rateLimitKind } from "../src/rateLimit";
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

  it("counts requests in Redis by default, shared by every replica", async () => {
    // Two app instances stand in for two server replicas: they share the limit.
    const replicas = [0, 1].map(() => createApp({ fetchAppleKeys: async () => [publicJWK], now: () => NOW }));
    // Stay inside one fixed one-minute window.
    const untilNextWindow = 60_000 - (Date.now() % 60_000);
    if (untilNextWindow < 3_000) await new Promise((resolve) => setTimeout(resolve, untilNextWindow + 50));
    const statuses: number[] = [];
    for (let i = 0; i < 25; i++) {
      const response = await replicas[i % 2]!.fetch(
        new Request("https://api.test/v1/auth/apple/start?state=x&code_challenge=y", { headers: { [CLIENT_IP_HEADER]: "203.0.113.9" } }),
        env,
      );
      statuses.push(response.status);
    }
    expect(statuses.filter((status) => status !== 429)).toHaveLength(20);
    expect(statuses.slice(20)).toEqual([429, 429, 429, 429, 429]);
  });
});
