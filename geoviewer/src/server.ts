import { serve } from "@hono/node-server";
import { serveStatic } from "@hono/node-server/serve-static";
import { Hono } from "hono";

const BASE_URL = process.env.GUMNUT_BASE_URL?.replace(/\/+$/, "");
const API_KEY = process.env.GUMNUT_API_KEY;

if (!BASE_URL || !API_KEY || API_KEY === "replace-me") {
  console.error(
    "Missing GUMNUT_BASE_URL or GUMNUT_API_KEY. Copy .env.example to .env and fill it in.",
  );
  process.exit(1);
}

const upstreamOrigin = new URL(BASE_URL).origin;
const authHeaders = { Authorization: `Bearer ${API_KEY}` };

function isAllowedThumbnailOrigin(target: URL): boolean {
  if (target.origin === upstreamOrigin) return true;
  const h = target.hostname.toLowerCase();
  return h === "gumnut.ai" || h.endsWith(".gumnut.ai");
}

const app = new Hono();

app.get("/api/assets", async (c) => {
  const params = new URLSearchParams({ limit: "100" });
  const after = c.req.query("starting_after_id");
  if (after) params.set("starting_after_id", after);

  const res = await fetch(`${BASE_URL}/api/assets?${params}`, {
    headers: authHeaders,
  });
  const body = await res.text();
  return new Response(body, {
    status: res.status,
    headers: { "content-type": res.headers.get("content-type") ?? "application/json" },
  });
});

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

  // Thumbnail URLs from assets.gumnut.ai are presigned; sending our
  // API key would only confuse them. Only forward auth to the upstream API.
  const headers = target.origin === upstreamOrigin ? authHeaders : undefined;
  const res = await fetch(target, { headers });
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

const port = 5173;
serve({ fetch: app.fetch, hostname: "127.0.0.1", port }, () => {
  console.log(`geoviewer listening on http://127.0.0.1:${port}`);
  console.log(`upstream: ${BASE_URL}`);
});
