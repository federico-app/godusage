-- Reactions now last one day instead of one week: the period column holds the UTC day they were
-- given ("2026-10-07"). Existing rows keep the day they were created on.
DROP INDEX reactions_team_week;
ALTER TABLE reactions RENAME COLUMN week TO day;
UPDATE reactions SET day = substr(created_at, 1, 10);
CREATE INDEX reactions_team_day ON reactions(team_id, day);
