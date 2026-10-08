import { DatabaseSync, type SQLInputValue, type StatementSync } from "node:sqlite";

/**
 * The subset of Cloudflare's D1 API the Worker uses, on a local SQLite file, so the same routes run
 * in a plain Node container. Statements run synchronously on one connection; `batch` is a transaction,
 * like D1's.
 */

type Row = Record<string, unknown>;

interface Meta {
  changes: number;
  last_row_id: number;
  rows_read: number;
  rows_written: number;
  duration: number;
  changed_db: boolean;
  size_after: number;
}

/** SQLite doesn't report rows scanned: `rows_read` is the rows returned, a lower bound. */
function meta(changes = 0, lastRowID = 0, rowsRead = 0): Meta {
  return { changes, last_row_id: lastRowID, rows_read: rowsRead, rows_written: changes, duration: 0, changed_db: changes > 0, size_after: 0 };
}

/** D1 binds booleans as 1/0 and undefined as null; node:sqlite accepts neither. */
function bindable(value: unknown): SQLInputValue {
  if (value === undefined || value === null) return null;
  if (typeof value === "boolean") return value ? 1 : 0;
  if (typeof value === "number" || typeof value === "bigint" || typeof value === "string" || value instanceof Uint8Array) return value;
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  throw new TypeError(`Cannot bind a ${typeof value} to a SQLite parameter.`);
}

class Statement {
  constructor(
    private readonly db: DatabaseSync,
    private readonly sql: string,
    private readonly params: SQLInputValue[] = [],
  ) {}

  bind(...values: unknown[]): Statement {
    return new Statement(this.db, this.sql, values.map(bindable));
  }

  private statement(): StatementSync {
    return this.db.prepare(this.sql);
  }

  /** Runs the statement and returns its rows, whether it is a query or not (`RETURNING`, upserts). */
  execute(): { results: Row[]; meta: Meta } {
    const statement = this.statement();
    if (statement.columns().length > 0) {
      const results = statement.all(...this.params) as Row[];
      return { results: results.map((row) => ({ ...row })), meta: meta(0, 0, results.length) };
    }
    const result = statement.run(...this.params);
    return { results: [], meta: meta(Number(result.changes), Number(result.lastInsertRowid)) };
  }

  async all() {
    return { success: true, ...this.execute() };
  }

  async run() {
    return { success: true, ...this.execute() };
  }

  async first(column?: string) {
    const row = this.execute().results[0];
    if (row === undefined) return null;
    if (column === undefined) return row;
    if (!(column in row)) throw new Error(`D1_COLUMN_NOTFOUND: Column not found (${column})`);
    return row[column];
  }

  async raw(options?: { columnNames?: boolean }) {
    const statement = this.statement();
    const rows = statement.all(...this.params) as Row[];
    const columns = statement.columns().map((column) => column.name);
    const values = rows.map((row) => columns.map((name) => row[name]));
    return options?.columnNames ? [columns, ...values] : values;
  }
}

export class SqliteD1 {
  readonly db: DatabaseSync;

  constructor(path: string) {
    this.db = new DatabaseSync(path);
    this.db.exec("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;");
  }

  prepare(sql: string): Statement {
    return new Statement(this.db, sql);
  }

  async batch(statements: Statement[]) {
    this.db.exec("BEGIN");
    try {
      const results = statements.map((statement) => ({ success: true, ...statement.execute() }));
      this.db.exec("COMMIT");
      return results;
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
  }

  async exec(sql: string) {
    this.db.exec(sql);
    return { count: 0, duration: 0 };
  }

  /** As a D1Database, for the Worker's routes. */
  asD1(): D1Database {
    return this as unknown as D1Database;
  }
}
