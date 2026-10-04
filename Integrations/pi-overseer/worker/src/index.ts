// Worker entry: authenticates and routes everything to the single PiOverseer object.

import { PiOverseer, type Env } from "./agent-do.ts";
import { PHONE_HTML } from "./phone-ui.ts";

export { PiOverseer };

function safeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const x = enc.encode(a);
  const y = enc.encode(b);
  if (x.byteLength !== y.byteLength) return false;
  return crypto.subtle.timingSafeEqual(x, y);
}

function bearer(request: Request): string {
  return request.headers.get("Authorization")?.replace(/^Bearer\s+/i, "") ?? "";
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (!env.BRIDGE_TOKEN || !env.PHONE_TOKEN) {
      return new Response("Set BRIDGE_TOKEN and PHONE_TOKEN secrets first (wrangler secret put).", { status: 500 });
    }

    if (url.pathname === "/" || url.pathname === "/index.html") {
      return new Response(PHONE_HTML, {
        headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
      });
    }

    let authorized = false;
    if (url.pathname === "/bridge") authorized = safeEqual(bearer(request), env.BRIDGE_TOKEN);
    // Browsers cannot set headers on WebSocket upgrades, so the phone socket uses a query token.
    else if (url.pathname === "/phone") authorized = safeEqual(url.searchParams.get("token") ?? "", env.PHONE_TOKEN);
    else if (url.pathname.startsWith("/api/")) authorized = safeEqual(bearer(request), env.PHONE_TOKEN);
    else return new Response("not found", { status: 404 });

    if (!authorized) return new Response("unauthorized", { status: 401 });

    const stub = env.PI_OVERSEER.get(env.PI_OVERSEER.idFromName("default"));
    return stub.fetch(request);
  },
} satisfies ExportedHandler<Env>;
