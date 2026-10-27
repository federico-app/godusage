-- A team plan's price history. From effective_from (a calendar day, inclusive) the plan has this name
-- and monthly price; team_plans.name and monthly_cost_usd are its terms before its first change. The
-- Plans report prorates a cycle that contains a change (see plans.ts).
CREATE TABLE team_plan_changes (
  plan_id TEXT NOT NULL REFERENCES team_plans(id) ON DELETE CASCADE,
  effective_from TEXT NOT NULL,
  name TEXT NOT NULL,
  monthly_cost_usd DOUBLE PRECISION NOT NULL,
  PRIMARY KEY (plan_id, effective_from)
);

-- The plan label GodUsage detects that a team plan stands for (e.g. "Max 20x"), and the detected
-- labels the owner chose to ignore for it (a JSON array). A covered member whose Mac detects another
-- label flags the plan for the owner.
ALTER TABLE team_plans ADD COLUMN detected_plan TEXT;
ALTER TABLE team_plans ADD COLUMN ignored_plans TEXT;

-- The plan GodUsage detected per provider on each Mac, as its latest upload sent it. detected_at and
-- detected_on (the Mac's local day) change only when the label does, so they say since when the Mac
-- has seen it. Removed with the Mac.
CREATE TABLE detected_plans (
  user_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  provider TEXT NOT NULL,
  plan TEXT NOT NULL,
  detected_at TEXT NOT NULL,
  detected_on TEXT NOT NULL,
  PRIMARY KEY (user_id, device_id, provider),
  FOREIGN KEY (user_id, device_id) REFERENCES devices(user_id, id) ON DELETE CASCADE
);
CREATE INDEX detected_plans_user ON detected_plans(user_id, provider);
