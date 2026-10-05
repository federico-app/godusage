import { env } from "cloudflare:test";
import { expect } from "vitest";
import { base64url } from "../src/http";
import { createApp } from "../src/index";

export const RELEASE_AUDIENCE = "com.montinovo.godusage";
export const NOW = new Date("2026-10-05T12:00:00Z");
const KID = "test-key";

async function generateKey(): Promise<CryptoKeyPair> {
  return (await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
}

export const appleKey = await generateKey();
export const otherKey = await generateKey();
export const publicJWK = { ...((await crypto.subtle.exportKey("jwk", appleKey.publicKey)) as JsonWebKey), kid: KID };

export interface TokenClaims {
  sub?: string;
  aud?: string | string[];
  iss?: string;
  exp?: number;
  kid?: string;
  alg?: string;
  key?: CryptoKey;
  nonce?: string;
}

export async function appleToken(claims: TokenClaims = {}): Promise<string> {
  const header = { alg: claims.alg ?? "RS256", kid: claims.kid ?? KID };
  const payload = {
    iss: claims.iss ?? "https://appleid.apple.com",
    aud: claims.aud ?? RELEASE_AUDIENCE,
    exp: claims.exp ?? Math.floor(NOW.getTime() / 1000) + 600,
    iat: Math.floor(NOW.getTime() / 1000),
    sub: claims.sub ?? "000123.apple-user",
    ...(claims.nonce === undefined ? {} : { nonce: claims.nonce }),
  };
  const encode = (value: object) => base64url(new TextEncoder().encode(JSON.stringify(value)));
  const signingInput = `${encode(header)}.${encode(payload)}`;
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    claims.key ?? appleKey.privateKey,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${base64url(new Uint8Array(signature))}`;
}

export function makeApp(now: Date = NOW) {
  return createApp({ fetchAppleKeys: async () => [publicJWK], now: () => now, rateLimiter: async () => true });
}

export interface APIResponse<T = any> {
  status: number;
  body: T;
}

export async function api<T = any>(
  method: string,
  path: string,
  options: { token?: string; body?: unknown; now?: Date } = {},
): Promise<APIResponse<T>> {
  const headers = new Headers();
  if (options.token) headers.set("authorization", `Bearer ${options.token}`);
  if (options.body !== undefined) headers.set("content-type", "application/json");
  const response = await makeApp(options.now).fetch(
    new Request(`https://api.test${path}`, {
      method,
      headers,
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
    }),
    env,
  );
  const text = await response.text();
  const type = response.headers.get("content-type") ?? "";
  return { status: response.status, body: type.includes("json") && text ? JSON.parse(text) : text };
}

let userCounter = 0;

/** Signs in a fresh, unique Apple user and returns its session token and user id. */
export async function signIn(displayName = "Tester"): Promise<{ token: string; userID: string }> {
  userCounter += 1;
  const sub = `sub-${userCounter}-${crypto.randomUUID()}`;
  const response = await api("POST", "/v1/auth/apple", { body: { identityToken: await appleToken({ sub }), displayName } });
  expect(response.status).toBe(201);
  return { token: response.body.token, userID: response.body.user.id };
}

export function inviteCode(inviteURL: string): string {
  return inviteURL.split("/join/")[1]!;
}

/** Creates a team owned by a new user, plus `memberNames.length` members who joined by invite. */
export async function teamWith(memberNames: string[], ownerName = "Owner") {
  const owner = await signIn(ownerName);
  const created = await api("POST", "/v1/teams", { token: owner.token, body: { name: "Crew" } });
  expect(created.status).toBe(201);
  const team = created.body.team;
  const members = [];
  for (const name of memberNames) {
    const member = await signIn(name);
    const joined = await api("POST", `/v1/invites/${inviteCode(team.inviteURL)}/accept`, { token: member.token });
    expect(joined.status).toBe(201);
    members.push(member);
  }
  return { owner, team, members };
}

export interface DayInput {
  date: string;
  tokens: number;
  costUSD?: number | null;
  models?: { model: string; tokens: number; costUSD?: number | null }[];
}

export function upload(providers: { provider: string; scope?: "device" | "account"; days: DayInput[] }[], deviceName = "MacBook") {
  return {
    schema: "godusage.team-usage.v1",
    deviceName,
    providers: providers.map((p) => ({ provider: p.provider, scope: p.scope ?? "device", days: p.days })),
  };
}
