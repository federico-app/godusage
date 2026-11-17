-- Claimed limit resets (see quotaClaims.ts). Claude keeps a weekly window's reset time when a reset is
-- claimed, so the window gets another full limit. Apps from 1.10.0 send each limit window's claims
-- ([{ at, after, percent, day, recorded }], [] when none); the window's percent is then the share used
-- since the last claim. NULL marks rows from older apps, whose percent is the highest share seen in the
-- whole window. Only adds a nullable column, so older servers and apps keep working on the same table.
ALTER TABLE quota_windows ADD COLUMN claims JSONB;
-- When the Mac's stretch since its last claim began (its first reading of it, `since` in the upload), so
-- the server can tell a share that may be from before a claim that Mac never saw. NULL when not sent.
ALTER TABLE quota_windows ADD COLUMN stretch_since TEXT;
