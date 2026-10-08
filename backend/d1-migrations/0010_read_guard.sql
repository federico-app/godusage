-- Covering indexes for the leaderboard queries: a day range of a team's members is read straight from
-- the index, never from the table (D1 bills every row read, table lookups included). They replace the
-- (user_id, day) indexes, so uploads touch as many indexes as before.
CREATE INDEX usage_days_user_day_cover
  ON usage_days(user_id, scope, day, provider, device_id, account_key, tokens, cost_usd);
DROP INDEX usage_days_user_day;
CREATE INDEX usage_model_days_user_day_cover
  ON usage_model_days(user_id, scope, day, provider, model, device_id, account_key, tokens, cost_usd);
DROP INDEX usage_model_days_user_day;

-- Bumped whenever something a team's stats show changes (usage, members, names, plans, challenges),
-- so a cached response is reused until then.
ALTER TABLE teams ADD COLUMN stats_version INTEGER NOT NULL DEFAULT 0;

-- Computed stats, challenges, and plan reports per team, reused while the team's stats_version is
-- unchanged (see src/readGuard.ts).
CREATE TABLE stats_cache (
  team_id TEXT NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
  cache_key TEXT NOT NULL,
  version INTEGER NOT NULL,
  body TEXT NOT NULL,
  computed_at TEXT NOT NULL,
  PRIMARY KEY (team_id, cache_key)
);

-- Rows read per UTC day by the expensive work (stats, challenges, plans, uploads). Past the daily
-- budget the server serves cached results until midnight UTC instead of reading more.
CREATE TABLE read_budget (
  day TEXT PRIMARY KEY,
  rows_read INTEGER NOT NULL
);
