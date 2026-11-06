-- Working hours belong to a member in one team, not to the person: someone who works weekdays for one
-- team and weekends for another sets each apart. Each stored schedule is copied to every team its
-- owner is in, so nothing changes until someone edits one. Leaving a team removes its hours there.
CREATE TABLE team_work_schedules (
  team_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  days TEXT NOT NULL,
  start_minute INTEGER NOT NULL,
  end_minute INTEGER NOT NULL,
  break_start_minute INTEGER,
  break_end_minute INTEGER,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (team_id, user_id),
  FOREIGN KEY (team_id, user_id) REFERENCES team_members(team_id, user_id) ON DELETE CASCADE
);
CREATE INDEX team_work_schedules_user ON team_work_schedules(user_id);

INSERT INTO team_work_schedules (team_id, user_id, days, start_minute, end_minute, break_start_minute, break_end_minute, updated_at)
SELECT m.team_id, s.user_id, s.days, s.start_minute, s.end_minute, s.break_start_minute, s.break_end_minute, s.updated_at
FROM work_schedules s JOIN team_members m ON m.user_id = s.user_id;

DROP TABLE work_schedules;
