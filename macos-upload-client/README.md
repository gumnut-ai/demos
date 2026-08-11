# macos-upload-client

A native macOS app that one-way syncs photo and video files from local
folders (including network volumes) to a [Gumnut Photos](https://gumnut.ai)
library.

**Status: implemented (pre-release).** Engine and UI are built; a
supervised real-library pass is the remaining step. See
[docs/DESIGN.md](docs/DESIGN.md) for the full design: goals, safety
guarantees, data model, and sync pipeline.

## Layout and building

Requires Xcode 16+ on macOS 15+.

- `UploaderCore/` — Swift package with the engine-independent core:
  embedded SQLite state store (GRDB), read-only file enumeration,
  streaming SHA-256, and the hand-rolled API client. Test with
  `cd UploaderCore && swift test`.
- `GumnutUploader/` — the sandboxed macOS app. Open
  `GumnutUploader/GumnutUploader.xcodeproj` in Xcode, or build with
  `xcodebuild -project GumnutUploader/GumnutUploader.xcodeproj -scheme GumnutUploader build`.

Highlights:

- **Upload-only, and provably so** — the app runs sandboxed with
  read-only file access, so it is incapable of modifying or deleting
  anything on disk. It never calls a destructive API endpoint.
- **Content-addressed sync** — files are identified by SHA-256, checked
  against the library in bulk, and only missing files are uploaded.
  Re-running is always safe: uploads are idempotent on the server side.
- **Review before upload** — every run ends in a plan you approve;
  nothing is sent without an explicit click. Exclusions persist across
  runs.
- **Built for big libraries** — designed for libraries in the hundreds
  of thousands of assets, with folders on NAS/network volumes as a
  first-class case.
