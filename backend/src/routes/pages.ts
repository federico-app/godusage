import type { Handler } from "../context";
import { ApiError } from "../http";
import { parseStatsQuery, teamStats, type TeamStats } from "../stats";
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
  const stats = await teamStats(env.DB, team.id, query);
  return page(`${team.name} Leaderboard`, renderBoard(team.name, stats, url));
};

export function renderBoard(teamName: string, stats: TeamStats, url: URL): string {
  const value = (totals: { tokens: number; costUSD: number }) =>
    stats.sort === "cost" ? formatUSD(totals.costUSD) : formatTokens(totals.tokens);
  const metric = (totals: { tokens: number; costUSD: number }) => (stats.sort === "cost" ? totals.costUSD : totals.tokens);
  const top = Math.max(...stats.members.map(metric), 0);
  const providers = stats.providers.map((p) => p.provider);

  const link = (range: string, sort: string, label: string, active: boolean) => {
    const target = new URL(url);
    target.searchParams.set("range", range);
    target.searchParams.set("sort", sort);
    target.searchParams.delete("today");
    return `<a class="chip${active ? " active" : ""}" href="${escapeHTML(target.pathname + target.search)}">${label}</a>`;
  };
  const rangeLinks = (["today", "7d", "30d"] as const)
    .map((range) => link(range, stats.sort, { today: "Today", "7d": "7 Days", "30d": "30 Days" }[range], range === stats.range.name))
    .join("");
  const sortLinks = [link(stats.range.name, "cost", "Spend", stats.sort === "cost"), link(stats.range.name, "tokens", "Tokens", stats.sort === "tokens")].join("");

  const rows = stats.members
    .map((member) => {
      const segments = member.providers
        .filter((provider) => metric(provider) > 0)
        .map((provider) => {
          const width = top > 0 ? (metric(provider) / top) * 100 : 0;
          const color = `var(--c${providers.indexOf(provider.provider) % 8})`;
          return `<span style="width:${width.toFixed(2)}%;background:${color}" title="${escapeHTML(provider.provider)}: ${value(provider)}"></span>`;
        })
        .join("");
      return `<li><span class="rank">${member.rank}</span><span class="name">${escapeHTML(member.displayName)}</span>
        <span class="bar">${segments}</span><span class="value">${value(member)}</span></li>`;
    })
    .join("");
  const legend = providers
    .map((provider, index) => `<span><i style="background:var(--c${index % 8})"></i>${escapeHTML(provider)}</span>`)
    .join("");
  const models = stats.models
    .slice(0, 10)
    .map((model) => `<li><span class="name">${escapeHTML(model.model)}</span><span class="muted">${escapeHTML(model.provider)}</span><span class="value">${value(model)}</span></li>`)
    .join("");

  return `<p class="eyebrow">GodUsage leaderboard</p>
    <h1>${escapeHTML(teamName)}</h1>
    <p class="muted">${stats.range.from === stats.range.to ? stats.range.to : `${stats.range.from} to ${stats.range.to}`} · Total ${value(stats.totals)}</p>
    <nav>${rangeLinks}<span class="sep"></span>${sortLinks}</nav>
    <ol class="board">${rows || `<li class="muted">No usage shared yet.</li>`}</ol>
    <div class="legend">${legend}</div>
    ${models ? `<h2>Top Models</h2><ol class="models">${models}</ol>` : ""}`;
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
  --c0:#4f6bed; --c1:#e8833a; --c2:#2fa37c; --c3:#c94f7c; --c4:#8a63d2; --c5:#d4a72c; --c6:#3a9ad9; --c7:#7a7a80; }
@media (prefers-color-scheme: dark) { :root { --bg:#161617; --fg:#f5f5f7; --muted:#a1a1a6; --line:#2c2c2e; --card:#1f1f21; --accent:#f5f5f7; --accent-fg:#161617; } }
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
.bar span { display:block; height:100%; }
.legend { display:flex; flex-wrap:wrap; gap:12px; margin-top:12px; font-size:13px; color:var(--muted); }
.legend i { display:inline-block; width:10px; height:10px; border-radius:3px; margin-right:6px; vertical-align:-1px; }
@media (max-width:480px) { .board li { grid-template-columns:24px 1fr auto; } .board .value { grid-row:1; grid-column:3; } .board .bar { grid-row:2; grid-column:2 / 4; } }
</style>
</head>
<body><main>${body}</main></body>
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
