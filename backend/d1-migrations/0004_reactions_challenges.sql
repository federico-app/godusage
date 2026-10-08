-- Reactions a member gives another member on the leaderboard. One of each emoji per giver and
-- receiver per week (ISO week of the UTC date); a new week starts clean.
CREATE TABLE reactions (
  team_id TEXT NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
  from_user TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  to_user TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  emoji TEXT NOT NULL CHECK (emoji IN ('fire', 'clap', 'clown')),
  week TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (team_id, from_user, to_user, emoji, week)
);
CREATE INDEX reactions_team_week ON reactions(team_id, week);

-- Timed challenges inside a team. Standings are computed from usage between starts_on and ends_on
-- (inclusive); the winner is fixed once ends_on has passed.
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
