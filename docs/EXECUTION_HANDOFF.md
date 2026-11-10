# Execution handoff

Updated 2026-11-09. The current branch is `feat-search-add`. The iOS worktree is clean at `9d8d31f`.

## Completed

- **Task 1 — parity and contract audit:** committed as `cd0b9ef`. The [web parity audit](WEBUI_PARITY_AUDIT.md) records current Search, Finder, Discover, Similar, streaming and download behavior, the client authorization findings, library-only limits, and shared iOS interfaces. The sibling server source was inspected read-only at clean HEAD `07c5d3a038707b3b1b296a936ac3a239e9af33a9`.
- **Task 2 — device contract tests:** no server production change was needed. Two paired-device middleware tests are committed as `bae3608` in the disposable local clone `/private/tmp/downtify-core-task2`; the sibling checkout was not changed. Twelve focused suites passed, 385 tests total, plus Ruff and diff checks.
- **Task 3 — catalog models and services:** committed as `c806bd8`. Adds typed provider-aware models, authenticated catalog clients, session/policy-aware presentation state, and `music_policy_changed` handling.
- **Task 4 — mixed catalog playback:** committed as `9d8d31f`. Adds persisted `.library`/`.catalog` queue entries with legacy migration, catalog stream resolution and prefetch, policy pruning, library-only listen/reporting isolation, and the three-consecutive-unplayable cutoff.

## Simulator and verification

The booted simulator is an iPhone 18 Pro on iOS 27.0 (`CCD1473E-C0CD-4469-B7D0-052E5E9F6152`). Networking was verified inside the simulator by loading `example.com` in Safari. Downtify was relaunched after Task 4 tests.

The latest full signed simulator suite passed **117/117 tests**. Result bundle: `/tmp/DowntifySimulatorTerraSigned/Logs/Test/Test-Downtify-2026.11.09_22-08-46--0500.xcresult`; log: `/private/tmp/task4-test.log`. Simulator/Xcode commands need the already-approved elevated CoreSimulator access; normal simulator signing avoids the unsigned Keychain error.

Task 3 and Task 4 source/project checks also passed. Task 4 verified `plutil -lint` and `git diff --check`. No live Downtify server session or credential-backed end-to-end run has been performed.

## Next: Task 5 — server download actions

Task 5 planning is complete; implementation was dispatched briefly and stopped before any edits. The worktree remains clean. Resume by assigning a Luna medium coordinator, then separate API and presentation owners, with the coordinator owning project/socket/AppContainer/localization integration.

Key contract details from the planner:

- Keep `requestTrack(link:)` for validated pasted HTTP(S) links. Add `requestTrack(song:)` that sends `/api/download/url?url=<song.url>` with the **complete raw CatalogSong payload** as JSON. Preserve `download_by_metadata`, provider IDs, track numbering, unknown fields, and `source=text_search` with its `downtify-search:` pseudo URL.
- Batch uses `POST /api/download/batch` with `{songs, playlist_url?, playlist_name?, cover_url?, generate_m3u}` and returns `{job_ids,count}`. Album uses `POST /api/download/album?url=…` only for verified YouTube Music album URL forms; its successful-only map does not establish partial completeness without an expected tracklist.
- Verify server identity, HTTP consent and `library_only` before bearer requests; preserve 401/403/409/404/5xx errors. Do not auto-retry an ambiguous cancelled/timed-out POST.
- Queue responses use `song_id`, `name`, and `artists` (with legacy `id`/`title` fallbacks). Decode `queue_reload` and progress events, coalesce refreshes, poll while work is active, scope states to the current session, prevent duplicate taps, and keep server jobs distinct from phone offline files. Existing `library_changed` handles library sync; do not resync for every progress frame.
- Publish a stable Task 6 action interface such as `request(song:)`, `requestBatch(songs:options:)`, `requestAlbum(url:expected:)`, `actionState(for:)`, and `refreshQueue()`.

After Task 5, execute Task 6 Search/Discover/Finder UI, then Task 7 end-to-end verification and documentation. Keep all Git operations local; commit each verified completed task and never push.
