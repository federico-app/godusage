-- Whether a membership counts toward the team: its usage, ranks, challenges, champions, momentum,
-- detected plans, and plan coverage. Only an owner can turn it off, for themself, to run a team they
-- don't use (see routes/teams.ts). Being made a member turns it back on.
ALTER TABLE team_members ADD COLUMN counts_usage BOOLEAN NOT NULL DEFAULT TRUE;
