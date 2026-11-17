import { badRequest, isRecord } from "./http";
import type { QuotaRow } from "./quota";
import { isValidDay } from "./usagePayload";

const HOUR_MS = 3_600_000;
/** At most this many claimed resets per window in an upload. */
const MAX_CLAIMS = 20;
/** Two Macs' claims whose times come this close (or overlap) are the same claim. */
export const SAME_CLAIM_SLACK_MS = 15 * 60_000;
/**
 * Ends this close name the same window: ends are rounded to the hour, and Codex counts a reset from
 * the reading, so two Macs can name one window an hour apart.
 */
const SAME_WINDOW_MS = HOUR_MS;

/**
 * A claimed limit reset as one Mac saw it (see the app's TeamQuotaLog). Claude keeps the window's
 * reset time when a reset is claimed, so the same window gets another 100% of the limit. `after` is
 * the Mac's last reading before the claim and `at` the claim itself (a claim GodUsage made: both its
 * time) or the first reading after the drop (a claim made elsewhere and inferred from it).
 */
export interface QuotaClaim {
  at: string;
  after: string;
  /** The highest share seen used before the claim. */
  percent: number;
  /** The Mac's local day of `at`. */
  day: string;
  /** GodUsage made the claim; otherwise it was inferred from a drop in the share used. */
  recorded: boolean;
}

/** Validates a window's claims (the system boundary). Missing: an app from before claims, null. */
export function parseClaims(value: unknown): QuotaClaim[] | null {
  if (value === undefined || value === null) return null;
  if (!Array.isArray(value) || value.length > MAX_CLAIMS) throw badRequest(`claims must be a list of at most ${MAX_CLAIMS}.`);
  return value.map((entry) => {
    if (!isRecord(entry)) throw badRequest("Each claim must be an object.");
    const at = instant(entry.at, "A claim's at");
    const after = instant(entry.after ?? entry.at, "A claim's after");
    if (typeof entry.percent !== "number" || !Number.isFinite(entry.percent) || entry.percent < 0 || entry.percent > 1000) {
      throw badRequest("A claim's percent must be a number from 0.");
    }
    if (typeof entry.day !== "string" || !isValidDay(entry.day)) throw badRequest("A claim's day must be YYYY-MM-DD.");
    if (entry.recorded !== undefined && typeof entry.recorded !== "boolean") throw badRequest("A claim's recorded must be true or false.");
    return {
      at: new Date(at).toISOString(),
      after: new Date(Math.min(after, at)).toISOString(),
      percent: entry.percent,
      day: entry.day,
      recorded: entry.recorded === true,
    };
  });
}

function instant(value: unknown, field: string): number {
  const time = typeof value === "string" && value.length <= 40 ? Date.parse(value) : Number.NaN;
  if (Number.isNaN(time)) throw badRequest(`${field} must be an ISO 8601 date and time.`);
  return time;
}

/** A claimed reset as every Mac's reports of it agree. */
export interface Claim {
  at: number;
  after: number;
  /** The highest share any Mac saw used before it. */
  percent: number;
  day: string;
  recorded: boolean;
}

/**
 * One account's limit window, merged across the Macs that read it. Shares are in points of the limit
 * (100 = one full limit). `used` counts every segment between claimed resets, so a week with one claim
 * can reach 200 of a `capacity` of 200.
 */
export interface MergedWindow {
  account: string;
  startsAt: number;
  endsAt: number;
  periodMs: number;
  /** The raw `ends_at` of the rows merged here: readings name their window by one of them. */
  keys: Set<string>;
  rows: QuotaRow[];
  /** The claimed resets in the window, oldest first. */
  claims: Claim[];
  /** The share used in each stretch between claims, the peak before each claim then the use since the last. */
  segments: number[];
  /** Used in all: the sum of the segments (at least what an app from before claims saw). */
  used: number;
  /** 100 per limit: 100 plus 100 per claim. */
  capacity: number;
  /** The latest reading of any Mac. */
  observedAt: number;
  /** The share used so far at the end of each day, all segments counted, the highest any Mac saw. */
  days: Map<string, number>;
  /** Some member who reported it is covered. */
  covered: boolean;
  /** One Mac's reading of the share used so far (`device` is user|device), with the claims it missed added. */
  correct(device: string, at: number, value: number): number;
}

export const deviceKey = (row: Pick<QuotaRow, "user_id" | "device_id">) => `${row.user_id}|${row.device_id}`;

interface Cluster extends Claim {
  /** Each Mac that saw this claim, with the share it saw used before it. */
  members: Map<string, number>;
}

/**
 * Merges one window's rows. Each Mac's claims are matched by time (a claim GodUsage made is exact; an
 * inferred one spans the gap between two readings), each Mac's own share after its last claim goes
 * into the stretch its last reading falls in, and every stretch counts at the highest share any Mac saw
 * in it. Rows from apps before claims (`claims` null) know no claims: they only set a floor.
 */
export function mergeRows(rows: QuotaRow[]): Pick<MergedWindow, "claims" | "segments" | "used" | "capacity" | "days" | "correct"> {
  const entries = rows.flatMap((row) =>
    (row.claims ?? []).map((claim) => ({
      device: deviceKey(row), at: Date.parse(claim.at), after: Date.parse(claim.after), percent: claim.percent, day: claim.day, recorded: claim.recorded,
    })));
  // The most precise claims first, so a wide inferred one joins the claim it spans rather than seeding its own.
  entries.sort((a, b) => a.at - a.after - (b.at - b.after) || a.at - b.at);
  const clusters: Cluster[] = [];
  for (const entry of entries) {
    const cluster = clusters.find((candidate) =>
      !candidate.members.has(entry.device)
      && entry.after - SAME_CLAIM_SLACK_MS <= candidate.at && candidate.after - SAME_CLAIM_SLACK_MS <= entry.at);
    if (!cluster) {
      clusters.push({ at: entry.at, after: entry.after, percent: entry.percent, day: entry.day, recorded: entry.recorded, members: new Map([[entry.device, entry.percent]]) });
      continue;
    }
    const after = Math.max(cluster.after, entry.after);
    const at = Math.min(cluster.at, entry.at);
    if (after <= at) {
      cluster.after = after;
      cluster.at = at;
    }
    if (entry.recorded && !cluster.recorded) cluster.day = entry.day;
    cluster.recorded = cluster.recorded || entry.recorded;
    cluster.percent = Math.max(cluster.percent, entry.percent);
    cluster.members.set(entry.device, entry.percent);
  }
  clusters.sort((a, b) => a.at - b.at);

  const segments = Array.from({ length: clusters.length + 1 }, (_, index) => clusters[index]?.percent ?? 0);
  const stretch = (time: number) => clusters.filter((claim) => claim.at <= time).length;
  let floor = 0;
  for (const row of rows) {
    const observedAt = Date.parse(row.observed_at);
    if (row.claims === null) {
      // An app from before claims reports the highest share it saw in the whole window.
      if (clusters.length === 0 || observedAt < clusters[0]!.at) segments[0] = Math.max(segments[0]!, row.percent);
      else floor = Math.max(floor, row.percent);
      continue;
    }
    const device = deviceKey(row);
    const known = clusters.reduce((last, claim, index) => (claim.members.has(device) ? index + 1 : last), 0);
    const index = Math.max(stretch(observedAt), known);
    segments[index] = Math.max(segments[index]!, row.percent);
  }

  const aware = new Set(rows.filter((row) => row.claims !== null).map(deviceKey));
  const missed = (claim: Cluster, device: string) => claim.percent - (claim.members.get(device) ?? 0);
  const correct = (device: string, at: number, value: number) => {
    if (!aware.has(device)) return value;
    return clusters.reduce((total, claim) => (claim.at <= at ? total + missed(claim, device) : total), value);
  };
  const days = new Map<string, number>();
  for (const row of rows) {
    const device = deviceKey(row);
    for (const reading of row.days ?? []) {
      let value = reading.percent;
      if (aware.has(device)) {
        for (const claim of clusters) {
          // A day's reading of a claim's own day may come from before it, unless the Mac saw the claim.
          if (claim.day < reading.day || (claim.day === reading.day && claim.members.has(device))) value += missed(claim, device);
        }
      }
      days.set(reading.day, Math.max(days.get(reading.day) ?? 0, value));
    }
  }
  const used = Math.max(segments.reduce((sum, value) => sum + value, 0), floor);
  return {
    claims: clusters.map(({ members: _members, ...claim }) => claim),
    segments,
    used,
    capacity: 100 * (clusters.length + 1),
    days,
    correct,
  };
}

/**
 * The covered accounts' limit windows of `provider` (only weekly ones with `weekly`), merged across
 * Macs, each account's oldest first. Windows whose ends come within an hour are one window. A window
 * that starts well before an earlier one ends means that one reset early (Codex starts a new week when
 * a reset is claimed), so the earlier one ends where the new one starts, even when the Mac that read it
 * never saw the new one. Each window starts no earlier than the account's previous one ends.
 */
export function accountWindows(
  rows: QuotaRow[], plan: { provider: string; covered: (userID: string) => boolean }, options: { weekly?: boolean } = {},
): Map<string, MergedWindow[]> {
  const groups = new Map<string, QuotaRow[]>();
  for (const row of rows) {
    if (row.provider !== plan.provider || row.kind !== "limit" || (options.weekly && row.period_hours !== 168)) continue;
    const key = `${row.account_key}|${row.period_hours}`;
    groups.set(key, [...(groups.get(key) ?? []), row]);
  }
  const accounts = new Map<string, MergedWindow[]>();
  for (const group of groups.values()) {
    const periodMs = group[0]!.period_hours * HOUR_MS;
    const ends = [...new Set(group.map((row) => Date.parse(row.ends_at)))].sort((a, b) => a - b);
    // A stale copy: no Mac read it after a later window started inside it. (A Mac that saw the new
    // window already ended its copy there, and its end then names no real start, so only the reading
    // times tell a stale copy from it.)
    const lastRead = (end: number) => Math.max(...group.filter((row) => Date.parse(row.ends_at) === end).map((row) => Date.parse(row.observed_at)));
    const effective = new Map(ends.map((end) => {
      const cut = ends
        .filter((later) => later > end + SAME_WINDOW_MS && later - periodMs < end - SAME_WINDOW_MS && lastRead(end) <= later - periodMs + SAME_WINDOW_MS)
        .map((later) => later - periodMs);
      return [end, cut.length === 0 ? end : Math.max(Math.min(...cut), end - periodMs + HOUR_MS)];
    }));
    const sorted = [...group].sort((a, b) => effective.get(Date.parse(a.ends_at))! - effective.get(Date.parse(b.ends_at))!);
    const clusters: QuotaRow[][] = [];
    for (const row of sorted) {
      const end = effective.get(Date.parse(row.ends_at))!;
      const last = clusters[clusters.length - 1];
      if (last && end - effective.get(Date.parse(last[last.length - 1]!.ends_at))! <= SAME_WINDOW_MS) last.push(row);
      else clusters.push([row]);
    }
    const windows = clusters.map((cluster): MergedWindow => {
      const latest = cluster.reduce((best, row) => (row.observed_at > best.observed_at ? row : best));
      const endsAt = effective.get(Date.parse(latest.ends_at))!;
      return {
        account: latest.account_key,
        // A copy a Mac ended early names no real start; the latest start any copy names is the window's.
        startsAt: Math.max(...cluster.map((row) => Date.parse(row.ends_at))) - periodMs,
        endsAt,
        periodMs,
        keys: new Set(cluster.map((row) => row.ends_at)),
        rows: cluster,
        observedAt: Math.max(...cluster.map((row) => Date.parse(row.observed_at))),
        covered: cluster.some((row) => plan.covered(row.user_id)),
        ...mergeRows(cluster),
      };
    });
    for (let index = 1; index < windows.length; index += 1) {
      windows[index]!.startsAt = Math.max(windows[index]!.startsAt, windows[index - 1]!.endsAt);
    }
    const covered = windows.filter((window) => window.covered);
    if (covered.length > 0) accounts.set(covered[0]!.account, [...(accounts.get(covered[0]!.account) ?? []), ...covered].sort((a, b) => a.endsAt - b.endsAt));
  }
  return accounts;
}

/** The share used of the window's capacity, 0–100 (more when over it): what older apps read as its share. */
export function shareOfCapacity(window: Pick<MergedWindow, "used" | "capacity">): number {
  return (window.used / window.capacity) * 100;
}

/** The share used so far at the moment of the window's latest claim on or after `from` (epoch ms), with that claim. */
export function latestClaimSince(window: MergedWindow, from: number): { claim: Claim; usedAt: number } | null {
  let index = -1;
  window.claims.forEach((claim, at) => { if (claim.at >= from) index = at; });
  if (index < 0) return null;
  return { claim: window.claims[index]!, usedAt: window.segments.slice(0, index + 1).reduce((sum, value) => sum + value, 0) };
}
