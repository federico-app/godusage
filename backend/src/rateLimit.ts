import { ApiError, sha256Hex } from "./http";

/**
 * Per-client request limits, on Cloudflare's rate limiting bindings (wrangler.jsonc `ratelimits`):
 * sign-in routes allow 20 requests a minute per IP; everything else under /v1 allows 120 a minute
 * per session (or per IP without one). Pages are not limited. Over the limit: 429 with Retry-After.
 */
export type RateLimitKind = "auth" | "api";
export type RateLimiter = (kind: RateLimitKind, key: string) => Promise<boolean>;

export function bindingRateLimiter(env: Env): RateLimiter {
  return async (kind, key) => {
    const binding = kind === "auth" ? env.AUTH_LIMITER : env.API_LIMITER;
    const { success } = await binding.limit({ key });
    return success;
  };
}

export function rateLimitKind(pathname: string): RateLimitKind | null {
  if (pathname.startsWith("/v1/auth/") || /^\/teams\/[^/]+\/sign-in$/.test(pathname)) return "auth";
  if (pathname.startsWith("/v1/") && pathname !== "/v1/health") return "api";
  return null;
}

/** The client a request counts against: its session token (hashed) or its IP. */
export async function rateLimitKey(request: Request, kind: RateLimitKind): Promise<string> {
  const bearer = request.headers.get("authorization")?.match(/^Bearer (.+)$/)?.[1];
  if (kind === "api" && bearer) return `session:${(await sha256Hex(bearer)).slice(0, 32)}`;
  return `ip:${request.headers.get("cf-connecting-ip") ?? "unknown"}`;
}

export class RateLimitedError extends ApiError {
  constructor() {
    super(429, "rate_limited", "Too many requests. Wait a minute and try again.");
  }
}
