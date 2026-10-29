-- How much of each plan's quota window an account used, for the Plans report's "plan used" (see
-- quota.ts). Each upload that carries quota windows replaces the Mac's rows. A window is the
-- provider's limiting quota (Claude and Codex weekly, Cursor's billing cycle) for one account,
-- keyed by an anonymous fingerprint of it. Removed with the Mac.
CREATE TABLE quota_windows (
  user_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  provider TEXT NOT NULL,
  account_key TEXT NOT NULL,
  -- When the window resets, ISO 8601 UTC, rounded to the hour so every Mac names it the same.
  ends_at TEXT NOT NULL,
  period_hours INTEGER NOT NULL,
  -- The highest share of the window seen used, 0–100.
  percent DOUBLE PRECISION NOT NULL,
  -- The Mac's last reading of the window (ISO 8601). Long before ends_at, percent is a lower bound.
  observed_at TEXT NOT NULL,
  PRIMARY KEY (user_id, device_id, provider, account_key, ends_at),
  FOREIGN KEY (user_id, device_id) REFERENCES devices(user_id, id) ON DELETE CASCADE
);
CREATE INDEX quota_windows_user ON quota_windows(user_id, provider);
