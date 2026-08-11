# macOS Upload Client — Design

**Status: implemented (pre-release).** The engine and the full UI are
built: `UploaderCore/` holds the tested engine (preflight → scan → hash
→ check → review gate → upload), and `GumnutUploader/` is the sandboxed
SwiftUI app — roots sidebar, stats cards, plan tree with persistent
exclusions, per-directory file list, activity bar, run history, and the
Settings window (server URL, API key in Keychain, library, concurrency).
Remaining before calling it done: a supervised real-library pass.

A native macOS app that one-way syncs photo and video files from local
folders to a Gumnut Photos library. Upload-only by construction: the app
cannot modify or delete local files, and never calls a destructive API
endpoint.

## Goals

- One-way sync: local folders → one Gumnut library. Never the reverse.
- Work well with folders on network volumes (NAS over SMB/NFS), not
  just the local disk.
- Multiple root folders, individually selectable per run, with
  selections and exclusions remembered between runs.
- Nothing happens without explicit user approval. Every run ends in a
  reviewable plan; uploads start only on a click.
- Zero chance of local file deletion — enforced by the OS, not by
  convention (see Safety invariants).
- Robust at scale: designed for libraries in the hundreds of thousands
  of assets.
- Clear statistics: files found, already synced, to upload, skipped
  (RAW/unsupported), excluded, errors.

## Non-goals (v1)

- RAW conversion. RAW files are detected, counted, and skipped — the
  API currently rejects them (`422`). The skip count makes the gap
  visible rather than silent.
- File watching, scheduling, or any background activity. The app does
  nothing while closed. (FSEvents does not work on network volumes
  anyway; watching a NAS would mean polling.)
- Two-way sync, downloads, or restore-from-trash.
- Multiple accounts or API keys.

## Identity and dedup: content hash, not filename

Cameras reuse filenames (`IMG_0001.JPG` rolls over every 10,000 shots),
so filenames cannot identify files. Every robust sync tool converges on
the same answer — a content hash of the original bytes (Immich uses
SHA-1, Dropbox a block-wise SHA-256 `content_hash`, Backblaze B2 a
per-file SHA-1) — and the Gumnut API supports this directly:

- **Uploads dedup by checksum.** The API deduplicates uploads by
  content checksum within a library. Uploading bytes the library
  already has returns `200` with the *existing* asset (vs `201` for a
  new one) — it never errors and never creates a duplicate. Uploads are
  therefore idempotent, which makes crash recovery and retries free.
- **Bulk existence check.** `POST /assets/exist` accepts up to 5,000
  base64 SHA-256 checksums per request and returns the matches. This is
  the sync gate: hash local files, ask which ones the library already
  has, upload only the misses.
- **Checksums are readable back.** Asset responses include the
  original file's checksums (`include=file_data`), so the client can
  verify an upload end-to-end by comparing digests.

The client computes **SHA-256** (streaming, via CryptoKit) and uses it
as the sole identity. Filename, path, and timestamps are metadata,
never identity.

**Trash subtlety.** A checksum match includes assets in the library's
trash, and re-uploading the same bytes returns the trashed asset
without restoring it. The client treats any match as "synced" — it
never re-uploads, never restores, and never fights a deletion the user
made in Gumnut.

## Safety invariants

1. **App Sandbox with read-only file access.** The app adopts the
   sandbox with the `com.apple.security.files.user-selected.read-only`
   entitlement. Deleting or modifying a user file is not a code path we
   avoid — it is a syscall the OS refuses. The app can only write
   inside its own container (database, logs, upload staging).
2. **Read-only file access in code, too.** Enumeration and stat go
   through a `FileReader` type; hashing and upload-body encoding open
   read-only `FileHandle`s. The only writes anywhere in the codebase
   target the app's own container: the state database and a temporary
   upload-body staging file.
3. **Additive-only API client.** The client implements exactly the
   endpoints it needs (validate key, list libraries, bulk existence
   check, upload). Trash/delete/update endpoints do not exist in the
   client, so no bug can call them.
4. **Idempotent uploads** (server contract, above): a crash, retry, or
   double-run can waste bandwidth but can never create duplicates.
5. **Unreachable ≠ deleted.** If a root folder doesn't resolve (NAS
   unmounted), an analysis run skips that root with a clear message; an
   upload run aborts entirely — a reviewed plan uploads all of its
   roots or nothing, never a silent subset. Local state is never
   expired because a volume was offline.

## Architecture

Swift + SwiftUI, macOS 15+. Single windowed app; no daemon, no login
item, no background agent.

```
┌─ SwiftUI UI ────────────────────────────────┐
│  Setup · Roots · Plan/Review · Activity ·   │
│  History                                    │
└──────────────┬──────────────────────────────┘
        ┌──────┴───────┐
        │  SyncEngine  │   actor; owns the scan → hash → check →
        └┬────┬────┬───┘   review → upload state machine
         │    │    │
  FileReader Hasher GumnutClient      Store (GRDB/SQLite)
  (read-only (SHA-256, (URLSession,   (app-container DB,
   enumerate/ CryptoKit  hand-rolled)  WAL mode)
   stat)      streaming)
```

- **SQLite is embedded** — a library compiled into the app (via GRDB),
  reading and writing a single file in the app container. No server,
  no daemon, nothing for the user to install or manage.
- **GumnutClient is hand-rolled** over URLSession: four endpoints
  against a configurable base URL (default `https://api.gumnut.ai`),
  and it distinguishes the `200`-duplicate from the `201`-created
  upload response by status code.
- **API key lives in the macOS Keychain**, never in the database or a
  config file.

## Data model

All primary keys are SQLite `INTEGER PRIMARY KEY` — 64-bit by
definition (as is Swift's `Int` on macOS). Nothing in the schema or
code assumes small key ranges or loads whole tables into memory.

- **`roots`** — a selected folder: absolute path (for display) plus a
  security-scoped bookmark (how a sandboxed app re-opens the folder
  across launches; works on network volumes), and an `included` flag —
  whether this root participates in the next scan. The included set
  persists and defaults to the previous run's selection.
- **`files`** — one row per discovered file: `(root_id, rel_path,
  size, mtime, sha256, status, asset_id, error, last_seen_scan_id)`.
  `status` ∈ `pending · synced · excluded · skipped_raw ·
  skipped_unsupported · error`. The `(size, mtime) → sha256` triple is
  the hash cache: files whose size and mtime are unchanged are never
  re-read, which is what makes re-runs cheap over a network mount.
- **`exclusions`** — persisted user choices: `(root_id, kind:
  dir|file, rel_path)`. A directory exclusion covers everything
  beneath it, including files that appear there later.
- **`runs`** — one row per sync run: timestamps, participating roots,
  and all counters. Powers the history view.
- **`settings`** — API base URL (default `https://api.gumnut.ai`),
  target library ID, concurrency knobs.

**Server scoping.** The SHA-256 hash cache is server-independent and
survives any settings change. Sync state (`synced` status and asset
IDs) is only meaningful against a particular server + library, so
changing either resets those fields — never the hashes — and the next
run rebuilds them with a cheap `/assets/exist` re-check.

The database is a **rebuildable cache**: delete it and the next run
re-hashes and re-checks everything against `/assets/exist` — slower,
never wrong. Exclusions and the root list are the only genuinely
user-authored state.

## Sync pipeline (one run)

1. **Preflight.** Resolve each included root's bookmark and confirm it
   is reachable and readable; roots that fail are skipped for this run
   (never expired). Validate the API key and target library. Take a
   `ProcessInfo` activity assertion so App Nap/sleep doesn't stall a
   long run.
2. **Scan.** Walk each included root (child directories included by
   default), applying exclusions. Classify by extension: media
   allowlist (JPEG, PNG, HEIC, WebP, GIF, TIFF, BMP, MP4, MOV, M4V,
   …) mirroring what the API accepts; known RAW extensions →
   `skipped_raw`; everything else (sidecars, hidden files, unknowns)
   → `skipped_unsupported`. Stat every media file; `(size, mtime)`
   unchanged → keep the cached hash, else mark for re-hash. Files
   modified within the last ~30 seconds are deferred to the next run
   (they may still be mid-copy). After a failure-free scan of a root,
   rows the scan did not see are pruned — those files are gone from
   disk (deleted, moved, or renamed; deferred files count as seen).
   Unreachable roots and scans with enumeration failures never prune
   (unreachable ≠ deleted).
3. **Hash.** Streaming SHA-256 over files that need it, 2–3 files
   concurrently — network mounts reward few sequential streams over
   many parallel ones. This is the honest cost of the first run
   (network-bound; roughly 6 GB/min on gigabit), and the UI shows
   bytes remaining and a real ETA. Later runs hash only new or changed
   files.
4. **Check.** Send all unresolved checksums to `POST /assets/exist` in
   batches of ≤ 5,000. Matches become `synced` with their asset ID
   recorded. A 200,000-file library is 40 cheap requests.
5. **Review — the gate.** Nothing so far has uploaded a byte of file
   content (only hashes). The user sees the plan: summary cards plus a
   lazily-loaded tree of the scanned roots with per-folder counts and
   include/exclude checkboxes. Unchecking writes an `exclusions` row,
   so it sticks for future runs. Files discovered in later runs are
   included in the plan by default (unless under an excluded
   directory) but always sit behind this same gate. Upload begins only
   on **"Upload N files (X GB)"**.
6. **Upload.** Approved files only, ~3 concurrent, throttled
   client-side. Multipart `POST /assets` with `file_created_at` /
   `file_modified_at` from filesystem stats (the service extracts EXIF
   itself), a stable `device_asset_id` (root UUID + relative path),
   and a per-install `device_id`. Response handling:
   - Before sending, the staged request body's file bytes are hashed
     and compared against the analyzed digest — a file whose bytes
     changed without moving its (size, mtime) is refused rather than
     uploaded unreviewed, and its hash cache is invalidated for
     re-analysis.
   - `201` → uploaded; `200` → already existed (record the asset ID
     either way). Compare the returned checksum against ours as a free
     integrity check.
   - `422` → unsupported format; mark permanently skipped.
   - `429` / rate limiting → back off and honor `Retry-After`.
   - Transient storage errors (`502` with a retryable error code) →
     bounded retries honoring `Retry-After`.
   - `507` (storage quota) → stop the run cleanly and tell the user.
   - Network drop → mark `error`, continue with the rest; errored
     files reappear in the next run's plan, and idempotency makes the
     retry free.
7. **Report.** Write the `runs` row; show the summary.

## Multiple roots

- **Sidebar of roots.** Add via the system folder picker (which is
  what grants sandbox access), remove with confirmation (removes
  database rows only — never files). Nested or duplicate roots are
  rejected at add time so no file can be tracked or uploaded under two
  identities.
- **Per-run selection with memory.** Each root has an "include in
  scan" checkbox; the checked set is the default next time. Unchecked
  roots keep all their state — file rows, hash cache, exclusions,
  stats — frozen until re-included, and are never treated as missing.
- **Scoping.** Exclusions are per-root. Stats can be viewed across all
  roots or per root. Each run records which roots participated. The
  target library is a single global setting in v1; the schema leaves
  room for per-root library mapping later.

## Scale and network-volume behavior

- Designed for libraries in the hundreds of thousands of files. The
  review tree and stats are backed by SQL aggregation (`GROUP BY` on
  an indexed path prefix, `COUNT`/`SUM` for cards) with rows fetched
  lazily on folder expansion — the full `files` table is never held in
  memory.
- Re-run scans are dominated by `stat()` calls over the mount — a few
  minutes for very large trees, shown as a progress phase, not hidden.
- No FSEvents on network volumes → no watching; scans are explicit.
- Duplicate local files (same SHA-256 at two paths) are surfaced as a
  statistic; they map to one Gumnut asset, and the second upload is a
  no-op by the dedup contract.

## Statistics

Files discovered · media files · already in Gumnut · to upload (count
and bytes) · uploaded this run · skipped (RAW) · skipped (unsupported)
· excluded · errors · duplicate local files. Shown as cards on the main
screen; per-run history in the history view.

## Screens

1. **Setup** — API key field (stored in Keychain), "Test connection",
   library picker when the account has more than one.
2. **Main** — roots sidebar, stats cards, plan tree with exclusion
   checkboxes, the upload button.
3. **Activity** — per-phase progress (scan / hash / check / upload),
   per-file feed, cancel (safe at any point; all state is in SQLite).
4. **History** — past runs and their counters.
5. **Settings** (standard macOS Settings window, ⌘,) — server base URL
   (default `https://api.gumnut.ai`, for self-hosted or staging
   servers; validated with the same "Test connection" check), target
   library, upload/hash concurrency. The natural home for future
   options as they arise. Changing the server or library triggers the
   sync-state reset described under Server scoping.

## Future directions

- RAW support, once the API accepts RAW uploads.
- An opt-in "re-scan on launch" convenience (still gated on approval).
- Per-root target libraries.
- Incremental awareness of server-side changes via the API's events
  feed, instead of relying solely on `/assets/exist`.
