import { describe, expect, it } from "vitest";
import { api, NOW, teamWith, upload } from "./support";

const DAY = "2026-10-05";
const PERSONAL = "e".repeat(64);
const CURSOR = "f".repeat(64);
const DEVICE = "device-aaaa-0001";
const at = (minutes: number) => new Date(NOW.getTime() + minutes * 60_000);

/** Fede's Mac: the work Claude account folded, the personal one split, left out of `excludedFrom`. */
function fedeUpload(work: number, personal: number, excludedFrom: string[]) {
  const body = upload([
    { provider: "claude", days: [{ date: DAY, tokens: work, costUSD: work, models: [{ model: "opus", tokens: work, costUSD: work }] }] },
  ]);
  return {
    ...body,
    providers: [
      ...body.providers,
      { provider: "claude", scope: "device", account: PERSONAL, split: true, days: [{ date: DAY, tokens: personal, costUSD: personal, models: [{ model: "opus", tokens: personal, costUSD: personal }] }] },
    ],
    excludedAccounts: excludedFrom.map((team) => ({ team, provider: "claude", account: PERSONAL })),
  };
}

async function stats(token: string, teamID: string, now = NOW) {
  const response = await api("GET", `/v1/teams/${teamID}/stats?range=today&today=${DAY}`, { token, now });
  expect(response.status).toBe(200);
  return response.body;
}

describe("accounts left out of a team", () => {
  it("drops a split account from the teams it's left out of and keeps it in the others", async () => {
    const { team: work, members } = await teamWith(["Fede"]);
    const fede = members[0]!;
    const friends = (await api("POST", "/v1/teams", { token: fede.token, body: { name: "Friends" } })).body.team;
    const put = await api("PUT", `/v1/devices/${DEVICE}/usage`, { token: fede.token, body: fedeUpload(30, 11, [work.id]) });
    expect(put.status).toBe(200);

    const workStats = (await stats(fede.token, work.id)).stats;
    expect(workStats.members.find((m: { displayName: string }) => m.displayName === "Fede")).toMatchObject({ costUSD: 30 });
    expect(workStats.totals).toEqual({ tokens: 30, costUSD: 30 });
    const friendsStats = (await stats(fede.token, friends.id)).stats;
    expect(friendsStats.totals).toEqual({ tokens: 41, costUSD: 41 });

    // Taking the exclusion back counts the account again (the cached board is stale).
    await api("PUT", `/v1/devices/${DEVICE}/usage`, { token: fede.token, body: fedeUpload(30, 11, []) });
    expect((await stats(fede.token, work.id)).stats.totals).toEqual({ tokens: 41, costUSD: 41 });
  });

  it("skips teams the member isn't in and rejects a split entry without its account", async () => {
    const { team } = await teamWith([]);
    const { members } = await teamWith(["Fede"]);
    const fede = members[0]!;
    // Fede isn't in `team`: the exclusion is ignored, not an error.
    expect((await api("PUT", `/v1/devices/${DEVICE}/usage`, { token: fede.token, body: fedeUpload(1, 1, [team.id]) })).status).toBe(200);

    const body = fedeUpload(1, 1, []);
    const { account: _, ...noAccount } = body.providers[1]!;
    const bad = await api("PUT", `/v1/devices/${DEVICE}/usage`, { token: fede.token, body: { ...body, providers: [body.providers[0], noAccount] } });
    expect(bad.status).toBe(400);
    const duplicate = await api("PUT", `/v1/devices/${DEVICE}/usage`, { token: fede.token, body: { ...body, providers: [body.providers[1], body.providers[1]] } });
    expect(duplicate.status).toBe(400);
  });

  it("keeps a left-out account's spend out of the team's ⚡", async () => {
    const { team, members } = await teamWith(["Fede"]);
    const fede = members[0]!;
    await api("PUT", `/v1/devices/${DEVICE}/usage`, { token: fede.token, body: fedeUpload(10, 10, [team.id]), now: at(0) });
    // The personal account grows $20, the work one $2.
    await api("PUT", `/v1/devices/${DEVICE}/usage`, { token: fede.token, body: fedeUpload(12, 30, [team.id]), now: at(10) });
    const momentum = (await stats(fede.token, team.id, at(11))).momentum;
    expect(momentum[fede.userID]).toMatchObject({ lastHourUSD: 2 });
  });

  it("leaves a left-out account's quota out of the team's plans", async () => {
    const { owner, team, members } = await teamWith(["Fede"]);
    const fede = members[0]!;
    const week = (account: string, percent: number) => ({
      provider: "claude", account, periodHours: 168, percent,
      endsAt: new Date(NOW.getTime() - 72 * 3_600_000).toISOString(),
      observedAt: new Date(NOW.getTime() - 72 * 3_600_000).toISOString(),
    });
    const WORK = "d".repeat(64);
    await api("PUT", `/v1/devices/${DEVICE}/usage`, {
      token: fede.token,
      body: { ...fedeUpload(1, 1, [team.id]), quotaWindows: [week(WORK, 40), week(PERSONAL, 100)] },
    });
    const report = (await api("PUT", `/v1/teams/${team.id}/plans`, {
      token: owner.token,
      body: { plans: [{ provider: "claude", name: "Team", monthlyCostUSD: 100, renewalDay: 1 }] },
    })).body;
    expect(report.plans[0].quota).toMatchObject({ usedPercent: 40, accounts: 1 });
  });

  it("drops a split Cursor account from shared-account detection in that team", async () => {
    const { owner, team, members } = await teamWith(["Fede"]);
    const fede = members[0]!;
    const cursor = (cost: number) => ({ provider: "cursor", scope: "account" as const, account: CURSOR, days: [{ date: DAY, tokens: cost, costUSD: cost }] });
    await api("PUT", "/v1/devices/device-bbbb-0002/usage", { token: owner.token, body: upload([cursor(9)]) });
    const split = { ...upload([]), providers: [{ ...cursor(9), split: true }], excludedAccounts: [{ team: team.id, provider: "cursor", account: CURSOR }] };
    expect((await api("PUT", `/v1/devices/${DEVICE}/usage`, { token: fede.token, body: split })).status).toBe(200);
    const board = (await stats(owner.token, team.id)).stats;
    // Only the owner counts the seat in this team, so it is theirs, not shared.
    expect(board.shared).toEqual([]);
    expect(board.totals).toEqual({ tokens: 9, costUSD: 9 });
  });
});
