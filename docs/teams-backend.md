# Teams Backend

The teams backend lets people create a team, invite friends with a link, and compare their AI usage on a leaderboard. It lives in `backend/`: a Node server on Postgres and Redis, run by Coolify on our own server from `backend/docker-compose.yml`. The apps call it on its own domain (`api.godusage.com`, `api-dev.godusage.com`); a small Cloudflare Worker keeps the `workers.dev` hosts that apps before 1.1.0 call. The Mac app is its only writer. A shared team can also be viewed as a read-only web page.

## Architecture

```
app 1.1.0+ ──────────────────────────────────────────────────▶ api[-dev].godusage.com (Coolify)
app before 1.1.0 ──▶ godusage-api[-dev].…workers.dev ──────────▶        │
                     (proxy Worker, backend/proxy/:                     ▼
                      adds the public host and client IP)     api (backend/server/, Node) ──▶ postgres (data)
                                                                                         └──▶ redis (cache, rate limits)
```

- **api** (`backend/Dockerfile`): the routes in `backend/src/` behind a Node HTTP server (`server/main.ts`). It applies pending Postgres migrations at startup.
- **postgres**: all data (accounts, sessions, teams, usage). The schema is in `backend/migrations/`.
- **redis**: computed boards and rate-limit counters only. Losing it loses nothing: the next requests recompute.
- **proxy Worker** (`backend/proxy/`): apps before 1.1.0 call the `workers.dev` hosts, which cannot point at another server, so the Workers that used to run the backend now forward to Coolify. See [Proxy Worker](#proxy-worker).

The backend used to run as a Cloudflare Worker on D1. D1's free plan (5M rows read a day) cut production off, so it moved; the D1 schema history stays in `backend/d1-migrations/` for reading D1 exports.

## What it stores

- **Accounts:** the Sign in with Apple user id (`sub`) and a display name the user chooses. No email, no Apple name.
- **Sessions:** only the SHA-256 hash of each session token. A session expires after 180 days without use.
- **Teams:** name, the account whose deletion deletes the team (`owner_id`, always one of its owners), one invite code, and an optional public-board token. Roles (`owner` or `member`) live on each membership; a team can have several owners.
- **Usage:** for each of the user's Macs, daily tokens and spend per provider and per model. The full history is kept: each upload replaces only the days in its window. No credentials, logs, prompts, project names, or account ids.

Deleting an account deletes its sessions, Macs, usage, memberships, and the teams it owns.

## How usage is combined

Each Mac uploads its own last 30 days. A full upload replaces that Mac's days from its `windowStart` on (all of them, so a provider turned off disappears from those days) and keeps older days, so history builds up beyond the app's window. The server writes only what changed: rows the upload no longer has are deleted, changed rows are updated, and identical rows are left alone. Most uploads repeat the last one except for today. After its first upload, the app sends **partial** uploads (see [API](#api)) with only the provider-days that changed, so the server reads and rewrites a day or two instead of the whole window. Signing out of a Mac removes all of that Mac's days. Every provider entry has a scope:

- **device:** usage read from this Mac's own logs (Claude, Codex, Grok, and so on). A user's Macs are summed.
- **account:** usage that is already account-wide (Cursor). Only the Mac that uploaded most recently counts, so it is never double counted.

An account entry may carry `account`, an anonymous fingerprint of the provider account (a SHA-256 hex hash made on the Mac). A fingerprint that two or more of a team's members uploaded is a **shared account**: one seat several people log into. Its usage counts once (the newest upload from any member wins) in the team's totals, providers, days, and models, and in no member's totals, ranks, challenges, or Hall of Fame. Stats list it in `shared`: `{ provider, tokens, costUSD, members: [userID] }`. A fingerprint only one member uploaded stays theirs.

The server keeps a small list of which fingerprints each user has uploaded, so finding shared accounts doesn't read anyone's usage history.

This mirrors how [iCloud Sync](icloud-sync.md) combines Macs.

## Caching

The app fetches stats on every popover open, every two minutes while it stays open, and after uploads, so computed results are kept in Redis per team (`src/teamCache.ts`): stats, challenges, plan reports, and champions.

- A result is reused for a minimum time even when the team's usage changed meanwhile: 5 minutes for Today and challenges, 10 for everything else.
- After that, it is reused while the team's usage has not changed. Every upload that changes stored usage bumps the uploader's teams' stats version.
- No result is ever served once it is 10 minutes old.
- Changes to members, names, plans, challenges, and removed Macs drop the team's cached results, so they show at once.

`computedAt` in the stats response says when the stats were computed. Leaderboard queries read only the days in their period (from covering indexes), and the year board never reads a second year. Combining Macs, accounts, and shared accounts happens in `src/teamUsage.ts`.

There is no daily read budget any more: it guarded D1's free-plan limit, and our own server has no per-row bill. Responses no longer carry `paused` (the apps treat a missing `paused` as false).

Day keys are each Mac's local calendar days. A stats request can pass the viewer's local `today` as the period's last day; the server accepts up to one day ahead of the UTC date and up to 400 days back (for last week's recap or a past month or year), and uses the UTC date otherwise. Ranges are Today, 7 Days, 30 Days, Year (365 days), and Month to Date (`mtd`: from the 1st to today, compared with the same days of the month before). Members are ranked by spend or by tokens; tied members share a rank. Each member carries `lastSyncAt`, the newest upload time across their Macs (ISO 8601, or null if none has uploaded); the apps and web boards show it as "updated 5m ago", then "not synced for N days" once it is more than 24 hours old. Each member also carries `appVersion`, the GodUsage version of that newest upload (null from apps before 1.0.8), shown after it as "· v1.0.8". Each member also carries `previous`, their rank and totals in the period just before (or null if they had no usage then), for the movement arrows.

## Reactions, champions, and challenges

- **Reactions:** a member can give each teammate 🔥 (`fire`), 👏 (`clap`), and 🤡 (`clown`), one of each per day. Reactions belong to the UTC day they were given in, so every day starts clean at midnight UTC. Nobody can react to themselves.
- **Champions:** the stats response lists the top spender of each of the last 12 complete calendar months among current members (the current month never counts until it is over). The server reuses a team's champions for up to 10 minutes, and recomputes them when its members change.
- **Challenges:** any member starts one for 7, 14, or 30 days, from today. Kinds: `lowest_spend` (least spend among members who spent anything), `most_models` (most different models), `most_tokens`, and `best_efficiency` (lowest cost per million tokens, with at least 100K tokens). Standings update live from usage in the window; once it has ended, the leaders are the winners. A team runs at most five at once. The creator or an owner can cancel one.

## Invites and roles

- Every member can see the invite link: `https://<host>/join/<code>`, on the host the app called. The page shows the team name and member count, an **Open in GodUsage** button (`godusage://join/<code>`), and a download link.
- Only owners can rotate the link (the old one stops working), rename the team, change roles, remove members, share or unshare the public board, edit plans, and delete the team.
- Anyone can leave. A team always keeps at least one owner: the last owner can neither leave nor be made a member (409). When the account behind `owner_id` leaves or is made a member, `owner_id` moves to the earliest-joined remaining owner.
- Deleting an account deletes the teams where it is the only owner. Teams with another owner stay.
- Limits: 50 members per team, 20 teams per user.

## Rate limits

Sign-in routes (`/v1/auth/*`, `/teams/<id>/sign-in`) allow 20 requests a minute per IP. Every other `/v1` route allows 120 a minute per session, or per IP without one. The board and invite pages (`/t/<token>`, `/teams/<id>`, `/join/<code>`) allow 30 a minute per IP, since each board view computes stats; other pages are not limited. Over the limit the server answers 429 with `Retry-After: 60` (pages as an HTML page). The limits are fixed one-minute windows counted in Redis (`src/rateLimit.ts`), so every replica shares them. The client's IP is the one the proxy Worker sends, or for direct requests the last `X-Forwarded-For` entry (the one Coolify's reverse proxy added).

## Privacy policy and terms

The server serves `/privacy` and `/terms`, linked from every page and from the app's sign-in. Keep them in step with what the service stores (this page) and with [Privacy](privacy.md).

## Members-only board

Every member can open `https://<host>/teams/<team id>` in a browser (the app's **Web Leaderboard** link). Visitors who are not signed in see **Sign In with Apple**, which runs the same web sign-in as the app (`/teams/<id>/sign-in`) and comes back to the board. The browser then keeps a 30-day session in a `HttpOnly`, `Secure`, `SameSite=Lax` cookie. Only members see the board; anyone else sees "Not a Member". **Sign Out** on the page ends that browser session. Sign-in only ever returns to a `/teams/<id>` path on the same site.

Both boards show the same extras as the app: 👑 for today's top spender, 🏆 for last month's champion, today's reactions, the team's month-end projection, challenges, and the Hall of Fame.

It sits beside the public board below: the public link needs no sign-in, the members-only one needs a member's Apple ID.

## Public board

While an owner shares it, `https://<host>/t/<token>` shows the leaderboard without sign-in: ranks, display names, spend or tokens split by provider, and the top models. Turning sharing off makes the link return 404. Turning it on again keeps the same link until it is turned off.

## API

All routes are JSON under `/v1`. Authenticated routes take `Authorization: Bearer <session token>`. Errors are `{ "error": { "code", "message" } }`; messages are safe to show to the user.

| Route | What it does |
| --- | --- |
| `GET /v1/auth/apple/start` | `?state=…&code_challenge=…` (PKCE S256). Redirects to Apple's web sign-in. See [Sign in with Apple](#sign-in-with-apple). |
| `POST /v1/auth/apple/callback` | Apple's form post. Redirects to `godusage://auth?state=…&code=…` (or `&error=cancelled\|invalid_token\|apple`). |
| `POST /v1/auth/apple/exchange` | `{ code, codeVerifier }` → `{ token, user, created }`. The code works once, for five minutes. |
| `POST /v1/auth/apple` | Native sign-in (for the iOS app): `{ identityToken, displayName? }` → `{ token, user, created }`. `displayName` is used only for a new account. |
| `POST /v1/auth/logout` | Ends this session. |
| `GET /v1/me/export` | Everything the server keeps about you, as one JSON document (the app's **Export My Data**). Session tokens are never included. |
| `GET`, `PATCH`, `DELETE /v1/me` | Read, rename (`{ displayName }`, at most 40 characters), or delete the account. |
| `GET`, `POST /v1/teams` | List my teams, or create one (`{ name }`, at most 60 characters). |
| `GET`, `PATCH`, `DELETE /v1/teams/:id` | Team with members; owner can change `{ name?, publicBoard? }` or delete it. |
| `POST /v1/teams/:id/invite` | Owner rotates the invite link. |
| `PATCH /v1/teams/:id/members/:userID` | Owner sets `{ role: "owner" \| "member" }`. |
| `DELETE /v1/teams/:id/members/:userID` | Leave (yourself) or remove a member (owner). |
| `GET /v1/teams/:id/stats` | `?range=today\|7d\|30d\|365d\|mtd&sort=cost\|tokens&today=YYYY-MM-DD&include=today,mtd`. Leaderboard (with each member's previous-period rank, except for Year), provider totals, top 20 models, per-day totals by member and by provider, today's `reactions` (`day` is the UTC day; `week` repeats it for older apps), and the last 12 months' `champions`. `include` adds the Today and Month to Date spend boards in `extra`, so the app needs one request instead of three. `computedAt` says when the stats were computed (see [Caching](#caching)). |
| `PUT`, `DELETE /v1/teams/:id/members/:userID/reactions/:emoji` | Give or take back `fire`, `clap`, or `clown` for today (UTC). |
| `GET`, `POST /v1/teams/:id/challenges` | List active challenges and the last five finished (with standings and winners), or start one (`{ kind, days, today? }`). |
| `DELETE /v1/teams/:id/challenges/:challengeID` | Cancel a challenge (creator or owner). |
| `GET /v1/invites/:code` | Invite preview: team name, member count, `alreadyMember`. |
| `POST /v1/invites/:code/accept` | Join the team. Joining again is a no-op. |
| `GET /v1/devices` | My Macs that have uploaded usage. |
| `PUT /v1/devices/:id/usage` | Replace this Mac's usage (see below). The response carries `partialUploads: true`; the app sends partial uploads only to a server that says so. |
| `DELETE /v1/devices/:id` | Remove a Mac and its usage. |

Upload body (`PUT /v1/devices/:id/usage`, at most 512 KB):

```json
{
  "schema": "godusage.team-usage.v1",
  "deviceName": "MacBook Pro",
  "appVersion": "1.0.8",
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

Plans (`GET /v1/teams/:id/plans?today=` for members, `PUT` with `{ plans: [{ provider, name, monthlyCostUSD, renewalDay, memberIDs }] }` for the owner, replacing the list, at most 30): `memberIDs` lists the team members the plan covers, and a missing or null value covers everyone. The response carries each plan with its `memberIDs`, `includesYou` (whether it covers the caller), its `cycle` (`from`, `to`, `daysElapsed`, `daysTotal`, `daysLeft`), `valueUSD` (the covered members' effective spend on the provider from `cycle.from` to today, shared accounts once and counted when any member who shares them is covered, split by cost across the plans of one provider that cover the same usage), `projectedValueUSD`, `projectedMultiple`, and `underused` (projected under 1×), plus `totals` and `canEdit`.

Account-scope entries may add `"account": "<64 hex characters>"`; it is rejected on device scope.

`appVersion` is optional (letters, digits, `.`, `+`, `-`, at most 32 characters); the Mac it came from keeps it until its next upload.

`windowStart` is the first day of the app's window; the Mac's stored days from there on are replaced. It must be within the last 40 days. Without it, the earliest day sent is used.

`"partial": true` (without `windowStart`) marks a partial upload: it carries only the provider-days that changed since the Mac's last upload. Each provider-day it carries is replaced whole, models included, and every other stored day is kept. The app sends a full upload instead after launch, when you sign in or join a team, and whenever a provider-day in the window disappeared (a provider turned off) or a provider changed scope or account.

`costUSD` may be `null` when a model has no price. Days more than 40 days old or more than one day in the future are dropped. Anything else malformed is rejected with 400.

## Sign in with Apple

The Mac app signs in through the web, because Developer ID provisioning profiles never grant the native Sign in with Apple entitlement:

1. The app opens `/v1/auth/apple/start` in a system sign-in sheet (`ASWebAuthenticationSession`) with its own random `state` and a PKCE `code_challenge`. The server stores a sign-in request (10 minutes) and redirects to Apple with its own state and a nonce.
2. Apple posts the identity token to `/v1/auth/apple/callback`. The server checks that the request exists and has not expired (each is used once), and verifies the token: Apple's signature, issuer, expiry, audience = the Services ID (`APPLE_WEB_CLIENT_ID`), and the request's nonce. It finds or creates the account (with the name Apple shares on the first sign-in) and redirects to `godusage://auth` with a one-time code.
3. The app checks the returned `state` and posts the code with its PKCE verifier to `/v1/auth/apple/exchange`. Only the app that started the sign-in can redeem the code.

Apple setup, once: one **Services ID** per environment (Identifiers → Services IDs), each with Sign in with Apple enabled and both of its hosts as domains and return URLs. The server builds the `redirect_uri` on the host the app called: the Coolify domain for apps from 1.1.0, the `workers.dev` host (through the proxy Worker, which tells the server the public host) for older apps:

| Environment | Services ID (`APPLE_WEB_CLIENT_ID`) | Primary App ID | Domain → return URL |
| --- | --- | --- | --- |
| Production | `com.montinovo.godusage.web` | `com.montinovo.godusage` | `api.godusage.com` → `https://api.godusage.com/v1/auth/apple/callback`; `godusage-api.federico-c80.workers.dev` → `https://godusage-api.federico-c80.workers.dev/v1/auth/apple/callback` |
| Development | `com.montinovo.godusage.web.dev` | `com.montinovo.godusage.dev` | `api-dev.godusage.com` → `https://api-dev.godusage.com/v1/auth/apple/callback`; `godusage-api-dev.federico-c80.workers.dev` → `https://godusage-api-dev.federico-c80.workers.dev/v1/auth/apple/callback` |

Apple gives a person the same user id for every app and Services ID grouped under the same primary App ID, so web and native sign-ins reach the same account.

## Development

```bash
cd backend
npm ci
npm run test:services   # Postgres and Redis in Docker (docker-compose.test.yml), on ports 55432 and 56379
npm test
npm run typecheck
```

The suite runs against real Postgres and Redis. Each test file gets its own Postgres schema with the migrations applied and its own Redis key prefix, so files run in parallel. `TEST_DATABASE_URL` and `TEST_REDIS_URL` point it elsewhere; CI uses service containers. Apple is never called: tests sign identity tokens with a generated key. `npm run test:services:down` removes the containers.

To run the whole stack as Coolify does, copy `.env.local.example` to `.env.local` and run `docker compose --env-file .env.local -f docker-compose.yml -f docker-compose.local.yml up --build`. The api answers on `http://127.0.0.1:8787`.

Schema changes go in a new numbered file in `backend/migrations/` (Postgres SQL). The server applies pending files at startup, each in its own transaction, recorded in `schema_migrations`; an advisory lock keeps replicas from applying one twice. Never edit a file that has shipped. `backend/d1-migrations/` is frozen.

The routes run SQL through a small interface (`src/db.ts`: `query`, `first`, `run`, and `transaction`), implemented on the `pg` driver in `server/postgres.ts`. Several writes that belong together run in one `transaction`. BIGINT and NUMERIC values come back as JS numbers. Timestamps and days are ISO 8601 text, as on D1.

## Environments

There are two deployments, each with its own Coolify resource, database, and Redis, so test data never reaches real leaderboards:

| | Production | Development |
| --- | --- | --- |
| App host (1.1.0+) | `api.godusage.com` | `api-dev.godusage.com` |
| Older apps (proxy Worker) | `godusage-api.federico-c80.workers.dev` | `godusage-api-dev.federico-c80.workers.dev` |
| Coolify resource | follows `main` | follows `develop` |
| Accepted app | `com.montinovo.godusage` | `com.montinovo.godusage.dev` |

Each environment accepts Sign in with Apple tokens only from its own bundle id (`APPLE_AUDIENCES`), so a dev build cannot sign in to production. Sign in with Apple must be enabled on both App IDs.

## Coolify setup

Do this once per environment (production, then development the same way):

1. **New resource:** Projects → your project → the environment → **+ New** → **Public Repository** (or a GitHub App source for the private repo) → this repository.
2. **Build pack:** **Docker Compose**. Branch: `main` for production, `develop` for development. **Base Directory:** `/backend`. **Docker Compose Location:** `/docker-compose.yml`.
3. **Domain:** under the `api` service, set the domain with the container port, e.g. `https://api.godusage.com:8787` (production) or `https://api-dev.godusage.com:8787` (development). Coolify routes it to port 8787 and gets the certificate. Point the DNS record at the server first. `postgres` and `redis` get no domain and publish no port.
4. **Environment variables** (Configuration → Environment Variables):

   | Variable | Production | Development | Notes |
   | --- | --- | --- | --- |
   | `APPLE_AUDIENCES` | `com.montinovo.godusage` | `com.montinovo.godusage.dev` | Required |
   | `APPLE_WEB_CLIENT_ID` | `com.montinovo.godusage.web` | `com.montinovo.godusage.web.dev` | Required |
   | `DOWNLOAD_URL` | optional | optional | Defaults to the latest GitHub release |
   | `SERVICE_USER_POSTGRES`, `SERVICE_PASSWORD_POSTGRES`, `SERVICE_PASSWORD_REDIS` | generated | generated | Coolify creates them on the first deploy; leave them |
   | `SERVICE_PASSWORD_64_PROXY` | generated | generated | The api's `PROXY_SECRET`. Copy it into the GitHub secret for the proxy (below) |
   | `SERVICE_URL_API_8787` | set by the domain | set by the domain | |

5. **Deploy.** Coolify builds the image, starts Postgres and Redis, waits for their health checks, then starts the api (its own health check is `GET /v1/health`, which answers only while Postgres and Redis do). The api logs `migration_applied` and `listening`.
6. **Auto deploy:** keep **Auto Deploy** on (Coolify's GitHub webhook or app), so pushes to the branch redeploy the api. Migrations run at startup.
7. **Backups:** turn on scheduled backups for the `postgres` service (Coolify → the service → Backups). Redis needs none.
8. **Check:** `curl https://<domain>/v1/health` answers `{"ok":true}`.

The api's environment, for reference: `DATABASE_URL` and `REDIS_URL` are built from the generated credentials in `docker-compose.yml`; `PROXY_SECRET` makes it trust the proxy Worker's headers; `PORT` is 8787.

## Proxy Worker

`backend/proxy/` is a Worker with the old Workers' names (`godusage-api`, and `godusage-api-dev` with `--env dev`), so deploying it replaces the D1 Worker on the same hosts and apps before 1.1.0 keep working unchanged. It forwards every request (method, path, query, headers, body) to `ORIGIN_URL`, the environment's Coolify domain, and returns the response as it is (redirects and cookies too). It has no bindings.

The server builds public links from the request host: Sign in with Apple's `redirect_uri` (which Apple only accepts on the hosts registered on the Services ID), invite links, and board links. The Worker sends the host the client called and the client's IP in `x-godusage-public-host` and `x-godusage-client-ip`, with `x-godusage-proxy-secret` set to the api's `PROXY_SECRET`. Coolify's reverse proxy rewrites the standard `X-Forwarded-*` headers, so these have their own names. The server uses them only when the secret matches, and refuses a request whose secret doesn't (403, logged as `proxy_rejected`). Requests straight to the Coolify domain use its own host.

**Deploy** with **Deploy Backend Proxy** (`.github/workflows/backend-deploy.yml`). It needs, in the repository settings, the variable `BACKEND_ORIGIN_URL` (production) or `BACKEND_DEV_ORIGIN_URL` (development) set to the Coolify domain (`https://api.godusage.com`, without the port), the secret `BACKEND_PROXY_SECRET` or `BACKEND_DEV_PROXY_SECRET` set to that environment's `SERVICE_PASSWORD_64_PROXY`, and `CLOUDFLARE_API_TOKEN`. It checks the Coolify server answers, sets the Worker's `PROXY_SECRET` secret, deploys with `ORIGIN_URL`, and checks the `workers.dev` host answers. A push to `develop` that changes `backend/proxy/` deploys the dev proxy; a stable release tag deploys production; either can be run by hand. Without the variable or secret it fails and deploys nothing.

`npm run dev` in `backend/proxy/` runs the Worker locally in front of a server on `127.0.0.1:8787`.

**Limits:** the Workers free plan allows 100,000 requests a day per account, shared by both proxies. Only apps before 1.1.0 use them, so traffic falls as people update. Retire the proxies once those versions are gone; invite and board links shared from old apps point at the `workers.dev` hosts and stop working then.

## Moving from D1 to Coolify

Do one environment at a time, development first. Sessions, teams, and invite codes move with the data, so nobody signs in again.

1. **Deploy the Coolify stack** for the environment ([Coolify setup](#coolify-setup)) and check `https://<domain>/v1/health`. Don't sign in to it yet: the import wants an empty database.
2. **Export D1:** run **Export Backend Database** (`.github/workflows/backend-export.yml`) for the environment and download the SQL artifact. From here until step 5, uploads and new sign-ins still land on D1; do the next steps without a long pause (anything written to D1 after the export is not moved).
3. **Import:** copy the file to the server and load it into the api container, which applies migrations and copies every table in one transaction:

   ```bash
   scp godusage-prod.sql root@<server>:/tmp/
   ssh root@<server>
   docker exec -i $(docker ps -qf name=api- | head -1) node server.mjs import-d1 - < /tmp/godusage-prod.sql
   ```

   With several Coolify resources on the server, pick the api container by its resource name (`docker ps --format '{{.Names}}' | grep api`). Coolify's terminal on the api container works too, with a path instead of `-`. It logs each table's row count and refuses a database that already has data (pending sign-ins excepted). The D1 caches (`stats_cache`, `team_champions`, `read_budget`) and `teams.stats_version` are left behind.
4. **Verify against the Coolify domain:** `curl -H "Authorization: Bearer <a session token>" https://<domain>/v1/teams` (a token from the Mac app's session file, or a fresh sign-in on the dev build pointed at the domain), compare a board with what the app showed, and open `https://<domain>/join/<an invite code>`.
5. **Deploy the proxy Worker:** set the repository variable and secret ([Proxy Worker](#proxy-worker)), then run **Deploy Backend Proxy** for the environment. From now on the `workers.dev` host serves Coolify.
6. **Verify the app:** open the app (the dev build for development): the leaderboard loads, an upload succeeds (Settings → Teams shows the last upload), Sign in with Apple completes in the web sheet, and an invite link opens. `https://<workers.dev host>/v1/health` answers through the proxy, for older apps.
7. **Keep D1 as a backup** for a few weeks: the deploy removed the Worker's D1 binding, but the database and its Time Travel history stay. Delete it (`wrangler d1 delete`) only once the Coolify backups are proven.

To roll back before step 5, nothing changed for the apps. After step 5, redeploy the old D1 Worker from the last commit before this change (`git checkout <commit> -- backend` and `wrangler deploy`): it still has its database, without the writes made on Coolify since.
