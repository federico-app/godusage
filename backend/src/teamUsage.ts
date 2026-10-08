/**
 * A team's usage in a day range, combined the way every leaderboard counts it:
 *
 * - Device-scope rows (usage read from a Mac's own logs) are summed across a user's Macs.
 * - Account-scope rows (usage that is already account-wide, like Cursor) count once per user: the
 *   newest device wins, per day.
 * - A fingerprint (`account_key`) two or more members uploaded is a shared account: it belongs to no
 *   one member and counts once for the team, the newest upload from any member winning, per day.
 *
 * The queries read raw rows of the period (from the (user_id, day) covering indexes), and the combining
 * happens here, where the rules above are easy to read and test.
 */
import type { Queryable } from "./db";

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

/**
 * Reads the team's usage from `from` to `to` (inclusive). An empty range (from after to) reads no
 * usage rows. `models` adds the per-model breakdown, which has several times more rows.
 */
export async function teamUsage(db: Queryable, teamID: string, from: string, to: string, options: { models: boolean }): Promise<TeamUsage> {
  const members = "JOIN team_members m ON m.user_id = t.user_id AND m.team_id = $1";
  const [deviceRows, keyRows, dayRows, modelRows] = await Promise.all([
    db.query(`SELECT t.user_id, t.id, t.updated_at, t.app_version FROM devices t ${members}`, [teamID]),
    db.query(`SELECT t.user_id, t.account_key, t.provider FROM account_keys t ${members}`, [teamID]),
    db.query(
      `SELECT t.user_id, t.device_id, t.provider, t.day, t.scope, t.account_key, t.tokens, t.cost_usd FROM usage_days t ${members}
       WHERE t.day BETWEEN $2 AND $3`,
      [teamID, from, to],
    ),
    options.models
      ? db.query(
          `SELECT t.user_id, t.device_id, t.provider, t.day, t.model, t.scope, t.account_key, t.tokens, t.cost_usd FROM usage_model_days t ${members}
           WHERE t.day BETWEEN $2 AND $3`,
          [teamID, from, to],
        )
      : null,
  ]);
  const devices = deviceRows as unknown as TeamDevice[];
  const keys = keyRows as { user_id: string; account_key: string; provider: string }[];

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
  const combined = combine(dayRows as unknown as UsageRow[], sharedKeys, updatedAt, false);
  const days = [...combined.members.values()].map((value) => ({ user_id: value.user, provider: value.provider, day: value.day, tokens: value.tokens, cost: value.cost }));
  const sharedDays = [...combined.shared.values()].map((value) => ({ account_key: value.key, provider: value.provider, day: value.day, tokens: value.tokens, cost: value.cost }));

  let models: MemberModel[] = [];
  let sharedModels: SharedModel[] = [];
  if (modelRows) {
    const byModel = combine(modelRows as unknown as UsageRow[], sharedKeys, updatedAt, true);
    models = [...byModel.members.values()].map((value) => ({ user_id: value.user, provider: value.provider, model: value.model, tokens: value.tokens, cost: value.cost }));
    sharedModels = [...byModel.shared.values()].map((value) => ({ account_key: value.key, provider: value.provider, model: value.model, tokens: value.tokens, cost: value.cost }));
  }
  return { days, models, sharedDays, sharedModels, sharedMembers, devices };
}

/**
 * One user's own usage per provider and day from `from` to `to`, across all of their Macs: the same
 * rules as a team board (Macs summed, account-scope rows from the newest Mac), with every account
 * counted as theirs, shared or not.
 */
export async function userUsage(db: Queryable, userID: string, from: string, to: string): Promise<{ days: MemberDay[]; devices: TeamDevice[] }> {
  const [deviceRows, dayRows] = await Promise.all([
    db.query("SELECT user_id, id, updated_at, app_version FROM devices WHERE user_id = $1", [userID]),
    db.query(
      `SELECT user_id, device_id, provider, day, scope, account_key, tokens, cost_usd FROM usage_days
       WHERE user_id = $1 AND day BETWEEN $2 AND $3`,
      [userID, from, to],
    ),
  ]);
  const devices = deviceRows as unknown as TeamDevice[];
  const updatedAt = new Map(devices.map((device) => [`${device.user_id}\u0000${device.id}`, device.updated_at]));
  const combined = combine(dayRows as unknown as UsageRow[], new Set(), updatedAt, false);
  const days = [...combined.members.values()].map((value) => ({ user_id: value.user, provider: value.provider, day: value.day, tokens: value.tokens, cost: value.cost }));
  return { days, devices };
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

/** Code-unit order, so the result never depends on the database's collation. */
function compare(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}
