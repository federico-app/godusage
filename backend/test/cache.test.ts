import { beforeAll, describe, expect, it } from "vitest";
import { teamChampions } from "../src/routes/social";
import { MAX_AGE_MS } from "../src/teamCache";
import { teamStats } from "../src/stats";
import { addDays } from "../src/usagePayload";
import { env } from "./env";
import { api, NOW, teamWith, upload } from "./support";

const TODAY = "2026-10-05";
const PROVIDERS = ["claude", "codex", "cursor", "grok"];
const MODELS = ["model-a", "model-b", "model-c", "model-d"];
const DEVICES = ["device-seed-0001", "device-seed-0002"];
const later = (minutes: number) => new Date(NOW.getTime() + minutes * 60_000);

/** `days` of history on two Macs for each user, written straight to the tables (uploads only reach 40 days back). */
async function seedHistory(userIDs: string[], days: number): Promise<void> {
  for (const userID of userIDs) {
    for (const [index, deviceID] of DEVICES.entries()) {
      await env.db.run("INSERT INTO devices (user_id, id, name, updated_at) VALUES ($1, $2, 'Mac', $3)", [userID, deviceID, `${TODAY}T12:0${index}:00.000Z`]);
      const dayRows: object[] = [];
      const modelRows: object[] = [];
      for (let offset = 0; offset < days; offset++) {
        const day = addDays(TODAY, -offset);
        for (const provider of PROVIDERS) {
          const scope = provider === "cursor" ? "account" : "device";
          const account_key = provider === "cursor" ? userID.replaceAll("-", "").padEnd(64, "0").slice(0, 64) : null;
          dayRows.push({ provider, day, scope, tokens: 400, cost_usd: 4, account_key });
          for (const model of MODELS) modelRows.push({ provider, day, model, scope, tokens: 100, cost_usd: 1, account_key });
        }
      }
      await env.db.run(
        `INSERT INTO usage_days (user_id, device_id, provider, day, scope, tokens, cost_usd, account_key)
         SELECT $1, $2, provider, day, scope, tokens, cost_usd, account_key
         FROM jsonb_to_recordset($3::jsonb) AS r(provider text, day text, scope text, tokens bigint, cost_usd double precision, account_key text)`,
        [userID, deviceID, JSON.stringify(dayRows)],
      );
      await env.db.run(
        `INSERT INTO usage_model_days (user_id, device_id, provider, day, model, scope, tokens, cost_usd, account_key)
         SELECT $1, $2, provider, day, model, scope, tokens, cost_usd, account_key
         FROM jsonb_to_recordset($3::jsonb) AS r(provider text, day text, model text, scope text, tokens bigint, cost_usd double precision, account_key text)`,
        [userID, deviceID, JSON.stringify(modelRows)],
      );
    }
    await env.db.run(
      "INSERT INTO account_keys (user_id, account_key, provider) SELECT DISTINCT user_id, account_key, provider FROM usage_days WHERE user_id = $1 AND account_key IS NOT NULL",
      [userID],
    );
  }
}

describe("a year of history", () => {
  // Ten members with two Macs and a year of history each: 29,200 day rows and 116,800 model rows.
  let team: { id: string };
  beforeAll(async () => {
    const created = await teamWith(["A", "B", "C", "D", "E", "F", "G", "H", "I"]);
    team = created.team;
    await seedHistory([created.owner, ...created.members].map((user) => user.userID), 365);
  });

  it("adds up on Postgres: Macs summed, account usage once, BIGINT sums as numbers", async () => {
    // A member's day: three device providers on two Macs (6 × 400 tokens, $24) and Cursor once (400, $4).
    const year = await teamStats(env.db, team.id, { range: "365d", sort: "cost", today: TODAY });
    expect(year.totals).toEqual({ tokens: 10 * 365 * 2_800, costUSD: 10 * 365 * 28 });
    expect(year.members.every((member) => member.rank === 1 && member.tokens === 365 * 2_800)).toBe(true);
    expect(year.models.find((model) => model.provider === "cursor" && model.model === "model-a")).toMatchObject({ tokens: 10 * 365 * 100 });
    const week = await teamStats(env.db, team.id, { range: "7d", sort: "tokens", today: TODAY });
    expect(week.totals.tokens).toBe(10 * 7 * 2_800);
    expect(week.members[0]!.previous).toEqual({ rank: 1, tokens: 7 * 2_800, costUSD: 7 * 28 });
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

    const days = await env.db.query("SELECT provider, day, tokens FROM usage_days WHERE user_id = $1 ORDER BY provider, day", [owner.userID]);
    expect(days).toEqual([
      { provider: "claude", day: "2026-10-04", tokens: 10 },
      { provider: "claude", day: "2026-10-05", tokens: 30 },
      { provider: "codex", day: "2026-10-05", tokens: 5 },
    ]);
    const models = await env.db.query("SELECT day, model, tokens FROM usage_model_days WHERE user_id = $1 ORDER BY day, model", [owner.userID]);
    expect(models).toEqual([
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

describe("team cache", () => {
  async function stats(token: string, teamID: string, now: Date, query = "range=today") {
    return (await api("GET", `/v1/teams/${teamID}/stats?${query}`, { token, now })).body;
  }

  it("reuses a board until the team's usage changes, and never past 10 minutes", async () => {
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
    expect(reused.paused).toBeUndefined();
    expect((await stats(owner.token, team.id, later(6))).stats.totals.costUSD).toBe(2);

    // Nothing changed: reused, but only until it is 10 minutes old.
    expect((await stats(owner.token, team.id, later(15))).computedAt).toBe(later(6).toISOString());
    expect((await stats(owner.token, team.id, later(16))).computedAt).toBe(later(16).toISOString());
    expect(MAX_AGE_MS).toBe(10 * 60_000);
  });

  it("recomputes longer boards after 10 minutes at most, even when usage keeps changing", async () => {
    const { owner, team } = await teamWith([]);
    const put = (tokens: number, now: Date) =>
      api("PUT", "/v1/devices/device-cache-0002/usage", { token: owner.token, now, body: upload([{ provider: "claude", days: [{ date: TODAY, tokens }] }]) });
    await put(1, NOW);
    expect((await stats(owner.token, team.id, NOW, "range=365d")).stats.totals.tokens).toBe(1);
    await put(2, later(1));
    expect((await stats(owner.token, team.id, later(9), "range=365d")).stats.totals.tokens).toBe(1);
    expect((await stats(owner.token, team.id, later(10), "range=365d")).stats.totals.tokens).toBe(2);
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

  it("reuses a team's champions for 10 minutes, and forgets them when its members change", async () => {
    const { owner, team } = await teamWith(["Bea"]);
    await api("PUT", "/v1/devices/device-champ-0001/usage", {
      token: owner.token,
      body: upload([{ provider: "claude", days: [{ date: "2026-09-20", tokens: 1, costUSD: 5 }] }]),
    });
    const first = await teamChampions(env, NOW, team.id, TODAY);
    expect(first[0]).toMatchObject({ month: "2026-09", userID: owner.userID, costUSD: 5 });

    await env.db.run("UPDATE usage_days SET cost_usd = cost_usd * 2 WHERE user_id = $1", [owner.userID]);
    expect(await teamChampions(env, later(9), team.id, TODAY)).toEqual(first);
    expect((await teamChampions(env, later(10), team.id, TODAY))[0]!.costUSD).toBe(10);

    await env.db.run("UPDATE usage_days SET cost_usd = 1 WHERE user_id = $1", [owner.userID]);
    expect((await teamChampions(env, later(11), team.id, TODAY))[0]!.costUSD).toBe(10);
    const joined = await teamWith([]);
    await api("POST", `/v1/invites/${(await api("GET", `/v1/teams/${team.id}`, { token: owner.token })).body.team.inviteURL.split("/join/")[1]}/accept`, {
      token: joined.owner.token,
    });
    expect((await teamChampions(env, later(12), team.id, TODAY))[0]!.costUSD).toBe(1);
  });
});
