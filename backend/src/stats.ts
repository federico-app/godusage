import { badRequest } from "./http";
import { addDays, dayKey, isValidDay } from "./usagePayload";

export type RangeName = "today" | "7d" | "30d" | "365d";
export type SortMetric = "cost" | "tokens";

const RANGE_DAYS: Record<RangeName, number> = { today: 1, "7d": 7, "30d": 30, "365d": 365 };
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
}

export interface TeamStats {
  range: { name: RangeName; from: string; to: string; previousFrom: string; previousTo: string };
  sort: SortMetric;
  totals: Totals;
  members: MemberStats[];
  providers: (Totals & { provider: string })[];
  models: (Totals & { model: string; provider: string; members: (Totals & { userID: string })[] })[];
  daily: { day: string; members: (Totals & { userID: string })[]; providers: (Totals & { provider: string })[] }[];
}

/**
 * Reads `range`, `sort`, and `today` from the query string. `today` may differ from the UTC date
 * by at most one day (any real time zone); otherwise the UTC date is used.
 */
export function parseStatsQuery(url: URL, now: Date): StatsQuery {
  const range = url.searchParams.get("range") ?? "7d";
  if (!(range in RANGE_DAYS)) throw badRequest("range must be today, 7d, 30d, or 365d.");
  const sort = url.searchParams.get("sort") ?? "cost";
  if (sort !== "cost" && sort !== "tokens") throw badRequest("sort must be cost or tokens.");

  const utcToday = dayKey(now);
  let today = utcToday;
  const requested = url.searchParams.get("today");
  if (requested !== null) {
    if (!isValidDay(requested)) throw badRequest("today must be a YYYY-MM-DD date.");
    if (requested >= addDays(utcToday, -1) && requested <= addDays(utcToday, 1)) today = requested;
  }
  return { range: range as RangeName, sort, today };
}

/**
 * Account-scope rows (usage that is already account-wide, like Cursor) count once per user: the
 * newest device wins. Device-scope rows are summed across the user's Macs.
 */
const EFFECTIVE_DAYS = `
  WITH ranked AS (
    SELECT u.user_id, u.provider, u.day, u.scope, u.tokens, u.cost_usd,
      ROW_NUMBER() OVER (
        PARTITION BY u.user_id, u.provider, u.day, u.scope ORDER BY d.updated_at DESC, u.device_id
      ) AS rn
    FROM usage_days u JOIN devices d ON d.user_id = u.user_id AND d.id = u.device_id
    WHERE u.user_id IN (SELECT user_id FROM team_members WHERE team_id = ?1) AND u.day BETWEEN ?2 AND ?3
  )
  SELECT user_id, provider, day, SUM(tokens) AS tokens, COALESCE(SUM(cost_usd), 0) AS cost
  FROM ranked WHERE scope = 'device' OR rn = 1
  GROUP BY user_id, provider, day`;

const EFFECTIVE_MODELS = `
  WITH ranked AS (
    SELECT u.user_id, u.provider, u.model, u.scope, u.tokens, u.cost_usd,
      ROW_NUMBER() OVER (
        PARTITION BY u.user_id, u.provider, u.day, u.model, u.scope ORDER BY d.updated_at DESC, u.device_id
      ) AS rn
    FROM usage_model_days u JOIN devices d ON d.user_id = u.user_id AND d.id = u.device_id
    WHERE u.user_id IN (SELECT user_id FROM team_members WHERE team_id = ?1) AND u.day BETWEEN ?2 AND ?3
  )
  SELECT user_id, provider, model, SUM(tokens) AS tokens, COALESCE(SUM(cost_usd), 0) AS cost
  FROM ranked WHERE scope = 'device' OR rn = 1
  GROUP BY user_id, provider, model`;

export async function teamStats(db: D1Database, teamID: string, query: StatsQuery): Promise<TeamStats> {
  const to = query.today;
  const length = RANGE_DAYS[query.range];
  const from = addDays(to, -(length - 1));
  const previousTo = addDays(from, -1);
  const previousFrom = addDays(previousTo, -(length - 1));

  const [memberRows, dayRows, modelRows, previousRows] = await db.batch([
    db.prepare(
      `SELECT u.id, u.display_name FROM team_members m JOIN users u ON u.id = m.user_id
       WHERE m.team_id = ? ORDER BY m.joined_at, u.id`,
    ).bind(teamID),
    db.prepare(EFFECTIVE_DAYS).bind(teamID, from, to),
    db.prepare(EFFECTIVE_MODELS).bind(teamID, from, to),
    db.prepare(EFFECTIVE_DAYS).bind(teamID, previousFrom, previousTo),
  ]);
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
      };
    })
    .sort((a, b) => metric(b) - metric(a) || a.displayName.localeCompare(b.displayName));
  denseRank(ranked, metric);

  const modelGroups = new Map<string, { model: string; provider: string; totals: Totals; members: Map<string, Totals> }>();
  for (const row of models) {
    const key = `${row.provider}\u0000${row.model}`;
    let group = modelGroups.get(key);
    if (!group) {
      group = { model: row.model, provider: row.provider, totals: zero(), members: new Map() };
      modelGroups.set(key, group);
    }
    add(group.totals, row);
    add(entry(group.members, row.user_id), row);
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
  for (const value of memberTotals.values()) add(totals, { tokens: value.tokens, cost: value.costUSD });

  return {
    range: { name: query.range, from, to, previousFrom, previousTo },
    sort: query.sort,
    totals: round(totals),
    members: ranked,
    providers: sortedTotals(providerTotals, "provider", metric),
    models: topModels,
    daily,
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
