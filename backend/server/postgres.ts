import pg from "pg";
import type { Database, Queryable } from "../src/db";

/**
 * The routes' database on a `pg` connection pool. BIGINT (COUNT(*), token sums) and NUMERIC come back
 * from Postgres as strings; here they become JS numbers, and a BIGINT too large to be exact throws.
 */
const INT8 = 20;
const NUMERIC = 1700;

function int8(value: string): number {
  const number = Number(value);
  if (!Number.isSafeInteger(number)) throw new RangeError(`BIGINT ${value} does not fit in a JS number.`);
  return number;
}

const types = {
  getTypeParser(oid: number, format?: "text" | "binary") {
    if (oid === INT8) return int8;
    if (oid === NUMERIC) return Number;
    return pg.types.getTypeParser(oid, format);
  },
} as pg.CustomTypesConfig;

export interface PostgresOptions {
  /** Every connection's `search_path` (tests give each file its own schema). */
  schema?: string;
  max?: number;
  onError?: (error: Error) => void;
}

/**
 * Queries on a pool run in parallel on separate connections. Queries on one connection (a transaction)
 * are queued here, so callers may still start several at once (`Promise.all`).
 */
function queryable(client: pg.Pool | pg.PoolClient): Queryable {
  let tail: Promise<unknown> = Promise.resolve();
  const execute = (sql: string, params: readonly unknown[]): Promise<pg.QueryResult> => {
    if (client instanceof pg.Pool) return client.query(sql, params as unknown[]);
    const result = tail.then(() => client.query(sql, params as unknown[]));
    tail = result.catch(() => {});
    return result;
  };
  return {
    async query<T extends object>(sql: string, params: readonly unknown[] = []) {
      return (await execute(sql, params)).rows as T[];
    },
    async first<T extends object>(sql: string, params: readonly unknown[] = []) {
      return ((await execute(sql, params)).rows[0] as T | undefined) ?? null;
    },
    async run(sql: string, params: readonly unknown[] = []) {
      return (await execute(sql, params)).rowCount ?? 0;
    },
  };
}

export class PostgresDatabase implements Database {
  readonly pool: pg.Pool;
  private readonly direct: Queryable;

  constructor(connectionString: string, options: PostgresOptions = {}) {
    this.pool = new pg.Pool({
      connectionString,
      types,
      max: options.max ?? 10,
      ...(options.schema ? { options: `-c search_path=${options.schema}` } : {}),
    });
    // An idle connection that drops (Postgres restarted) must not crash the process; the pool replaces it.
    this.pool.on("error", (error) => (options.onError ?? console.error)(error));
    this.direct = queryable(this.pool);
  }

  query<T extends object = Record<string, unknown>>(sql: string, params?: readonly unknown[]) {
    return this.direct.query<T>(sql, params);
  }

  first<T extends object = Record<string, unknown>>(sql: string, params?: readonly unknown[]) {
    return this.direct.first<T>(sql, params);
  }

  run(sql: string, params?: readonly unknown[]) {
    return this.direct.run(sql, params);
  }

  async transaction<T>(work: (tx: Queryable) => Promise<T>): Promise<T> {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      const result = await work(queryable(client));
      await client.query("COMMIT");
      return result;
    } catch (error) {
      await client.query("ROLLBACK").catch(() => {});
      throw error;
    } finally {
      client.release();
    }
  }

  /** A dedicated connection, for work that needs one session (migrations hold an advisory lock). */
  async withClient<T>(work: (client: pg.PoolClient) => Promise<T>): Promise<T> {
    const client = await this.pool.connect();
    try {
      return await work(client);
    } finally {
      client.release();
    }
  }

  close(): Promise<void> {
    return this.pool.end();
  }
}
