import { serveStatic } from "@hono/node-server/serve-static";
import { Hono } from "hono";

export const PORT = 5173;

// The page is only meant to be opened as http://127.0.0.1:5173 or
// http://localhost:5173. Any other Host header is refused before routing.
const ALLOWED_HOSTS = new Set([`127.0.0.1:${PORT}`, `localhost:${PORT}`]);

export interface AppOptions {
  baseUrl: string;
  apiKey: string;
  fetch?: typeof globalThis.fetch;
}

export function createApp({ baseUrl, apiKey, fetch = globalThis.fetch }: AppOptions): Hono {
  const upstreamOrigin = new URL(baseUrl).origin;

  function isAllowedThumbnailOrigin(target: URL): boolean {
    if (target.origin === upstreamOrigin) return true;
    const h = target.hostname.toLowerCase();
    return h === "gumnut.ai" || h.endsWith(".gumnut.ai");
  }

  const app = new Hono();

  app.use("*", async (c, next) => {
    const host = c.req.header("host");
    if (!host || !ALLOWED_HOSTS.has(host)) return c.text("host not allowed", 403);
    await next();
  });

  // The only route that sends the API key upstream.
  app.get("/api/assets", async (c) => {
    const params = new URLSearchParams({ limit: "100" });
    const after = c.req.query("starting_after_id");
    if (after) params.set("starting_after_id", after);

    const res = await fetch(`${baseUrl}/api/assets?${params}`, {
      headers: { Authorization: `Bearer ${apiKey}` },
    });
    const body = await res.text();
    return new Response(body, {
      status: res.status,
      headers: { "content-type": res.headers.get("content-type") ?? "application/json" },
    });
  });

  // Thumbnail URLs in the asset payload are presigned (or, against a local
  // Gumnut API server, served without auth), so they are fetched without the
  // API key.
  app.get("/api/thumbnail", async (c) => {
    const u = c.req.query("u");
    if (!u) return c.text("missing u", 400);

    let target: URL;
    try {
      target = new URL(u);
    } catch {
      return c.text("bad url", 400);
    }
    if (!isAllowedThumbnailOrigin(target)) {
      return c.text("origin not allowed", 400);
    }

    const res = await fetch(target);
    return new Response(res.body, {
      status: res.status,
      headers: {
        "content-type": res.headers.get("content-type") ?? "application/octet-stream",
        "cache-control": "private, max-age=300",
      },
    });
  });

  app.use("/*", serveStatic({ root: "./public" }));
  app.get("/", serveStatic({ path: "./public/index.html" }));

  return app;
}
