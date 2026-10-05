-- Sign in with Apple through the web (Developer ID builds cannot use the native flow).
-- A pending request lives from /v1/auth/apple/start until Apple posts back to the callback.
CREATE TABLE auth_requests (
  state TEXT PRIMARY KEY,
  nonce TEXT NOT NULL,
  code_challenge TEXT NOT NULL,
  app_state TEXT NOT NULL,
  expires_at TEXT NOT NULL
);

-- A one-time code the app trades for a session, bound to the app's PKCE challenge so only the app
-- that started the sign-in can redeem it. Only the SHA-256 of the code is stored.
CREATE TABLE login_codes (
  code_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  code_challenge TEXT NOT NULL,
  created INTEGER NOT NULL CHECK (created IN (0, 1)),
  expires_at TEXT NOT NULL
);
