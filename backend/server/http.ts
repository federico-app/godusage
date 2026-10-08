import { timingSafeEqual } from "node:crypto";
import type { IncomingHttpHeaders, IncomingMessage, ServerResponse } from "node:http";
import type { Env } from "../src/context";
import { CLIENT_IP_HEADER } from "../src/rateLimit";

/**
 * Node's HTTP request → the Fetch API Request the routes take, and their Response → Node's.
 *
 * The routes build public links (Sign in with Apple's redirect_uri, invite and board links) from the
 * request URL, so it must carry the host the client used:
 *
 * - Through the proxy Worker (the app's workers.dev hosts, see proxy/), the Worker sends the public
 *   host and the client's IP in `x-godusage-*` headers with a shared secret (`PROXY_SECRET`). Coolify's
 *   reverse proxy (Traefik) rewrites the standard `X-Forwarded-*` headers, so these have their own names.
 * - Directly through Coolify's domain, Traefik's `X-Forwarded-Proto` and `Host` are used, and the
 *   client's IP is the last `X-Forwarded-For` entry (the one Traefik itself appended).
 *
 * A request with a proxy secret that does not match is refused: it is either a misconfigured Worker
 * or someone forging the public host.
 */
export const PROXY_SECRET_HEADER = "x-godusage-proxy-secret";
export const PROXY_HOST_HEADER = "x-godusage-public-host";
export const PROXY_CLIENT_IP_HEADER = "x-godusage-client-ip";

export class ProxyRejected extends Error {}

const HOST_PATTERN = /^[A-Za-z0-9.-]+(:\d{1,5})?$/;

function secretMatches(expected: string, actual: string): boolean {
  const a = Buffer.from(expected);
  const b = Buffer.from(actual);
  return a.length === b.length && timingSafeEqual(a, b);
}

export function toFetchRequest(
  method: string,
  path: string,
  headers: IncomingHttpHeaders,
  body: Buffer | undefined,
  socketAddress: string | undefined,
  proxySecret: string | undefined,
): Request {
  const requestHeaders = new Headers();
  for (const [name, value] of Object.entries(headers)) {
    if (value === undefined) continue;
    for (const item of Array.isArray(value) ? value : [value]) requestHeaders.append(name, item);
  }
  const secret = requestHeaders.get(PROXY_SECRET_HEADER);
  const publicHost = requestHeaders.get(PROXY_HOST_HEADER);
  const proxiedIP = requestHeaders.get(PROXY_CLIENT_IP_HEADER);
  for (const name of [PROXY_SECRET_HEADER, PROXY_HOST_HEADER, PROXY_CLIENT_IP_HEADER, CLIENT_IP_HEADER]) requestHeaders.delete(name);

  let proto: string;
  let host: string;
  let clientIP: string;
  if (secret !== null) {
    if (!proxySecret) throw new ProxyRejected("A proxied request arrived, but PROXY_SECRET is not set.");
    if (!secretMatches(proxySecret, secret)) throw new ProxyRejected("A proxied request carried the wrong proxy secret.");
    if (!publicHost || !HOST_PATTERN.test(publicHost)) throw new ProxyRejected("A proxied request has no valid public host.");
    proto = "https";
    host = publicHost;
    clientIP = proxiedIP || "unknown";
  } else {
    proto = requestHeaders.get("x-forwarded-proto")?.split(",")[0]?.trim() || "http";
    host = requestHeaders.get("host") || "localhost";
    const forwardedFor = requestHeaders.get("x-forwarded-for")?.split(",").map((part) => part.trim()).filter(Boolean);
    clientIP = forwardedFor?.at(-1) || socketAddress || "unknown";
  }
  if (!HOST_PATTERN.test(host)) host = "localhost";
  requestHeaders.set(CLIENT_IP_HEADER, clientIP);
  return new Request(`${proto}://${host}${path}`, {
    method,
    headers: requestHeaders,
    body: body && body.length > 0 && method !== "GET" && method !== "HEAD" ? new Uint8Array(body) : undefined,
  });
}

export async function writeFetchResponse(response: Response, res: ServerResponse): Promise<void> {
  const headers: Record<string, string | string[]> = {};
  response.headers.forEach((value, name) => {
    if (name !== "set-cookie") headers[name] = value;
  });
  const cookies = response.headers.getSetCookie();
  if (cookies.length > 0) headers["set-cookie"] = cookies;
  res.writeHead(response.status, headers);
  res.end(Buffer.from(await response.arrayBuffer()));
}

const MAX_BODY_BYTES = 1024 * 1024;

/** Node's request handler for the app: reads the body (up to 1 MB), runs the route, writes the response. */
export function requestListener(
  app: { fetch(request: Request, env: Env): Promise<Response> },
  env: Env,
  proxySecret: string | undefined,
  logError: (event: string, error: unknown) => void,
): (req: IncomingMessage, res: ServerResponse) => void {
  return (req, res) => {
    const chunks: Buffer[] = [];
    let size = 0;
    req.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        res.writeHead(413, { "content-type": "application/json" }).end(JSON.stringify({ error: { code: "too_large", message: "Request too large." } }));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", async () => {
      if (res.writableEnded) return;
      try {
        const request = toFetchRequest(req.method ?? "GET", req.url ?? "/", req.headers, Buffer.concat(chunks), req.socket.remoteAddress, proxySecret);
        await writeFetchResponse(await app.fetch(request, env), res);
      } catch (error) {
        const rejected = error instanceof ProxyRejected;
        logError(rejected ? "proxy_rejected" : "server_error", error);
        if (!res.headersSent) res.writeHead(rejected ? 403 : 500, { "content-type": "application/json" });
        res.end(
          JSON.stringify(
            rejected
              ? { error: { code: "forbidden", message: "This request did not come through the GodUsage proxy." } }
              : { error: { code: "internal", message: "Something went wrong. Try again later." } },
          ),
        );
      }
    });
  };
}
