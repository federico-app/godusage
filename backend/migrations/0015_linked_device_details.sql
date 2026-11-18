-- What a phone or iPad linked by QR pairing reports about itself in the X-GodUsage-Client header
-- (see clientHeader.ts): its model ("iPhone 13"), OS version ("26.1") and GodUsage version ("1.10.1"),
-- and when it last used its session. Set only on paired sessions; NULL until the device reports (apps
-- before this header never do). last_seen_at is written at most once an hour, so reads stay reads.
-- Only adds nullable columns, so older servers and apps keep working on the same table.
ALTER TABLE sessions ADD COLUMN device_model TEXT;
ALTER TABLE sessions ADD COLUMN os_version TEXT;
ALTER TABLE sessions ADD COLUMN app_version TEXT;
ALTER TABLE sessions ADD COLUMN last_seen_at TEXT;
