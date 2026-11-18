/**
 * The `X-GodUsage-Client` header the iPhone and iPad app sends on every request:
 *
 *     X-GodUsage-Client: ios; app=1.10.1; model=iPhone 13; os=26.1
 *
 * The first part names the platform; the rest are `key=value` pairs in any order. Unknown keys are
 * skipped. It is external input, so a header longer than `CLIENT_HEADER_MAX` is ignored whole, and a
 * value that is empty, too long, or not printable ASCII is dropped (that field stays unknown). It
 * never fails a request.
 */
export const CLIENT_HEADER = "x-godusage-client";
export const CLIENT_HEADER_MAX = 256;

export interface ClientInfo {
  platform: string;
  model: string | null;
  osVersion: string | null;
  appVersion: string | null;
}

const LIMITS = { model: 60, os: 32, app: 32 } as const;
const PRINTABLE = /^[\x20-\x7e]+$/;
const PLATFORM = /^[a-z]{1,16}$/;

/** The parsed header, or null when it is missing or unusable. */
export function readClientHeader(request: Request): ClientInfo | null {
  const header = request.headers.get(CLIENT_HEADER);
  if (!header) return null;
  if (header.length > CLIENT_HEADER_MAX) {
    console.log(JSON.stringify({ event: "client_header_ignored", reason: "too_long", length: header.length }));
    return null;
  }
  const [first, ...pairs] = header.split(";").map((part) => part.trim());
  const platform = first?.toLowerCase() ?? "";
  if (!PLATFORM.test(platform)) {
    console.log(JSON.stringify({ event: "client_header_ignored", reason: "platform" }));
    return null;
  }
  const values: Partial<Record<keyof typeof LIMITS, string>> = {};
  for (const pair of pairs) {
    const equals = pair.indexOf("=");
    if (equals <= 0) continue;
    const key = pair.slice(0, equals).trim().toLowerCase();
    const value = pair.slice(equals + 1).trim().replace(/\s+/g, " ");
    if (!(key in LIMITS)) continue;
    const limit = LIMITS[key as keyof typeof LIMITS];
    if (value.length === 0 || value.length > limit || !PRINTABLE.test(value)) continue;
    values[key as keyof typeof LIMITS] = value;
  }
  return { platform, model: values.model ?? null, osVersion: values.os ?? null, appVersion: values.app ?? null };
}
