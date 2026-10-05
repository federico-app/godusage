import { describe, expect, it } from "vitest";
import { api, inviteCode, signIn, teamWith, upload } from "./support";

describe("invite page", () => {
  it("shows the team and links into the app", async () => {
    const owner = await signIn();
    const team = (await api("POST", "/v1/teams", { token: owner.token, body: { name: `<b>"Hackers"</b>` } })).body.team;
    const code = inviteCode(team.inviteURL);

    const page = await api("GET", `/join/${code}`);
    expect(page.status).toBe(200);
    expect(page.body).toContain("Join &lt;b&gt;&quot;Hackers&quot;&lt;/b&gt;");
    expect(page.body).not.toContain("<b>");
    expect(page.body).toContain(`href="godusage://join/${code}"`);
    expect(page.body).toContain("1 member.");
    expect(page.body).toContain("https://github.com/federico-app/godusage/releases/latest");
  });

  it("explains an expired link", async () => {
    const page = await api("GET", "/join/not-a-real-code");
    expect(page.status).toBe(404);
    expect(page.body).toContain("Invite Expired");
  });
});

describe("public leaderboard", () => {
  it("is only reachable while the owner shares it", async () => {
    const { owner, team, members } = await teamWith(["<script>x</script>"]);
    await api("PUT", "/v1/devices/device-aaaa-0001/usage", {
      token: members[0]!.token,
      body: upload([{ provider: "claude", days: [{ date: "2026-10-05", tokens: 2_500_000, costUSD: 12.345, models: [{ model: "opus", tokens: 2_500_000, costUSD: 12.345 }] }] }]),
    });

    const shared = await api("PATCH", `/v1/teams/${team.id}`, { token: owner.token, body: { publicBoard: true } });
    const path = new URL(shared.body.team.publicBoardURL).pathname;

    const board = await api("GET", `${path}?range=today`);
    expect(board.status).toBe(200);
    expect(board.body).toContain("Crew");
    expect(board.body).toContain("$12.35");
    expect(board.body).toContain("&lt;script&gt;x&lt;/script&gt;");
    expect(board.body).not.toContain("<script>");
    expect(board.body).toContain("Top Models");

    const tokens = await api("GET", `${path}?range=today&sort=tokens`);
    expect(tokens.body).toContain("2.5M");

    await api("PATCH", `/v1/teams/${team.id}`, { token: owner.token, body: { publicBoard: false } });
    expect((await api("GET", path)).status).toBe(404);
  });
});
