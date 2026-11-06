import SwiftUI

@main
struct DowntifyApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let container = AppContainer()

    var body: some Scene {
        WindowGroup {
            AppShellView(name: container.displayName, presentation: container.sessionPresentation,
                         library: container.libraryPresentation, playback: container.playback)
                .tint(DowntifyStyle.accent)
                .preferredColorScheme(.dark)
                .environmentObject(container.artwork)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            container.librarySync.setActive(phase == .active)
            if phase == .active {
                container.playback.observeSessions(
                    updates: { try await container.connectionService.sessionUpdates() },
                    tracks: { try await container.library.snapshot().tracks }
                )
            } else {
                container.playback.persist()
            }
        }
    }
}
