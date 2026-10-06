import type { Handler } from "../context";
import { ApiError } from "../http";
import { parseStatsQuery, rangeBounds, teamStats, type StatsQuery, type TeamStats } from "../stats";
import { addDays, dayKey } from "../usagePayload";
import { teamChallengeList } from "./challenges";
import { isoWeek, reactionSummary, teamChampions, type Champion, type MemberReactions } from "./social";
import { invitePreview } from "./teams";

/** GET / — where the browser lands after signing out. */
export const homePage: Handler = async ({ env }) =>
  page(
    "GodUsage Teams",
    `<p class="eyebrow">GodUsage</p><h1>GodUsage Teams</h1>
     <p class="muted">Compare AI usage with friends. Open your team's leaderboard from GodUsage, or ask a member for its link.</p>
     <p><a href="${escapeHTML(env.DOWNLOAD_URL)}">Download GodUsage for macOS</a></p>`,
  );

/** GET /join/:code — the invite link. Opens the app, or points to the download. */
export const invitePage: Handler = async ({ env, params }) => {
  const code = params.code!;
  let team: { name: string; memberCount: number };
  try {
    team = await invitePreview(env.DB, code);
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) {
      return page("Invite Expired", `<h1>Invite Expired</h1><p>This invite link is no longer valid. Ask for a new one.</p>`, 404);
    }
    throw error;
  }
  const appURL = `godusage://join/${encodeURIComponent(code)}`;
  const members = team.memberCount === 1 ? "1 member" : `${team.memberCount} members`;
  return page(
    `Join ${team.name}`,
    `<p class="eyebrow">GodUsage team invite</p>
     <h1>Join ${escapeHTML(team.name)}</h1>
     <p class="muted">${members}. Members see each other's AI usage: spend and tokens by provider and model.</p>
     <p><a class="button" href="${escapeHTML(appURL)}">Open in GodUsage</a></p>
     <p class="muted">Don't have GodUsage? <a href="${escapeHTML(env.DOWNLOAD_URL)}">Download it for macOS</a>, then open this link again.</p>`,
  );
};

/** GET /t/:token — read-only leaderboard, available only while the owner shares it. */
export const publicBoardPage: Handler = async ({ env, url, params, deps }) => {
  const team = await env.DB.prepare("SELECT id, name FROM teams WHERE public_token = ?")
    .bind(params.token!)
    .first<{ id: string; name: string }>();
  if (!team) return page("Not Found", `<h1>Not Found</h1><p>This leaderboard is not shared anymore.</p>`, 404);

  const query = parseStatsQuery(url, deps.now());
  const [stats, extras] = await Promise.all([teamStats(env.DB, team.id, query), boardExtras(env.DB, team.id, query, deps.now())]);
  return page(`${team.name} Leaderboard`, renderBoard(team.name, stats, url, extras, deps.now()));
};

/** What the web boards show around the ranking: crowns, reactions, the projection, challenges, champions. */
export interface BoardExtras {
  kingUserID: string | null;
  lastMonthChampionID: string | null;
  champions: Champion[];
  reactions: Record<string, MemberReactions>;
  projection: { projected: number; month: string; daysLeft: number } | null;
  challenges: Awaited<ReturnType<typeof teamChallengeList>>;
}

export async function boardExtras(db: D1Database, teamID: string, query: StatsQuery, now: Date): Promise<BoardExtras> {
  const today = query.today;
  const [todayStats, monthStats, champions, reactions, challenges] = await Promise.all([
    teamStats(db, teamID, { ...query, range: "today", sort: "cost" }),
    teamStats(db, teamID, { ...query, range: "mtd", sort: "cost" }),
    teamChampions(db, teamID, today),
    reactionSummary(db, teamID, isoWeek(dayKey(now)), ""),
    teamChallengeList(db, teamID, today),
  ]);
  const leaders = todayStats.members.filter((m) => m.rank === 1 && m.costUSD > 0);
  const previousMonth = addDays(`${today.slice(0, 7)}-01`, -1).slice(0, 7);
  const { from } = rangeBounds("mtd", today);
  const elapsed = Number(today.slice(8, 10));
  const monthDays = new Date(Date.UTC(Number(from.slice(0, 4)), Number(from.slice(5, 7)), 0)).getUTCDate();
  return {
    kingUserID: leaders.length === 1 ? leaders[0]!.userID : null,
    lastMonthChampionID: champions[0]?.month === previousMonth ? champions[0]!.userID : null,
    champions,
    reactions,
    projection: monthStats.totals.costUSD > 0
      ? {
          projected: (monthStats.totals.costUSD / elapsed) * monthDays,
          month: new Date(`${from}T00:00:00Z`).toLocaleString("en-US", { month: "long", timeZone: "UTC" }),
          daysLeft: monthDays - elapsed,
        }
      : null,
    challenges,
  };
}

const REACTION_EMOJI = { fire: "🔥", clap: "👏", clown: "🤡" } as const;
const CHALLENGE_TITLES: Record<string, string> = {
  lowest_spend: "Lowest Spend",
  most_models: "Most Models",
  most_tokens: "Most Tokens",
  best_efficiency: "Best Efficiency",
};

function challengeValue(kind: string, value: number): string {
  switch (kind) {
    case "lowest_spend": return formatUSD(value);
    case "most_models": return value === 1 ? "1 model" : `${value} models`;
    case "most_tokens": return formatTokens(value);
    default: return `${formatUSD(value)} / 1M`;
  }
}

function renderExtras(extras: BoardExtras): string {
  const challenges = extras.challenges
    .map((challenge) => {
      const people = challenge.finished ? challenge.winners : challenge.standings.filter((s) => s.rank === 1);
      const lead = people[0]
        ? `${challenge.finished ? "🏅 Won by" : "Leading:"} ${escapeHTML(people[0].displayName)} · ${challengeValue(challenge.kind, people[0].value)}`
        : challenge.finished ? "No winner" : "Nobody qualifies yet";
      const when = challenge.finished ? "Ended" : challenge.daysLeft === 1 ? "Last day" : `${challenge.daysLeft} days left`;
      return `<li><span class="name">${escapeHTML(CHALLENGE_TITLES[challenge.kind] ?? challenge.kind)}</span><span class="muted">${lead}</span><span class="value muted">${when}</span></li>`;
    })
    .join("");
  const champions = extras.champions
    .map((champion) => {
      const month = new Date(`${champion.month}-01T00:00:00Z`).toLocaleString("en-US", { month: "long", year: "numeric", timeZone: "UTC" });
      return `<li><span class="name">🏆 ${escapeHTML(month)}</span><span>${escapeHTML(champion.displayName)}</span><span class="value">${formatUSD(champion.costUSD)}</span></li>`;
    })
    .join("");
  return (challenges ? `<h2>Challenges</h2><ol class="models">${challenges}</ol>` : "")
    + (champions ? `<h2>Hall of Fame</h2><ol class="models">${champions}</ol>` : "");
}

function memberMarks(extras: BoardExtras | undefined, userID: string): string {
  if (!extras) return "";
  let marks = "";
  if (extras.kingUserID === userID) marks += ` <span title="Top spender today">👑</span>`;
  if (extras.lastMonthChampionID === userID) marks += ` <span title="Last month's champion">🏆</span>`;
  const reactions = extras.reactions[userID];
  if (reactions) {
    const counts = (["fire", "clap", "clown"] as const)
      .filter((emoji) => reactions[emoji] > 0)
      .map((emoji) => `${REACTION_EMOJI[emoji]}${reactions[emoji]}`)
      .join(" ");
    if (counts) marks += ` <span class="muted reactions">${counts}</span>`;
  }
  return marks;
}

/** "not synced for 3 days" once a member's newest upload is more than 24 hours old; otherwise nothing. */
export function syncNote(lastSyncAt: string | null, now: Date): string | null {
  if (!lastSyncAt) return null;
  const hours = (now.getTime() - Date.parse(lastSyncAt)) / 3_600_000;
  if (!(hours > 24)) return null;
  const days = Math.floor(hours / 24);
  return `not synced for ${days} ${days === 1 ? "day" : "days"}`;
}

export function renderBoard(teamName: string, stats: TeamStats, url: URL, extras?: BoardExtras, now: Date = new Date()): string {
  const value = (totals: { tokens: number; costUSD: number }) =>
    stats.sort === "cost" ? formatUSD(totals.costUSD) : formatTokens(totals.tokens);
  const metric = (totals: { tokens: number; costUSD: number }) => (stats.sort === "cost" ? totals.costUSD : totals.tokens);
  const shared = stats.shared.filter((account) => metric(account) > 0);
  const top = Math.max(...stats.members.map(metric), ...shared.map(metric), 0);
  const providers = stats.providers.map((p) => p.provider);

  const link = (range: string, sort: string, label: string, active: boolean) => {
    const target = new URL(url);
    target.searchParams.set("range", range);
    target.searchParams.set("sort", sort);
    target.searchParams.delete("today");
    return `<a class="chip${active ? " active" : ""}" href="${escapeHTML(target.pathname + target.search)}">${label}</a>`;
  };
  const rangeLinks = (["today", "7d", "30d", "365d"] as const)
    .map((range) => link(range, stats.sort, { today: "Today", "7d": "7 Days", "30d": "30 Days", "365d": "Year" }[range], range === stats.range.name))
    .join("");
  const sortLinks = [link(stats.range.name, "cost", "Spend", stats.sort === "cost"), link(stats.range.name, "tokens", "Tokens", stats.sort === "tokens")].join("");

  const rows = stats.members
    .map((member) => {
      const segments = member.providers
        .filter((provider) => metric(provider) > 0)
        .map((provider) => {
          const width = top > 0 ? (metric(provider) / top) * 100 : 0;
          const color = providerColor(provider.provider);
          return `<span style="width:${width.toFixed(2)}%;background:${color}" title="${escapeHTML(providerName(provider.provider))}: ${value(provider)}"></span>`;
        })
        .join("");
      return `<li><span class="rank">${member.rank}</span><span class="name">${escapeHTML(member.displayName)}${memberMarks(extras, member.userID)}${(() => {
        const note = syncNote(member.lastSyncAt, now);
        return note ? ` <span class="muted">· ${note}</span>` : "";
      })()}</span>
        <span class="bar">${segments}</span><span class="value">${value(member)}</span></li>`;
    })
    .join("");
  // Shared accounts are in the total but in no member's row: unranked, after the members.
  const names = new Map(stats.members.map((member) => [member.userID, member.displayName]));
  const sharedRows = shared
    .map((account) => {
      const width = top > 0 ? (metric(account) / top) * 100 : 0;
      const by = account.members.map((id) => names.get(id)).filter((name) => name !== undefined).join(", ");
      return `<li class="shared"><span class="rank">·</span><span class="name">Shared ${escapeHTML(providerName(account.provider))} <span class="muted">${escapeHTML(by)}</span></span>
        <span class="bar"><span style="width:${width.toFixed(2)}%;background:${providerColor(account.provider)};opacity:.6"></span></span><span class="value muted">${value(account)}</span></li>`;
    })
    .join("");
  const legend = providers
    .map((provider) => `<span><i style="background:${providerColor(provider)}"></i>${escapeHTML(providerName(provider))}</span>`)
    .join("");
  const models = stats.models
    .slice(0, 10)
    .map((model) => `<li><span class="name"><i class="dot" style="background:${providerColor(model.provider)}"></i>${escapeHTML(model.model)}</span><span class="muted">${escapeHTML(providerName(model.provider))}</span><span class="value">${value(model)}</span></li>`)
    .join("");

  return `<p class="eyebrow">GodUsage leaderboard</p>
    <h1>${escapeHTML(teamName)}</h1>
    <p class="muted">${stats.range.from === stats.range.to ? stats.range.to : `${stats.range.from} to ${stats.range.to}`} · Total ${value(stats.totals)}</p>
    ${extras?.projection ? `<p class="muted">Team on pace for ${formatUSD(extras.projection.projected)} in ${extras.projection.month}${extras.projection.daysLeft > 0 ? ` · ${extras.projection.daysLeft} days left` : ""}</p>` : ""}
    <nav>${rangeLinks}<span class="sep"></span>${sortLinks}</nav>
    <ol class="board">${rows + sharedRows || `<li class="muted">No usage shared yet.</li>`}</ol>
    <div class="legend">${legend}</div>
    ${models ? `<h2>Top Models</h2><ol class="models">${models}</ol>` : ""}
    ${extras ? renderExtras(extras) : ""}`;
}

/**
 * Provider colors match the Mac app's palette (TotalSpendPalette), so Claude is the same terracotta
 * everywhere. Brand-black providers get a light variant in dark mode via CSS variables.
 */
const PROVIDER_COLORS: Record<string, string> = {
  claude: "#DE7356",
  codex: "#10A37F",
  cursor: "var(--p-cursor)",
  grok: "var(--p-grok)",
  opencode: "var(--p-opencode)",
  openrouter: "#6467F2",
  antigravity: "#4285F4",
  copilot: "#A855F7",
  amp: "#F34E3F",
  factory: "var(--p-factory)",
  kimi: "#0A66FF",
  minimax: "#F5433C",
  zai: "var(--p-zai)",
};
const FALLBACK_COLORS = ["#34C759", "#5856D6", "#FF2D55", "#A2845E"];
const PROVIDER_NAMES: Record<string, string> = {
  claude: "Claude", codex: "Codex", cursor: "Cursor", grok: "Grok", opencode: "OpenCode", openrouter: "OpenRouter",
  antigravity: "Antigravity", copilot: "Copilot", kimi: "Kimi", zai: "Z.ai", muse: "Muse", sakana: "Sakana", devin: "Devin", pi: "Pi",
};

/** Same stable fallback as the app: keyed off the provider id, never its rank. */
export function providerColor(id: string): string {
  const known = PROVIDER_COLORS[id];
  if (known) return known;
  let hash = 0;
  for (const char of id) hash = (hash * 31 + char.codePointAt(0)!) & 0xffff;
  return FALLBACK_COLORS[hash % FALLBACK_COLORS.length]!;
}

function providerName(id: string): string {
  return PROVIDER_NAMES[id] ?? id.charAt(0).toUpperCase() + id.slice(1);
}

function formatUSD(value: number): string {
  return `$${value.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

function formatTokens(value: number): string {
  if (value >= 1e9) return `${(value / 1e9).toFixed(1)}B`;
  if (value >= 1e6) return `${(value / 1e6).toFixed(1)}M`;
  if (value >= 1e3) return `${(value / 1e3).toFixed(1)}K`;
  return String(value);
}

export function escapeHTML(value: string): string {
  return value.replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]!);
}

export function page(title: string, body: string, status = 200, extraHeaders: Record<string, string> = {}): Response {
  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>${escapeHTML(title)}</title>
<style>
:root { --bg:#fbfbfa; --fg:#1d1d1f; --muted:#6e6e73; --line:#e5e5e7; --card:#fff; --accent:#1d1d1f; --accent-fg:#fff;
  --p-cursor:#13120A; --p-grok:#8E8E93; --p-opencode:#6E6E73; --p-factory:#48484A; --p-zai:#2D2D2D; }
@media (prefers-color-scheme: dark) { :root { --bg:#161617; --fg:#f5f5f7; --muted:#a1a1a6; --line:#2c2c2e; --card:#1f1f21; --accent:#f5f5f7; --accent-fg:#161617;
  --p-cursor:#F5F5F7; --p-grok:#98989D; --p-opencode:#AEAEB2; --p-factory:#C7C7CC; --p-zai:#D1D1D6; } }
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--fg); font:16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
main { max-width:720px; margin:0 auto; padding:48px 16px; }
h1 { font-size:32px; line-height:1.2; margin:4px 0 8px; }
h2 { font-size:18px; margin:32px 0 8px; }
a { color:inherit; }
.eyebrow { text-transform:uppercase; letter-spacing:.08em; font-size:12px; color:var(--muted); margin:0; }
.muted { color:var(--muted); }
.button { display:inline-block; background:var(--accent); color:var(--accent-fg); padding:10px 18px; border-radius:10px; text-decoration:none; font-weight:600; }
nav { display:flex; flex-wrap:wrap; gap:6px; margin:16px 0; align-items:center; }
.chip { padding:4px 12px; border:1px solid var(--line); border-radius:999px; text-decoration:none; font-size:14px; }
.chip.active { background:var(--accent); color:var(--accent-fg); border-color:var(--accent); }
.sep { width:12px; }
footer { margin-top:48px; font-size:13px; }
h2 + ul, main ul { padding-left:20px; }
.account { display:flex; gap:12px; align-items:center; justify-content:space-between; margin-bottom:24px; font-size:14px; }
.account form { margin:0; }
.linkbutton { background:none; border:none; padding:0; color:inherit; text-decoration:underline; font:inherit; cursor:pointer; }
ol { list-style:none; padding:0; margin:0; }
.board li, .models li { display:grid; gap:12px; align-items:center; padding:10px 0; border-bottom:1px solid var(--line); }
.board li { grid-template-columns:28px minmax(80px, 160px) 1fr auto; }
.models li { grid-template-columns:1fr auto auto; }
.rank { color:var(--muted); font-variant-numeric:tabular-nums; }
.name { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.value { font-variant-numeric:tabular-nums; font-weight:600; text-align:right; }
.bar { display:flex; height:10px; border-radius:5px; overflow:hidden; background:var(--line); }
.bar { gap:2px; }
.bar span { display:block; height:100%; }
.reactions { font-size:12px; margin-left:4px; }
.dot { display:inline-block; width:8px; height:8px; border-radius:50%; margin-right:8px; vertical-align:0; }
.legend { display:flex; flex-wrap:wrap; gap:12px; margin-top:12px; font-size:13px; color:var(--muted); }
.legend i { display:inline-block; width:10px; height:10px; border-radius:3px; margin-right:6px; vertical-align:-1px; }
@media (max-width:480px) { .board li { grid-template-columns:24px 1fr auto; } .board .value { grid-row:1; grid-column:3; } .board .bar { grid-row:2; grid-column:2 / 4; } }
</style>
</head>
<body><main>${body}<footer class="muted"><a href="/privacy">Privacy Policy</a> · <a href="/terms">Terms</a></footer></main></body>
</html>`;
  return new Response(html, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'",
      "referrer-policy": "no-referrer",
      ...extraHeaders,
    },
  });
}
