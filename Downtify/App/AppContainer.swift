@MainActor
struct AppContainer {
    let displayName: String
    let connectionService: ConnectionService
    let sessionPresentation: SessionPresentationCoordinator
    let serverDiscovery = BonjourServerDiscovery()
    let library: LibraryRepository
    let librarySync: LibrarySyncCoordinator
    let libraryPresentation: LibraryPresentationModel
    let playback: PlaybackController
    let artwork: ArtworkLoader

    init(displayName: String = "Downtify") {
        self.displayName = displayName
        let connection = ConnectionService()
        connectionService = connection
        artwork = ArtworkLoader(connection: connection)
        sessionPresentation = SessionPresentationCoordinator(connectionService: connection, serverDiscovery: serverDiscovery) {
            try await connection.sessionUpdates()
        }
        let api = LibraryAPIClient()
        let repository = LibraryRepository(database: LibraryDatabase(), feed: api) {
            try await connection.restoreSession()
        }
        library = repository
        let sessionUpdates: @Sendable () async throws -> AsyncStream<DeviceSession?> = { try await connection.sessionUpdates() }
        let presentation = LibraryPresentationModel(repository: repository, sessionUpdates: sessionUpdates)
        libraryPresentation = presentation
        librarySync = LibrarySyncCoordinator(
            repository: repository, events: LibraryWebSocket(api: api),
            sessionUpdates: sessionUpdates,
            verifySession: { try await connection.verifySession(expected: $0) },
            didUpdate: { await presentation.syncDidUpdate(for: $0) },
            didFail: { presentation.syncDidFail(for: $0, message: $1) }
        )
        let playbackCache = PlaybackCache()
        let verifyPlaybackSession: (DeviceSession) async -> Void = {
            _ = try? await connection.verifySession(expected: $0)
        }
        playback = PlaybackController(
            engine: AVPlaybackEngine(), resolver: PlaybackStreamResolver(cache: playbackCache),
            audioSession: SystemPlaybackAudioSession(), remote: SystemPlaybackRemoteControls(),
            store: PlaybackStateStore(), networkMonitor: SystemPlaybackNetworkMonitor(),
            cache: playbackCache, reporting: PlaybackReporting(verifySession: verifyPlaybackSession),
            verifySession: verifyPlaybackSession
        )
    }
}
