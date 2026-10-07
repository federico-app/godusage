-- The GodUsage version each Mac last uploaded from, shown beside "updated 5m ago" on the boards.
-- Null for uploads from apps before 1.0.8.
ALTER TABLE devices ADD COLUMN app_version TEXT;
