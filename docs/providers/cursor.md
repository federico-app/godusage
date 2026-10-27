# Cursor

Tracks your Cursor plan usage using the login from the Cursor app.

## What it tracks

| Metric | Meaning |
|---|---|
| Credits | Credit balance left from grants and prepaid account balance |
| Total Usage | Plan usage for the billing cycle (percent or dollars; included request count vs. cap on request-based Enterprise accounts) |
| Requests | Optional copy of the included request count vs. cap for custom layouts |
| Cursor Models | Cursor-native model usage percent (Grok, Composer) |
| Other Models | Third-party model usage percent |
| Grok Bot | Grok Bot weekly usage percent and reset countdown. Enabled by default, On Demand |
| Extra Usage | On-demand spend, user-scoped when available, otherwise the team aggregate. Shown as a meter when Cursor returns a limit |

When Cursor reports your plan name, GodUsage shows it beside the provider name.

Some Enterprise and Team seats still report the plan as **Pro**. When the billing membership says `enterprise` or `team` and the reported plan is missing or Pro, GodUsage shows Enterprise or Team instead. The membership comes from the Cursor app's local state, or from `usage-summary`. A keychain login for a different account never takes the local membership. Explicit plan names such as Ultra or Business are kept.

Team and Enterprise accounts:

- A dollar limit shows Total Usage as a dollar meter.
- Without a dollar limit, Total Usage uses the reported total percentage.
- When the main usage call has no on-demand row, GodUsage adds Extra Usage from `usage-summary` and leaves the other meters as they are. Personal seats never make this extra call.

Grok Bot has its own weekly allowance, separate from Cursor's billing-cycle meter. It uses the existing Cursor login. Signing into the Grok CLI is not required. Accounts without a personal included allowance (including pooled enterprise seats) hide the meter.

## Where credentials come from

Be signed into the Cursor app. GodUsage reads Cursor's local state database and its keychain entries for the session tokens. Cursor credentials are read-only to GodUsage. It never refreshes a token and never writes the state database or keychain. The Cursor app owns the login. When the token lapses, the card shows **"Cursor login needs renewal"**. Sign in again where that login lives (open the Cursor app, or run `agent login` if you use the Cursor CLI), then refresh GodUsage.

Automatic refreshes never request the keychain secrets. After launch or a credential change, the card shows a neutral **Connect** action. That manual read is cached in memory for the running session while the items' non-secret metadata is unchanged. Choose **Always Allow** to avoid a dialog on future manual reads. If the login keychain cannot be inspected (it is locked, say), the card asks you to unlock it.

## The spend tiles

Today, Yesterday, Last 30 Days, and Usage Trend come from Cursor's usage history, the same data as Cursor's Usage page. GodUsage uses its token counts and the shared model pricing to estimate cost locally.

GodUsage fetches the history one local day at a time and keeps each finished day on this Mac, separately for each Cursor account. Every refresh re-checks today and yesterday, plus any older day not stored yet. That fetch stops after 6 seconds; days it did not reach are picked up on the next refresh. A failed or short download never erases stored days: a day is saved only when its event count matches Cursor's total. The tiles and chart appear once all 30 days are stored, so the first fill can take a few refreshes on a heavy account. Until then the dashboard keeps the last history it had. Changing the Mac's time zone starts the stored days over.

GodUsage leaves malformed usage events out instead of counting them as zero, and records failures in the log without the usage data.

## Troubleshooting

- **"Not logged in" / token errors**: open Cursor and make sure you are signed in, then refresh.
- **Some metrics missing**: Cursor omits fields depending on plan type. Missing metrics show "No data".
- **Optional lookup failed**: plan, credit-grant, prepaid-balance, Grok Bot, usage-summary, and request-fallback failures are nonfatal when primary usage is available. GodUsage records fixed, credential-free reasons in the log.

## Under the hood

Connect RPC on `api2.cursor.sh` (dashboard usage and `DashboardService/GetSandUsageStatus` for Grok Bot), a combined REST fallback at `cursor.com/api/usage` and `cursor.com/api/usage-summary` for Enterprise and team accounts, Stripe balance at `cursor.com/api/auth/stripe`, and paged usage events at `cursor.com/api/dashboard/get-filtered-usage-events` (1,000 per page, one local day per request). The fallback combines the included request allowance with structured percentages and user-scoped on-demand spend. Neither REST response is treated as the whole account snapshot by itself. All requests are read-only against the stored token. A 401/403 shows the renewal notice instead of refreshing and retrying. Optional endpoint failures are nonfatal when the other fallback response is usable and are recorded in the log. The credit-grants response follows protobuf JSON, which leaves out default values: a missing `hasCreditGrants` means no grants, and a missing `usedCents` means nothing spent. Per-day spend uses usage-event token counts priced through the shared [model pricing](../pricing.md). Cursor-native models (`auto`, `composer-*`) come from its supplement layer, which maintainers sync from [Cursor models & pricing](https://cursor.com/docs/models-and-pricing.md).

If this account is pinned and its login becomes unavailable, its menu-bar icon stays visible but faded, with no usage values, until a refresh confirms a usable login. See [Menu Bar](../menu-bar.md#login-unavailable).
