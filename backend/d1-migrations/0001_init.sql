-- Accounts are keyed by the Sign in with Apple subject. Display names are chosen by the user.
CREATE TABLE users (
  id TEXT PRIMARY KEY,
  apple_sub TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  created_at TEXT NOT NULL
);

-- Only the SHA-256 of a session token is stored.
CREATE TABLE sessions (
  token_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL
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

-- Device ids come from the app; they are only unique per user.
CREATE TABLE devices (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  id TEXT NOT NULL,
  name TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (user_id, id)
);

-- scope 'device': usage read from this Mac's own logs, summed across a user's Macs.
-- scope 'account': usage that is already account-wide (Cursor), taken from the newest device only.
CREATE TABLE usage_days (
  user_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  provider TEXT NOT NULL,
  day TEXT NOT NULL,
  scope TEXT NOT NULL CHECK (scope IN ('device', 'account')),
  tokens INTEGER NOT NULL,
  cost_usd REAL,
  PRIMARY KEY (user_id, device_id, provider, day),
  FOREIGN KEY (user_id, device_id) REFERENCES devices(user_id, id) ON DELETE CASCADE
);
CREATE INDEX usage_days_user_day ON usage_days(user_id, day);

CREATE TABLE usage_model_days (
  user_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  provider TEXT NOT NULL,
  day TEXT NOT NULL,
  model TEXT NOT NULL,
  scope TEXT NOT NULL CHECK (scope IN ('device', 'account')),
  tokens INTEGER NOT NULL,
  cost_usd REAL,
  PRIMARY KEY (user_id, device_id, provider, day, model),
  FOREIGN KEY (user_id, device_id) REFERENCES devices(user_id, id) ON DELETE CASCADE
);
CREATE INDEX usage_model_days_user_day ON usage_model_days(user_id, day);
