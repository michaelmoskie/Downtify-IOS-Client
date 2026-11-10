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
                         serverDownloadQueue: container.serverDownloadQueue)
                .environmentObject(container.artwork)
                .environmentObject(container.collections)
                .environmentObject(container.catalogPresentation)
                .task { container.collections.start() }
                .environmentObject(container.offlineDownloads)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            container.librarySync.setActive(phase == .active)
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
