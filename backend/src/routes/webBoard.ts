import type { Handler } from "../context";
import { clearedWebSessionCookie, cookieUser, deleteSession } from "../session";
import { cachedTeamStats, parseStatsQuery } from "../stats";
import { boardExtras, escapeHTML, page, renderBoard } from "./pages";
import { startBrowserSignIn } from "./webSignIn";

/**
 * The members-only web leaderboard: /teams/:teamID shows the same board as the public link, but only
 * to signed-in members (Sign in with Apple in the browser, a 30-day session cookie). It sits beside
 * the owner's optional public link, which needs no sign-in.
 */

const TEAM_ID = /^[A-Za-z0-9-]{1,64}$/;

/** GET /teams/:teamID */
export const memberBoardPage: Handler = async ({ request, env, url, params, deps }) => {
  const teamID = params.teamID!;
  if (!TEAM_ID.test(teamID)) return page("Not Found", `<h1>Not Found</h1>`, 404);
  const user = await cookieUser(request, env.db);
  const signInPath = `/teams/${encodeURIComponent(teamID)}/sign-in`;

  if (!user) {
    return page(
      "Sign In",
      `<p class="eyebrow">GodUsage team leaderboard</p>
       <h1>Sign In to See Your Team</h1>
       <p class="muted">This leaderboard is for team members. Sign in with the Apple ID you use in GodUsage.</p>
       <p><a class="button" href="${escapeHTML(signInPath)}">Sign In with Apple</a></p>`,
    );
  }

  const team = await env.db.first<{ id: string; name: string }>(
    `SELECT t.id, t.name FROM teams t JOIN team_members m ON m.team_id = t.id WHERE t.id = $1 AND m.user_id = $2`,
    [teamID, user.id],
  );
  const account = `<div class="account"><span class="muted">Signed in as ${escapeHTML(user.displayName)}</span>
    <form method="post" action="/sign-out"><button class="linkbutton" type="submit">Sign Out</button></form></div>`;
  if (!team) {
    return page(
      "Not a Member",
      `${account}<h1>Not a Member</h1><p class="muted">Your account isn't in this team. Ask a member for an invite link.</p>`,
      404,
    );
  }

  const query = parseStatsQuery(url, deps.now());
  const now = deps.now();
  const [stats, extras] = await Promise.all([cachedTeamStats(env, now, team.id, query), boardExtras(env, now, team.id, query)]);
  return page(`${team.name} Leaderboard`, account + renderBoard(team.name, stats.value, url, extras, now));
};

/** GET /teams/:teamID/sign-in — starts Sign in with Apple and comes back to the board. */
export const memberBoardSignIn: Handler = async ({ env, url, params, deps }) => {
  return startBrowserSignIn(env, url, deps.now(), `/teams/${params.teamID!}`);
};

/**
 * POST /sign-out — ends the browser session. The cookie is SameSite=Lax, so another site cannot
 * submit this with it; the Origin check refuses cross-site posts anyway.
 */
export const browserSignOut: Handler = async ({ request, env, url }) => {
  const origin = request.headers.get("origin");
  if (origin !== null && origin !== url.origin) return page("Not Allowed", `<h1>Not Allowed</h1>`, 403);
  await deleteSession(request, env.db);
  return new Response(null, {
    status: 303,
    headers: { location: "/", "set-cookie": clearedWebSessionCookie(), "cache-control": "no-store" },
  });
};
