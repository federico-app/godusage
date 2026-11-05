-- Live Pace (see livePace.ts): each member's working hours, the time zone they're in, and recent
-- readings of the open weekly windows, for the pace of the last working hour.

-- A member's working hours, in their own time zone (one per person, shared by all their teams).
-- days is a JSON array of ISO weekdays (1 = Monday … 7 = Sunday); the times are minutes after
-- midnight. A member without a row works the team's working days, 9:00 to 18:00.
CREATE TABLE work_schedules (
  user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  days TEXT NOT NULL,
  start_minute INTEGER NOT NULL,
  end_minute INTEGER NOT NULL,
  break_start_minute INTEGER,
  break_end_minute INTEGER,
  updated_at TEXT NOT NULL
);

-- The IANA time zone of the user's Mac, from their latest upload that sent one (null before).
ALTER TABLE users ADD COLUMN time_zone TEXT;

-- Each Mac's readings of its accounts' open weekly windows, kept a day and a half.
CREATE TABLE quota_readings (
  user_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  provider TEXT NOT NULL,
  account_key TEXT NOT NULL,
  ends_at TEXT NOT NULL,
  observed_at TEXT NOT NULL,
  percent DOUBLE PRECISION NOT NULL,
  PRIMARY KEY (user_id, device_id, provider, account_key, observed_at),
  FOREIGN KEY (user_id, device_id) REFERENCES devices(user_id, id) ON DELETE CASCADE
);
CREATE INDEX quota_readings_user ON quota_readings(user_id, observed_at);
