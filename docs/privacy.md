# Privacy

GodUsage collects no product analytics or usage statistics. It has no analytics or crash-reporting service, creates no analytics identifier, and sends no app-use events, refresh summaries, error categories, or crash reports.

On the first launch after upgrading from a version that included analytics, GodUsage deletes the retired analytics identifier and counters that version stored locally.

Provider usage stays on your Mac except for the network requests needed to read each provider's limits, and the optional services described below (iCloud Sync and Teams), which you can turn off.

## Credentials stored on this Mac

GodUsage reads credentials that provider tools already keep on your Mac.

- **Codex, Cursor, Copilot, Muse:** read-only. GodUsage never refreshes these logins and never writes their Keychain items, databases, or credential files. Each tool owns its own login and token rotation.
- **Claude Code:** GodUsage never writes Claude Code's Keychain item or `.credentials.json` except in one guarded case. When a stored token has already been expired for a while, so no live Claude Code session can be mid-rotation, GodUsage renews it and writes the rotated credential back to the same store, keeping one token chain. See [Claude](providers/claude.md) for the rules and the switch that turns this off.
- **Claude Desktop:** read-only. GodUsage can ask macOS for permission to use the `Claude Safe Storage` Keychain item so it can decrypt Desktop's current access token. It never uses Desktop's refresh token and never modifies Desktop's config, cookies, or Keychain data.
- **Grok and Kimi:** GodUsage refreshes these tokens and saves them back to the same credential files their CLIs use, replacing each file atomically and restricting it to your macOS account (owner read and write only).
- **Antigravity:** the access token is refreshed through Google OAuth (Google refresh tokens do not rotate) and cached in GodUsage's own file, never written back to Antigravity's Keychain item. The cache is tied to the current Keychain login by a one-way fingerprint and is never used after logout, an account change, or while Keychain access is unavailable.
- **Muse Code:** GodUsage reads the Meta developer dashboard’s teams and subscription-quota JSON APIs with its existing browser session cookie from Chrome, Arc, Brave, Edge, or Firefox. Firefox cookie databases are read-only and require no Keychain access. Browser cookies stay in memory and are sent only to HTTPS `dev.meta.ai`; the Muse CLI login is not read, and no API keys are minted or model calls made.

## Other network requests

Besides the provider API calls, GodUsage fetches public [model price lists](pricing.md) about once an hour from `raw.githubusercontent.com`, `models.dev`, and this project's GitHub Pages. These are plain downloads of public data and carry no usage, log, or account information. Spend tiles are computed from local CLI logs on your Mac. No log data leaves it.

Release builds also check the signed update feed. See [Updates](updates.md).

## Local usage cache

To avoid re-reading unchanged Claude, Codex, Grok, Muse, and pi logs after every relaunch, GodUsage keeps parsed usage events in `~/Library/Application Support/GodUsage/log-scan-cache/`. These records hold the usage metadata needed for local totals, including any per-event cost a provider recorded, but not raw JSONL lines or conversation text.

The cache is private to your macOS account and is never sent to a provider or iCloud. GodUsage drops old source-file records as the scan window advances and removes identity caches unused for 35 days. Pricing runs after the cache is read, so computed totals are not stored in it.

## iCloud Sync

iCloud Sync is on by default. You can turn it off in Settings. With [iCloud Sync](icloud-sync.md) on, GodUsage writes normalized daily tokens, spend, and model totals to its private CloudKit database, plus each device's latest rendered usage snapshot (current quotas, plans, balances, and refresh errors). Your own devices use this data to show one combined summary and live usage. It stays inside your iCloud account and is never visible to GodUsage's developers or any provider. Credentials, raw provider responses, and raw logs are never written there. Turning sync off deletes this device's record from iCloud.

## Teams

Teams are off until you sign in with Apple. While you are signed in and in a team, each Mac uploads its own daily tokens and spend per provider and per model for the last 30 days to the GodUsage teams server (run on our own server, behind Cloudflare), and your teammates can see them with your display name. For Cursor, whose usage is per account, each Mac also sends a one-way hash of the Cursor account so a team can count an account several members share once. Account ids, credentials, logs, prompts, and project names are never uploaded, and the server never receives your email. The session token is kept in a private file in GodUsage's Application Support folder, readable only by your macOS account. The service's own [privacy policy](https://godusage-api.federico-c80.workers.dev/privacy) and [terms](https://godusage-api.federico-c80.workers.dev/terms) cover it in full; **Export My Data** in Settings → Teams downloads everything it keeps about you. The server keeps the history each Mac shares until that Mac signs out (which removes all of its days) or the account is deleted. See [Teams](teams.md).

## Local diagnostics

GodUsage writes a redacted diagnostic log on your Mac. It is never uploaded automatically. See [Logging](logging.md).
