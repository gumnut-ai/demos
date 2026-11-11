import assert from "node:assert/strict";
import { request as httpRequest, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, beforeEach, test } from "node:test";
import { serve } from "@hono/node-server";
import { createApp } from "./app.js";

const API_KEY = "test-key";
const upstream: { url: string; authorization: string | null }[] = [];

const fakeFetch: typeof fetch = async (input, init) => {
  const url = input instanceof Request ? input.url : String(input);
  upstream.push({ url, authorization: new Request(input, init).headers.get("authorization") });
  const json = url.includes("/api/assets");
  return new Response(json ? '{"data":[]}' : "img", {
    headers: { "content-type": json ? "application/json" : "image/webp" },
  });
};

let server: Server;
let port: number;

before(async () => {
  const app = createApp({ baseUrl: "http://localhost:8000", apiKey: API_KEY, fetch: fakeFetch });
  await new Promise<void>((resolve) => {
    server = serve({ fetch: app.fetch, hostname: "127.0.0.1", port: 0 }, () => resolve()) as Server;
  });
  port = (server.address() as AddressInfo).port;
});

after(() => new Promise<void>((resolve) => server.close(() => resolve())));

beforeEach(() => {
  upstream.length = 0;
});

// Sends a real HTTP request with an explicit Host header, as a browser would.
function get(path: string, host: string): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const req = httpRequest({ hostname: "127.0.0.1", port, path, headers: { host } }, (res) => {
      let body = "";
      res.setEncoding("utf8");
      res.on("data", (chunk) => (body += chunk));
      res.on("end", () => resolve({ status: res.statusCode ?? 0, body }));
    });
    req.on("error", reject);
    req.end();
  });
}

for (const host of ["127.0.0.1:5173", "localhost:5173"]) {
  test(`serves the page and asset listing for Host ${host}`, async () => {
    assert.equal((await get("/", host)).status, 200);
    const res = await get("/api/assets", host);
    assert.equal(res.status, 200);
    assert.equal(res.body, '{"data":[]}');
  });
}

for (const host of ["example.com", "example.com:5173", "127.0.0.1", "localhost:8000", "localhost.example.com:5173"]) {
  test(`refuses Host ${host} before any upstream request`, async () => {
    for (const path of ["/", "/api/assets", "/api/thumbnail?u=" + encodeURIComponent("http://localhost:8000/api/assets")]) {
      assert.equal((await get(path, host)).status, 403, path);
    }
    assert.deepEqual(upstream, []);
  });
}

test("sends the API key with the asset listing", async () => {
  await get("/api/assets?starting_after_id=asset_1", "127.0.0.1:5173");
  assert.deepEqual(upstream, [
    {
      url: "http://localhost:8000/api/assets?limit=100&starting_after_id=asset_1",
      authorization: `Bearer ${API_KEY}`,
    },
  ]);
});

for (const thumbnail of [
  "https://assets.gumnut.ai/thumb.webp?verify=sig",
  "http://localhost:8000/serve-assets/thumb.webp",
  "http://localhost:8000/api/assets",
]) {
  test(`fetches ${thumbnail} without the API key`, async () => {
    const res = await get("/api/thumbnail?u=" + encodeURIComponent(thumbnail), "localhost:5173");
    assert.equal(res.status, 200);
    assert.deepEqual(upstream, [{ url: thumbnail, authorization: null }]);
  });
}

test("refuses thumbnail URLs outside the allowed origins", async () => {
  const res = await get("/api/thumbnail?u=" + encodeURIComponent("https://example.com/x.webp"), "127.0.0.1:5173");
  assert.equal(res.status, 400);
  assert.deepEqual(upstream, []);
});
