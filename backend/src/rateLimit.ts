import type { Cache } from "./cache";
import { ApiError, sha256Hex } from "./http";

/**
 * Per-client request limits, counted in the shared cache (Redis), so every replica sees the same
 * counts: sign-in routes allow 20 requests a minute per IP; everything else under /v1 allows 120 a
 * minute per session (or per IP without one); the leaderboard and invite pages allow 30 a minute per
 * IP, since each board view may compute stats. Over the limit: 429 with Retry-After.
 */
export type RateLimitKind = "auth" | "api" | "page";
export type RateLimiter = (kind: RateLimitKind, key: string) => Promise<boolean>;

export const RATE_LIMITS: Record<RateLimitKind, { limit: number; periodSeconds: number }> = {
  auth: { limit: 20, periodSeconds: 60 },
  api: { limit: 120, periodSeconds: 60 },
  page: { limit: 30, periodSeconds: 60 },
};

/** Fixed windows in the cache: at most `limit` requests per key in each period. */
export function cacheRateLimiter(cache: Cache): RateLimiter {
  return async (kind, key) => {
    const { limit, periodSeconds } = RATE_LIMITS[kind];
    return (await cache.hit(`${kind}:${key}`, periodSeconds)) <= limit;
  };
}

export function rateLimitKind(pathname: string): RateLimitKind | null {
  if (pathname.startsWith("/v1/auth/") || /^\/teams\/[^/]+\/sign-in$/.test(pathname)) return "auth";
  if (pathname.startsWith("/v1/") && pathname !== "/v1/health") return "api";
  if (/^\/(t|teams|join)\/[^/]+$/.test(pathname)) return "page";
  return null;
}

/** The header carrying the client's address. The server sets it from the connection (see `server/http.ts`). */
export const CLIENT_IP_HEADER = "x-godusage-client-ip";

/** The client a request counts against: its session token (hashed) or its IP. */
export async function rateLimitKey(request: Request, kind: RateLimitKind): Promise<string> {
  const bearer = request.headers.get("authorization")?.match(/^Bearer (.+)$/)?.[1];
  if (kind === "api" && bearer) return `session:${(await sha256Hex(bearer)).slice(0, 32)}`;
  return `ip:${request.headers.get(CLIENT_IP_HEADER) ?? "unknown"}`;
}

export class RateLimitedError extends ApiError {
  constructor() {
    super(429, "rate_limited", "Too many requests. Wait a minute and try again.");
  }
}
