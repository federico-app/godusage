-- An anonymous fingerprint of the provider account behind account-scope rows (a hash made on the
-- Mac; the account id itself never leaves it). Two team members uploading the same fingerprint share
-- one account: their usage counts once for the team and belongs to neither member.
ALTER TABLE usage_days ADD COLUMN account_key TEXT;
ALTER TABLE usage_model_days ADD COLUMN account_key TEXT;
CREATE INDEX usage_days_account_key ON usage_days(account_key) WHERE account_key IS NOT NULL;
