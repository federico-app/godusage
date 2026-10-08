-- The teams backend's schema on Postgres: the D1 schema after d1-migrations/0010_read_guard.sql, minus
-- what moved to Redis (stats_cache, team_champions, teams.stats_version) and the D1-only read budget.
-- Timestamps and days stay ISO 8601 TEXT, as on D1, so `server.mjs import-d1` copies them unchanged.

-- Accounts are keyed by the Sign in with Apple subject. Display names are chosen by the user.
CREATE TABLE users (
  id TEXT PRIMARY KEY,
  apple_sub TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  created_at TEXT NOT NULL
);

-- Only the SHA-256 of a session token is stored. App sessions live 180 days, browser sessions 30.
CREATE TABLE sessions (
  token_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  lifetime_days INTEGER NOT NULL DEFAULT 180
);
CREATE INDEX sessions_user ON sessions(user_id);

-- One active invite code per team; rotating it invalidates the old link.
-- public_token is set only while the owner shares a read-only web leaderboard.
CREATE TABLE teams (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  invite_code TEXT NOT NULL UNIQUE,
  public_token TEXT UNIQUE,
  created_at TEXT NOT NULL
);

CREATE TABLE team_members (
  team_id TEXT NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('owner', 'member')),
  joined_at TEXT NOT NULL,
  PRIMARY KEY (team_id, user_id)
);
CREATE INDEX team_members_user ON team_members(user_id);

-- Device ids come from the app; they are only unique per user. app_version is null for uploads from
-- apps before 1.0.8.
CREATE TABLE devices (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  id TEXT NOT NULL,
  name TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  app_version TEXT,
  PRIMARY KEY (user_id, id)
);

-- scope 'device': usage read from this Mac's own logs, summed across a user's Macs.
-- scope 'account': usage that is already account-wide (Cursor), taken from the newest device only.
-- account_key: an anonymous fingerprint of the provider account (a hash made on the Mac).
CREATE TABLE usage_days (
  user_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  provider TEXT NOT NULL,
  day TEXT NOT NULL,
  scope TEXT NOT NULL CHECK (scope IN ('device', 'account')),
  tokens BIGINT NOT NULL,
  cost_usd DOUBLE PRECISION,
  account_key TEXT,
  PRIMARY KEY (user_id, device_id, provider, day),
  FOREIGN KEY (user_id, device_id) REFERENCES devices(user_id, id) ON DELETE CASCADE
);
-- The leaderboards read a period of a team's members straight from this index.
CREATE INDEX usage_days_user_day ON usage_days(user_id, day) INCLUDE (scope, provider, device_id, account_key, tokens, cost_usd);
CREATE INDEX usage_days_account_key ON usage_days(account_key, user_id, provider) WHERE account_key IS NOT NULL;

CREATE TABLE usage_model_days (
  user_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  provider TEXT NOT NULL,
  day TEXT NOT NULL,
  model TEXT NOT NULL,
  scope TEXT NOT NULL CHECK (scope IN ('device', 'account')),
  tokens BIGINT NOT NULL,
  cost_usd DOUBLE PRECISION,
  account_key TEXT,
  PRIMARY KEY (user_id, device_id, provider, day, model),
  FOREIGN KEY (user_id, device_id) REFERENCES devices(user_id, id) ON DELETE CASCADE
);
CREATE INDEX usage_model_days_user_day ON usage_model_days(user_id, day) INCLUDE (scope, provider, model, device_id, account_key, tokens, cost_usd);

-- Which provider-account fingerprints each user has uploaded, so finding a team's shared accounts
-- doesn't read usage history. Kept in step with usage_days by every upload and device removal.
CREATE TABLE account_keys (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  account_key TEXT NOT NULL,
  provider TEXT NOT NULL,
  PRIMARY KEY (user_id, account_key, provider)
);

-- Sign in with Apple through the web. A pending request lives from /v1/auth/apple/start until Apple
-- posts back to the callback; it is for the app (a one-time code to godusage://auth) or for the web
-- (a session cookie, then back to `return_to`).
CREATE TABLE auth_requests (
  state TEXT PRIMARY KEY,
  nonce TEXT NOT NULL,
  code_challenge TEXT NOT NULL,
  app_state TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'app' CHECK (kind IN ('app', 'web')),
  return_to TEXT
);
CREATE INDEX auth_requests_expires ON auth_requests(expires_at);

-- A one-time code the app trades for a session, bound to the app's PKCE challenge. Only the SHA-256
-- of the code is stored.
CREATE TABLE login_codes (
  code_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  code_challenge TEXT NOT NULL,
  created INTEGER NOT NULL CHECK (created IN (0, 1)),
  expires_at TEXT NOT NULL
);

-- Reactions a member gives another member, one of each emoji per giver and receiver per UTC day.
CREATE TABLE reactions (
  team_id TEXT NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
  from_user TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  to_user TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  emoji TEXT NOT NULL CHECK (emoji IN ('fire', 'clap', 'clown')),
  day TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (team_id, from_user, to_user, emoji, day)
);
CREATE INDEX reactions_team_day ON reactions(team_id, day);

-- Timed challenges inside a team, computed from usage between starts_on and ends_on (inclusive).
CREATE TABLE challenges (
  id TEXT PRIMARY KEY,
  team_id TEXT NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('lowest_spend', 'most_models', 'most_tokens', 'best_efficiency')),
  starts_on TEXT NOT NULL,
  ends_on TEXT NOT NULL,
  created_by TEXT REFERENCES users(id) ON DELETE SET NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX challenges_team ON challenges(team_id, ends_on);

-- The subscriptions a team pays for. The owner keeps the list.
CREATE TABLE team_plans (
  id TEXT PRIMARY KEY,
  team_id TEXT NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
  provider TEXT NOT NULL,
  name TEXT NOT NULL,
  monthly_cost_usd DOUBLE PRECISION NOT NULL,
  renewal_day INTEGER NOT NULL CHECK (renewal_day BETWEEN 1 AND 31),
  position INTEGER NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX team_plans_team ON team_plans(team_id, position);
