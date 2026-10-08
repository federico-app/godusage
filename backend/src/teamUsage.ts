/**
 * A team's usage in a day range, combined the way every leaderboard counts it:
 *
 * - Device-scope rows (usage read from a Mac's own logs) are summed across a user's Macs.
 * - Account-scope rows (usage that is already account-wide, like Cursor) count once per user: the
 *   newest device wins, per day.
 * - A fingerprint (`account_key`) two or more members uploaded is a shared account: it belongs to no
 *   one member and counts once for the team, the newest upload from any member winning, per day.
 *
 * D1 bills every row a query reads, and its count includes each step SQLite takes: temporary sorts,
 * window functions, subqueries, table lookups. So the queries only read raw rows straight from the
 * covering indexes (one billed row per stored row), and the combining happens here.
 */

export interface MemberDay {
  user_id: string;
  provider: string;
  day: string;
  tokens: number;
  cost: number;
}

export interface MemberModel {
  user_id: string;
  provider: string;
  model: string;
  tokens: number;
  cost: number;
}

export interface SharedDay {
  account_key: string;
  provider: string;
  day: string;
  tokens: number;
  cost: number;
}

export interface SharedModel {
  account_key: string;
  provider: string;
  model: string;
  tokens: number;
  cost: number;
}

export interface TeamDevice {
  user_id: string;
  id: string;
  updated_at: string;
  app_version: string | null;
}

export interface TeamUsage {
  /** Each member's own usage per provider and day (shared accounts left out). */
  days: MemberDay[];
  /** Each member's own usage per provider and model over the range. Empty unless asked for. */
  models: MemberModel[];
  /** Shared accounts' usage per day. */
  sharedDays: SharedDay[];
  /** Shared accounts' usage per model over the range. Empty unless models were asked for. */
  sharedModels: SharedModel[];
  /** Who shares each shared account, ordered by account, provider, user. */
  sharedMembers: { account_key: string; provider: string; user_id: string }[];
  /** The members' Macs. */
  devices: TeamDevice[];
}

interface UsageRow {
  user_id: string;
  device_id: string;
  provider: string;
  day: string;
  scope: "device" | "account";
  account_key: string | null;
  tokens: number;
  cost_usd: number | null;
  model?: string;
}

const TEAM_USERS = "SELECT user_id FROM team_members WHERE team_id = ?1";

/**
 * Reads the team's usage from `from` to `to` (inclusive). An empty range (from after to) reads no
 * usage rows. `models` adds the per-model breakdown, which has several times more rows.
 */
export async function teamUsage(db: D1Database, teamID: string, from: string, to: string, options: { models: boolean }): Promise<TeamUsage> {
  // `scope IN (...)` lets both scopes seek the (user_id, scope, day) covering index by day.
  const statements = [
    db.prepare(`SELECT user_id, id, updated_at, app_version FROM devices WHERE user_id IN (${TEAM_USERS})`).bind(teamID),
    db.prepare(`SELECT user_id, account_key, provider FROM account_keys WHERE user_id IN (${TEAM_USERS})`).bind(teamID),
    db.prepare(
      `SELECT user_id, device_id, provider, day, scope, account_key, tokens, cost_usd FROM usage_days
       WHERE user_id IN (${TEAM_USERS}) AND scope IN ('device', 'account') AND day BETWEEN ?2 AND ?3`,
    ).bind(teamID, from, to),
  ];
  if (options.models) {
    statements.push(
      db.prepare(
        `SELECT user_id, device_id, provider, day, model, scope, account_key, tokens, cost_usd FROM usage_model_days
         WHERE user_id IN (${TEAM_USERS}) AND scope IN ('device', 'account') AND day BETWEEN ?2 AND ?3`,
      ).bind(teamID, from, to),
    );
  }
  const [deviceRows, keyRows, dayRows, modelRows] = await db.batch(statements);
  const devices = deviceRows!.results as unknown as TeamDevice[];
  const keys = keyRows!.results as { user_id: string; account_key: string; provider: string }[];

  const usersByKey = new Map<string, Set<string>>();
  for (const row of keys) {
    const users = usersByKey.get(row.account_key) ?? new Set<string>();
    users.add(row.user_id);
    usersByKey.set(row.account_key, users);
  }
  const sharedKeys = new Set([...usersByKey].filter(([, users]) => users.size > 1).map(([key]) => key));
  const sharedMembers = keys
    .filter((row) => sharedKeys.has(row.account_key))
    .map((row) => ({ account_key: row.account_key, provider: row.provider, user_id: row.user_id }))
    .sort((a, b) => compare(a.account_key, b.account_key) || compare(a.provider, b.provider) || compare(a.user_id, b.user_id));

  const updatedAt = new Map(devices.map((device) => [`${device.user_id}\u0000${device.id}`, device.updated_at]));
  const combined = combine(dayRows!.results as unknown as UsageRow[], sharedKeys, updatedAt, false);
  const days = [...combined.members.values()].map((value) => ({ user_id: value.user, provider: value.provider, day: value.day, tokens: value.tokens, cost: value.cost }));
  const sharedDays = [...combined.shared.values()].map((value) => ({ account_key: value.key, provider: value.provider, day: value.day, tokens: value.tokens, cost: value.cost }));

  let models: MemberModel[] = [];
  let sharedModels: SharedModel[] = [];
  if (modelRows) {
    const byModel = combine(modelRows.results as unknown as UsageRow[], sharedKeys, updatedAt, true);
    models = [...byModel.members.values()].map((value) => ({ user_id: value.user, provider: value.provider, model: value.model, tokens: value.tokens, cost: value.cost }));
    sharedModels = [...byModel.shared.values()].map((value) => ({ account_key: value.key, provider: value.provider, model: value.model, tokens: value.tokens, cost: value.cost }));
  }
  return { days, models, sharedDays, sharedModels, sharedMembers, devices };
}

interface Total {
  user: string;
  key: string;
  provider: string;
  day: string;
  model: string;
  tokens: number;
  cost: number;
}

/**
 * Picks the winning account-scope row per day, then sums. With `byModel`, rows are per model and
 * the totals are per model over the whole range (not per day).
 */
function combine(rows: UsageRow[], sharedKeys: Set<string>, updatedAt: Map<string, string>, byModel: boolean) {
  const members = new Map<string, Total>();
  const shared = new Map<string, Total>();
  // The winning account-scope row for each (user or shared account, provider, day[, model]).
  const winners = new Map<string, { row: UsageRow; updatedAt: string; shared: boolean }>();
  const model = (row: UsageRow) => (byModel ? row.model! : "");

  for (const row of rows) {
    if (row.scope === "device") {
      addTo(members, [row.user_id, row.provider, byModel ? model(row) : row.day], row, { user: row.user_id, key: "", day: row.day, model: model(row) });
      continue;
    }
    const isShared = row.account_key !== null && sharedKeys.has(row.account_key);
    // Shared accounts: the newest upload from any member (then user id, device id). Otherwise per user.
    const owner = isShared ? `s\u0000${row.account_key}` : `u\u0000${row.user_id}`;
    const slot = [owner, row.provider, row.day, model(row)].join("\u0000");
    const rowUpdatedAt = updatedAt.get(`${row.user_id}\u0000${row.device_id}`) ?? "";
    const current = winners.get(slot);
    if (!current || newer(row, rowUpdatedAt, current.row, current.updatedAt, isShared)) {
      winners.set(slot, { row, updatedAt: rowUpdatedAt, shared: isShared });
    }
  }
  for (const { row, shared: isShared } of winners.values()) {
    const bucket = byModel ? model(row) : row.day;
    if (isShared) addTo(shared, [row.account_key!, row.provider, bucket], row, { user: "", key: row.account_key!, day: row.day, model: model(row) });
    else addTo(members, [row.user_id, row.provider, bucket], row, { user: row.user_id, key: "", day: row.day, model: model(row) });
  }
  return { members, shared };
}

function newer(row: UsageRow, rowUpdatedAt: string, current: UsageRow, currentUpdatedAt: string, shared: boolean): boolean {
  if (rowUpdatedAt !== currentUpdatedAt) return rowUpdatedAt > currentUpdatedAt;
  if (shared && row.user_id !== current.user_id) return row.user_id < current.user_id;
  return row.device_id < current.device_id;
}

function addTo(map: Map<string, Total>, keyParts: string[], row: UsageRow, base: { user: string; key: string; day: string; model: string }): void {
  const key = keyParts.join("\u0000");
  let total = map.get(key);
  if (!total) {
    total = { ...base, provider: row.provider, tokens: 0, cost: 0 };
    map.set(key, total);
  }
  total.tokens += row.tokens;
  total.cost += row.cost_usd ?? 0;
}

/** SQLite's BINARY collation: byte order, which matches UTF-16 order for the ids and names stored. */
function compare(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}
