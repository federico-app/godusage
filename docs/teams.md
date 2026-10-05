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

Uploads happen after a refresh, at most every 15 minutes, and right away when you sign in, create or join a team, or change which providers are enabled. Each upload replaces this Mac's previous one. The Account section shows when this Mac last shared. A Mac whose [iCloud Sync](icloud-sync.md) identity is unresolved does not upload, so it is never counted twice.

Your Macs are combined like iCloud Sync combines them. Local usage (Claude, Codex, Grok, and others) adds up across Macs. Cursor's usage is already account-wide, so only your most recently updated Mac counts.

**Sign Out** removes this Mac's usage from your teams first, then ends the session. If removing it fails, you stay signed in and see the error. **Delete Account** removes your account, the usage all your Macs shared, and the teams you own.

## Leaderboards

Open the **Teams** window from the popover's gear menu or **Open Leaderboards** in Settings → Teams. Pick a team, a range (Today, 7 Days, 30 Days), and Spend or Tokens. The window shows:

- the ranking (members with the same value share a rank),
- each member's usage by provider,
- usage by day per member,
- the team's top models.

Days are calendar days on each Mac. Refresh uploads this Mac's latest usage and reloads.

Every member can open the team's **Web Leaderboard** in a browser. It shows the same board after you sign in with your Apple ID, and only to members.

The owner can also turn on **Public Leaderboard** for a team. That gives a read-only web page anyone with its link can open without signing in. It shows display names, ranks, spend or tokens by provider, and top models. Turning it off makes the link stop working.

## Requirements

Sign in goes through Apple's web sign-in, so it works in every build, including Developer ID releases (their provisioning profiles never grant the native Sign in with Apple entitlement). It needs the teams backend's Services IDs; see [Teams backend](teams-backend.md#sign-in-with-apple).
