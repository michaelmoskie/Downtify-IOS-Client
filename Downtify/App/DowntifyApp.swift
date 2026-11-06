import SwiftUI

@main
struct DowntifyApp: App {
    private let container = AppContainer()

    var body: some Scene {
        WindowGroup {
            FoundationView(name: container.displayName)
        }
    }
}
