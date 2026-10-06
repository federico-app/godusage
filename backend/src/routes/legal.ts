import type { Handler } from "../context";
import { page } from "./pages";

/**
 * The Teams service's privacy policy and terms, served at /privacy and /terms and linked from every
 * page and from the app's sign-in. Keep them in step with docs/teams-backend.md and docs/privacy.md.
 */

const UPDATED = "October 5, 2026";
const CONTACT = `<a href="https://github.com/federico-app/godusage/issues">GitHub issues</a> (for private requests, a <a href="https://github.com/federico-app/godusage/security/advisories/new">private report</a>)`;

export const privacyPage: Handler = async () =>
  page(
    "Privacy Policy",
    `<p class="eyebrow">GodUsage Teams</p>
     <h1>Privacy Policy</h1>
     <p class="muted">Last updated ${UPDATED}</p>

     <p>This policy covers GodUsage Teams: the optional service that lets GodUsage users form teams and compare AI usage. The GodUsage app itself keeps your usage on your Mac; nothing reaches this service unless you sign in to Teams.</p>

     <h2>What we collect</h2>
     <ul>
       <li><strong>Account:</strong> the user id Sign in with Apple gives us and the display name you choose. We never receive your email or your Apple ID password.</li>
       <li><strong>Usage you share:</strong> for each of your Macs, its name and a random id, and daily tokens and estimated spend per AI provider and per model. For account-wide providers (Cursor), a one-way hash of the account, so a team counts an account several members share once. Never credentials, prompts, code, logs, project names, or provider account ids.</li>
       <li><strong>Teams:</strong> the teams you create or join, your role, reactions you give and receive, and challenges you start.</li>
       <li><strong>Sessions:</strong> a hash of each sign-in token. In a browser, one cookie keeps you signed in to your team's leaderboard.</li>
       <li><strong>Service logs:</strong> our host keeps short-lived request logs (time, route, status) to operate and secure the service.</li>
     </ul>

     <h2>Why</h2>
     <p>Only to run Teams: show your team's leaderboards, charts, reactions, and challenges, and send the notifications you turn on. No advertising, no selling or sharing data for marketing, no analytics profiles.</p>

     <h2>Who sees it</h2>
     <p>Members of your teams see your display name and the usage you share. If a team owner turns on a public leaderboard, anyone with that link sees the team's names and usage. Nobody else does.</p>

     <h2>Service providers</h2>
     <p>Cloudflare hosts the service and its database. Apple provides Sign in with Apple. They process data only to provide those services.</p>

     <h2>How long we keep it</h2>
     <ul>
       <li>Shared usage stays until you sign out on that Mac (which removes all of that Mac's usage) or delete your account.</li>
       <li>Deleting your account removes your account, all usage from all your Macs, your memberships, your reactions, and the teams you own, at once.</li>
       <li>App sign-ins expire after 180 days without use, browser sign-ins after 30. Unused sign-in requests expire after 10 minutes.</li>
     </ul>

     <h2>Your rights</h2>
     <p>In GodUsage, Settings → Teams: <strong>Export My Data</strong> downloads everything we keep about you as JSON, <strong>Edit Name</strong> corrects your name, <strong>Sign Out</strong> removes a Mac's usage, and <strong>Delete Account</strong> erases everything. You can also contact us below. If you are in the EU or UK you may lodge a complaint with your data protection authority.</p>

     <h2>Children</h2>
     <p>Teams is not meant for anyone under 16.</p>

     <h2>Changes</h2>
     <p>We will update this page and its date when this policy changes.</p>

     <h2>Contact</h2>
     <p>${CONTACT}.</p>`,
  );

export const termsPage: Handler = async () =>
  page(
    "Terms of Use",
    `<p class="eyebrow">GodUsage Teams</p>
     <h1>Terms of Use</h1>
     <p class="muted">Last updated ${UPDATED}</p>

     <p>By signing in to GodUsage Teams you agree to these terms and to the <a href="/privacy">Privacy Policy</a>.</p>

     <h2>The service</h2>
     <p>Teams is a free, optional companion to the open-source GodUsage app. It is provided as is, without warranties, and may change, pause, or end at any time. Usage and spend figures are estimates from your own Mac and may be incomplete or wrong; do not rely on them for billing.</p>

     <h2>Your account</h2>
     <p>You are responsible for what your account shares and for who you invite. Only share usage you are allowed to share; if your employer restricts it, don't.</p>

     <h2>Acceptable use</h2>
     <p>Don't abuse the service: no attacks, scraping, automated flooding, impersonation, or offensive names. We limit request rates and may remove content or accounts that break these terms.</p>

     <h2>Liability</h2>
     <p>To the extent the law allows, the GodUsage maintainers are not liable for any loss arising from your use of Teams.</p>

     <h2>Ending</h2>
     <p>You can delete your account at any time in Settings → Teams. We may close accounts that break these terms.</p>

     <h2>Contact</h2>
     <p>${CONTACT}.</p>`,
  );
