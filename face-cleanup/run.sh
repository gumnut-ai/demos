#!/usr/bin/env bash
# Launch the face-cleanup dashboard locally.
#
# Starts a static HTTP server in this directory and opens the page in
# the default browser. Stop with Ctrl-C.
set -euo pipefail

cd "$(dirname "$0")"

PORT="${PORT:-8000}"
URL="http://localhost:${PORT}/"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to run this demo." >&2
  echo "Alternative: 'npx serve . -l ${PORT}' from this directory." >&2
  exit 1
fi

if lsof -i ":${PORT}" -P -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port ${PORT} is already in use." >&2
  echo "Set PORT=<other> and re-run, or stop the process using ${PORT}." >&2
  exit 1
fi

echo "Serving face-cleanup on ${URL}"
echo "Press Ctrl-C to stop."

# Open the browser shortly after the server starts.
( sleep 1
  if command -v open >/dev/null 2>&1; then
    open "${URL}"
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "${URL}"
  fi
) &

exec python3 -m http.server "${PORT}"
