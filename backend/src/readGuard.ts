import { ApiError } from "./http";
import { dayKey } from "./usagePayload";

/**
 * D1's free plan allows 5M rows read a day per account, and production and dev share it. Two guards
 * keep the Worker under it:
 *
 * - Expensive results (stats, challenges, plan reports) are cached per team in `stats_cache` and
 *   reused until the team's `stats_version` changes, and never recomputed more often than the
 *   caller's minimum age (a few minutes: uploads bump the version all day long).
 * - Every expensive read (those recomputations and uploads) is added to `read_budget` for the UTC day.
 *   Past the environment's budget (`READ_BUDGET_PER_DAY`) nothing expensive runs until midnight UTC:
 *   cached results are served as they are (`paused`), and uploads are refused with 503.
 */

/** A cached result is reused for at most this long while nothing changed, so "updated 5m ago" stays close to the truth. */
const MAX_AGE_MS = 15 * 60_000;
/** Cached results older than this are dropped when the team's cache is next written. */
const KEEP_MS = 2 * 24 * 60 * 60_000;

export class ReadBudgetExceeded extends ApiError {
  constructor() {
    super(503, "read_budget", "Team stats are paused until midnight UTC to stay within the database's daily limit. They resume then.");
  }
}

export interface ReadGuard {
  db: D1Database;
  now: Date;
  /** Rows a day this environment may spend on expensive reads. */
  budget: number;
}

export function readGuard(env: Env, now: Date): ReadGuard {
  const budget = Number(env.READ_BUDGET_PER_DAY);
  if (!Number.isFinite(budget) || budget <= 0) throw new Error("READ_BUDGET_PER_DAY must be a positive number.");
  return { db: env.DB, now, budget };
}

export interface Cached<T> {
  value: T;
  /** When the value was computed (ISO 8601). */
  computedAt: string;
  /** The daily read budget is spent: this is the last value computed, kept until midnight UTC. */
  paused: boolean;
}

/**
 * The team's cached result for `key`, or a fresh one from `compute` (which reads through the handle
 * it is given, so its reads are counted). A cached result younger than `minAgeMs` is reused even when
 * the team's data changed meanwhile.
 */
export async function cachedTeamResult<T>(
  guard: ReadGuard,
  teamID: string,
  key: string,
  minAgeMs: number,
  compute: (db: D1Database) => Promise<T>,
): Promise<Cached<T>> {
  const { db, now } = guard;
  const row = await db
    .prepare(
      `SELECT t.stats_version AS current, c.version, c.body, c.computed_at FROM teams t
       LEFT JOIN stats_cache c ON c.team_id = t.id AND c.cache_key = ?2 WHERE t.id = ?1`,
    )
    .bind(teamID, key)
    .first<{ current: number; version: number | null; body: string | null; computed_at: string | null }>();
  if (!row) throw new Error(`cachedTeamResult: team ${teamID} not found`);

  const cached = row.body !== null && row.computed_at !== null ? { value: JSON.parse(row.body) as T, computedAt: row.computed_at } : null;
  if (cached) {
    const age = now.getTime() - Date.parse(cached.computedAt);
    if (age < minAgeMs || (row.version === row.current && age < MAX_AGE_MS)) return { ...cached, paused: false };
  }
  if (!(await budgetLeft(guard))) {
    if (cached) return { ...cached, paused: true };
    throw new ReadBudgetExceeded();
  }

  const counter = metered(db);
  const value = await compute(counter.db);
  const computedAt = now.toISOString();
  await db.batch([
    db.prepare(
      `INSERT INTO stats_cache (team_id, cache_key, version, body, computed_at) VALUES (?, ?, ?, ?, ?)
       ON CONFLICT (team_id, cache_key) DO UPDATE SET version = excluded.version, body = excluded.body, computed_at = excluded.computed_at`,
    ).bind(teamID, key, row.current, JSON.stringify(value), computedAt),
    db.prepare("DELETE FROM stats_cache WHERE team_id = ? AND computed_at < ?").bind(teamID, new Date(now.getTime() - KEEP_MS).toISOString()),
    chargeStatement(guard, counter.rowsRead()),
  ]);
  return { value, computedAt, paused: false };
}

/** Runs expensive work and counts its reads, or returns null once today's budget is spent. */
export async function tryGuardedWork<T>(guard: ReadGuard, work: (db: D1Database) => Promise<T>): Promise<{ value: T } | null> {
  if (!(await budgetLeft(guard))) return null;
  const counter = metered(guard.db);
  const value = await work(counter.db);
  await chargeStatement(guard, counter.rowsRead()).run();
  return { value };
}

/** Runs expensive work that has no cached fallback (an upload): refused once the budget is spent. */
export async function guardedWork<T>(guard: ReadGuard, work: (db: D1Database) => Promise<T>): Promise<T> {
  const result = await tryGuardedWork(guard, work);
  if (!result) throw new ReadBudgetExceeded();
  return result.value;
}

/**
 * Drops a team's cached results whose key starts with `prefix` (all of them by default), for changes
 * that must show at once: members, names, plans, challenges.
 */
export function forgetTeamCache(db: D1Database, teamID: string, prefix = ""): D1PreparedStatement {
  return db.prepare("DELETE FROM stats_cache WHERE team_id = ?1 AND substr(cache_key, 1, length(?2)) = ?2").bind(teamID, prefix);
}

/** Rows read so far today (UTC). */
export async function rowsReadToday(db: D1Database, now: Date): Promise<number> {
  return (await db.prepare("SELECT rows_read FROM read_budget WHERE day = ?").bind(dayKey(now)).first<number>("rows_read")) ?? 0;
}

async function budgetLeft(guard: ReadGuard): Promise<boolean> {
  return (await rowsReadToday(guard.db, guard.now)) < guard.budget;
}

function chargeStatement(guard: ReadGuard, rows: number): D1PreparedStatement {
  return guard.db
    .prepare(
      `INSERT INTO read_budget (day, rows_read) VALUES (?, ?)
       ON CONFLICT (day) DO UPDATE SET rows_read = rows_read + excluded.rows_read`,
    )
    .bind(dayKey(guard.now), rows);
}

/**
 * Bumps the stats version of the given teams, so their cached results are recomputed (at most once a
 * minute). `teamsSQL` selects team ids; `binds` fill its parameters.
 */
export function bumpStatsVersion(db: D1Database, teamsSQL: string, ...binds: unknown[]): D1PreparedStatement {
  return db.prepare(`UPDATE teams SET stats_version = stats_version + 1 WHERE id IN (${teamsSQL})`).bind(...binds);
}

/** Drops the cached results of every team the user is in (their name changed, or they left). */
export function forgetUserTeamsCache(db: D1Database, userID: string): D1PreparedStatement {
  return db.prepare("DELETE FROM stats_cache WHERE team_id IN (SELECT team_id FROM team_members WHERE user_id = ?)").bind(userID);
}

/** Bumps every team the user is in. */
export function bumpUserTeams(db: D1Database, userID: string): D1PreparedStatement {
  return bumpStatsVersion(db, "SELECT team_id FROM team_members WHERE user_id = ?", userID);
}

/** A D1 handle that adds up the rows its statements read (`meta.rows_read`). */
export function metered(db: D1Database): { db: D1Database; rowsRead: () => number } {
  let rows = 0;
  const count = <R extends { meta: { rows_read?: number } }>(result: R): R => {
    rows += result.meta.rows_read ?? 0;
    return result;
  };
  const inner = new WeakMap<object, D1PreparedStatement>();
  const wrap = (statement: D1PreparedStatement): D1PreparedStatement => {
    const wrapped = {
      bind: (...values: unknown[]) => wrap(statement.bind(...values)),
      all: async () => count(await statement.all()),
      run: async () => count(await statement.run()),
      raw: (options?: { columnNames?: boolean }) => statement.raw(options as { columnNames: true }),
      // `first` reports no meta, so it reads through `all`.
      first: async (column?: string) => {
        const result = count(await statement.all<Record<string, unknown>>());
        const first = result.results[0];
        if (first === undefined) return null;
        return column === undefined ? first : first[column];
      },
    } as unknown as D1PreparedStatement;
    inner.set(wrapped, statement);
    return wrapped;
  };
  const handle = {
    prepare: (query: string) => wrap(db.prepare(query)),
    batch: async (statements: D1PreparedStatement[]) => {
      const results = await db.batch(statements.map((statement) => inner.get(statement) ?? statement));
      for (const result of results) count(result);
      return results;
    },
    exec: (query: string) => db.exec(query),
    withSession: () => {
      throw new Error("metered: sessions are not supported");
    },
    dump: () => db.dump(),
  } as unknown as D1Database;
  return { db: handle, rowsRead: () => rows };
}
