@MainActor
struct AppContainer {
    let displayName: String
    let connectionService: ConnectionService
    let sessionPresentation: SessionPresentationCoordinator
    let serverDiscovery = BonjourServerDiscovery()
    let library: LibraryRepository
    let librarySync: LibrarySyncCoordinator
    let collections: LibraryCollectionsModel
    let libraryPresentation: LibraryPresentationModel
    let catalogPresentation: CatalogPresentationModel
    let playback: PlaybackController
    let artwork: ArtworkLoader
    let offlineDownloads: OfflineDownloads
    let serverDownloadQueue: ServerDownloadQueue

    init(displayName: String = "Downtify") {
        self.displayName = displayName
        let connection = ConnectionService()
        connectionService = connection
        artwork = ArtworkLoader(connection: connection)
        sessionPresentation = SessionPresentationCoordinator(connectionService: connection, serverDiscovery: serverDiscovery) {
            try await connection.sessionUpdates()
        }
        let api = LibraryAPIClient()
        let database = LibraryDatabase()
        let repository = LibraryRepository(database: database, feed: api) {
            try await connection.restoreSession()
        }
        library = repository
        let sessionUpdates: @Sendable () async throws -> AsyncStream<DeviceSession?> = { try await connection.sessionUpdates() }
        let collections = LibraryCollectionsModel(database: database, sessionUpdates: sessionUpdates)
        self.collections = collections
        let presentation = LibraryPresentationModel(repository: repository, sessionUpdates: sessionUpdates)
        libraryPresentation = presentation
        let catalogPresentation = CatalogPresentationModel(api: CatalogAPI(), sessionUpdates: sessionUpdates)
        self.catalogPresentation = catalogPresentation
        catalogPresentation.start()
        librarySync = LibrarySyncCoordinator(
            repository: repository, events: LibraryWebSocket(api: api),
            sessionUpdates: sessionUpdates,
            verifySession: { try await connection.verifySession(expected: $0) },
            didUpdate: { await presentation.syncDidUpdate(for: $0) },
            didFail: { presentation.syncDidFail(for: $0, message: $1) },
            didChangeCollections: { await collections.refresh(for: $0) },
            didChangeMusicPolicy: { await catalogPresentation.refreshPolicy(for: $0) }
        )
        let playbackCache = PlaybackCache()
        let verifyPlaybackSession: (DeviceSession) async -> Void = {
            _ = try? await connection.verifySession(expected: $0)
        }
        offlineDownloads = .live
        offlineDownloads.verifySession = verifyPlaybackSession
        serverDownloadQueue = ServerDownloadQueue(verifySession: verifyPlaybackSession)
        playback = PlaybackController(
            engine: AVPlaybackEngine(), resolver: PlaybackStreamResolver(cache: playbackCache, offline: offlineDownloads),
            audioSession: SystemPlaybackAudioSession(), remote: SystemPlaybackRemoteControls(),
            store: PlaybackStateStore(), networkMonitor: SystemPlaybackNetworkMonitor(),
            cache: playbackCache, reporting: PlaybackReporting(verifySession: verifyPlaybackSession),
            verifySession: verifyPlaybackSession
        )
    }
}
