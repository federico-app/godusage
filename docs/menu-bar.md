# Menu Bar

Star your most important metrics into the menu bar strip.

## Right-clicking the icon

Right-click (or control-click) the menu bar icon for a menu with **Settings**, **Memory** (opens the [Memory Explorer](memory-explorer.md)), and **Quit**. Left-click opens the popover.

## Starring

Star a metric from any row's right-click menu, or from the star beside a metric in Customize.

- The app ships with a default set of stars (Antigravity Session and Weekly, Claude Session and Weekly, Codex Weekly, Cursor Models and Other Models, Copilot Credits, Muse Five-Hour Usage and Weekly Usage, OpenRouter Credits, Z.ai Session and Weekly) so the strip shows numbers right away. Each discovered Claude or Codex account card gets its family's default stars with its own values. A card discovered later receives them once and then keeps your changes. A provider's Reset restores its defaults, and Reset All restores the full set. Only providers that are on render in the strip, and a fresh install starts with just the providers detected on your Mac (see [Dashboard § First launch](dashboard.md#first-launch)).
- At most **2 stars per provider**. If an account or plan change makes a starred metric unavailable, GodUsage keeps the star for a future switch back, and the dormant star does not use one of the two slots. If a later switch makes more than two saved stars live at once, the strip renders the first two in Customize order without deleting the others.
- When a star is not allowed, the star button stays clickable. Clicking it shakes and shows the reason in a temporary pill at the bottom of Customize (for example, "Up to 2 stars per provider").

## Styles

Settings → Appearance → Icon Style:

- **Text**: provider icon plus values. Two starred metrics from the same provider stack on two lines. Each value of a session (five-hour) or weekly window starts with a small dimmed **S** or **W**. The letter comes from the metric itself, not its position, so Weekly starred alone still reads **W**. Other metrics (model pools such as Codex Spark or Antigravity's Claude pool, credits, spend) have no letter. Hover an account segment to see that card's current name.
- **Bars**: a compact glyph with the first four starred metrics that have a limit. Metrics without limits only appear in Text style.

The strip uses color only for things worth acting on: orange for a warning, green for room to spare. A strip with no colored part looks exactly like the plain menu-bar text. Every colored part follows the light or dark menu bar.

## What a value shows

In Text style a starred value reads, from most to least urgent:

- **Session about to run out**: a session window with under 10% left shows the time until it resets, in orange, for example **↻38m**.
- **Limit used up**: a limit that is used up (and doesn't fade the whole account, see below) shows the time until it resets, dimmed, for example **↻2d 4h**.
- **Over pace**: when the dashboard shows the flame on a metric (on pace to run out before it resets), the value turns orange and adds the time to the projected limit, for example **91%·3d**, **91%·17h**, or **91%·45m**. It's the same projection as the dashboard's "Limit in 3d 17h". When the pace lands right at the limit, the value is orange with no time.
- Otherwise the plain value.

In Bars style a bar over pace fills in orange. The color goes away once the pace recovers or the limit resets. Times move with the clock: the strip redraws once a minute.

## Use this now

While the dashboard's **Switch to …** suggestion is active (a provider is running out and another one has room), the account it recommends gets a small green dot on its icon. The dot stays even if you close the suggestion banner, and goes away when the situation ends. Bars style shows it only on faded icons.

## Team rank

<<<<<<< HEAD
With **Show Rank in Menu Bar** on (Settings → Teams → You), the strip ends with a team segment for the selected team:

- **Top line**: your rank, how it moved since yesterday when known (**▲1** in green, **▼1** dimmed), and your spend today in whole dollars, for example **#2 ▲1 · $37**.
- **Bottom line**: your pace on your team plan today, from Live Pace (see [Teams](teams.md#leaderboards)) for the plans in the selected team that cover you:
  - ahead of pace: **+41m** in orange (plain when you're ahead but slowing down, as on the dashboard),
  - under pace: **−2h 40m** in green,
  - on pace: **On pace**, dimmed,
  - over today's budget: a solid orange chip, for example **+6.3%**.
  
  On several plans, the most urgent one shows: over today's budget beats ahead of pace, which beats the rest. Plans outside the working day (not started, day done, day off) don't count. Without a plan or pace data, the bottom line shows your share of the team's spend today (**30%**), or nothing while the team has spent nothing.
- When your team data is more than an hour old (your usage last reached the server over an hour ago), the bottom line says so, dimmed, for example **Upd 2h**.

Your share of the team's spend today is in the segment's tooltip and VoiceOver label. The segment updates with each team upload, at most every 15 minutes, and whenever the dashboard's Team section loads Today. See [Teams](teams.md).
=======
With **Show Rank in Menu Bar** on (Settings → Teams → You), the strip ends with a team segment: your rank in the selected team and your share of the team's spend today, over your spend today, for example **#2 · 38%** over **$12.40**. The share is left out while the team has spent nothing today. It updates with each team upload, at most every 15 minutes, and whenever the dashboard's Team section loads Today. See [Teams](teams.md).
>>>>>>> origin/main

## Login unavailable

An account with an expired, invalid, missing, or unreadable login shows in the menu bar as a faded provider icon with a small orange dot and no values, even when no usage has loaded. This applies to every enabled account, starred or not, and also when a login failure leaves cached usage or local spend history available. Both Text and Bars styles restore the normal icon and values after a successful refresh. Open the dashboard for the login notice and recovery steps. Disabled accounts stay hidden. Temporary network failures do not count as login failures and cannot clear an already-known login failure.

## Exhausted weekly usage

When an account has used all of its weekly allowance, its menu-bar segment becomes a faded provider icon with the time until the weekly reset, dimmed, for example **↻2d 4h**. In Bars style, its bars are replaced by the faded icon and reset time beside any remaining active bars. The icon and values return to normal after a refresh reports available usage. Your stars stay saved, and Weekly does not need to be starred or Always Visible for this to work.

Independent model pools (Antigravity and Codex Spark) fade the icon only when all currently rendered starred metrics belong to exhausted pools; the reset time is then the first of those pools to reset. Dormant pins and pins beyond the two-value display limit do not count as usable alternatives. Other usable starred pools keep their values. Open the dashboard for the exhaustion message.

## Hiding usage while screen sharing

Settings → General → Privacy → **Hide From Screen Share** (off by default). While your screen is shared or recorded (a Zoom, Meet, or Teams share, a screen recording, macOS Screen Sharing), the strip shows the GodUsage icon and wordmark instead of your numbers. When the capture ends, your starred metrics come back. Captures you start yourself count too.

Detection uses the system's own screen-capture signal, the one that lights the capture indicator in the menu bar. GodUsage checks it the instant it changes, and again every few seconds while the setting is on.

Normally:

![The menu bar strip showing usage values](assets/menu-bar-privacy-idle.png)

While the screen is shared or recorded:

![The menu bar strip concealed behind the GodUsage wordmark](assets/menu-bar-privacy-sharing.png)

## The notch

On MacBooks with a notch, a crowded menu bar can push the GodUsage item under the notch where you cannot see or click it. GodUsage watches for this and recovers:

1. **Move back into view.** The item's remembered position is rewritten so it lands just right of the notch. This is the normal outcome. The strip can hop visibly.
2. **Surrogate button.** If the move does not stick, a small round GodUsage button appears just below the menu bar next to the notch. Click it to open the dashboard, drag it anywhere, or right-click for Hide Until Relaunch.
3. Either way, the dashboard opens beside the notch, never centered under it.

Free up menu bar space (quit other menu bar apps, or use a menu bar manager) and everything returns to normal.

On macOS 27 and later this recovery is off. The system folds items that do not fit behind a chevron next to the notch.

## What the strip shows

The strip only renders real data. A starred metric with nothing fetched yet is skipped. A provider whose stars all lack data disappears, icon included, unless it needs a login or its shared weekly allowance is exhausted—in those cases its faded icon stays visible. A provider with no stars appears only when its login needs renewing. An exhausted weekly allowance instead keeps a faded icon and temporarily hides its values. When nothing has data, the strip shows the app icon. Stars follow your Customize order: Always Visible metrics first, then On Demand ones. A metric can be starred whether it is Always Visible or On Demand.
