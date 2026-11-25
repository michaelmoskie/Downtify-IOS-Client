import SwiftUI

@main
struct DowntifyApp: App {
    @UIApplicationDelegateAdaptor(OfflineDownloadAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    private let container = AppContainer()

    var body: some Scene {
        WindowGroup {
            AppShellView(name: container.displayName, presentation: container.sessionPresentation,
                         library: container.libraryPresentation, playback: container.playback,
                         serverDownloadQueue: container.serverDownloadQueue,
                         serverDownloads: container.serverDownloads)
                .environmentObject(container.artwork)
                .environmentObject(container.collections)
                .environmentObject(container.catalogPresentation)
                .environmentObject(container.storageSettings)
                .environmentObject(container.reachability)
                .task { container.reachability.start() }
                .environment(\.lyricDefaults, container.defaults)
                .task { container.collections.start() }
                .environmentObject(container.offlineDownloads)
                .environmentObject(container.playback.nowPlaying)
                #if DEBUG
                .overlay(alignment: .topLeading) {
                    if container.harness != nil {
                        DebugStateHost(container: container)
                    }
                }
                #endif
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            container.librarySync.setActive(phase == .active)
            container.collections.setActionsActive(phase == .active)
            container.reachability.setActive(phase == .active)
            if phase == .active {
                container.offlineDownloads.observeSessions { try await container.connectionService.sessionUpdates() }
                container.offlineDownloads.reconnect()
                container.playback.observeSessions(
                    updates: { try await container.connectionService.sessionUpdates() },
                    tracks: { try await container.library.snapshot().tracks }
                )
            } else {
                container.offlineDownloads.persistProgress()
                container.playback.persist()
            }
        }
    }
}

#if DEBUG
/// Refreshes the redacted `debug.state` element several times per second. Reads only; never writes state.
private struct DebugStateHost: View {
    let container: AppContainer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            DebugStateProbe(snapshot: snapshot())
        }
    }

    @MainActor
    private func snapshot() -> DebugStateSnapshot {
        let playback = container.playback
        let phase = Self.phaseName(playback.phase)
        if phase != Self.lastPhase {
            Self.lastPhase = phase
            DebugLog.logger.info("playback phase -> \(phase, privacy: .public) queue=\(playback.queue.entries.count, privacy: .public)")
        }
        let sessionActive: Bool
        if case .library = container.sessionPresentation.destination { sessionActive = true } else { sessionActive = false }
        return DebugStateSnapshot(
            playbackPhase: Self.phaseName(playback.phase),
            queueCount: playback.queue.entries.count,
            currentTrackID: playback.queue.current?.item.libraryTrack?.id,
            position: playback.position,
            network: String(describing: playback.network),
            libraryTrackCount: container.libraryPresentation.tracks.count,
            lastErrorCode: Self.errorCode(playback.phase),
            artworkLoaded: ArtworkLoader.debugLoadCount > 0,
            playerVisible: playback.queue.current != nil || playback.podcast != nil,
            sessionActive: sessionActive,
            queueTrackIDs: playback.queue.order.map { $0.item.libraryTrack?.id ?? "catalog" }
        )
    }

    private static var lastPhase = ""

    private static func phaseName(_ phase: PlaybackPhase) -> String {
        switch phase {
        case .idle: return "idle"
        case .loading: return "loading"
        case .paused: return "paused"
        case .playing: return "playing"
        case .buffering: return "buffering"
        case .ended: return "ended"
        case .failed: return "failed"
        }
    }

    private static func errorCode(_ phase: PlaybackPhase) -> String? {
        if case .failed(let failure) = phase { return String(describing: failure) }
        return nil
    }
}
#endif
