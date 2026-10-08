import { env } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { teamChallengeList } from "../src/routes/challenges";
import { computeChampions, teamChampions } from "../src/routes/social";
import { storeDeviceUsage } from "../src/routes/usage";
import { planReports } from "../src/plans";
import { metered, rowsReadToday, type ReadGuard } from "../src/readGuard";
import { teamStats, type RangeName } from "../src/stats";
import { addDays, parseUsageUpload } from "../src/usagePayload";
import { api, NOW, teamWith, upload } from "./support";

/**
 * D1 bills every row a query reads (temporary sorts and lookups included), and the free plan allows
 * 5M a day for the whole account. The leaderboard is fetched on every popover open, every two minutes
 * while it is open, and after uploads, so its reads must follow the period asked for, never the full
 * history every member has built up.
 */

const TODAY = "2026-10-05";
const PROVIDERS = ["claude", "codex", "cursor", "grok"];
const MODELS = ["model-a", "model-b", "model-c", "model-d"];
const DEVICES = ["device-seed-0001", "device-seed-0002"];

/** `days` of history on two Macs for each user, written straight to the tables (uploads only reach 40 days back). */
async function seedHistory(userIDs: string[], days: number): Promise<void> {
  for (const userID of userIDs) {
    for (const deviceID of DEVICES) {
      await env.DB.prepare("INSERT INTO devices (user_id, id, name, updated_at) VALUES (?, ?, 'Mac', ?)")
        .bind(userID, deviceID, `${TODAY}T12:00:00.000Z`)
        .run();
      const dayRows: unknown[][] = [];
      const modelRows: unknown[][] = [];
      for (let offset = 0; offset < days; offset++) {
        const day = addDays(TODAY, -offset);
        for (const provider of PROVIDERS) {
          const scope = provider === "cursor" ? "account" : "device";
          const key = provider === "cursor" ? userID.replaceAll("-", "").padEnd(64, "0").slice(0, 64) : null;
          dayRows.push([provider, day, scope, 400, 4, key]);
          for (const model of MODELS) modelRows.push([provider, day, model, scope, 100, 1, key]);
        }
      }
      await env.DB.batch([
        env.DB.prepare(
          `INSERT INTO usage_days (user_id, device_id, provider, day, scope, tokens, cost_usd, account_key)
           SELECT ?1, ?2, value ->> 0, value ->> 1, value ->> 2, value ->> 3, value ->> 4, value ->> 5 FROM json_each(?3)`,
        ).bind(userID, deviceID, JSON.stringify(dayRows)),
        env.DB.prepare(
          `INSERT INTO usage_model_days (user_id, device_id, provider, day, model, scope, tokens, cost_usd, account_key)
           SELECT ?1, ?2, value ->> 0, value ->> 1, value ->> 2, value ->> 3, value ->> 4, value ->> 5, value ->> 6 FROM json_each(?3)`,
        ).bind(userID, deviceID, JSON.stringify(modelRows)),
      ]);
    }
    await env.DB.prepare(
      "INSERT OR IGNORE INTO account_keys (user_id, account_key, provider) SELECT DISTINCT user_id, account_key, provider FROM usage_days WHERE user_id = ? AND account_key IS NOT NULL",
    ).bind(userID).run();
  }
}

async function rowsRead(work: (db: D1Database) => Promise<unknown>): Promise<number> {
  const counter = metered(env.DB);
  await work(counter.db);
  return counter.rowsRead();
}

/** A month of one Mac's usage, as the app uploads it. */
function monthUpload(costToday: number) {
  return upload(
    PROVIDERS.filter((provider) => provider !== "cursor").map((provider) => ({
      provider,
      days: Array.from({ length: 30 }, (_, i) => {
        const cost = i === 0 ? costToday : 4;
        return { date: addDays(TODAY, -i), tokens: 400, costUSD: cost, models: MODELS.map((model) => ({ model, tokens: 100, costUSD: cost / 4 })) };
      }),
    })),
  );
}

describe("read budget", () => {
  // Ten members with two Macs and a year of history each: 29,200 day rows and 116,800 model rows.
  let team: { id: string };
  let ownerID: string;
  beforeAll(async () => {
    const created = await teamWith(["A", "B", "C", "D", "E", "F", "G", "H", "I"]);
    team = created.team;
    ownerID = created.owner.userID;
    await seedHistory([created.owner, ...created.members].map((user) => user.userID), 365);
  });

  // Before the read budget, a 30-day board read 108K rows and a Year 366K; each stored row cost about
  // six reads. Now it reads each row of its period about once: one day of this team is 400 rows.
  it.each<[RangeName, number]>([
    ["today", 1_000],
    ["7d", 4_000],
    ["mtd", 3_000],
    ["30d", 16_000],
    // A year has no movement arrows, so it reads no second year.
    ["365d", 150_000],
  ])("a %s board reads only its period", async (range, limit) => {
    expect(await rowsRead((db) => teamStats(db, team.id, { range, sort: "cost", today: TODAY }))).toBeLessThan(limit);
  });

  it("champions, challenges, and plans read only their period", async () => {
    // Twelve months of daily totals (no models): 80 rows a day for this team. Recomputed every 6 hours.
    expect(await rowsRead((db) => computeChampions(db, team.id, TODAY))).toBeLessThan(30_000);
    await env.DB.prepare("INSERT INTO challenges (id, team_id, kind, starts_on, ends_on, created_by, created_at) VALUES ('c1', ?, 'most_models', ?, ?, NULL, 'x')")
      .bind(team.id, addDays(TODAY, -6), TODAY)
      .run();
    expect(await rowsRead((db) => teamChallengeList(db, team.id, TODAY))).toBeLessThan(4_000);
    const plans = [{ id: "p", provider: "claude", name: "Max", monthlyCostUSD: 200, renewalDay: 1 }];
    expect(await rowsRead((db) => planReports(db, team.id, plans, TODAY))).toBeLessThan(800);
  });

  it("an upload reads its window, and a partial one only the days it sends", async () => {
    const full = parseUsageUpload(monthUpload(4), NOW);
    // A full upload (after launch, or when a provider was turned off) reads its window of the user's
    // Macs: 30 days of 4 providers and 16 models on each of two Macs here.
    expect(await rowsRead((db) => storeDeviceUsage(db, ownerID, DEVICES[0]!, full, NOW))).toBeLessThan(4_000);

    const today = parseUsageUpload(
      { ...upload([{ provider: "claude", days: [{ date: TODAY, tokens: 500, costUSD: 9, models: [{ model: "model-a", tokens: 500, costUSD: 9 }] }] }]), partial: true },
      NOW,
    );
    expect(await rowsRead((db) => storeDeviceUsage(db, ownerID, DEVICES[0]!, today, NOW))).toBeLessThan(100);
  });
});

describe("partial uploads", () => {
  it("replace only the provider-days they carry", async () => {
    const { owner, team } = await teamWith([]);
    const device = "device-part-0001";
    const put = (body: unknown) => api("PUT", `/v1/devices/${device}/usage`, { token: owner.token, body });
    await put(
      upload([
        { provider: "claude", days: [
          { date: "2026-10-04", tokens: 10, costUSD: 1, models: [{ model: "opus", tokens: 10, costUSD: 1 }] },
          { date: "2026-10-05", tokens: 20, costUSD: 2, models: [{ model: "opus", tokens: 10, costUSD: 1 }, { model: "sonnet", tokens: 10, costUSD: 1 }] },
        ] },
        { provider: "codex", days: [{ date: "2026-10-05", tokens: 5, costUSD: 0.5 }] },
      ]),
    );
    // Today's Claude changed and dropped Sonnet; yesterday and Codex are not sent and stay.
    const response = await put({
      ...upload([{ provider: "claude", days: [{ date: "2026-10-05", tokens: 30, costUSD: 3, models: [{ model: "opus", tokens: 30, costUSD: 3 }] }] }]),
      partial: true,
    });
    expect(response.status).toBe(200);

    const days = await env.DB.prepare("SELECT provider, day, tokens FROM usage_days WHERE user_id = ? ORDER BY provider, day").bind(owner.userID).all();
    expect(days.results).toEqual([
      { provider: "claude", day: "2026-10-04", tokens: 10 },
      { provider: "claude", day: "2026-10-05", tokens: 30 },
      { provider: "codex", day: "2026-10-05", tokens: 5 },
    ]);
    const models = await env.DB.prepare("SELECT day, model, tokens FROM usage_model_days WHERE user_id = ? ORDER BY day, model").bind(owner.userID).all();
    expect(models.results).toEqual([
      { day: "2026-10-04", model: "opus", tokens: 10 },
      { day: "2026-10-05", model: "opus", tokens: 30 },
    ]);
    expect(team.id).toBeTruthy();
  });

  it("cannot carry a window", async () => {
    const { owner } = await teamWith([]);
    const response = await api("PUT", "/v1/devices/device-part-0002/usage", {
      token: owner.token,
      body: { ...upload([]), partial: true, windowStart: "2026-09-06" },
    });
    expect(response.status).toBe(400);
  });
});

describe("stats cache", () => {
  const later = (minutes: number) => new Date(NOW.getTime() + minutes * 60_000);

  async function stats(token: string, teamID: string, now: Date, query = "range=today") {
    return (await api("GET", `/v1/teams/${teamID}/stats?${query}`, { token, now })).body;
  }

  it("reuses a board until the team's usage changes, and at most every few minutes", async () => {
    const { owner, team } = await teamWith([]);
    const put = (cost: number, now: Date) =>
      api("PUT", "/v1/devices/device-cache-0001/usage", {
        token: owner.token,
        now,
        body: upload([{ provider: "claude", days: [{ date: TODAY, tokens: 1, costUSD: cost }] }]),
      });
    await put(1, NOW);
    expect((await stats(owner.token, team.id, NOW)).stats.totals.costUSD).toBe(1);

    // Usage changed, but today's board was computed under 5 minutes ago.
    await put(2, later(1));
    const reused = await stats(owner.token, team.id, later(2));
    expect(reused.stats.totals.costUSD).toBe(1);
    expect(reused.computedAt).toBe(NOW.toISOString());
    expect((await stats(owner.token, team.id, later(6))).stats.totals.costUSD).toBe(2);

    // Nothing changed: reused for up to 15 minutes.
    expect((await stats(owner.token, team.id, later(20))).computedAt).toBe(later(6).toISOString());
  });

  it("sends Today and Month to Date beside the board asked for", async () => {
    const { owner, team } = await teamWith([]);
    const body = await stats(owner.token, team.id, NOW, "range=30d&include=today,mtd");
    expect(body.stats.range.name).toBe("30d");
    expect(body.extra.today.range.name).toBe("today");
    expect(body.extra.mtd.range.name).toBe("mtd");
    expect((await api("GET", `/v1/teams/${team.id}/stats?include=year`, { token: owner.token })).status).toBe(400);
  });

  it("shows a new name and a new member at once", async () => {
    const { owner, team } = await teamWith(["Bea"]);
    await stats(owner.token, team.id, NOW);
    await api("PATCH", "/v1/me", { token: owner.token, body: { displayName: "Renamed" } });
    const names = (await stats(owner.token, team.id, later(1))).stats.members.map((m: { displayName: string }) => m.displayName);
    expect(names).toContain("Renamed");
  });
});

describe("daily read budget", () => {
  beforeEach(async () => {
    await env.DB.prepare("DELETE FROM read_budget").run();
  });

  async function spend(rows: number, now = NOW) {
    await env.DB.prepare("INSERT INTO read_budget (day, rows_read) VALUES (?, ?) ON CONFLICT (day) DO UPDATE SET rows_read = rows_read + excluded.rows_read")
      .bind(now.toISOString().slice(0, 10), rows)
      .run();
  }

  it("counts the rows expensive work reads", async () => {
    const { owner, team } = await teamWith([]);
    const before = await rowsReadToday(env.DB, NOW);
    await api("GET", `/v1/teams/${team.id}/stats?range=7d`, { token: owner.token });
    expect(await rowsReadToday(env.DB, NOW)).toBeGreaterThan(before);
  });

  it("serves the last board, refuses uploads, and resumes the next UTC day once the budget is spent", async () => {
    const { owner, team } = await teamWith([]);
    await api("PUT", "/v1/devices/device-budget-0001/usage", { token: owner.token, body: upload([{ provider: "claude", days: [{ date: TODAY, tokens: 1, costUSD: 1 }] }]) });
    const first = await api("GET", `/v1/teams/${team.id}/stats?range=today`, { token: owner.token });
    expect(first.body.paused).toBe(false);

    await spend(Number(env.READ_BUDGET_PER_DAY));
    const upload2 = await api("PUT", "/v1/devices/device-budget-0001/usage", {
      token: owner.token,
      now: new Date(NOW.getTime() + 60 * 60_000),
      body: upload([{ provider: "claude", days: [{ date: TODAY, tokens: 2, costUSD: 2 }] }]),
    });
    expect(upload2.status).toBe(503);
    expect(upload2.body.error.code).toBe("read_budget");

    const paused = await api("GET", `/v1/teams/${team.id}/stats?range=today`, { token: owner.token, now: new Date(NOW.getTime() + 60 * 60_000) });
    expect(paused.status).toBe(200);
    expect(paused.body.paused).toBe(true);
    expect(paused.body.stats.totals.costUSD).toBe(1);

    // A board never computed today has nothing to fall back on.
    const never = await api("GET", `/v1/teams/${team.id}/stats?range=30d`, { token: owner.token, now: new Date(NOW.getTime() + 60 * 60_000) });
    expect(never.status).toBe(503);

    const tomorrow = new Date(NOW.getTime() + 24 * 60 * 60_000);
    const resumed = await api("GET", `/v1/teams/${team.id}/stats?range=today`, { token: owner.token, now: tomorrow });
    expect(resumed.body.paused).toBe(false);
  });

  it("keeps the last champions while paused", async () => {
    const { team } = await teamWith([]);
    const guard = (now: Date, budget: number): ReadGuard => ({ db: env.DB, now, budget });
    expect(await teamChampions(guard(NOW, 1e9), team.id, TODAY)).toEqual([]);
    await env.DB.prepare("UPDATE team_champions SET champions = ? WHERE team_id = ?")
      .bind(JSON.stringify([{ month: "2026-09", userID: "x", displayName: "X", costUSD: 1 }]), team.id)
      .run();
    // Stale after six hours, but the budget is spent: the last result stays.
    expect(await teamChampions(guard(new Date(NOW.getTime() + 7 * 60 * 60_000), -1), team.id, TODAY)).toHaveLength(1);
  });

  it("reuses a team's champions for six hours", async () => {
    const { owner, team } = await teamWith(["Bea"]);
    await api("PUT", "/v1/devices/device-champ-0001/usage", {
      token: owner.token,
      body: upload([{ provider: "claude", days: [{ date: "2026-09-20", tokens: 1, costUSD: 5 }] }]),
    });
    const guard = (minutes: number): ReadGuard => ({ db: env.DB, now: new Date(NOW.getTime() + minutes * 60_000), budget: 1e9 });
    const first = await teamChampions(guard(0), team.id, TODAY);
    expect(first[0]).toMatchObject({ month: "2026-09", userID: owner.userID, costUSD: 5 });

    await env.DB.prepare("UPDATE usage_days SET cost_usd = cost_usd * 2 WHERE user_id = ?").bind(owner.userID).run();
    expect(await teamChampions(guard(5 * 60), team.id, TODAY)).toEqual(first);
    expect((await teamChampions(guard(6 * 60 + 1), team.id, TODAY))[0]!.costUSD).toBe(10);
  });
});
