-- When usage was spent, for the "accelerating" ⚡ on leaderboards: each upload adds how much the
-- Mac's recent days grew to the five-minute bucket it arrived in. Kept seven days (see momentum.ts).
CREATE TABLE spend_pulses (
  user_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  -- Start of the five-minute bucket, ISO 8601 UTC (e.g. 2026-10-08T15:05:00.000Z).
  bucket TEXT NOT NULL,
  cost_usd DOUBLE PRECISION NOT NULL,
  PRIMARY KEY (user_id, device_id, bucket),
  FOREIGN KEY (user_id, device_id) REFERENCES devices(user_id, id) ON DELETE CASCADE
);
CREATE INDEX spend_pulses_user_bucket ON spend_pulses(user_id, bucket);
