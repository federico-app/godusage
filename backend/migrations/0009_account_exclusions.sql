-- Leaving a provider account out of a team (see teamUsage.ts). A Mac sends an account a member
-- leaves out of any team as its own usage rows, keyed by `slot` (the account's anonymous
-- fingerprint); every other account of the provider stays folded in the row with slot ''. Rows
-- stored before this migration have slot ''.
ALTER TABLE usage_days ADD COLUMN slot TEXT NOT NULL DEFAULT '';
ALTER TABLE usage_days DROP CONSTRAINT usage_days_pkey;
ALTER TABLE usage_days ADD PRIMARY KEY (user_id, device_id, provider, slot, day);
DROP INDEX usage_days_user_day;
CREATE INDEX usage_days_user_day ON usage_days(user_id, day) INCLUDE (scope, provider, slot, device_id, account_key, tokens, cost_usd);

ALTER TABLE usage_model_days ADD COLUMN slot TEXT NOT NULL DEFAULT '';
ALTER TABLE usage_model_days DROP CONSTRAINT usage_model_days_pkey;
ALTER TABLE usage_model_days ADD PRIMARY KEY (user_id, device_id, provider, slot, day, model);
DROP INDEX usage_model_days_user_day;
CREATE INDEX usage_model_days_user_day ON usage_model_days(user_id, day) INCLUDE (scope, provider, slot, model, device_id, account_key, tokens, cost_usd);

-- The ⚡ pulses keep the slot too, so a left-out account's spend never lights up that team.
ALTER TABLE spend_pulses ADD COLUMN slot TEXT NOT NULL DEFAULT '';
ALTER TABLE spend_pulses DROP CONSTRAINT spend_pulses_pkey;
ALTER TABLE spend_pulses ADD PRIMARY KEY (user_id, device_id, slot, bucket);

-- Which of a member's accounts (by fingerprint) a Mac leaves out of which team. Each upload that
-- carries `excludedAccounts` replaces the Mac's rows. Removed with the Mac or the team.
CREATE TABLE account_exclusions (
  user_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  team_id TEXT NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
  provider TEXT NOT NULL,
  account_key TEXT NOT NULL,
  PRIMARY KEY (user_id, device_id, team_id, account_key),
  FOREIGN KEY (user_id, device_id) REFERENCES devices(user_id, id) ON DELETE CASCADE
);
CREATE INDEX account_exclusions_team ON account_exclusions(team_id, user_id);
