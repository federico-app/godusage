# Teams Backend

The teams backend lets people create a team, invite friends with a link, and compare their AI usage on a leaderboard. It is a Cloudflare Worker with a D1 database, in `backend/`. The Mac app is its only writer. A shared team can also be viewed as a read-only web page.

## What it stores

- **Accounts:** the Sign in with Apple user id (`sub`) and a display name the user chooses. No email, no Apple name.
- **Sessions:** only the SHA-256 hash of each session token. A session expires after 180 days without use.
- **Teams:** name, owner, one invite code, and an optional public-board token.
- **Usage:** for each of the user's Macs, daily tokens and spend per provider and per model, for the last 30 days. No credentials, logs, prompts, project names, or account ids.

Deleting an account deletes its sessions, Macs, usage, memberships, and the teams it owns.

## How usage is combined

Each Mac uploads its own window, which replaces everything that Mac uploaded before. Every provider entry has a scope:

- **device:** usage read from this Mac's own logs (Claude, Codex, Grok, and so on). A user's Macs are summed.
- **account:** usage that is already account-wide (Cursor). Only the Mac that uploaded most recently counts, so it is never double counted.

This mirrors how [iCloud Sync](icloud-sync.md) combines Macs.

Day keys are each Mac's local calendar days. A stats request can pass the viewer's local `today`; the server accepts it if it is within one day of the UTC date and uses the UTC date otherwise. Ranges are Today, 7 Days, and 30 Days. Members are ranked by spend or by tokens; tied members share a rank.

## Invites and roles

- Every member can see the invite link: `https://<worker>/join/<code>`. The page shows the team name and member count, an **Open in GodUsage** button (`godusage://join/<code>`), and a download link.
- Only the owner can rotate the link (the old one stops working), rename the team, remove members, share or unshare the public board, and delete the team.
- A member can leave. The owner cannot leave; they delete the team instead.
- Limits: 50 members per team, 20 teams per user.

## Public board

While the owner shares it, `https://<worker>/t/<token>` shows the leaderboard without sign-in: ranks, display names, spend or tokens split by provider, and the top models. Turning sharing off makes the link return 404. Turning it on again keeps the same link until it is turned off.

## API

All routes are JSON under `/v1`. Authenticated routes take `Authorization: Bearer <session token>`. Errors are `{ "error": { "code", "message" } }`; messages are safe to show to the user.

| Route | What it does |
| --- | --- |
| `POST /v1/auth/apple` | `{ identityToken, displayName? }` → `{ token, user, created }`. `displayName` is used only for a new account. |
| `POST /v1/auth/logout` | Ends this session. |
| `GET`, `PATCH`, `DELETE /v1/me` | Read, rename (`{ displayName }`, at most 40 characters), or delete the account. |
| `GET`, `POST /v1/teams` | List my teams, or create one (`{ name }`, at most 60 characters). |
| `GET`, `PATCH`, `DELETE /v1/teams/:id` | Team with members; owner can change `{ name?, publicBoard? }` or delete it. |
| `POST /v1/teams/:id/invite` | Owner rotates the invite link. |
| `DELETE /v1/teams/:id/members/:userID` | Leave (yourself) or remove a member (owner). |
| `GET /v1/teams/:id/stats` | `?range=today\|7d\|30d&sort=cost\|tokens&today=YYYY-MM-DD`. Leaderboard, provider totals, top 20 models, and per-day totals. |
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

`costUSD` may be `null` when a model has no price. Days more than 40 days old or more than one day in the future are dropped. Anything else malformed is rejected with 400.

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
