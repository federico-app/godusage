import { proxyRequest, type ProxyEnv } from "./proxy";

// The Worker's entry module exports only the handler: Workers treat every named export as an entrypoint.
export default {
  fetch: (request: Request, env: ProxyEnv) => proxyRequest(request, env),
};
