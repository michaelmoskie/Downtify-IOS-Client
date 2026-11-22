# Simulator automation (debug harness)

Repeatable simulator checks for the iOS client, from issue #48. The harness exists only in Debug builds (`#if DEBUG`). Release and TestFlight builds contain none of it; `scripts/verify_release_omits_debug_hooks.sh` checks that.

## Running the checks

```bash
scripts/run_simulator_checks.sh
```

- Uses the first booted simulator. Override with `DOWNTIFY_SIM_DESTINATION='platform=iOS Simulator,id=<UDID>'`.
- Writes result bundles and logs to a temp directory (override with `DOWNTIFY_SIM_ARTIFACTS`).
- Runs the catalog/player unit tests, the fixture UI scenarios, and a secret scan of the artifacts.
- Fixture mode is used unless `.local/test-server.txt` is present. Force it with `DOWNTIFY_SIM_MODE=fixture`.

Individual suites:

```bash
xcodebuild test -project Downtify.xcodeproj -scheme Downtify -only-testing:DowntifyTests -destination 'platform=iOS Simulator,id=<UDID>'
xcodebuild test -project Downtify.xcodeproj -scheme Downtify -only-testing:DowntifyUITests -destination 'platform=iOS Simulator,id=<UDID>' -resultBundlePath <dir>/uitests.xcresult
scripts/verify_release_omits_debug_hooks.sh Release   # must exit 0
scripts/verify_release_omits_debug_hooks.sh Debug     # negative control: must exit 1
```

Run only one `xcodebuild` or simulator job at a time.

## Modes

| Mode | Activated by | Network | Media |
| --- | --- | --- | --- |
| fixture (default) | `-DowntifyHarness` | Canned JSON API only, in-process. No sockets. | Generated silent WAV (30 s, 8 kHz, mono, 8-bit) written to the harness temp directory. |
| staging | `-DowntifyHarness -DowntifyHarnessMode staging` plus the env vars below | Real server, through a guard that enforces the rules below | Real server |

Fixture credentials are test values inside the harness. Sign-in is automatic in both modes.

### Launch arguments

- `-DowntifyHarness`: activates the harness. Without it the app behaves exactly as Release.
- `-DowntifyHarnessMode fixture|staging`: default `fixture`.
- `-DowntifyFault <route>=<kind>`: repeatable. See the fault catalogue.
- `-DowntifyFixtureTracks <n>`: fixture mode only. Generates `n` library tracks (2 to 12, default 2) named `fixture-track-1...n`, "Fixture One", "Fixture Two", and so on. The Songs list shows newest first, so the highest number is listed first.
- `-DowntifyFixtureLyrics none|synced|plain|both|error`: fixture mode only. Default `none` keeps the lyrics capability off. The other values turn it on and serve four placeholder lines (2 s, 8 s, 14 s, 20 s) as synced and/or plain text; `error` makes the lyrics route fail with a 500.
- `-DowntifyFixtureSimilar <pages>[,failpage=<n>]`: fixture mode only (pages 1 to 3). Turns on the discover capability and serves `/api/similar/tracks` with 20 real song titles per page. Each page's last song, used as the next seed, returns the following page. Past the last page only duplicates come back. `failpage` makes that page fail once with a 500, then succeed on retry.

### Environment (test runner)

Set these in the shell that runs `xcodebuild`. The UI test runner forwards `TEST_RUNNER_`-prefixed variables to the app without the prefix.

| Variable | Meaning |
| --- | --- |
| `TEST_RUNNER_DOWNTIFY_TEST_SERVER` | Server base URL (`http`/`https`). Required in staging mode. |
| `TEST_RUNNER_DOWNTIFY_TEST_USER` / `..._PASSWORD` | Test account. Required in staging mode. Use a test account only. |
| `TEST_RUNNER_DOWNTIFY_TEST_ALLOWED_HOST` | Optional. If set, must equal the server host. |
| `TEST_RUNNER_DOWNTIFY_TEST_ALLOW_MUTATIONS=1` | Opt-in for non-GET requests. Honored only on loopback-like hosts. |

### Staging rules (fail closed)

- Missing server, missing credentials, unsupported scheme, or a host outside the allow-list makes the harness refuse all network traffic.
- Allowed hosts: `localhost`, `127.0.0.1`, `::1`, `*.localhost`, `*.test`, or any host whose name contains `staging`, `dev`, or `qa`.
- Mutations (any method other than GET or HEAD) are allowed only when both hold: the host is loopback-like (`localhost`, `127.0.0.1`, `::1`, `*.localhost`, `*.test`), and `ALLOW_MUTATIONS=1` is set.
- Remote staging-named hosts are read-only even with the opt-in.
- Any request to a host other than the configured one is refused.

## Local staging configuration

`.local/test-server.txt` is gitignored (`.git/info/exclude` and `.gitignore`). Never commit it. Format:

```
SERVER_URL=<base URL>
USERNAME=<test account>
PASSWORD=<test password>
```

`scripts/run_simulator_checks.sh` reads it in-process and exports the `TEST_RUNNER_` variables without printing them. Do not use `set -x` around it.

## Observability: `debug.state`

A hidden accessibility element with identifier `debug.state`. Its value is redacted JSON with these keys only:

`playbackPhase`, `queueCount`, `currentTrackID`, `position`, `network`, `libraryTrackCount`, `lastErrorCode`, `artworkLoaded`, `playerVisible`, `sessionActive`, `queueTrackIDs` (library track ids in play order; catalog items appear as `catalog`).

It never contains tokens, usernames, server addresses, or track titles. Keys are always present (null when absent). UI tests decode it through `DowntifyUITestSupport.waitForState(_:timeout:where:)`.

Stable accessibility identifiers used by the tests: `tab.library`, `tab.search`, `tab.more`, `library.trackRow.<id>`, `catalog.searchField`, `catalog.result.<id>`, `tab.discover`, `lyrics.line.<index>`, `lyrics.modePicker`, `lyrics.plain`, `lyrics.resetOffset`, `lyrics.offsetValue`, `similar.row.<songID>`, `similar.loadingMore`, `similar.retry`, `similar.end`, `player.dock`, `player.full`, `player.playPause`, `player.artwork`, `connect.serverField`, `connect.signInButton`.

## Fault catalogue

`-DowntifyFault <route>=<kind>`

| Route | Applies to | Kinds |
| --- | --- | --- |
| `serverInfo` | `/api/server/info` | `timeout`, `http500`, `offline`, `401` |
| `auth` | `/api/auth/*` | same |
| `library` | `/api/v1/library` | same |
| `catalog` | `/api/songs`, `/api/albums`, `/api/artists`, `/api/url`, `/api/finder` | same |
| `stream` | playback stream (the harness resolver) | `timeout`/`offline` → network failure, `http500` → invalid stream, `401` → unauthorized |

Unknown route or kind names are ignored.

## Adding a scenario

1. Add a `func test...()` to `DowntifyUITests/DebugHarnessUITests.swift`.
2. Launch with `DowntifyUITestSupport.launch(faults:staging:)`.
3. Drive the UI through identifiers, then assert on `debug.state` with `waitForState`.
4. For a new fault, add the route case in `DebugHarness.swift` and handle it in `DebugFixtureTransport`.
5. Add unit coverage in `DowntifyTests/DebugHarnessTests.swift`.

## Redaction and artifacts

- The app never prints or logs configuration values.
- `scripts/check_no_secrets_in_artifacts.sh <dir>` checks a directory (result bundles, logs) for the configured password, username, server host and URL, and `Bearer` token patterns. It reports counts and file names only.
- Do not share artifact directories until the scan passes.
- The scan covers raw files. Result bundles store some attachments compressed, so export and scan them when a leak is suspected.

## Combining with bad-network simulation

The `simulate-bad-network` skill (`.claude/skills/simulate-bad-network`) degrades the host network with `sudo`. Run it manually, then run the checks. Do not run it from automation. The `stream` and `library` faults cover the same failure paths without touching the host.

## Mutation scenarios and the local server

Mutation scenarios need a local server on loopback. The server source is the Downtify server repository. Its documented run command is `uv run python main.py web`, with the port set by `DOWNTIFY_PORT` (default 8000).

Status: **not verified in this change.** The command comes from that repository's Makefile. It has not been started and checked from this harness. Until someone verifies it, treat mutation scenarios as unverified.

## What stays manual

- Real energy and battery use.
- Lock screen and Control Center Now Playing.
- Real device behaviour (audio routes, background audio, push).
- Long-running soak tests and real network conditions.
- Anything that needs a human to judge sound or visual quality.

## Manual GitHub Actions experiment

The manual checks run the unit suite and fixture smoke tests on an iPhone simulator with Xcode 26.2. The separate compatibility workflow runs the full suite on iPhone / iOS 18.5 and iPad / iOS 26.2, both with Xcode 26.2. Both use standard macOS runners and select an available simulator of the requested family and runtime. No server credentials are needed. Failed results are scanned before upload and retained for seven days; compressed attachments are not covered by the scan.

These workflows have no automatic triggers. Their jobs only run when both the original actor and the person initiating a rerun are `michaelmoskie`, and the selected ref is `release/0.1.2-12`. This is a workflow-level safeguard: people with write access can still dispatch a run, modify workflows on branches they control, or alter this guard. Restrict repository write access for stronger control.

GitHub requires a workflow file on the default branch before it can be manually dispatched, even when running a different branch. While these files exist only on the release branch, they cannot yet be dispatched through GitHub Actions. The pinned runner images and runtimes may also need updates over time.
