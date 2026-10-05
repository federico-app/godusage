# Teams Backend

The teams backend lets people create a team, invite friends with a link, and compare their AI usage on a leaderboard. It is a Cloudflare Worker with a D1 database, in `backend/`. The Mac app is its only writer. A shared team can also be viewed as a read-only web page.

## What it stores

- **Accounts:** the Sign in with Apple user id (`sub`) and a display name the user chooses. No email, no Apple name.
- **Sessions:** only the SHA-256 hash of each session token. A session expires after 180 days without use.
- **Teams:** name, owner, one invite code, and an optional public-board token.
- **Usage:** for each of the user's Macs, daily tokens and spend per provider and per model. The full history is kept: each upload replaces only the days in its window. No credentials, logs, prompts, project names, or account ids.

Deleting an account deletes its sessions, Macs, usage, memberships, and the teams it owns.

## How usage is combined

Each Mac uploads its own last 30 days. An upload replaces that Mac's days from its `windowStart` on (all of them, so a provider turned off disappears from those days) and keeps older days, so history builds up beyond the app's window. Signing out of a Mac removes all of that Mac's days. Every provider entry has a scope:

- **device:** usage read from this Mac's own logs (Claude, Codex, Grok, and so on). A user's Macs are summed.
- **account:** usage that is already account-wide (Cursor). Only the Mac that uploaded most recently counts, so it is never double counted.

This mirrors how [iCloud Sync](icloud-sync.md) combines Macs.

Day keys are each Mac's local calendar days. A stats request can pass the viewer's local `today` as the period's last day; the server accepts up to one day ahead of the UTC date and up to 400 days back (for last week's recap or a past month or year), and uses the UTC date otherwise. Ranges are Today, 7 Days, 30 Days, and Year (365 days). Members are ranked by spend or by tokens; tied members share a rank. Each member also carries `previous`, their rank and totals in the period just before (or null if they had no usage then), for the movement arrows.

## Invites and roles

- Every member can see the invite link: `https://<worker>/join/<code>`. The page shows the team name and member count, an **Open in GodUsage** button (`godusage://join/<code>`), and a download link.
- Only the owner can rotate the link (the old one stops working), rename the team, remove members, share or unshare the public board, and delete the team.
- A member can leave. The owner cannot leave; they delete the team instead.
- Limits: 50 members per team, 20 teams per user.

## Members-only board

Every member can open `https://<worker>/teams/<team id>` in a browser (the app's **Web Leaderboard** link). Visitors who are not signed in see **Sign In with Apple**, which runs the same web sign-in as the app (`/teams/<id>/sign-in`) and comes back to the board. The browser then keeps a 30-day session in a `HttpOnly`, `Secure`, `SameSite=Lax` cookie. Only members see the board; anyone else sees "Not a Member". **Sign Out** on the page ends that browser session. Sign-in only ever returns to a `/teams/<id>` path on the same site.

It sits beside the public board below: the public link needs no sign-in, the members-only one needs a member's Apple ID.

## Public board

While the owner shares it, `https://<worker>/t/<token>` shows the leaderboard without sign-in: ranks, display names, spend or tokens split by provider, and the top models. Turning sharing off makes the link return 404. Turning it on again keeps the same link until it is turned off.

## API

All routes are JSON under `/v1`. Authenticated routes take `Authorization: Bearer <session token>`. Errors are `{ "error": { "code", "message" } }`; messages are safe to show to the user.

| Route | What it does |
| --- | --- |
| `GET /v1/auth/apple/start` | `?state=…&code_challenge=…` (PKCE S256). Redirects to Apple's web sign-in. See [Sign in with Apple](#sign-in-with-apple). |
| `POST /v1/auth/apple/callback` | Apple's form post. Redirects to `godusage://auth?state=…&code=…` (or `&error=cancelled\|invalid_token\|apple`). |
| `POST /v1/auth/apple/exchange` | `{ code, codeVerifier }` → `{ token, user, created }`. The code works once, for five minutes. |
| `POST /v1/auth/apple` | Native sign-in (for the iOS app): `{ identityToken, displayName? }` → `{ token, user, created }`. `displayName` is used only for a new account. |
| `POST /v1/auth/logout` | Ends this session. |
| `GET`, `PATCH`, `DELETE /v1/me` | Read, rename (`{ displayName }`, at most 40 characters), or delete the account. |
| `GET`, `POST /v1/teams` | List my teams, or create one (`{ name }`, at most 60 characters). |
| `GET`, `PATCH`, `DELETE /v1/teams/:id` | Team with members; owner can change `{ name?, publicBoard? }` or delete it. |
| `POST /v1/teams/:id/invite` | Owner rotates the invite link. |
| `DELETE /v1/teams/:id/members/:userID` | Leave (yourself) or remove a member (owner). |
| `GET /v1/teams/:id/stats` | `?range=today\|7d\|30d\|365d&sort=cost\|tokens&today=YYYY-MM-DD`. Leaderboard (with each member's previous-period rank), provider totals, top 20 models, and per-day totals by member and by provider. |
| `GET /v1/invites/:code` | Invite preview: team name, member count, `alreadyMember`. |
| `POST /v1/invites/:code/accept` | Join the team. Joining again is a no-op. |
| `GET /v1/devices` | My Macs that have uploaded usage. |
| `PUT /v1/devices/:id/usage` | Replace this Mac's usage (see below). |
| `DELETE /v1/devices/:id` | Remove a Mac and its usage. |

Upload body (`PUT /v1/devices/:id/usage`, at most 512 KB):

```json
{
  "schema": "godusage.team-usage.v1",
  "deviceName": "MacBook Pro",
  "windowStart": "2026-09-05",
  "providers": [
    {
      "provider": "claude",
      "scope": "device",
      "days": [
        {
          "date": "2026-10-05",
          "tokens": 120000,
          "costUSD": 3.2,
          "models": [{ "model": "claude-opus-4-1", "tokens": 120000, "costUSD": 3.2 }]
        }
      ]
    }
  ]
}
```

`windowStart` is the first day of the app's window; the Mac's stored days from there on are replaced. It must be within the last 40 days. Without it, the earliest day sent is used.

`costUSD` may be `null` when a model has no price. Days more than 40 days old or more than one day in the future are dropped. Anything else malformed is rejected with 400.

## Sign in with Apple

The Mac app signs in through the web, because Developer ID provisioning profiles never grant the native Sign in with Apple entitlement:

1. The app opens `/v1/auth/apple/start` in a system sign-in sheet (`ASWebAuthenticationSession`) with its own random `state` and a PKCE `code_challenge`. The Worker stores a sign-in request (10 minutes) and redirects to Apple with its own state and a nonce.
2. Apple posts the identity token to `/v1/auth/apple/callback`. The Worker checks that the request exists and has not expired (each is used once), and verifies the token: Apple's signature, issuer, expiry, audience = the Services ID (`APPLE_WEB_CLIENT_ID`), and the request's nonce. It finds or creates the account (with the name Apple shares on the first sign-in) and redirects to `godusage://auth` with a one-time code.
3. The app checks the returned `state` and posts the code with its PKCE verifier to `/v1/auth/apple/exchange`. Only the app that started the sign-in can redeem the code.

Apple setup, once: one **Services ID** per environment (Identifiers → Services IDs), each with Sign in with Apple enabled and its own Worker as domain and return URL:

| Environment | Services ID (`APPLE_WEB_CLIENT_ID`) | Primary App ID | Domain → return URL |
| --- | --- | --- | --- |
| Production | `com.montinovo.godusage.web` | `com.montinovo.godusage` | `godusage-api.federico-c80.workers.dev` → `https://godusage-api.federico-c80.workers.dev/v1/auth/apple/callback` |
| Development | `com.montinovo.godusage.web.dev` | `com.montinovo.godusage.dev` | `godusage-api-dev.federico-c80.workers.dev` → `https://godusage-api-dev.federico-c80.workers.dev/v1/auth/apple/callback` |

Apple gives a person the same user id for every app and Services ID grouped under the same primary App ID, so web and native sign-ins reach the same account.

## Development

```bash
cd backend
npm ci
npm test
```

Tests run inside the Workers runtime with a local D1 and the migrations applied. Apple is never called: tests sign identity tokens with a generated key.

`npm run dev` serves the Worker locally with a local D1. Apply the migrations to it first with `npx wrangler d1 migrations apply godusage-dev --env dev --local`.

## Environments

There are two deployments, each with its own Worker and database, so test data never reaches real leaderboards:

| | Production | Development |
| --- | --- | --- |
| Worker | `godusage-api` | `godusage-api-dev` (`https://godusage-api-dev.federico-c80.workers.dev`) |
| D1 database | `godusage` | `godusage-dev` |
| Accepted app | `com.montinovo.godusage` | `com.montinovo.godusage.dev` |
| Migrate | `npm run migrate` | `npm run migrate:dev` |
| Deploy | `npm run deploy` | `npm run deploy:dev` |

Each environment accepts Sign in with Apple tokens only from its own bundle id (`APPLE_AUDIENCES` in `wrangler.jsonc`), so a dev build cannot sign in to production.

Schema changes go in a new file in `backend/migrations/`. Apply it with the migrate command of each environment before deploying that environment. Run `npx wrangler login` once before the first remote command.

Sign in with Apple must be enabled on both App IDs.
