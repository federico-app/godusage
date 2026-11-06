import { describe, expect, it } from "vitest";
import { api, NOW, teamWith, upload } from "./support";

const SHARED = "a".repeat(64);
const OWN = "b".repeat(64);
const at = (iso: string) => new Date(iso).toISOString();
const plan = { provider: "claude", name: "Max", monthlyCostUSD: 100, renewalDay: 1 };

function weekly(account: string, endsAt: string, days: [string, number][]) {
  return {
    provider: "claude", kind: "limit", account, endsAt: at(endsAt), periodHours: 168,
    percent: Math.max(...days.map(([, percent]) => percent)), observedAt: NOW.toISOString(),
    days: days.map(([day, percent]) => ({ day, percent })),
  };
}

/** Today is Monday Oct 5. Both read the shared account; Bea also reads her own login, which resets first. */
async function setUp() {
  const { owner, team, members } = await teamWith(["Bea"]);
  const bea = members[0]!;
  await api("PUT", "/v1/devices/device-aaaa-0001/usage", {
    token: owner.token,
    body: { ...upload([{ provider: "claude", days: [{ date: "2026-10-05", tokens: 1000, costUSD: 10 }] }]), quotaWindows: [weekly(SHARED, "2026-10-09T00:00:00Z", [["2026-10-02", 10], ["2026-10-05", 40]])] },
  });
  await api("PUT", "/v1/devices/device-bbbb-0002/usage", {
    token: bea.token,
    body: {
      ...upload([{ provider: "claude", days: [{ date: "2026-10-05", tokens: 1000, costUSD: 5 }] }]),
      quotaWindows: [
        weekly(SHARED, "2026-10-09T00:00:00Z", [["2026-10-02", 10], ["2026-10-05", 40]]),
        weekly(OWN, "2026-10-06T08:00:00Z", [["2026-10-02", 20], ["2026-10-05", 90]]),
      ],
    },
  });
  const saved = (await api("PUT", `/v1/teams/${team.id}/plans?today=2026-10-05`, { token: owner.token, body: { plans: [plan] } })).body.plans[0];
  return { owner, team, bea, saved };
}

const hide = (teamID: string, planID: string, token: string, account: string, hidden: boolean) =>
  api("PUT", `/v1/teams/${teamID}/plans/${planID}/hidden-accounts?today=2026-10-05`, { token, body: { account, hidden } });

describe("accounts hidden from a plan", () => {
  it("leaves the account out of the plan's quota figures but keeps its usage", async () => {
    const { owner, team, bea, saved } = await setUp();
    expect(saved.budget.accounts).toBe(2);
    expect(saved.budget.perAccount[0].account).toBe(OWN);

    const response = await hide(team.id, saved.id, owner.token, OWN, true);
    expect(response.status).toBe(200);
    const after = response.body.plans[0];
    expect(after.id).toBe(saved.id);
    expect(after.hiddenAccounts).toEqual([OWN]);
    expect(after.budget.accounts).toBe(1);
    expect(after.budget.perAccount.map((account: { account: string }) => account.account)).toEqual([SHARED]);
    expect(after.budget.resetsAt).toBe("2026-10-09T00:00:00.000Z");
    expect(after.hiddenPerAccount).toEqual([
      { people: ["Bea"], percent: 90, todayPercent: 70, resetsAt: "2026-10-06T08:00:00.000Z", perDevice: false, account: OWN },
    ]);
    expect(after.valueUSD).toBe(saved.valueUSD);

    // Members see the figures without the account, and neither the keys nor the hidden list.
    const asBea = (await api("GET", `/v1/teams/${team.id}/plans?today=2026-10-05`, { token: bea.token })).body.plans[0];
    expect(asBea.budget.accounts).toBe(1);
    expect(asBea.hiddenAccounts).toEqual([]);
    expect(asBea.hiddenPerAccount).toEqual([]);

    const history = (await api("GET", `/v1/teams/${team.id}/plans/history?today=2026-10-05&weeks=1`, { token: owner.token })).body;
    expect(history.plans[0].weeks[0]).toMatchObject({ accounts: 1, endsAt: "2026-10-09T00:00:00.000Z" });

    // The last account with an open week stays: the plan would have no week to show it again from.
    expect((await hide(team.id, saved.id, owner.token, SHARED, true)).status).toBe(400);

    const shown = (await hide(team.id, saved.id, owner.token, OWN, false)).body.plans[0];
    expect(shown.hiddenAccounts).toEqual([]);
    expect(shown.budget.accounts).toBe(2);
  });

  it("keeps hidden accounts across saves, also from apps that don't send them", async () => {
    const { owner, team, saved } = await setUp();
    await hide(team.id, saved.id, owner.token, OWN, true);
    const resaved = (await api("PUT", `/v1/teams/${team.id}/plans?today=2026-10-05`, { token: owner.token, body: { plans: [plan] } })).body.plans[0];
    expect(resaved.hiddenAccounts).toEqual([OWN]);
    const cleared = (await api("PUT", `/v1/teams/${team.id}/plans?today=2026-10-05`, {
      token: owner.token, body: { plans: [{ ...plan, hiddenAccounts: [] }] },
    })).body.plans[0];
    expect(cleared.hiddenAccounts).toEqual([]);
  });

  it("lets only owners hide accounts, and only from their team's plans", async () => {
    const { team, bea, saved } = await setUp();
    expect((await hide(team.id, saved.id, bea.token, OWN, true)).status).toBe(403);
    const other = await teamWith([]);
    expect((await hide(other.team.id, saved.id, other.owner.token, OWN, true)).status).toBe(404);
    expect((await api("PUT", `/v1/teams/${team.id}/plans/${saved.id}/hidden-accounts`, { token: bea.token, body: { account: "" } })).status).toBe(403);
  });
});
