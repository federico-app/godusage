-- Accounts an owner hides from a team plan (a JSON array of account keys, as quota_windows names
-- them): a member's own login beside the plan's shared one. They stay out of the plan's quota
-- figures (weekly limit, Live Pace, Per Day, Sessions, Weekly History); usage still counts. See plans.ts.
ALTER TABLE team_plans ADD COLUMN hidden_accounts TEXT;
