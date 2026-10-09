# GodUsage Teams Backend

Teams, invites, and leaderboards: a Node server on Postgres and Redis, run by Coolify from `docker-compose.yml`, with a small proxy Worker (`proxy/`) keeping the `workers.dev` hosts the apps call.

| Path | What it is |
| --- | --- |
| `src/` | The routes and the leaderboard logic |
| `server/` | The Node server: HTTP, Postgres (`pg`), Redis, migrations, the D1 import |
| `migrations/` | Postgres schema, applied at startup |
| `d1-migrations/` | The old D1 schema history (frozen), for reading D1 exports |
| `proxy/` | The Cloudflare Worker that forwards the `workers.dev` hosts to Coolify |
| `docker-compose.yml` | The Coolify stack: api, postgres, redis |

```bash
npm ci
npm run test:services   # Postgres and Redis for the tests, in Docker
npm test
```

Setup, environment variables, and the D1 → Postgres runbook: [docs/teams-backend.md](../docs/teams-backend.md).
