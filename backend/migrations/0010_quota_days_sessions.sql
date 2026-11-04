-- The team's working days, as ISO weekdays (1 = Monday … 7 = Sunday) in a JSON array. The Plans
-- report paces its forecasts on them (see workingDays.ts). Monday to Friday by default.
ALTER TABLE teams ADD COLUMN working_days TEXT NOT NULL DEFAULT '[1,2,3,4,5]';

-- Quota windows now come in two kinds: 'limit' (the plan's limiting window, as before) and
-- 'session' (Claude's and Codex's 5-hour session). A limit window also carries the share seen used
-- at the end of each calendar day it was read (`days`, [{ day, percent }]), for the daily usage
-- (see quotaDaily.ts). Rows stored before this migration are limit windows without days.
ALTER TABLE quota_windows ADD COLUMN kind TEXT NOT NULL DEFAULT 'limit' CHECK (kind IN ('limit', 'session'));
ALTER TABLE quota_windows ADD COLUMN days JSONB;
-- Whether the Mac could only name the account per Mac (no account id to hash), so one account used
-- on several Macs looks like several. The Plans report warns about those. Claude's and Codex's
-- windows stored before this migration were all named per Mac.
ALTER TABLE quota_windows ADD COLUMN per_device BOOLEAN NOT NULL DEFAULT false;
UPDATE quota_windows SET per_device = true WHERE provider IN ('claude', 'codex');
ALTER TABLE quota_windows DROP CONSTRAINT quota_windows_pkey;
ALTER TABLE quota_windows ADD PRIMARY KEY (user_id, device_id, provider, kind, account_key, ends_at);
