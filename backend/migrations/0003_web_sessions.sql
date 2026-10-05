-- Browser sign-in for the members-only web leaderboard. A sign-in request is either for the app
-- (returns a one-time code to godusage://auth) or for the web (sets a session cookie and returns to
-- `return_to`). Web sessions live shorter than app sessions.
ALTER TABLE auth_requests ADD COLUMN kind TEXT NOT NULL DEFAULT 'app' CHECK (kind IN ('app', 'web'));
ALTER TABLE auth_requests ADD COLUMN return_to TEXT;
ALTER TABLE sessions ADD COLUMN lifetime_days INTEGER NOT NULL DEFAULT 180;
