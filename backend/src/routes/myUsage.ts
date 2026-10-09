import type { Handler } from "../context";
import { json } from "../http";
import { requireUser } from "../session";
import { parseStatsQuery } from "../stats";
import { userUsage } from "../teamUsage";
import { addDays } from "../usagePayload";

const DAYS = 30;

/**
 * GET /v1/me/usage?today=YYYY-MM-DD — the signed-in user's own usage over the last 30 days (ending
 * on `today`, as the stats routes read it), combined across their Macs. For the iPhone app.
 * `days` lists every day of the window (zero when nothing was used), oldest first.
 */
export const getMyUsage: Handler = async ({ request, env, url, deps }) => {
  const user = await requireUser(request, env.db);
  const { today } = parseStatsQuery(url, deps.now());
  const from = addDays(today, -(DAYS - 1));
  const { days, devices } = await userUsage(env.db, user.id, from, today);

  const byDay = new Map<string, { tokens: number; cost: number }>();
  const byProvider = new Map<string, { tokens: number; cost: number }>();
  for (const row of days) {
    for (const [map, key] of [[byDay, row.day], [byProvider, row.provider]] as const) {
      const total = map.get(key) ?? { tokens: 0, cost: 0 };
      total.tokens += row.tokens;
      total.cost += row.cost;
      map.set(key, total);
    }
  }
  const series = Array.from({ length: DAYS }, (_, index) => {
    const day = addDays(from, index);
    const total = byDay.get(day);
    return { day, tokens: total?.tokens ?? 0, costUSD: round(total?.cost ?? 0) };
  });
  const providers = [...byProvider]
    .map(([provider, total]) => ({ provider, tokens: total.tokens, costUSD: round(total.cost) }))
    .sort((a, b) => b.costUSD - a.costUSD || b.tokens - a.tokens || (a.provider < b.provider ? -1 : 1));
  const lastSyncAt = devices.reduce<string | null>((newest, device) => (newest === null || device.updated_at > newest ? device.updated_at : newest), null);
  return json({ from, to: today, days: series, providers, lastSyncAt });
};

function round(value: number): number {
  return Math.round(value * 1e6) / 1e6;
}
