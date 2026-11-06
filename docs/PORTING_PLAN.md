# Downtify iOS port plan

## Baseline and decisions

- Source baseline: [downtify-android](https://github.com/henriquesebastiao/downtify-android) at `100be83e49c3250424e6326670a73bff69325b73`. The workspace has no existing iOS project. Before building, Task 1 must audit this exact revision and the matching server mobile-client contract; the feature list below is provisional until that audit is complete.
- Build a native Swift/SwiftUI app, initially targeting iOS 17+, iPhone and adaptive iPad layouts. Use Swift concurrency, URLSession, Network/Bonjour, Keychain, a transactional local database, AVFoundation and MediaPlayer. Finalize the database and deployment target in Task 2. Use protocol-based composition and value types; the hierarchy below is a responsibility map, not an inheritance mandate.
- Support server mobile API v1, server 3.1.0+ and capability-gated password sign-in on supported servers. Preserve the server contract and its compatibility behavior; do not infer endpoints from this plan. Review the Android GPL-3.0 license and all asset/font licenses before distribution.
- HTTP may be necessary for self-hosted LAN servers. Design the narrowest practical ATS policy, explicitly warn before sending credentials or tokens over insecure HTTP, retain normal TLS validation, and document any App Store implications. Never persist passwords or log tokens.

## Coverage and platform adaptations

| Android capability | iOS target |
|---|---|
| Discovery, manual address, QR/code pairing, password sign-in, revoke/sign out | Bonjour/local-network permission, camera permission, Keychain token, feature negotiation and recovery. |
| Home, library, artists, albums, tracks, collections/playlists, likes, recents, search | Native browsing, filtering/sorting and available mutations, including favorites and display names. |
| Discover, similar tracks, podcasts/shows, lyrics | Match actual Android behavior and server capabilities identified in Task 1, including preview and synchronized lyrics if present. |
| Playback, queue, shuffle/repeat, streaming quality, normalization, cache and resume | Background audio, lock screen, Bluetooth/AirPlay controls, queue/position restore, network-aware transcoding, peak protection where technically feasible. |
| Offline downloads and server download queue | Separate on-device offline files from server-side jobs; show progress, cancellation, storage and recovery. Background transfers are OS-scheduled and cannot promise uninterrupted execution after force quit. |
| Admin music trash | Capability/role gated; match Android actions and confirmations, including irreversible operations. |
| Settings, appearance, about, eight languages | System/light/dark and OLED black, accessible native typography, localized strings, licenses and source links. Android wallpaper colors and Android-specific font delivery have no direct iOS equivalent; use artwork-derived accents and locally licensed fonts or system font. |
| Android Auto | CarPlay browsing and playback if Apple grants the required entitlement; otherwise ship phone, lock-screen and vehicle Bluetooth controls, documenting the gap. Do not block core release on entitlement. |

## Responsibility and class hierarchy

```text
DowntifyApp
└── AppContainer (composition root, dependency ownership)
    ├── AppRouter / SessionCoordinator
    ├── Domain (structs/enums: Server, Session, Track, Album, Artist,
    │   Playlist, Podcast, Episode, Lyrics, Download, Queue, Settings)
    ├── Network
    │   ├── APIClient → endpoint services (Auth, Library, Catalog, Playback,
    │   │   Discovery, Podcasts, Downloads, Trash)
    │   ├── ServerDiscoveryService, SocketEventService, NetworkMonitor
    │   └── KeychainSessionStore
    ├── Data
    │   ├── DatabaseStore + migrations; SettingsStore; ArtworkCache
    │   ├── LibraryRepository, CatalogRepository, PodcastRepository,
    │   │   DownloadRepository, TrashRepository, PlaybackRepository
    │   └── SyncCoordinator, ListenReporter, OfflineTransferManager
    ├── Playback
    │   ├── PlaybackController → AudioEngine (AVFoundation adapter)
    │   ├── QueueController, StreamResolver, PlaybackStateStore
    │   └── AudioSessionCoordinator, NowPlayingCoordinator, normalization
    └── Presentation
        ├── DesignSystem (tokens, components, accessibility)
        ├── Connect, Home, Library, Search, Discover, Podcasts, Downloads,
        │   Settings, Trash: each View → feature ViewModel → protocols
        └── MiniPlayer, NowPlaying, Queue, Lyrics → PlayerViewModel
```

Views observe main-actor presentation state; repositories expose domain values, not database entities or server DTOs. Serialize mutable sync, transfer and playback state with actors or explicit isolation. Centralize authorization, retries, server capability checks and revoked-session handling. Keep offline media, artwork and transient stream cache distinct; avoid credentials in media URLs or logs where possible.

## Agent protocol and dependencies

A coordinator owns the integration branch, interface contracts, task ordering and acceptance. For every numbered task, start one fresh subagent for that task only; provide only its goal, relevant source paths and pinned revision, agreed interfaces, allowed files, dependencies and acceptance checks. The subagent returns a diff, tests and unresolved issues, then terminates. Never send the whole plan or unrelated task context. Coordinator reviews and integrates before launching dependent work; use separate worktrees or otherwise non-overlapping files for concurrent tasks. If a task fails review, assign a new single-task agent with only the relevant feedback. Model and reasoning-effort assignments are starting estimates, not guarantees. Use the smallest assignment that can handle the task; the coordinator reviews each result. Escalate only after a documented blocker or failed review, and give the replacement agent only the relevant feedback. The user must approve any model change.

Each implementation task includes its own meaningful unit or integration tests and accessibility/error states where applicable. The coordinator must maintain the parity matrix from Task 1 and record evidence, deviations and platform constraints for every row. Work may run concurrently only after its dependencies and interfaces are accepted.

## Tasks

| ID | Model / effort | Task and acceptance | Depends on |
|---|---|---|---|
| 1 | gpt-6.1-sol / high | Audit Android screens, settings, tests, server API contract and server-version gates at the pinned SHA. Produce a feature/action matrix with source paths, endpoint references, expected behavior, unsupported cases and test scenarios; include podcasts, server jobs, local downloads, admin trash and all settings. Flag unknowns instead of guessing. | — |
| 2 | gpt-6.1-sol / medium | Establish Swift project, build/test configuration, module boundaries, dependency injection and versioned protocol/DTO contracts based on Task 1. Decide database, supported iOS versions, storage protection, app lifecycle and migration strategy. A clean simulator build and contract fixtures pass. | 1 |
| 3 | gpt-6.1-sol / high | Implement address normalization, API transport, server info/capabilities, typed failures, TLS/HTTP policy and mock-server contract tests. Validate compatibility and prevent secrets in diagnostics. | 2 |
| 4 | gpt-6.1-sol / high | Implement Bonjour discovery, manual connection, QR/code pairing, password sign-in, Keychain sessions, revocation and permission flows. Verify old/new server gates, denied permissions, restart and sign-out. | 3 |
| 5 | gpt-6.1-sol / high | Implement transactional local library database, migrations and repositories, incremental/full sync, socket-triggered refresh and conflict/retry behavior. Test initial, interrupted and repeated sync without lost updates. | 3 |
| 6 | gpt-6.1-sol / high | Implement playback engine, queue and restoration, quality policy, stream resolution, audio session, interruptions, remote commands, metadata, Bluetooth/AirPlay and background playback. Verify queue operations, network transitions and device lifecycle. | 3, 5 |
| 7 | gpt-6.1-sol / high | Implement playback cache/read-ahead, pretranscode where supported, listen/activity reporting with durable retry, and measured peak-protected normalization. Verify no duplicate/lost reports and test audio gain/clipping; document any AVFoundation limitations before claiming parity. | 5, 6 |
| 8 | gpt-6.1-sol / high | Implement offline downloads with background URLSession where suitable, persisted progress, cancel/delete/retry, integrity checks, storage accounting and offline playback; separate server download queue operations. Test relaunch, network loss, low storage and force-quit limitations. | 3, 5, 6 |
| 9 | gpt-6.1-sol / medium | Build design system and app shell: polished artwork-led surfaces, native navigation, responsive iPhone/iPad layouts, persistent mini player, reusable lists and accessible states. Support Dynamic Type, VoiceOver, contrast, reduced motion and light/dark/OLED; supply previews for representative states. | 2 |
| 10 | gpt-6-luna / high | Build connection screens on Task 4 interfaces and Task 9 components. Verify discovery, QR, manual entry, login, insecure-connection warning and permission recovery end to end. | 4, 9 |
| 11 | gpt-6.1-sol / medium | Build Home and Library browsing, artist/album/playlist/collection details, likes, favorites, recents, sorting and supported mutations per parity matrix. Verify empty, offline, large-library and error states. | 5, 9 |
| 12 | gpt-6.1-sol / medium | Build local/server search, Discover, Similar and previews using the audited server capabilities. Verify cancellation, paging if applicable, offline behavior and unavailable features. | 5, 9 |
| 13 | gpt-6-luna / high | Build podcasts and shows, including episode browsing and playback as specified by the parity matrix. Verify server capability gates and resume behavior. | 5, 6, 9 |
| 14 | gpt-6.1-sol / medium | Build Now Playing, queue editing, lyrics, mini-player controls and playback feedback using existing player interfaces. Verify transport, progress, queue changes, lyrics timing and accessibility. | 6, 9 |
| 15 | gpt-6-luna / high | Build local downloads and server queue screens using Task 8 interfaces; verify status, retry, cancel, delete and offline playback. | 8, 9 |
| 16 | gpt-6.1-sol / high | Implement capability- and role-gated administrator trash operations and screens, matching server contract and Android confirmations. Verify authorization failures, stale data and irreversible-action safeguards. | 3, 5, 9 |
| 17 | gpt-6-luna / high | Implement settings, appearance, About, attribution and localization for Bulgarian, English, French, Greek, Hungarian, Portuguese (Brazil), Spanish and Turkish. Audit existing translations and licenses; test fallback, long strings and layout. | 7, 8, 9 |
| 18 | gpt-6.1-sol / high | Evaluate and implement CarPlay browsing/search/playback using a shared library and player, conditional on entitlement. Test simulator and real vehicle/receiver when available; otherwise deliver entitlement request prerequisites and documented fallback. | 5, 6 |
| 19 | gpt-6.1-sol / high | Run integration and release validation against real supported servers and devices: pairing, sync, offline, playback and remote controls, reconnect/revocation, migrations, privacy, accessibility, localizations and performance. Reconcile every parity row, fix or assign scoped fixes, document remaining gaps and GPL/asset obligations, and produce a reproducible release checklist. | 1–18 |

## Release gate

A release candidate requires a clean build and automated suite on macOS, completed parity matrix, successful real-device background/lock-screen and offline tests, supported-server compatibility results, accessibility and localization checks, and no unresolved critical security, data-loss or playback defects. Record CarPlay entitlement and physical-vehicle results separately, together with any iOS or server limitations. App Store distribution additionally requires signing, privacy disclosures, ATS review and license compliance; resolve these with the project owner before submission.

