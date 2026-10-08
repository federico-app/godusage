-- The subscriptions a team pays for (Claude Max, Cursor Ultra, ...). The owner keeps the list; the
-- Plans report compares each plan's cost with the team's usage at API prices in its billing cycle.
CREATE TABLE team_plans (
  id TEXT PRIMARY KEY,
  team_id TEXT NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
  provider TEXT NOT NULL,
  name TEXT NOT NULL,
  monthly_cost_usd REAL NOT NULL,
  renewal_day INTEGER NOT NULL CHECK (renewal_day BETWEEN 1 AND 31),
  position INTEGER NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX team_plans_team ON team_plans(team_id, position);
