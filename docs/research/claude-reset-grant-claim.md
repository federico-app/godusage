# Claude Usage-Limit Reset Grants: How Claiming Works

Protocol reference for claiming one of Anthropic's `cedar_ember` usage-limit reset grants. GodUsage claims from the resets popover (`Sources/GodUsage/Providers/Claude/ClaudeProvider+ResetClaim.swift`). Ported from upstream OpenUsage 0.7.16 (#1413), whose research is the source for this page. GodUsage itself has not sent a live claim; its tests use mocked HTTP only.

Sources: strings in the Claude Code binary and several public projects that send the same request (for example `lidge-jun/opencodex` `src/providers/anthropic-reset-grants.ts`). Those projects test with mocks only. The live answers below are upstream's.

## Reading grants

`GET https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1` returns a `cedar_ember` block:

```json
{
  "eligible": true, "ineligible_reason": null, "at_limit": false,
  "grants": [
    { "id": "opus55-launch-promax-20260921", "resets_total": 1, "resets_left": 1,
      "starts_at": "2026-09-22T16:00:00+00:00", "ends_at": "2026-10-22T16:00:00+00:00",
      "clears": ["five_hour", "seven_day"], "paused": false, "usable_now": true,
      "use_requires_limit": false }
  ],
  "next_grant_id": "opus55-launch-promax-20260921",
  "cooldown_until": null
}
```

Anthropic decides eligibility by client surface. A User-Agent it doesn't recognize as Claude Code comes back `eligible: false, ineligible_reason: "surface"`. GodUsage rejects the whole block when a grant is malformed (no string `id` or numeric `resets_left`), like Claude Code does. GodUsage reads this at most once an hour per login (see [Claude](../providers/claude.md)).

## Claiming

`POST https://api.anthropic.com/api/organizations/{orgUUID}/reset_rate_limits`

Headers: `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-cli/<version> (external, cli)`, `Content-Type: application/json`. Timeout 25s.

```json
{ "program": "cedar_ember", "grant_id": "<next_grant_id>", "request_id": "<stable per claim>" }
```

- `orgUUID` is `organization.uuid` from `GET /api/oauth/profile` for the same token. GodUsage reuses the profile its account check already read for that token, and refuses a token whose account isn't the card's.
- `grant_id` matches `^[a-z0-9_-]{1,40}$`. GodUsage always sends `next_grant_id`.
- `request_id` matches `^[A-Za-z0-9_-]{1,64}$`. The popover mints one UUID per node and reuses it for every retry. If an answer never settles (transport error, 5xx, unreadable body, or `reset_unconfirmed`), the provider keeps that id for the grant and reuses it even when the popover was reopened, so a retry can't spend twice.
- Only the login the grants were read with may claim. Grant ids are shared promos, so another login could hold the same id.
- Claude Code refreshes OAuth before claiming. GodUsage only renews an already-expired token, through the same guarded renewal a refresh uses.

Response: `{ result, reason, resets_left, cleared, weekly_resets_at, cooldown_until }`.

| `result` / `reason` | Meaning | GodUsage outcome |
|---|---|---|
| `reset` | Limits cleared | Success |
| `already_used` | This request id already spent the grant | Success |
| `not_limited` | Nothing to reset; nothing spent | Nothing to reset |
| `ineligible`; `unavailable` + `no_grant` / `unknown_grant` / `not_next_grant` | Refused; nothing spent | No longer available |
| `reset_unconfirmed`, `stamp_indeterminate` | May still be going through | Unconfirmed |
| `cooldown`; `unavailable` + `paused` / `low_priority_active` | Can't be used right now | Unavailable now (with `cooldown_until`) |
| `not_authorized`, `no_profile_scope`, `grant_id_required`, anything else, non-2xx | Error | Failed |

After Success or Unconfirmed, GodUsage drops its hourly grants answer, the cached usage, and any 429 cooldown, then forces a refresh of that card. After No longer available it drops only the grants answer. A refused claim (Nothing to reset, Unavailable now) leaves the caches alone. A Failed claim is never retried automatically.

## Upstream verification

1. A dry run with `grant_id: "openusage-dryrun-probe"` (matches no grant) against an account holding one unspent grant. The server validated `grant_id` and spent nothing:

   ```json
   {"result":"ineligible","reason":"unknown_grant","reset":false,"grant_id":"openusage-dryrun-probe",
    "resets_left":null,"cleared":[],"weekly_resets_at":null,"cooldown_until":null}
   ```

   An unknown grant comes back as `result: "ineligible"`, not `unavailable`. Both map to "no longer available".
2. A real claim with an anytime grant while not at a limit. HTTP 200:

   ```json
   {"result":"reset","reason":null,"reset":true,"grant_id":"opus55-launch-promax-20260921","resets_left":0,
    "cleared":["five_hour","seven_day","seven_day_overage_included"],
    "weekly_resets_at":"2026-10-20T20:00:00+00:00","cooldown_until":"2026-10-18T11:56:45.910978+00:00"}
   ```

   A successful claim also starts a short `cooldown_until`, about two minutes here. `cooldown_until` carries fractional seconds.

GodUsage's mocked tests: `Tests/GodUsageTests/ClaudeResetClaimTests.swift`.
