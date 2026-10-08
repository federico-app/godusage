-- Who a team plan covers, as a JSON array of user ids. Null covers every member (plans saved
-- before this column existed). The Plans report counts only covered members' usage, and only
-- covered members get the dashboard suggestion to use the plan.
ALTER TABLE team_plans ADD COLUMN member_ids TEXT;
