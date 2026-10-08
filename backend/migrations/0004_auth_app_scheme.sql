-- The URL scheme the app asked to come back on (`godusage` or `godusage-dev`), so a sign-in finished
-- in Safari returns to the app that started it when both the release and DEV apps are installed.
-- Null for requests from apps that don't send one: they come back on `godusage`.
ALTER TABLE auth_requests ADD COLUMN app_scheme TEXT;
