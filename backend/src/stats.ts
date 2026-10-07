import { badRequest } from "./http";
import { addDays, dayKey, isValidDay } from "./usagePayload";

export type RangeName = "today" | "7d" | "30d" | "365d" | "mtd";
export type SortMetric = "cost" | "tokens";

/** Fixed-length ranges. "mtd" (the calendar month so far) is computed from `today`. */
const RANGE_DAYS: Record<Exclude<RangeName, "mtd">, number> = { today: 1, "7d": 7, "30d": 30, "365d": 365 };
const RANGE_NAMES = new Set<string>([...Object.keys(RANGE_DAYS), "mtd"]);

/** The period's days and the period just before it (for "mtd": the same days of the previous month). */
export function rangeBounds(range: RangeName, today: string): { from: string; to: string; previousFrom: string; previousTo: string } {
  if (range === "mtd") {
    const from = `${today.slice(0, 7)}-01`;
    const elapsed = daysBetween(from, today) + 1;
    const previousFrom = `${addDays(from, -1).slice(0, 7)}-01`;
    const lastOfPrevious = addDays(from, -1);
    const sameDay = addDays(previousFrom, elapsed - 1);
    return { from, to: today, previousFrom, previousTo: sameDay < lastOfPrevious ? sameDay : lastOfPrevious };
  }
  const length = RANGE_DAYS[range];
  const from = addDays(today, -(length - 1));
  const previousTo = addDays(from, -1);
  return { from, to: today, previousFrom: addDays(previousTo, -(length - 1)), previousTo };
}

export function daysBetween(from: string, to: string): number {
  return Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000);
}
const TOP_MODELS = 20;

export interface StatsQuery {
  range: RangeName;
  sort: SortMetric;
  /** The viewer's local calendar day. Day keys come from each Mac's local calendar. */
  today: string;
}

interface Totals {
  tokens: number;
  costUSD: number;
}

export interface MemberStats extends Totals {
  userID: string;
  displayName: string;
  rank: number;
  providers: (Totals & { provider: string })[];
  /** The same member in the period just before this one, or null if they had no usage then. */
  previous: (Totals & { rank: number }) | null;
  /** When any of the member's Macs last uploaded (ISO 8601), or null if none has. */
  lastSyncAt: string | null;
  /** The GodUsage version of that latest upload, or null if it came from an app before 1.0.8. */
  appVersion: string | null;
}

export interface TeamStats {
  range: { name: RangeName; from: string; to: string; previousFrom: string; previousTo: string };
  sort: SortMetric;
  totals: Totals;
  members: MemberStats[];
  providers: (Totals & { provider: string })[];
  models: (Totals & { model: string; provider: string; members: (Totals & { userID: string })[] })[];
  daily: { day: string; members: (Totals & { userID: string })[]; providers: (Totals & { provider: string })[] }[];
  /**
   * Accounts several members log into (one shared Cursor seat). Counted once in the team's totals,
   * providers, days, and models, and in no member's: they are not split per person.
   */
  shared: (Totals & { provider: string; members: string[] })[];
}

/**
 * Reads `range`, `sort`, and `today` from the query string. `today` is the period's last day: up to
 * one day ahead of the UTC date (any real time zone) and up to 400 days back (last week's recap, a
 * past month or year). Anything else falls back to the UTC date.
 */
export function parseStatsQuery(url: URL, now: Date): StatsQuery {
  const range = url.searchParams.get("range") ?? "7d";
  if (!RANGE_NAMES.has(range)) throw badRequest("range must be today, 7d, 30d, 365d, or mtd.");
  const sort = url.searchParams.get("sort") ?? "cost";
  if (sort !== "cost" && sort !== "tokens") throw badRequest("sort must be cost or tokens.");

  const utcToday = dayKey(now);
  let today = utcToday;
  const requested = url.searchParams.get("today");
  if (requested !== null) {
    if (!isValidDay(requested)) throw badRequest("today must be a YYYY-MM-DD date.");
    if (requested >= addDays(utcToday, -400) && requested <= addDays(utcToday, 1)) today = requested;
  }
  return { range: range as RangeName, sort, today };
}

/**
 * Fingerprints (see `usage_days.account_key`) that two or more of the team's members uploaded: one
 * provider account several people log into. Defined over everything stored, so an account stays
 * shared in a period only one of them used it. Read from `account_keys`, never from the usage
 * history: this runs in every stats query. Expects the team id as ?1.
 */
const SHARED_KEYS = `
  team_users AS (SELECT user_id FROM team_members WHERE team_id = ?1),
  shared_keys AS (
    SELECT account_key FROM account_keys
    WHERE user_id IN (SELECT user_id FROM team_users)
    GROUP BY account_key HAVING COUNT(DISTINCT user_id) > 1
  )`;

/**
 * Each member's own usage. Account-scope rows (usage that is already account-wide, like Cursor)
 * count once per user: the newest device wins. Device-scope rows are summed across the user's Macs.
 * Shared accounts are left out: they belong to no one member (see `SHARED_DAYS`).
 */
export const EFFECTIVE_DAYS = `
  WITH ${SHARED_KEYS},
  ranked AS (
    SELECT u.user_id, u.provider, u.day, u.scope, u.tokens, u.cost_usd,
      ROW_NUMBER() OVER (
        PARTITION BY u.user_id, u.provider, u.day, u.scope ORDER BY d.updated_at DESC, u.device_id
      ) AS rn
    FROM usage_days u JOIN devices d ON d.user_id = u.user_id AND d.id = u.device_id
    WHERE u.user_id IN (SELECT user_id FROM team_users) AND u.day BETWEEN ?2 AND ?3
      AND (u.account_key IS NULL OR u.account_key NOT IN (SELECT account_key FROM shared_keys))
  )
  SELECT user_id, provider, day, SUM(tokens) AS tokens, COALESCE(SUM(cost_usd), 0) AS cost
  FROM ranked WHERE scope = 'device' OR rn = 1
  GROUP BY user_id, provider, day`;

export const EFFECTIVE_MODELS = `
  WITH ${SHARED_KEYS},
  ranked AS (
    SELECT u.user_id, u.provider, u.model, u.scope, u.tokens, u.cost_usd,
      ROW_NUMBER() OVER (
        PARTITION BY u.user_id, u.provider, u.day, u.model, u.scope ORDER BY d.updated_at DESC, u.device_id
      ) AS rn
    FROM usage_model_days u JOIN devices d ON d.user_id = u.user_id AND d.id = u.device_id
    WHERE u.user_id IN (SELECT user_id FROM team_users) AND u.day BETWEEN ?2 AND ?3
      AND (u.account_key IS NULL OR u.account_key NOT IN (SELECT account_key FROM shared_keys))
  )
  SELECT user_id, provider, model, SUM(tokens) AS tokens, COALESCE(SUM(cost_usd), 0) AS cost
  FROM ranked WHERE scope = 'device' OR rn = 1
  GROUP BY user_id, provider, model`;

/** Shared accounts' usage, once per account and day: the newest upload from any member wins. */
export const SHARED_DAYS = `
  WITH ${SHARED_KEYS},
  ranked AS (
    SELECT u.account_key, u.provider, u.day, u.tokens, u.cost_usd,
      ROW_NUMBER() OVER (
        PARTITION BY u.account_key, u.provider, u.day ORDER BY d.updated_at DESC, u.user_id, u.device_id
      ) AS rn
    FROM usage_days u JOIN devices d ON d.user_id = u.user_id AND d.id = u.device_id
    WHERE u.user_id IN (SELECT user_id FROM team_users) AND u.day BETWEEN ?2 AND ?3
      AND u.account_key IN (SELECT account_key FROM shared_keys)
  )
  SELECT account_key, provider, day, tokens, COALESCE(cost_usd, 0) AS cost FROM ranked WHERE rn = 1`;

export const SHARED_MODELS = `
  WITH ${SHARED_KEYS},
  ranked AS (
    SELECT u.account_key, u.provider, u.model, u.tokens, u.cost_usd,
      ROW_NUMBER() OVER (
        PARTITION BY u.account_key, u.provider, u.day, u.model ORDER BY d.updated_at DESC, u.user_id, u.device_id
      ) AS rn
    FROM usage_model_days u JOIN devices d ON d.user_id = u.user_id AND d.id = u.device_id
    WHERE u.user_id IN (SELECT user_id FROM team_users) AND u.day BETWEEN ?2 AND ?3
      AND u.account_key IN (SELECT account_key FROM shared_keys)
  )
  SELECT account_key, provider, model, SUM(tokens) AS tokens, COALESCE(SUM(cost_usd), 0) AS cost
  FROM ranked WHERE rn = 1 GROUP BY account_key, provider, model`;

/** Who shares each shared account. */
const SHARED_MEMBERS = `
  WITH ${SHARED_KEYS}
  SELECT account_key, provider, user_id FROM account_keys
  WHERE user_id IN (SELECT user_id FROM team_users) AND account_key IN (SELECT account_key FROM shared_keys)
  ORDER BY account_key, provider, user_id`;

export async function teamStats(db: D1Database, teamID: string, query: StatsQuery): Promise<TeamStats> {
  const to = query.today;
  const { from, previousFrom, previousTo } = rangeBounds(query.range, to);

  const [memberRows, dayRows, modelRows, previousRows, sharedDayRows, sharedModelRows, sharedMemberRows, syncRows] = await db.batch([
    db.prepare(
      `SELECT u.id, u.display_name FROM team_members m JOIN users u ON u.id = m.user_id
       WHERE m.team_id = ? ORDER BY m.joined_at, u.id`,
    ).bind(teamID),
    db.prepare(EFFECTIVE_DAYS).bind(teamID, from, to),
    db.prepare(EFFECTIVE_MODELS).bind(teamID, from, to),
    db.prepare(EFFECTIVE_DAYS).bind(teamID, previousFrom, previousTo),
    db.prepare(SHARED_DAYS).bind(teamID, from, to),
    db.prepare(SHARED_MODELS).bind(teamID, from, to),
    db.prepare(SHARED_MEMBERS).bind(teamID),
    db.prepare(
      `SELECT user_id, updated_at AS last_sync, app_version FROM (
         SELECT user_id, updated_at, app_version,
           ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY updated_at DESC, id) AS rn
         FROM devices WHERE user_id IN (SELECT user_id FROM team_members WHERE team_id = ?)
       ) WHERE rn = 1`,
    ).bind(teamID),
  ]);
  const lastSync = new Map(
    (syncRows!.results as { user_id: string; last_sync: string; app_version: string | null }[]).map((row) => [row.user_id, row]),
  );
  const sharedDays = sharedDayRows!.results as { account_key: string; provider: string; day: string; tokens: number; cost: number }[];
  const sharedModels = sharedModelRows!.results as { account_key: string; provider: string; model: string; tokens: number; cost: number }[];
  const sharedMembers = sharedMemberRows!.results as { account_key: string; provider: string; user_id: string }[];
  const previousDays = previousRows!.results as { user_id: string; tokens: number; cost: number }[];
  const members = (memberRows!.results as { id: string; display_name: string }[]);
  const days = dayRows!.results as { user_id: string; provider: string; day: string; tokens: number; cost: number }[];
  const models = modelRows!.results as { user_id: string; provider: string; model: string; tokens: number; cost: number }[];

  const memberTotals = new Map<string, Totals>();
  const memberProviders = new Map<string, Map<string, Totals>>();
  const providerTotals = new Map<string, Totals>();
  const dailyTotals = new Map<string, Map<string, Totals>>();
  const dailyProviders = new Map<string, Map<string, Totals>>();
  for (const row of days) {
    add(entry(nested(dailyProviders, row.day), row.provider), row);
    add(entry(memberTotals, row.user_id), row);
    add(entry(nested(memberProviders, row.user_id), row.provider), row);
    add(entry(providerTotals, row.provider), row);
    add(entry(nested(dailyTotals, row.day), row.user_id), row);
  }
  const sharedTotals = new Map<string, Totals & { provider: string; members: string[] }>();
  for (const row of sharedMembers) {
    const key = `${row.account_key}\u0000${row.provider}`;
    const account = sharedTotals.get(key) ?? { provider: row.provider, members: [], ...zero() };
    account.members.push(row.user_id);
    sharedTotals.set(key, account);
  }
  for (const row of sharedDays) {
    add(entry(nested(dailyProviders, row.day), row.provider), row);
    add(entry(providerTotals, row.provider), row);
    const account = sharedTotals.get(`${row.account_key}\u0000${row.provider}`);
    if (account) add(account, row);
  }

  const metric = (totals: Totals) => (query.sort === "cost" ? totals.costUSD : totals.tokens);

  // Ranks in the previous period, among today's members, for the ▲▼ movement next to each name.
  const previousTotals = new Map<string, Totals>();
  for (const row of previousDays) add(entry(previousTotals, row.user_id), row);
  const previousRanked = members
    .map((member) => ({ userID: member.id, name: member.display_name, rank: 0, ...round(previousTotals.get(member.id) ?? zero()) }))
    .sort((a, b) => metric(b) - metric(a) || a.name.localeCompare(b.name));
  denseRank(previousRanked, metric);
  const previousByUser = new Map(previousRanked.map((member) => [member.userID, member]));

  const ranked = members
    .map((member) => {
      const totals = memberTotals.get(member.id) ?? zero();
      return {
        userID: member.id,
        displayName: member.display_name,
        rank: 0,
        ...round(totals),
        providers: sortedTotals(memberProviders.get(member.id), "provider", metric),
        previous: previousSnapshot(previousByUser.get(member.id)),
        lastSyncAt: lastSync.get(member.id)?.last_sync ?? null,
        appVersion: lastSync.get(member.id)?.app_version ?? null,
      };
    })
    .sort((a, b) => metric(b) - metric(a) || a.displayName.localeCompare(b.displayName));
  denseRank(ranked, metric);

  const modelGroups = new Map<string, { model: string; provider: string; totals: Totals; members: Map<string, Totals> }>();
  for (const row of [...models, ...sharedModels]) {
    const key = `${row.provider}\u0000${row.model}`;
    let group = modelGroups.get(key);
    if (!group) {
      group = { model: row.model, provider: row.provider, totals: zero(), members: new Map() };
      modelGroups.set(key, group);
    }
    add(group.totals, row);
    if ("user_id" in row) add(entry(group.members, row.user_id), row);
  }
  const topModels = [...modelGroups.values()]
    .sort((a, b) => metric(b.totals) - metric(a.totals) || a.model.localeCompare(b.model))
    .slice(0, TOP_MODELS)
    .map((group) => ({
      model: group.model,
      provider: group.provider,
      ...round(group.totals),
      members: sortedTotals(group.members, "userID", metric),
    }));

  const daily: TeamStats["daily"] = [];
  for (let day = from; day <= to; day = addDays(day, 1)) {
    daily.push({
      day,
      members: sortedTotals(dailyTotals.get(day), "userID", metric),
      providers: sortedTotals(dailyProviders.get(day), "provider", metric),
    });
  }

  const totals = zero();
  for (const value of [...memberTotals.values(), ...sharedTotals.values()]) add(totals, { tokens: value.tokens, cost: value.costUSD });
  const shared = [...sharedTotals.values()]
    .filter((account) => account.tokens > 0 || account.costUSD > 0)
    .map((account) => ({ provider: account.provider, ...round(account), members: account.members }))
    .sort((a, b) => metric(b) - metric(a) || a.provider.localeCompare(b.provider));

  return {
    range: { name: query.range, from, to, previousFrom, previousTo },
    sort: query.sort,
    totals: round(totals),
    members: ranked,
    providers: sortedTotals(providerTotals, "provider", metric),
    models: topModels,
    daily,
    shared,
  };
}

/** Dense ranking: members with the same value share a rank. */
function denseRank<T extends Totals & { rank: number }>(list: T[], metric: (totals: Totals) => number): void {
  list.forEach((member, index) => {
    const previous = list[index - 1];
    member.rank = previous && metric(previous) === metric(member) ? previous.rank : (previous?.rank ?? 0) + 1;
  });
}

function previousSnapshot(member: (Totals & { rank: number }) | undefined): (Totals & { rank: number }) | null {
  if (!member || (member.tokens === 0 && member.costUSD === 0)) return null;
  return { rank: member.rank, tokens: member.tokens, costUSD: member.costUSD };
}

function zero(): Totals {
  return { tokens: 0, costUSD: 0 };
}

function add(target: Totals, row: { tokens: number; cost: number }): void {
  target.tokens += row.tokens;
  target.costUSD += row.cost;
}

function entry<K>(map: Map<K, Totals>, key: K): Totals {
  let value = map.get(key);
  if (!value) {
    value = zero();
    map.set(key, value);
  }
  return value;
}

function nested<K, V>(map: Map<K, Map<string, V>>, key: K): Map<string, V> {
  let value = map.get(key);
  if (!value) {
    value = new Map();
    map.set(key, value);
  }
  return value;
}

function round(totals: Totals): Totals {
  return { tokens: totals.tokens, costUSD: Math.round(totals.costUSD * 10_000) / 10_000 };
}

function sortedTotals<F extends string>(
  map: Map<string, Totals> | undefined,
  field: F,
  metric: (totals: Totals) => number,
): (Totals & Record<F, string>)[] {
  return [...(map ?? new Map<string, Totals>()).entries()]
    .map(([key, totals]) => ({ [field]: key, ...round(totals) }) as Totals & Record<F, string>)
    .sort((a, b) => metric(b) - metric(a) || a[field].localeCompare(b[field]));
}
