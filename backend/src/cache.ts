/**
 * The cache the routes use: computed team results and request counters. `server/redis.ts` implements
 * it on Redis, so every replica of the server shares it.
 *
 * Each team has a stats version, bumped whenever its usage changes, and cached entries (stats,
 * challenges, plan reports, champions) stored with the version they were computed at. Nothing in it
 * is lost data: an empty cache only means the next requests recompute.
 */
export interface Cache {
  /** The team's current stats version and the entry cached under `key` (or null). */
  readTeam(teamID: string, key: string): Promise<{ version: number; entry: string | null }>;
  writeTeam(teamID: string, key: string, entry: string): Promise<void>;
  /** Bumps the stats version of these teams: their cached entries count as stale. */
  bumpTeams(teamIDs: readonly string[]): Promise<void>;
  /** Drops these teams' entries whose key starts with `prefix` (all of them by default). */
  forgetTeams(teamIDs: readonly string[], prefix?: string): Promise<void>;
  /** Counts one request against `key` in the current fixed window and returns the window's count. */
  hit(key: string, windowSeconds: number): Promise<number>;
  /** Throws unless the cache answers. */
  ping(): Promise<void>;
}
