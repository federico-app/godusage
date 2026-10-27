# Antigravity

Tracks pool quotas for Antigravity (Google's AI IDE) using credentials the app or the `agy` CLI already stored on your Mac.

## What it tracks

Antigravity has two shared quota pools, and each pool has a rolling 5-hour window and a weekly window. Eligible accounts also have a separate Gemini 4 Argon weekly quota:

| Metric | Meaning |
|---|---|
| Session | The shared Gemini pool (Pro and Flash draw from the same quota), rolling 5-hour window |
| Weekly | The same Gemini pool's weekly window |
| Argon Weekly | The separate Gemini 4 Argon weekly quota, when Antigravity reports one |
| Claude | The shared non-Gemini pool (Claude, GPT-OSS, and others), rolling 5-hour window |
| Claude Weekly | The same non-Gemini pool's weekly window |

When Antigravity reports your subscription tier (such as `Pro` or `Ultra`), GodUsage shows it beside the provider name.

Gemini Pro and Gemini Flash are one pool, so GodUsage shows one meter per window instead of separate Pro and Flash meters. That pair is named Session and Weekly to match the other providers. Every non-Gemini model shares the second pool, shown under the Claude name. Quotas are reported as a fraction, so there are no token or dollar spend tiles.

Paid Pro plans have a separate Argon weekly quota. Ultra includes Argon in its larger shared Gemini quota, shown by Session and Weekly. Argon Weekly reads **No data** when the response has no usable separate Argon weekly quota. GodUsage uses the quota Antigravity returns rather than guessing from the plan name.

When a pool's 5-hour window has no usage yet, that meter reads **Not started** instead of a reset countdown. Hover it for an explanation. The weekly meters always show a reset countdown.

## Where credentials come from

GodUsage reads what Antigravity already has:

- **Antigravity running**: GodUsage talks to the app's local language server. This is the richest source and where the plan name comes from.
- **App closed**: GodUsage falls back to the OAuth token Antigravity and `agy` store in your macOS Keychain and queries Google's Cloud Code API. GodUsage refreshes an expired token itself and never writes back to Antigravity's keychain item. It reuses its short-lived cache only while the same Keychain login is present and readable.

If neither is available you see *Start Antigravity or run `agy` and try again.*

## Troubleshooting

- **"Start Antigravity or run `agy`…"**: sign in to the Antigravity app or run `agy` so a usable token exists, then refresh. A manual refresh (⌘R) looks for the local server immediately. The automatic 5-minute passes find it within about 15 minutes of it starting.
- **"Antigravity login found in Keychain"** (neutral key glyph): the item is present, but automatic refreshes do not request its secret. Connect to load it. Choose **Always Allow** to avoid a dialog on future manual reads.
- **"Keychain access to the Antigravity login was declined"**: a manual read was denied. Refresh and choose **Always Allow** when macOS asks.
- **"Couldn't read Antigravity credentials from Keychain"**: the keychain itself could not be read, usually because it is locked. Unlock it, then refresh.
- **"Couldn't read Antigravity credentials…"**: unlock Keychain, or sign in to Antigravity again. GodUsage does not use its cached access token until the current login can be verified.
- **The weekly meters show "No data"**: your Antigravity build does not expose the quota-summary endpoint yet. The 5-hour meters still work from the older endpoints. Updating Antigravity brings the weekly meters back.
- **Argon Weekly shows "No data"**: the response had no enabled, usable separate Argon weekly quota. On Ultra, Argon uses the shared Gemini quota shown by Session and Weekly. Older endpoints also omit it. A model appearing in Antigravity's picker does not mean a separate quota exists.
- **A meter shows "No data"**: that pool or window was not in the latest response. Some tiers only report certain windows. The other meters still update.
- **No plan beside the name while Antigravity is closed**: Google returns the tier only to requests that look like the Antigravity app. GodUsage sends the installed app's version for this; if Antigravity is not installed it uses a recent known version. The local log records the tier ids Google returned when no plan could be read.
- **Where did the Gemini Pro and Flash meters go?** They merged. Both models draw from the one shared Gemini pool, which is now the Session meter.
- **Quotas look full after heavy use**: the 5-hour windows reset on a rolling basis and the weekly windows once a week. The reset time is on each meter.

## Under the hood

Best source first: the local language server, found by scanning for the `language_server` / `agy` process and reading its CSRF token and listening ports; then Google Cloud Code using the Keychain token, refreshed via Google OAuth when needed. GodUsage binds its short-lived refreshed-token cache to a one-way fingerprint of the current Keychain refresh credential, so logout, account changes, legacy caches, and expired or malformed entries cannot reuse a previous account's access token. On each source GodUsage asks the quota-summary endpoint first (`RetrieveUserQuotaSummary` on the language server, `v1internal:retrieveUserQuotaSummary` on Cloud Code). That is the only endpoint that reports the merged pools and the weekly windows. Builds without it fall back to the legacy per-model endpoints (`GetUserStatus` / `GetCommandModelConfigs` locally, `fetchAvailableModels` / `retrieveUserQuota` remotely), whose per-model quotas are merged into the two pools by keeping each pool's worst remaining fraction. Those endpoints only know the 5-hour windows. The plan name prefers Antigravity's own `userTier` over the inherited Windsurf plan field.

For the quota summary, Cloud Code asks production (`cloudcode-pa`) first. When production's answer has all four shared-pool windows, that answer is used and the daily host (`daily-cloudcode-pa`) is not asked. Otherwise, including when production fails or rejects the sign-in, GodUsage also asks the daily host and combines the two answers by bucket id, because one host can leave out a whole pool (for example, return only the Claude meters). Production's answer wins where both report the same window. A window neither host reports shows **No data** for that refresh. Other Cloud Code requests try production first, then the daily host after a network error or an error response other than a sign-in rejection.

The four shared-pool windows use their known bucket ids. Argon Weekly requires the exact `Gemini 4 Argon` group and one explicitly weekly bucket with its own id and a usable remaining fraction. Disabled, malformed, or ambiguous Argon quotas are left out. The legacy per-model endpoints never feed Argon into the shared Gemini meter, because they do not say which pool or period its quota belongs to.

With the app closed, the plan comes from Cloud Code's `loadCodeAssist`, called the way the Antigravity app calls it: its client metadata (`ideType` `ANTIGRAVITY`, `pluginType` `GEMINI`) and its `antigravity/<version> (aidev_client; …)` User-Agent. The version is read from the installed Antigravity app's `Info.plist`, with a pinned fallback when the app is missing. Google leaves out the tier for any other caller. A known `paidTier.id` (Pro, Ultra, Ultra Lite) wins over the tier's display name.

> Reverse-engineered from the app and language-server binary. Endpoints and storage can change without notice.

When Weekly is Always Visible and exhausted, the dashboard replaces its bar with **Usage Exhausted** and a live countdown plus the reset date and time, and temporarily hides the other Always Visible bars until a refresh reports available usage. On Demand rows and saved settings are preserved; independent model pools affect only their own session bar. See [Dashboard](../dashboard.md) for details.

If this account is pinned and its login becomes unavailable, its menu-bar icon stays visible but faded, with no usage values, until a refresh confirms a usable login. See [Menu Bar](../menu-bar.md#login-unavailable).
