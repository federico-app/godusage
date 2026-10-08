# Teams

Teams let you compare AI usage with friends. Create a team, share its invite link, and see who spends the most, on which providers and models. Teams are off until you sign in.

## Signing in

Open **Settings → Teams** and choose **Sign In with Apple**. A system sign-in sheet opens Apple's sign-in page; if Safari is already signed in to your Apple ID, you only confirm. The first sign-in creates your account. Your display name starts as the name Apple shares (or "GodUsage User") and you can change it in the same pane. It is what teammates see. GodUsage never receives or stores your email.

The sign-in stays on this Mac until you sign out, delete the account, or it goes unused for 180 days. Each Mac signs in on its own. Signing in on another Mac with the same Apple ID uses the same account, so your Macs add up to one person on the leaderboard.

Development builds (`com.montinovo.godusage.dev`) use a separate backend with separate accounts and teams, so testing never touches real leaderboards. See [Teams backend](teams-backend.md#environments).

## Teams and invites

- **Create a team** under **Add a Team**. You are its owner.
- **Invite people** by copying the team's **Invite Link** in **Your Teams**. Anyone with the link can join. Opening it shows the team name and an **Open in GodUsage** button. GodUsage then opens Settings → Teams and asks you to confirm. You can also paste a link into **Invite Link** under **Add a Team**.
- **Owners** can make a **New Link** (the old one stops working; members stay), share a public leaderboard, edit plans, and delete the team. From the **⋯** menu next to a member, they can **Make Owner…**, **Make Member** (for another owner), or **Remove…**. A team can have several owners, all with the same powers.
- **Anyone** can leave. The last owner cannot; they make someone else an owner first, or delete the team.

A team holds up to 50 members, and you can be in up to 20 teams.

## What is shared

While you are signed in and in at least one team, this Mac uploads its own last 30 days of usage:

- daily tokens and spend per provider (Claude, Codex, Cursor, and the rest),
- the same per model.

Extra accounts of a provider are added into that provider; account ids never leave the Mac. Credentials, logs, prompts, and project names are never uploaded. Usage that iCloud Sync brought in from your other Macs is not uploaded again: each Mac uploads only what it read itself. Disabled providers are left out.

The server keeps everything each Mac shared, so history grows beyond the app's 30-day window; each upload replaces only that Mac's last 30 days. After the first upload since launch, the Mac sends only the days that changed (usually just today), and the whole window again when a provider is turned off.

Uploads happen after each refresh (every 5 minutes) when your usage changed, at least every 15 minutes even when it didn't, and right away when you sign in, create or join a team, or change which providers are enabled. The server recomputes a board at most every few minutes (Today every 5, 30 Days every 15, Year every hour), so a teammate's new usage reaches Today's board within about 10 minutes. Each upload replaces this Mac's previous one. The Account section shows when this Mac last shared. A Mac whose [iCloud Sync](icloud-sync.md) identity is unresolved does not upload, so it is never counted twice.

Your Macs are combined like iCloud Sync combines them. Local usage (Claude, Codex, Grok, and others) adds up across Macs. Cursor's usage is already account-wide, so only your most recently updated Mac counts.

**Shared accounts.** Cursor reports usage per account, not per person. When two or more members log into the same Cursor account, their usage is counted once: it is in the team total, the providers, By Day, and Top Models, but in no member's total. It shows as an unranked **Shared Cursor** row after the members, with who shares it, on the dashboard, in the Teams window, and on the web boards. To tell accounts apart, each Mac sends an anonymous fingerprint of its Cursor account (a one-way hash); the account id itself never leaves the Mac.

**Export My Data** (Settings → Teams) saves everything the service keeps about you as a JSON file. The service's [Terms](https://godusage-api.federico-c80.workers.dev/terms) and [Privacy Policy](https://godusage-api.federico-c80.workers.dev/privacy) are linked at sign-in.

**Sign Out** removes this Mac's usage from your teams first, then ends the session. If removing it fails, you stay signed in and see the error. **Delete Account** removes your account, the usage all your Macs shared, and the teams you own.

## Leaderboards

Ranges are Today, 7 Days, 30 Days, and Year. The server keeps every day each Mac uploaded, so the Year range fills in from the day you start sharing.

**On the dashboard.** Once you're signed in and in a team, a Team section sits right under Total Spend, above the provider cards. It shows the selected team's ranking. The period follows the Total Spend card's switcher (Today, Yesterday, 30 Days; 7 Days and Year are in the Teams window), and the metric follows its menu: Cost, Cost/MTok (what each member pays per million tokens, highest first, without movement arrows), or Tokens. Each member's bar is split by provider. Click a member to see their providers and top models. Only the top 2 members show at first; the caret under them shows the rest. **Advanced Stats** at the bottom opens the Teams window. With more than one team, pick one from the team name. The section reloads each time you open the popover and every 2 minutes while it stays open; the Teams window also reloads every 2 minutes while open. If the teams server has used up its daily database allowance, boards keep their last numbers and say that updates are paused until midnight UTC. Press **⌘T**, or choose **Team** in the gear menu, to open the Teams window directly.

**Customize → Team** (shown while you're in a team) changes how the section looks: turn it off on the dashboard, pick how many members show before the caret (Top 2, Top 3, Top 5, or All), and show or hide the team projection and the challenges.

**In the Teams window** (the popover's chart button, or **Open Leaderboards** in Settings → Teams):

- the ranking (members with the same value share a rank), each bar split by provider,
- **Who Uses What**: each member's usage, split by provider,
- **By Day**: the team's usage per day, split by provider; hover a day for its numbers,
- **Top Models**: the team's most used models, colored by provider.

The gear button in its toolbar opens Settings → Teams.

**Plans.** Team owners list the subscriptions the team pays for in Settings → Teams → Plans: provider, name, monthly cost, and the day of the month it renews (29–31 fall on the last day of shorter months). Every member sees the **Plans** tab in the Teams window. For each plan it shows the current billing cycle (last renewal to the day before the next), the team's usage of that provider in the cycle at API prices, the projection to the end of the cycle at the current pace, and the value per dollar (projected value ÷ monthly cost). Plans projected under 1× are flagged as underused. Usage counts like the leaderboard, shared accounts once; several plans of one provider split its usage by cost. An underused plan that renews within 7 days also shows as a [suggestion](dashboard.md#suggestions) on the dashboard of members who use its provider.

**Last update.** Each member shows when their Macs last uploaded, on the dashboard, in the Teams window, and on the web boards: **Updated 5m ago** (or **just now**, **3h ago**) within the last 24 hours, then **Not synced for N days** with a warning icon, so their numbers aren't read as no usage. After it comes the GodUsage version that Mac runs (**· v1.0.8**), so you can tell who is behind on updates; uploads from apps before 1.0.8 carry no version. Members who never synced show nothing.

**Team life.** Around the ranking:

- **👑** marks today's top spender and **🏆** last month's champion; hover either for its meaning (the **Hall of Fame** in the Teams window lists every month's champion; a month counts once it's over).
- **Reactions:** give a teammate 🔥, 👏, or 🤡, one of each per day; click again to take it back. Counts start clean every day at midnight UTC. On the dashboard's team section, click a member to react; the Teams window has the buttons on each row.
- **Projection:** "Team on pace for $X in October" stretches this month's spend so far over the whole month, for the team and for each member.
- **Challenges** (Teams window, **New Challenge**): any member starts one for 7, 14, or 30 days: **Lowest Spend** (among members who spend something), **Most Models**, **Most Tokens**, or **Best Efficiency** (with at least 100K tokens). Standings update live; when it ends, the leader wins. The creator or an owner can cancel it. Active challenges also show under the dashboard's team ranking.

Every ranking except Year shows each member's movement since the period before: ▲ places gained, ▼ places lost, or **New** for someone who had no usage then. Each member also shows **Efficiency**, what they pay per million tokens (lower means cheaper models or more cache use); the Teams window charts it for the whole team.

**Compare** (Teams window) puts two members side by side: totals, rank, efficiency, each provider as mirrored bars, their top models, and their days as a solid and a dashed line. It starts with you and the next member; pick anyone from either name.

**Share Wrapped** (Teams window) copies an image of your standing in the team over the last 30 days or 12 months: your rank, spend, tokens, efficiency, top provider and model, and the team's top five.

**Show Rank in Menu Bar** (Settings → Teams) adds your rank, your share of the team's spend, and your spend today in the selected team to the menu bar. See [Menu bar](menu-bar.md#team-rank).

Providers have the same color everywhere: the popover's Cost ring, the dashboard's Team section, the Teams window, and the web boards (Claude is terracotta, Codex green, Cursor black, or white in dark mode). Every chart also has a legend and value labels, so no number depends on color alone.

The popover, the Teams window, and Settings share the selected team.

Days are calendar days on each Mac. Refresh uploads this Mac's latest usage and reloads.

Every member can open the team's **Web Leaderboard** in a browser. It shows the same board after you sign in with your Apple ID, and only to members.

An owner can also turn on **Public Leaderboard** for a team. That gives a read-only web page anyone with its link can open without signing in. It shows display names, ranks, spend or tokens by provider, and top models. Turning it off makes the link stop working.

## Notifications

Three team alerts in **Settings → Notifications**, all on by default:

- **Team Overtakes**: when a teammate passes you by spend over the last 7 days. The first check after you turn it on only records where everyone stands, so it never alerts about old moves.
- **Weekly Team Recap**: from Monday 9:00, one notification per team about the week that just ended: your rank (and how it moved), your spend, who led, and your top model.

- **Team Challenges**: who won, when a challenge ends. Challenges that had already ended when you turned it on are never announced.

All three are checked after each upload, so after a refresh that changed your usage or at least every 15 minutes, and only while GodUsage is running.

## Requirements

Sign in goes through Apple's web sign-in, so it works in every build, including Developer ID releases (their provisioning profiles never grant the native Sign in with Apple entitlement). It needs the teams backend's Services IDs; see [Teams backend](teams-backend.md#sign-in-with-apple).
