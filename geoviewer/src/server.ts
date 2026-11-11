import { serve } from "@hono/node-server";
import { createApp, PORT } from "./app.js";

const BASE_URL = process.env.GUMNUT_BASE_URL?.replace(/\/+$/, "");
const API_KEY = process.env.GUMNUT_API_KEY;

if (!BASE_URL || !API_KEY || API_KEY === "replace-me") {
  console.error(
    "Missing GUMNUT_BASE_URL or GUMNUT_API_KEY. Copy .env.example to .env and fill it in.",
  );
  process.exit(1);
}

const app = createApp({ baseUrl: BASE_URL, apiKey: API_KEY });

serve({ fetch: app.fetch, hostname: "127.0.0.1", port: PORT }, () => {
  console.log(`geoviewer listening on http://127.0.0.1:${PORT}`);
  console.log(`upstream: ${BASE_URL}`);
});
