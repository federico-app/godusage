import type { AppleKeyFetcher } from "./apple";
import type { Cache } from "./cache";
import type { Database } from "./db";
import type { RateLimiter } from "./rateLimit";

/** What the routes run against. `server/main.ts` builds it from the environment. */
export interface Env {
  db: Database;
  cache: Cache;
  /** Bundle IDs whose native Sign in with Apple identity tokens are accepted (comma-separated). */
  APPLE_AUDIENCES: string;
  /** The Services ID of the web Sign in with Apple flow. */
  APPLE_WEB_CLIENT_ID: string;
  /** Where the invite page sends people who do not have the app yet. */
  DOWNLOAD_URL: string;
  /** The URL scheme of the app this server serves (`godusage`, or `godusage-dev` for the dev server), for the invite page's link. */
  APP_SCHEME: "godusage" | "godusage-dev";
}

/** Outside-world dependencies, injectable so tests never call Apple. */
export interface AppDeps {
  fetchAppleKeys: AppleKeyFetcher;
  now: () => Date;
  /** Nil counts requests in the cache (see `rateLimit.ts`). */
  rateLimiter?: RateLimiter;
}

export interface RouteContext {
  request: Request;
  env: Env;
  url: URL;
  params: Record<string, string>;
  deps: AppDeps;
}

export type Handler = (context: RouteContext) => Promise<Response>;
