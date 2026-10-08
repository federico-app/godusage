-- QR pairing: a signed-in Mac asks for a one-time code and shows it as a QR code; the iPhone app
-- trades it for its own session of the same account. Only the code's SHA-256 is stored, and a user
-- has at most one live code (asking for a new one drops the old one).
CREATE TABLE pairing_codes (
  code_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expires_at TEXT NOT NULL
);
CREATE INDEX pairing_codes_user ON pairing_codes(user_id);

-- The name of the phone or iPad a session was paired to. Set only on sessions made by pairing, so
-- the Mac can list linked devices and unlink them.
ALTER TABLE sessions ADD COLUMN paired_device TEXT;
