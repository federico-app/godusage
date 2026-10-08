/**
 * The proxy Worker: keeps the hosts the apps already call (godusage-api[-dev].federico-c80.workers.dev)
 * working after the backend moved to Coolify. A workers.dev hostname cannot point at another server,
 * so this Worker forwards every request, unchanged, to `ORIGIN_URL` (the Coolify domain) and returns
 * the response as it is (redirects and cookies included).
 *
 * The server builds public links (Sign in with Apple's redirect_uri, invite and board links) from the
 * host the client used, so the Worker tells it that host and the client's IP in `x-godusage-*`
 * headers, with `PROXY_SECRET` proving they come from here (see backend/server/http.ts). Coolify's
 * reverse proxy rewrites the standard X-Forwarded-* headers, so they are not used for this.
 */
export interface ProxyEnv {
  /** The Coolify domain, e.g. https://api.godusage.com. */
  ORIGIN_URL: string;
  /** The api service's PROXY_SECRET (a Worker secret). */
  PROXY_SECRET: string;
}

export const PROXY_SECRET_HEADER = "x-godusage-proxy-secret";
export const PROXY_HOST_HEADER = "x-godusage-public-host";
export const PROXY_CLIENT_IP_HEADER = "x-godusage-client-ip";

type Fetcher = (input: Request | string | URL, init?: RequestInit) => Promise<Response>;

function failure(status: number, code: string, message: string): Response {
  return new Response(JSON.stringify({ error: { code, message } }), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}

export async function proxyRequest(request: Request, env: ProxyEnv, fetcher: Fetcher = fetch): Promise<Response> {
  if (!env.ORIGIN_URL || !env.PROXY_SECRET) {
    console.error(JSON.stringify({ event: "proxy_misconfigured", originURL: Boolean(env.ORIGIN_URL), proxySecret: Boolean(env.PROXY_SECRET) }));
    return failure(500, "internal", "Something went wrong. Try again later.");
  }
  const incoming = new URL(request.url);
  const target = new URL(`${incoming.pathname}${incoming.search}`, env.ORIGIN_URL);

  const headers = new Headers(request.headers);
  headers.delete("host");
  for (const name of [PROXY_SECRET_HEADER, PROXY_HOST_HEADER, PROXY_CLIENT_IP_HEADER]) headers.delete(name);
  headers.set(PROXY_SECRET_HEADER, env.PROXY_SECRET);
  headers.set(PROXY_HOST_HEADER, incoming.host);
  headers.set(PROXY_CLIENT_IP_HEADER, request.headers.get("cf-connecting-ip") ?? "unknown");

  const hasBody = request.method !== "GET" && request.method !== "HEAD";
  try {
    // Bodies are small (uploads are capped at 512 KB), so buffering keeps this simple and portable.
    return await fetcher(target.toString(), {
      method: request.method,
      headers,
      body: hasBody ? await request.arrayBuffer() : undefined,
      redirect: "manual",
    });
  } catch (error) {
    console.error(JSON.stringify({ event: "proxy_origin_unreachable", origin: target.origin, message: error instanceof Error ? error.message : String(error) }));
    return failure(502, "unavailable", "The GodUsage server can't be reached right now. Try again in a minute.");
  }
}
