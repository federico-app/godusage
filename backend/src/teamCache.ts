import type { Cache } from "./cache";
import type { Queryable } from "./db";

/**
 * Computed team results (stats, challenges, plan reports, champions) are kept in the cache (Redis) and
 * reused while they are fresh enough:
 *
 * - An entry younger than its minimum age (5 minutes for Today and challenges, 10 for the rest) is
 *   reused even when the team's usage changed meanwhile: uploads arrive all day long.
 * - After that, it is reused while the team's stats version is unchanged, up to `MAX_AGE_MS`.
 * - No entry is ever served once it is 10 minutes old.
 *
 * Uploads that change stored usage bump the version of the uploader's teams. Changes that must show at
 * once (members, names, plans, challenges) drop the team's entries instead.
 */
export const MAX_AGE_MS = 10 * 60_000;

export interface Cached<T> {
  value: T;
  /** When the value was computed (ISO 8601). */
  computedAt: string;
}

interface Entry<T> {
  version: number;
  computedAt: string;
  value: T;
}

/** The team's cached result for `key`, or a fresh one from `compute`. */
export async function cachedTeamResult<T>(
  cache: Cache,
  now: Date,
  teamID: string,
  key: string,
  minAgeMs: number,
  compute: () => Promise<T>,
): Promise<Cached<T>> {
  const { version, entry } = await cache.readTeam(teamID, key);
  if (entry !== null) {
    const cached = JSON.parse(entry) as Entry<T>;
    const age = now.getTime() - Date.parse(cached.computedAt);
    if (age >= 0 && age < MAX_AGE_MS && (age < minAgeMs || cached.version === version)) {
      return { value: cached.value, computedAt: cached.computedAt };
    }
  }
  const value = await compute();
  const computedAt = now.toISOString();
  await cache.writeTeam(teamID, key, JSON.stringify({ version, computedAt, value } satisfies Entry<T>));
  return { value, computedAt };
}

/** The teams the user is in. */
export async function userTeamIDs(db: Queryable, userID: string): Promise<string[]> {
  const rows = await db.query<{ team_id: string }>("SELECT team_id FROM team_members WHERE user_id = $1", [userID]);
  return rows.map((row) => row.team_id);
}
