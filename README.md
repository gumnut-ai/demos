# Gumnut demos

Standalone, self-contained demos that integrate with the [Gumnut Photos
API](https://api.gumnut.ai). Each demo lives in its own subdirectory and
runs against your own Gumnut library using a personal API key.

These are reference integrations — small enough to read end-to-end,
designed to be forked and adapted.

## Demos

| Demo | What it does |
| --- | --- |
| [`face-cleanup/`](face-cleanup/) | Browser-only triage UI for cleaning up a Person's face cluster — surfaces likely-misassigned faces and one-clicks them onto the right Person. |

## Get an API key

1. Sign in to [gumnut.ai](https://gumnut.ai).
2. Open the dashboard and create a personal API key.
3. Each demo's README explains where to paste it.

The API key is scoped to your account; demos only ever see data from
libraries you own.

## Running a demo

Every demo here is a static page or a small script — no servers, no
build step, no Gumnut credentials checked into the repo. See each demo's
`README.md` for the exact commands.

## Contributing

Demos should be:

- **Self-contained** — one directory, no shared state between demos.
- **Easy to run** — a single command to start, ideally with no install
  step beyond what ships on most laptops (Python 3, `npx`, etc.).
- **Documented** — each demo has its own `README.md` covering setup,
  what it does, and what API endpoints it consumes.
- **Read-only by default**, or clearly mark write actions. Demos that
  mutate library data (reassign faces, rename people, etc.) should say
  so up front.

## License

Apache 2.0 — see [LICENSE](LICENSE).
