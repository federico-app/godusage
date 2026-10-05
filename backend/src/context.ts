import type { AppleKeyFetcher } from "./apple";

/** Outside-world dependencies, injectable so tests never call Apple. */
export interface AppDeps {
  fetchAppleKeys: AppleKeyFetcher;
  now: () => Date;
}

export interface RouteContext {
  request: Request;
  env: Env;
  url: URL;
  params: Record<string, string>;
  deps: AppDeps;
}

export type Handler = (context: RouteContext) => Promise<Response>;
