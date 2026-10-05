import { describe, expect, it } from "vitest";
import { api, inviteCode, signIn, teamWith } from "./support";

describe("teams", () => {
  it("creates a team with the creator as owner", async () => {
    const owner = await signIn("Ada");
    const created = await api("POST", "/v1/teams", { token: owner.token, body: { name: "  Night   Owls " } });
    expect(created.status).toBe(201);
    const team = created.body.team;
    expect(team.name).toBe("Night Owls");
    expect(team.role).toBe("owner");
    expect(team.inviteURL).toMatch(/^https:\/\/api\.test\/join\/[A-Za-z0-9_-]{22}$/);
    expect(team.publicBoardURL).toBeNull();
    expect(team.members).toEqual([expect.objectContaining({ id: owner.userID, displayName: "Ada", role: "owner" })]);

    const list = await api("GET", "/v1/teams", { token: owner.token });
    expect(list.body.teams).toEqual([{ id: team.id, name: "Night Owls", role: "owner", memberCount: 1 }]);
  });

  it("validates the team name", async () => {
    const owner = await signIn();
    expect((await api("POST", "/v1/teams", { token: owner.token, body: {} })).status).toBe(400);
    expect((await api("POST", "/v1/teams", { token: owner.token, body: { name: " " } })).status).toBe(400);
    expect((await api("POST", "/v1/teams", { token: owner.token, body: { name: "x".repeat(61) } })).status).toBe(400);
  });

  it("hides teams from non-members", async () => {
    const { team } = await teamWith([]);
    const stranger = await signIn();
    expect((await api("GET", `/v1/teams/${team.id}`, { token: stranger.token })).status).toBe(404);
    expect((await api("GET", `/v1/teams/${team.id}/stats`, { token: stranger.token })).status).toBe(404);
    expect((await api("DELETE", `/v1/teams/${team.id}`, { token: stranger.token })).status).toBe(404);
  });
});

describe("invites", () => {
  it("previews and accepts an invite, and accepting twice is a no-op", async () => {
    const { owner, team } = await teamWith([]);
    const code = inviteCode(team.inviteURL);
    const friend = await signIn("Bea");

    const preview = await api("GET", `/v1/invites/${code}`, { token: friend.token });
    expect(preview.body).toEqual({ team: { id: team.id, name: "Crew", memberCount: 1 }, alreadyMember: false });

    const joined = await api("POST", `/v1/invites/${code}/accept`, { token: friend.token });
    expect(joined.status).toBe(201);
    expect(joined.body.team.role).toBe("member");
    expect(joined.body.team.members.map((m: { displayName: string }) => m.displayName)).toEqual(["Owner", "Bea"]);

    const again = await api("POST", `/v1/invites/${code}/accept`, { token: friend.token });
    expect(again.status).toBe(200);
    expect((await api("GET", `/v1/invites/${code}`, { token: friend.token })).body.alreadyMember).toBe(true);

    const ownerView = await api("GET", `/v1/teams/${team.id}`, { token: owner.token });
    expect(ownerView.body.team.members).toHaveLength(2);
  });

  it("lets only the owner rotate the link, and the old link stops working", async () => {
    const { owner, team, members } = await teamWith(["Bea"]);
    const oldCode = inviteCode(team.inviteURL);
    expect((await api("POST", `/v1/teams/${team.id}/invite`, { token: members[0]!.token })).status).toBe(403);

    const rotated = await api("POST", `/v1/teams/${team.id}/invite`, { token: owner.token });
    const newCode = inviteCode(rotated.body.team.inviteURL);
    expect(newCode).not.toBe(oldCode);

    const late = await signIn();
    const stale = await api("POST", `/v1/invites/${oldCode}/accept`, { token: late.token });
    expect(stale.status).toBe(404);
    expect(stale.body.error.message).toMatch(/no longer valid/);
    expect((await api("POST", `/v1/invites/${newCode}/accept`, { token: late.token })).status).toBe(201);
  });

  it("requires sign-in to accept", async () => {
    const { team } = await teamWith([]);
    expect((await api("POST", `/v1/invites/${inviteCode(team.inviteURL)}/accept`)).status).toBe(401);
  });
});

describe("members", () => {
  it("lets a member leave and the owner remove others, but not the owner", async () => {
    const { owner, team, members } = await teamWith(["Bea", "Cy"]);
    const [bea, cy] = members as [typeof owner, typeof owner];

    expect((await api("DELETE", `/v1/teams/${team.id}/members/${cy.userID}`, { token: bea.token })).status).toBe(403);
    expect((await api("DELETE", `/v1/teams/${team.id}/members/${bea.userID}`, { token: bea.token })).status).toBe(204);
    expect((await api("GET", `/v1/teams/${team.id}`, { token: bea.token })).status).toBe(404);

    expect((await api("DELETE", `/v1/teams/${team.id}/members/${cy.userID}`, { token: owner.token })).status).toBe(204);
    const ownerLeaves = await api("DELETE", `/v1/teams/${team.id}/members/${owner.userID}`, { token: owner.token });
    expect(ownerLeaves.status).toBe(409);
    expect((await api("DELETE", `/v1/teams/${team.id}/members/${cy.userID}`, { token: owner.token })).status).toBe(404);
  });

  it("deletes the team for everyone", async () => {
    const { owner, team, members } = await teamWith(["Bea"]);
    expect((await api("DELETE", `/v1/teams/${team.id}`, { token: members[0]!.token })).status).toBe(403);
    expect((await api("DELETE", `/v1/teams/${team.id}`, { token: owner.token })).status).toBe(204);
    expect((await api("GET", "/v1/teams", { token: members[0]!.token })).body.teams).toEqual([]);
  });

  it("deleting an account removes the teams it owns", async () => {
    const { owner, team, members } = await teamWith(["Bea"]);
    expect((await api("DELETE", "/v1/me", { token: owner.token })).status).toBe(204);
    expect((await api("GET", `/v1/teams/${team.id}`, { token: members[0]!.token })).status).toBe(404);
  });

  it("renames the team and toggles the public board (owner only)", async () => {
    const { owner, team, members } = await teamWith(["Bea"]);
    expect((await api("PATCH", `/v1/teams/${team.id}`, { token: members[0]!.token, body: { name: "X" } })).status).toBe(403);

    const shared = await api("PATCH", `/v1/teams/${team.id}`, { token: owner.token, body: { name: "Renamed", publicBoard: true } });
    expect(shared.body.team.name).toBe("Renamed");
    expect(shared.body.team.publicBoardURL).toMatch(/^https:\/\/api\.test\/t\/[A-Za-z0-9_-]{22}$/);
    // Members never see the public link; only the owner manages it.
    expect((await api("GET", `/v1/teams/${team.id}`, { token: members[0]!.token })).body.team.publicBoardURL).toBeNull();

    const kept = await api("PATCH", `/v1/teams/${team.id}`, { token: owner.token, body: { publicBoard: true } });
    expect(kept.body.team.publicBoardURL).toBe(shared.body.team.publicBoardURL);

    const off = await api("PATCH", `/v1/teams/${team.id}`, { token: owner.token, body: { publicBoard: false } });
    expect(off.body.team.publicBoardURL).toBeNull();
    expect((await api("PATCH", `/v1/teams/${team.id}`, { token: owner.token, body: { publicBoard: "yes" } })).status).toBe(400);
  });
});
