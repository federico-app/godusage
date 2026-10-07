import { badRequest, isRecord, requireName } from "./http";

export const USAGE_SCHEMA = "godusage.team-usage.v1";
/** Uploads carry the app's 30-day window; a little slack covers time zones and clock skew. */
export const UPLOAD_WINDOW_DAYS = 40;
const MAX_PROVIDERS = 40;
const MAX_MODELS_PER_DAY = 100;
const MAX_TOKENS = 1e13;
const MAX_COST_USD = 1e6;

export type Scope = "device" | "account";

export interface DayRow {
  provider: string;
  day: string;
  scope: Scope;
  /** The account's anonymous fingerprint, for account-scope rows whose app sent one. */
  accountKey: string | null;
  tokens: number;
  costUSD: number | null;
}

export interface ModelRow extends DayRow {
  model: string;
}

export interface UsageUpload {
  deviceName: string;
  /** The GodUsage version that sent the upload; null from apps before 1.0.8. */
  appVersion: string | null;
  /**
   * The first day this upload speaks for. The device's stored days from here on are replaced; older
   * days are kept, so history outlives the app's 30-day window. Null when the upload covers no days.
   */
  replaceFrom: string | null;
  days: DayRow[];
  models: ModelRow[];
}

const DAY_PATTERN = /^\d{4}-\d{2}-\d{2}$/;
const PROVIDER_PATTERN = /^[a-z0-9][a-z0-9-]{0,39}$/;
const ACCOUNT_KEY_PATTERN = /^[a-f0-9]{32,64}$/;

export function dayKey(date: Date): string {
  return date.toISOString().slice(0, 10);
}

export function addDays(day: string, delta: number): string {
  const date = new Date(`${day}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + delta);
  return dayKey(date);
}

export function isValidDay(value: unknown): value is string {
  return typeof value === "string" && DAY_PATTERN.test(value) && dayKey(new Date(`${value}T00:00:00Z`)) === value;
}

const APP_VERSION_PATTERN = /^[0-9A-Za-z.+-]{1,32}$/;

/**
 * Validates one device's upload (the system boundary for usage data) and flattens it into rows.
 * Shape: { schema, deviceName, appVersion?, providers: [{ provider, scope, account?, days: [{ date, tokens, costUSD, models? }] }] }
 */
export function parseUsageUpload(body: Record<string, unknown>, now: Date): UsageUpload {
  if (body.schema !== USAGE_SCHEMA) throw badRequest(`schema must be "${USAGE_SCHEMA}". Update GodUsage.`);
  const deviceName = requireName(body.deviceName, "deviceName", 80);
  let appVersion: string | null = null;
  if (body.appVersion !== undefined) {
    if (typeof body.appVersion !== "string" || !APP_VERSION_PATTERN.test(body.appVersion)) {
      throw badRequest("appVersion must be a short version string like 1.0.8.");
    }
    appVersion = body.appVersion;
  }
  if (!Array.isArray(body.providers)) throw badRequest("providers must be an array.");
  if (body.providers.length > MAX_PROVIDERS) throw badRequest(`At most ${MAX_PROVIDERS} providers per upload.`);

  const today = dayKey(now);
  const earliest = addDays(today, -UPLOAD_WINDOW_DAYS);
  const latest = addDays(today, 1);
  let windowStart: string | null = null;
  if (body.windowStart !== undefined) {
    if (!isValidDay(body.windowStart) || body.windowStart < earliest || body.windowStart > latest) {
      throw badRequest("windowStart must be a recent YYYY-MM-DD date.");
    }
    windowStart = body.windowStart;
  }

  const seenProviders = new Set<string>();
  const days: DayRow[] = [];
  const models: ModelRow[] = [];

  for (const entry of body.providers) {
    if (!isRecord(entry)) throw badRequest("Each provider entry must be an object.");
    const provider = entry.provider;
    if (typeof provider !== "string" || !PROVIDER_PATTERN.test(provider)) throw badRequest("Invalid provider id.");
    if (seenProviders.has(provider)) throw badRequest(`Duplicate provider ${provider}.`);
    seenProviders.add(provider);
    if (entry.scope !== "device" && entry.scope !== "account") throw badRequest(`Invalid scope for ${provider}.`);
    const scope: Scope = entry.scope;
    let accountKey: string | null = null;
    if (entry.account !== undefined && entry.account !== null) {
      if (scope !== "account") throw badRequest(`account is only allowed on account-scope usage (${provider}).`);
      if (typeof entry.account !== "string" || !ACCOUNT_KEY_PATTERN.test(entry.account)) {
        throw badRequest(`Invalid account for ${provider}.`);
      }
      accountKey = entry.account;
    }
    if (!Array.isArray(entry.days)) throw badRequest(`days must be an array for ${provider}.`);
    if (entry.days.length > UPLOAD_WINDOW_DAYS + 2) throw badRequest(`Too many days for ${provider}.`);

    const seenDays = new Set<string>();
    for (const dayEntry of entry.days) {
      if (!isRecord(dayEntry)) throw badRequest("Each day must be an object.");
      const day = dayEntry.date;
      if (!isValidDay(day)) throw badRequest(`Invalid date for ${provider}.`);
      if (seenDays.has(day)) throw badRequest(`Duplicate date ${day} for ${provider}.`);
      seenDays.add(day);
      // Days outside the window are dropped, not rejected: the client's window can drift by a day.
      if (day < earliest || day > latest) continue;

      days.push({ provider, day, scope, accountKey, tokens: parseTokens(dayEntry.tokens), costUSD: parseCost(dayEntry.costUSD) });

      const dayModels = dayEntry.models ?? [];
      if (!Array.isArray(dayModels)) throw badRequest(`models must be an array (${provider} ${day}).`);
      if (dayModels.length > MAX_MODELS_PER_DAY) throw badRequest(`Too many models (${provider} ${day}).`);
      const seenModels = new Set<string>();
      for (const modelEntry of dayModels) {
        if (!isRecord(modelEntry)) throw badRequest("Each model must be an object.");
        const model = requireName(modelEntry.model, "model", 120);
        const key = model.toLowerCase();
        if (seenModels.has(key)) throw badRequest(`Duplicate model ${model} (${provider} ${day}).`);
        seenModels.add(key);
        models.push({
          provider,
          day,
          scope,
          accountKey,
          model,
          tokens: parseTokens(modelEntry.tokens),
          costUSD: parseCost(modelEntry.costUSD),
        });
      }
    }
  }
  // Without an explicit window (older apps), the earliest day sent marks it.
  const replaceFrom = windowStart ?? days.reduce<string | null>((min, row) => (min === null || row.day < min ? row.day : min), null);
  return { deviceName, appVersion, replaceFrom, days, models };
}

function parseTokens(value: unknown): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0 || value > MAX_TOKENS) {
    throw badRequest("tokens must be a non-negative integer.");
  }
  return value;
}

function parseCost(value: unknown): number | null {
  if (value === null || value === undefined) return null;
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > MAX_COST_USD) {
    throw badRequest("costUSD must be a non-negative number or null.");
  }
  return value;
}
