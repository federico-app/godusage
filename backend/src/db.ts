/**
 * The database the routes use: plain SQL in Postgres's dialect, with `$1, $2, …` parameters.
 * `server/postgres.ts` implements it on a `pg` pool. BIGINT and NUMERIC columns come back as JS
 * numbers (tokens, costs, counts), and timestamps are ISO 8601 strings stored as TEXT.
 */
export interface Queryable {
  /** Every row the statement returns. */
  query<T extends object = Record<string, unknown>>(sql: string, params?: readonly unknown[]): Promise<T[]>;
  /** The first row, or null. */
  first<T extends object = Record<string, unknown>>(sql: string, params?: readonly unknown[]): Promise<T | null>;
  /** Runs a statement and returns how many rows it changed. */
  run(sql: string, params?: readonly unknown[]): Promise<number>;
}

export interface Database extends Queryable {
  /** Runs `work` in one transaction: it commits when `work` resolves and rolls back when it throws. */
  transaction<T>(work: (tx: Queryable) => Promise<T>): Promise<T>;
}
