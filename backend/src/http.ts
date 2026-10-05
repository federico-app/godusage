/** An error that maps to a JSON error response. Thrown by handlers, rendered by the router. */
export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

export const badRequest = (message: string) => new ApiError(400, "bad_request", message);
export const notFound = (message = "Not found.") => new ApiError(404, "not_found", message);
export const forbidden = (message: string) => new ApiError(403, "forbidden", message);
export const conflict = (message: string) => new ApiError(409, "conflict", message);
export const unauthorized = (message = "Sign in again.") => new ApiError(401, "unauthorized", message);

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}

export function noContent(): Response {
  return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
}

export function errorResponse(error: ApiError): Response {
  return json({ error: { code: error.code, message: error.message } }, error.status);
}

/** Usage uploads are the largest bodies (about 30 days × a few providers × models). */
const MAX_BODY_BYTES = 512 * 1024;

/** Reads a JSON object body with a hard size cap, so an oversized upload cannot exhaust memory. */
export async function readJSONObject(request: Request): Promise<Record<string, unknown>> {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (declared > MAX_BODY_BYTES) throw new ApiError(413, "too_large", "Request body is too large.");
  if (!request.body) throw badRequest("Missing request body.");

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_BODY_BYTES) {
      await reader.cancel();
      throw new ApiError(413, "too_large", "Request body is too large.");
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    throw badRequest("Request body is not valid JSON.");
  }
  if (!isRecord(parsed)) throw badRequest("Request body must be a JSON object.");
  return parsed;
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Trims and validates a user-chosen name (display name, team name). */
export function requireName(value: unknown, field: string, maxLength: number): string {
  if (typeof value !== "string") throw badRequest(`${field} is required.`);
  const trimmed = value.trim().replace(/\s+/g, " ");
  if (trimmed.length === 0) throw badRequest(`${field} cannot be empty.`);
  if ([...trimmed].length > maxLength) throw badRequest(`${field} must be at most ${maxLength} characters.`);
  if (/[\u0000-\u001f\u007f]/.test(trimmed)) throw badRequest(`${field} contains invalid characters.`);
  return trimmed;
}

export function nowISO(): string {
  return new Date().toISOString();
}

/** A URL-safe random token with `bytes` bytes of entropy. */
export function randomToken(bytes: number): string {
  const buffer = crypto.getRandomValues(new Uint8Array(bytes));
  return base64url(buffer);
}

export function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function base64urlDecode(value: string): Uint8Array {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
