import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { challengeStandings } from "../src/routes/challenges";
import { teamChampions } from "../src/routes/social";
import { storeDeviceUsage } from "../src/routes/usage";
import { teamStats } from "../src/stats";
import { addDays, parseUsageUpload } from "../src/usagePayload";
import { NOW, teamWith, upload } from "./support";

/**
 * D1 bills every row a query reads, and the free plan allows 5M a day. The leaderboard is fetched on
 * every popover open and after every upload, so its reads must follow the period asked for, not the
 * full history every member has built up.
 */

/** A D1 handle that counts the rows its batches read. */
function counting(db: D1Database): { db: D1Database; rowsRead: () => number } {
  let rows = 0;
  const wrapped = Object.create(db) as D1Database;
  wrapped.prepare = (query: string) => db.prepare(query);
  wrapped.batch = (async (statements: D1PreparedStatement[]) => {
    const results = await db.batch(statements);
    for (const result of results) rows += result.meta.rows_read ?? 0;
    return results;
  }) as D1Database["batch"];
  return { db: wrapped, rowsRead: () => rows };
}

const TODAY = "2026-10-05";
const PROVIDERS = ["claude", "codex", "cursor"];
const MODELS = ["model-a", "model-b", "model-c"];

/** `days` of history for each user, written straight to the tables (uploads only reach 40 days back). */
async function seedHistory(userIDs: string[], days: number): Promise<void> {
  for (const userID of userIDs) {
    await env.DB.prepare("INSERT INTO devices (user_id, id, name, updated_at) VALUES (?, 'device-seed-0001', 'Mac', ?)")
      .bind(userID, `${TODAY}T12:00:00.000Z`)
      .run();
    const dayRows: unknown[][] = [];
    const modelRows: unknown[][] = [];
    for (let offset = 0; offset < days; offset++) {
      const day = addDays(TODAY, -offset);
      for (const provider of PROVIDERS) {
        const scope = provider === "cursor" ? "account" : "device";
        const key = provider === "cursor" ? userID.padEnd(64, "0").slice(0, 64) : null;
        dayRows.push([provider, day, scope, 300, 3, key]);
        for (const model of MODELS) modelRows.push([provider, day, model, scope, 100, 1, key]);
      }
    }
    await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO usage_days (user_id, device_id, provider, day, scope, tokens, cost_usd, account_key)
         SELECT ?1, 'device-seed-0001', value ->> 0, value ->> 1, value ->> 2, value ->> 3, value ->> 4, value ->> 5 FROM json_each(?2)`,
      ).bind(userID, JSON.stringify(dayRows)),
      env.DB.prepare(
        `INSERT INTO usage_model_days (user_id, device_id, provider, day, model, scope, tokens, cost_usd, account_key)
         SELECT ?1, 'device-seed-0001', value ->> 0, value ->> 1, value ->> 2, value ->> 3, value ->> 4, value ->> 5, value ->> 6 FROM json_each(?2)`,
      ).bind(userID, JSON.stringify(modelRows)),
    ]);
  }
}

describe("read budget", () => {
  it("reads rows for the period asked for, not the whole history", async () => {
    const { owner, team, members } = await teamWith(["Bea", "Cy", "Di", "Ed"]);
    const users = [owner, ...members].map((user) => user.userID);
    await seedHistory(users, 365);
    // A year of history is 5 users x 3 providers x 365 days = 5,475 day rows and 16,425 model rows.
    // Before this budget, a "today" request read 44.6K rows, a week's challenge 17.7K, an upload 11K.

    const today = counting(env.DB);
    await teamStats(today.db, team.id, { range: "today", sort: "cost", today: TODAY });
    expect(today.rowsRead()).toBeLessThan(1_500);
    

    const challenge = counting(env.DB);
    await challengeStandings(challenge.db, team.id, { id: "c", kind: "most_tokens", starts_on: addDays(TODAY, -6), ends_on: TODAY, created_by: null });
    expect(challenge.rowsRead()).toBeLessThan(4_000);
    

    // An upload of the app's 30-day window reads about what it carries, not the history behind it.
    const body = upload([{ provider: "claude", days: Array.from({ length: 30 }, (_, i) => ({ date: addDays(TODAY, -i), tokens: 5, costUSD: 1, models: [{ model: "m", tokens: 5, costUSD: 1 }] })) }]);
    const store = counting(env.DB);
    await storeDeviceUsage(store.db, owner.userID, "device-seed-0001", parseUsageUpload(body, NOW), NOW);
    expect(store.rowsRead()).toBeLessThan(2_500);
  });

  it("reuses a team's champions for an hour, and recomputes them when members change", async () => {
    const { owner, team } = await teamWith(["Bea"]);
    await seedHistory([owner.userID], 60);
    const first = await teamChampions(env.DB, team.id, TODAY, NOW);
    expect(first[0]).toMatchObject({ month: "2026-09", userID: owner.userID });

    await env.DB.prepare("UPDATE usage_days SET cost_usd = cost_usd * 2 WHERE user_id = ?").bind(owner.userID).run();
    expect(await teamChampions(env.DB, team.id, TODAY, new Date(NOW.getTime() + 30 * 60_000))).toEqual(first);
    const later = await teamChampions(env.DB, team.id, TODAY, new Date(NOW.getTime() + 61 * 60_000));
    expect(later[0]!.costUSD).toBe(first[0]!.costUSD * 2);
  });
});
