import { fetchAppleKeys } from "./apple";
import type { AppDeps, Handler } from "./context";
import { ApiError, errorResponse, json } from "./http";
import { deleteMe, getMe, signInWithApple, signOut, updateMe } from "./routes/account";
import { homePage, invitePage, publicBoardPage } from "./routes/pages";
import { getTeamStats } from "./routes/stats";
import {
  acceptInvite,
  createTeam,
  deleteTeam,
  getInvite,
  getTeam,
  listTeams,
  removeMember,
  rotateInvite,
  updateTeam,
} from "./routes/teams";
import { deleteDevice, listDevices, putDeviceUsage } from "./routes/usage";
import { createChallenge, deleteChallenge, listChallenges } from "./routes/challenges";
import { addReaction, removeReaction } from "./routes/social";
import { browserSignOut, memberBoardPage, memberBoardSignIn } from "./routes/webBoard";
import { exchangeWebSignIn, finishWebSignIn, startWebSignIn } from "./routes/webSignIn";

type Method = "GET" | "POST" | "PUT" | "PATCH" | "DELETE";

interface Route {
  method: Method;
  pattern: URLPattern;
  handler: Handler;
}

const route = (method: Method, pathname: string, handler: Handler): Route => ({
  method,
  pattern: new URLPattern({ pathname }),
  handler,
});

const ROUTES: Route[] = [
  route("GET", "/v1/health", async () => json({ ok: true })),
  route("POST", "/v1/auth/apple", signInWithApple),
  route("GET", "/v1/auth/apple/start", startWebSignIn),
  route("POST", "/v1/auth/apple/callback", finishWebSignIn),
  route("POST", "/v1/auth/apple/exchange", exchangeWebSignIn),
  route("POST", "/v1/auth/logout", signOut),
  route("GET", "/v1/me", getMe),
  route("PATCH", "/v1/me", updateMe),
  route("DELETE", "/v1/me", deleteMe),
  route("GET", "/v1/teams", listTeams),
  route("POST", "/v1/teams", createTeam),
  route("GET", "/v1/teams/:teamID", getTeam),
  route("PATCH", "/v1/teams/:teamID", updateTeam),
  route("DELETE", "/v1/teams/:teamID", deleteTeam),
  route("POST", "/v1/teams/:teamID/invite", rotateInvite),
  route("DELETE", "/v1/teams/:teamID/members/:userID", removeMember),
  route("GET", "/v1/teams/:teamID/stats", getTeamStats),
  route("PUT", "/v1/teams/:teamID/members/:userID/reactions/:emoji", addReaction),
  route("DELETE", "/v1/teams/:teamID/members/:userID/reactions/:emoji", removeReaction),
  route("GET", "/v1/teams/:teamID/challenges", listChallenges),
  route("POST", "/v1/teams/:teamID/challenges", createChallenge),
  route("DELETE", "/v1/teams/:teamID/challenges/:challengeID", deleteChallenge),
  route("GET", "/v1/invites/:code", getInvite),
  route("POST", "/v1/invites/:code/accept", acceptInvite),
  route("GET", "/v1/devices", listDevices),
  route("PUT", "/v1/devices/:deviceID/usage", putDeviceUsage),
  route("DELETE", "/v1/devices/:deviceID", deleteDevice),
  route("GET", "/", homePage),
  route("GET", "/join/:code", invitePage),
  route("GET", "/t/:token", publicBoardPage),
  route("GET", "/teams/:teamID", memberBoardPage),
  route("GET", "/teams/:teamID/sign-in", memberBoardSignIn),
  route("POST", "/sign-out", browserSignOut),
];

export function createApp(deps: AppDeps) {
  return {
    async fetch(request: Request, env: Env): Promise<Response> {
      const url = new URL(request.url);
      let pathMatched = false;
      for (const candidate of ROUTES) {
        const match = candidate.pattern.exec({ pathname: url.pathname });
        if (!match) continue;
        pathMatched = true;
        if (candidate.method !== request.method) continue;
        const params = Object.fromEntries(
          Object.entries(match.pathname.groups).filter((entry): entry is [string, string] => entry[1] !== undefined),
        );
        try {
          return await candidate.handler({ request, env, url, params, deps });
        } catch (error) {
          if (error instanceof ApiError) return errorResponse(error);
          console.error(
            JSON.stringify({
              event: "unhandled_error",
              method: request.method,
              path: candidate.pattern.pathname,
              message: error instanceof Error ? error.message : String(error),
              stack: error instanceof Error ? error.stack : undefined,
            }),
          );
          return errorResponse(new ApiError(500, "internal", "Something went wrong. Try again later."));
        }
      }
      return pathMatched
        ? errorResponse(new ApiError(405, "method_not_allowed", "Method not allowed."))
        : errorResponse(new ApiError(404, "not_found", "Not found."));
    },
  };
}

const app = createApp({ fetchAppleKeys, now: () => new Date() });

export default {
  fetch: (request, env) => app.fetch(request, env),
} satisfies ExportedHandler<Env>;
