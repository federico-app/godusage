# Teams

Teams let you compare AI usage with friends. Create a team, share its invite link, and see who spends the most, on which providers and models. Teams are off until you sign in.

## Signing in

Open **Settings → Teams** and choose **Sign In with Apple**. A system sign-in sheet opens Apple's sign-in page; if Safari is already signed in to your Apple ID, you only confirm. The first sign-in creates your account. Your display name starts as the name Apple shares (or "GodUsage User") and you can change it in the same pane. It is what teammates see. GodUsage never receives or stores your email.

The sign-in stays on this Mac until you sign out, delete the account, or it goes unused for 180 days. Each Mac signs in on its own. Signing in on another Mac with the same Apple ID uses the same account, so your Macs add up to one person on the leaderboard.

Development builds (`com.montinovo.godusage.dev`) use a separate backend with separate accounts and teams, so testing never touches real leaderboards. See [Teams backend](teams-backend.md#environments).

## Teams and invites

- **Create a team** under **Add a Team**. You are its owner.
- **Invite people** by copying the team's **Invite Link** in **Your Teams**. Anyone with the link can join. Opening it shows the team name and an **Open in GodUsage** button. GodUsage then opens Settings → Teams and asks you to confirm. You can also paste a link into **Invite Link** under **Add a Team**.
- **The owner** can make a **New Link** (the old one stops working; members stay), remove members, share a public leaderboard, and delete the team.
- **Members** can leave. The owner cannot leave; they delete the team instead.

A team holds up to 50 members, and you can be in up to 20 teams.

## What is shared

While you are signed in and in at least one team, this Mac uploads its own last 30 days of usage:

- daily tokens and spend per provider (Claude, Codex, Cursor, and the rest),
- the same per model.

Extra accounts of a provider are added into that provider; account ids never leave the Mac. Credentials, logs, prompts, and project names are never uploaded. Usage that iCloud Sync brought in from your other Macs is not uploaded again: each Mac uploads only what it read itself. Disabled providers are left out.

The server keeps everything each Mac shared, so history grows beyond the app's 30-day window; each upload replaces only that Mac's last 30 days.

Uploads happen after a refresh, at most every 15 minutes, and right away when you sign in, create or join a team, or change which providers are enabled. Each upload replaces this Mac's previous one. The Account section shows when this Mac last shared. A Mac whose [iCloud Sync](icloud-sync.md) identity is unresolved does not upload, so it is never counted twice.

Your Macs are combined like iCloud Sync combines them. Local usage (Claude, Codex, Grok, and others) adds up across Macs. Cursor's usage is already account-wide, so only your most recently updated Mac counts.

**Sign Out** removes this Mac's usage from your teams first, then ends the session. If removing it fails, you stay signed in and see the error. **Delete Account** removes your account, the usage all your Macs shared, and the teams you own.

## Leaderboards

Ranges are Today, 7 Days, 30 Days, and Year. The server keeps every day each Mac uploaded, so the Year range fills in from the day you start sharing.

**In the popover.** Press **⌘T**, or once you're signed in use the footer's **team** button (also **Team** in the gear menu). The Team screen shows the selected team's ranking for Today, 7 Days, or 30 Days, by Spend or Tokens. Each member's bar is split by provider. Click a member to see their providers and top models. The chart button in its top bar opens the Teams window. With more than one team, pick one from the team name.

**In the Teams window** (the popover's chart button, or **Open Leaderboards** in Settings → Teams):

- the ranking (members with the same value share a rank), each bar split by provider,
- **Who Uses What**: each member's usage, split by provider,
- **By Day**: the team's usage per day, split by provider; hover a day for its numbers,
- **Top Models**: the team's most used models, colored by provider.

Every ranking shows each member's movement since the period before: ▲ places gained, ▼ places lost, or **New** for someone who had no usage then. Each member also shows **Efficiency**, what they pay per million tokens (lower means cheaper models or more cache use); the Teams window charts it for the whole team.

**Compare** (Teams window) puts two members side by side: totals, rank, efficiency, each provider as mirrored bars, their top models, and their days as a solid and a dashed line. It starts with you and the next member; pick anyone from either name.

**Share Wrapped** (Teams window) copies an image of your standing in the team over the last 30 days or 12 months: your rank, spend, tokens, efficiency, top provider and model, and the team's top five.

**Show Rank in Menu Bar** (Settings → Teams) adds your rank, your share of the team's spend, and your spend today in the selected team to the menu bar. See [Menu bar](menu-bar.md#team-rank).

Providers have the same color everywhere: the popover's Cost ring, the Team screen, the Teams window, and the web boards (Claude is terracotta, Codex green, Cursor black, or white in dark mode). Every chart also has a legend and value labels, so no number depends on color alone.

The popover, the Teams window, and Settings share the selected team.

Days are calendar days on each Mac. Refresh uploads this Mac's latest usage and reloads.

Every member can open the team's **Web Leaderboard** in a browser. It shows the same board after you sign in with your Apple ID, and only to members.

The owner can also turn on **Public Leaderboard** for a team. That gives a read-only web page anyone with its link can open without signing in. It shows display names, ranks, spend or tokens by provider, and top models. Turning it off makes the link stop working.

## Notifications

Two team alerts in **Settings → Notifications**, both off by default:

- **Team Overtakes**: when a teammate passes you by spend over the last 7 days. The first check after you turn it on only records where everyone stands, so it never alerts about old moves.
- **Weekly Team Recap**: from Monday 9:00, one notification per team about the week that just ended: your rank (and how it moved), your spend, who led, and your top model.

Both are checked after each upload, so at most every 15 minutes, and only while GodUsage is running.

## Requirements

Sign in goes through Apple's web sign-in, so it works in every build, including Developer ID releases (their provisioning profiles never grant the native Sign in with Apple entitlement). It needs the teams backend's Services IDs; see [Teams backend](teams-backend.md#sign-in-with-apple).
