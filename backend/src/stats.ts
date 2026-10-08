import { badRequest } from "./http";
import { cachedTeamResult, type Cached, type ReadGuard } from "./readGuard";
import { teamUsage } from "./teamUsage";
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
 * How often a board may be recomputed, in minutes. Longer ranges read more rows, and today (the part
 * that moves) is a smaller share of them.
 */
const STATS_MIN_AGE_MINUTES: Record<RangeName, number> = { today: 5, "7d": 10, mtd: 10, "30d": 15, "365d": 60 };

/** The team's stats from the cache (see `readGuard.ts`). */
export function cachedTeamStats(guard: ReadGuard, teamID: string, query: StatsQuery): Promise<Cached<TeamStats>> {
  const minAge = STATS_MIN_AGE_MINUTES[query.range] * 60_000;
  return cachedTeamResult(guard, teamID, `stats|${query.range}|${query.sort}|${query.today}`, minAge, (db) => teamStats(db, teamID, query));
}

export async function teamStats(db: D1Database, teamID: string, query: StatsQuery): Promise<TeamStats> {
  const to = query.today;
  const { from, previousFrom, previousTo } = rangeBounds(query.range, to);
  // A year's movement arrows would read a second year of history: the Year range has none. An empty
  // range (from after to) reads no rows.
  const previous = query.range === "365d" ? ["9999-12-31", "0000-01-01"] : [previousFrom, previousTo];

  const [memberRows, usage, previousUsage] = await Promise.all([
    db.prepare(
      `SELECT u.id, u.display_name FROM team_members m JOIN users u ON u.id = m.user_id
       WHERE m.team_id = ? ORDER BY m.joined_at, u.id`,
    ).bind(teamID).all<{ id: string; display_name: string }>(),
    teamUsage(db, teamID, from, to, { models: true }),
    teamUsage(db, teamID, previous[0]!, previous[1]!, { models: false }),
  ]);
  const lastSync = new Map<string, { last_sync: string; app_version: string | null }>();
  for (const device of [...usage.devices].sort((a, b) => (a.updated_at === b.updated_at ? (a.id < b.id ? -1 : 1) : a.updated_at > b.updated_at ? -1 : 1))) {
    if (!lastSync.has(device.user_id)) lastSync.set(device.user_id, { last_sync: device.updated_at, app_version: device.app_version });
  }
  const { sharedDays, sharedModels, sharedMembers, days, models } = usage;
  const previousDays = previousUsage.days;
  const members = memberRows.results;

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
