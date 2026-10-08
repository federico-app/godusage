import { createClient } from "redis";
import type { Cache } from "../src/cache";

/**
 * The routes' cache on Redis. Each team is one hash (`team:<id>`): the field `version` holds its stats
 * version and `c:<key>` its cached entries, so bumping, reading, and forgetting a team touch one key,
 * and an evicted or expired hash loses its version and entries together. A hash expires 10 minutes
 * after its last write; no entry is served older than that anyway (src/teamCache.ts).
 */
const TEAM_TTL_SECONDS = 10 * 60;

type Client = ReturnType<typeof createClient>;

export class RedisCache implements Cache {
  private constructor(
    readonly client: Client,
    private readonly prefix: string,
  ) {}

  /** Connects to `url`. Every key starts with `prefix` (tests give each file its own). */
  static async connect(url: string, options: { prefix?: string; onError?: (error: Error) => void } = {}): Promise<RedisCache> {
    const client: Client = createClient({ url });
    // node-redis reconnects by itself; without a listener, a dropped connection would crash the process.
    client.on("error", (error: Error) => (options.onError ?? console.error)(error));
    await client.connect();
    return new RedisCache(client, options.prefix ?? "godusage:");
  }

  private team(teamID: string): string {
    return `${this.prefix}team:${teamID}`;
  }

  async readTeam(teamID: string, key: string) {
    const [version, entry] = await this.client.hmGet(this.team(teamID), ["version", `c:${key}`]);
    return { version: Number(version ?? 0), entry: entry ?? null };
  }

  async writeTeam(teamID: string, key: string, entry: string) {
    const hash = this.team(teamID);
    await this.client.multi().hSet(hash, `c:${key}`, entry).expire(hash, TEAM_TTL_SECONDS).exec();
  }

  async bumpTeams(teamIDs: readonly string[]) {
    if (teamIDs.length === 0) return;
    const multi = this.client.multi();
    for (const teamID of teamIDs) multi.hIncrBy(this.team(teamID), "version", 1).expire(this.team(teamID), TEAM_TTL_SECONDS);
    await multi.exec();
  }

  async forgetTeams(teamIDs: readonly string[], prefix = "") {
    for (const teamID of teamIDs) {
      const hash = this.team(teamID);
      const fields = (await this.client.hKeys(hash)).filter((field) => field.startsWith(`c:${prefix}`));
      if (fields.length > 0) await this.client.hDel(hash, fields);
    }
  }

  async hit(key: string, windowSeconds: number) {
    const window = Math.floor(Date.now() / 1000 / windowSeconds);
    const counter = `${this.prefix}rate:${key}:${window}`;
    const [count] = await this.client.multi().incr(counter).expire(counter, windowSeconds).exec();
    return Number(count);
  }

  async ping() {
    await this.client.ping();
  }

  /** Deletes every key under this cache's prefix (tests). */
  async clear() {
    for await (const keys of this.client.scanIterator({ MATCH: `${this.prefix}*`, COUNT: 500 })) {
      if (keys.length > 0) await this.client.del(keys);
    }
  }

  async close() {
    await this.client.close();
  }
}
