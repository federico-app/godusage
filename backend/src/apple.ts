import { base64urlDecode, isRecord, unauthorized } from "./http";

const APPLE_ISSUER = "https://appleid.apple.com";
export const APPLE_KEYS_URL = "https://appleid.apple.com/auth/keys";

export interface AppleIdentity {
  /** Stable per-team user id. The only claim GodUsage keeps. */
  sub: string;
}

export type AppleKeyFetcher = () => Promise<JsonWebKey[]>;

/** Downloads Apple's current signing keys. Login is rare, so the keys are fetched per login. */
export const fetchAppleKeys: AppleKeyFetcher = async () => {
  const response = await fetch(APPLE_KEYS_URL);
  if (!response.ok) throw new Error(`Apple keys request failed with HTTP ${response.status}`);
  const body: unknown = await response.json();
  if (!isRecord(body) || !Array.isArray(body.keys)) throw new Error("Apple keys response has no keys");
  return body.keys as JsonWebKey[];
};

/**
 * Verifies a Sign in with Apple identity token (an RS256 JWT): signature against Apple's key with
 * the token's `kid`, issuer, audience (one of our bundle ids), and expiry.
 */
export async function verifyAppleIdentityToken(
  token: string,
  audiences: string[],
  fetchKeys: AppleKeyFetcher,
  now: Date = new Date(),
  expectedNonce?: string,
): Promise<AppleIdentity> {
  const parts = token.split(".");
  if (parts.length !== 3) throw unauthorized("The Apple sign-in token is malformed.");
  const [headerPart, payloadPart, signaturePart] = parts as [string, string, string];

  const header = decodeJSONPart(headerPart);
  const payload = decodeJSONPart(payloadPart);
  if (header.alg !== "RS256" || typeof header.kid !== "string") {
    throw unauthorized("The Apple sign-in token uses an unsupported algorithm.");
  }

  const keys = await fetchKeys();
  const jwk = keys.find((key) => (key as JsonWebKey & { kid?: string }).kid === header.kid);
  if (!jwk) throw unauthorized("The Apple sign-in token was signed with an unknown key.");

  const key = await crypto.subtle.importKey(
    "jwk",
    { kty: jwk.kty, n: jwk.n, e: jwk.e, alg: "RS256", ext: true },
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"],
  );
  const valid = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    key,
    base64urlDecode(signaturePart),
    new TextEncoder().encode(`${headerPart}.${payloadPart}`),
  );
  if (!valid) throw unauthorized("The Apple sign-in token signature is invalid.");

  if (payload.iss !== APPLE_ISSUER) throw unauthorized("The Apple sign-in token has the wrong issuer.");
  const tokenAudiences = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
  if (!tokenAudiences.some((aud) => typeof aud === "string" && audiences.includes(aud))) {
    throw unauthorized("The Apple sign-in token is for a different app.");
  }
  if (typeof payload.exp !== "number" || payload.exp * 1000 <= now.getTime()) {
    throw unauthorized("The Apple sign-in token has expired. Sign in again.");
  }
  // The web flow binds the token to its sign-in request, so a token from another request is refused.
  if (expectedNonce !== undefined && payload.nonce !== expectedNonce) {
    throw unauthorized("The Apple sign-in token belongs to a different sign-in attempt.");
  }
  if (typeof payload.sub !== "string" || payload.sub.length === 0) {
    throw unauthorized("The Apple sign-in token has no user id.");
  }
  return { sub: payload.sub };
}

function decodeJSONPart(part: string): Record<string, unknown> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder().decode(base64urlDecode(part)));
  } catch {
    throw unauthorized("The Apple sign-in token is malformed.");
  }
  if (!isRecord(parsed)) throw unauthorized("The Apple sign-in token is malformed.");
  return parsed;
}
