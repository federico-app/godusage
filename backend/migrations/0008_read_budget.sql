-- Which provider-account fingerprints each user has uploaded, so finding a team's shared accounts no
-- longer scans every member's whole usage history (D1 bills every row read). Kept in step with
-- usage_days by every upload and device removal.
CREATE TABLE account_keys (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  account_key TEXT NOT NULL,
  provider TEXT NOT NULL,
  PRIMARY KEY (user_id, account_key, provider)
);

INSERT INTO account_keys (user_id, account_key, provider)
SELECT DISTINCT user_id, account_key, provider FROM usage_days WHERE account_key IS NOT NULL;

-- The last 12 months' champions per team, recomputed at most once an hour (they only change when a
-- month ends or a late upload lands).
CREATE TABLE team_champions (
  team_id TEXT NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
  month TEXT NOT NULL,
  champions TEXT NOT NULL,
  computed_at TEXT NOT NULL,
  PRIMARY KEY (team_id, month)
);
