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
    let serverDownloads: ServerDownloadPresentationModel

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
        let playbackCache = PlaybackCache()
        let verifyPlaybackSession: (DeviceSession) async -> Void = {
            _ = try? await connection.verifySession(expected: $0)
        }
        offlineDownloads = .live
        offlineDownloads.verifySession = verifyPlaybackSession
        let serverDownloadQueue = ServerDownloadQueue(verifySession: verifyPlaybackSession)
        self.serverDownloadQueue = serverDownloadQueue
        let serverDownloads = ServerDownloadPresentationModel(queue: serverDownloadQueue, sessionUpdates: sessionUpdates)
        self.serverDownloads = serverDownloads
        serverDownloads.start()
        let controller = PlaybackController(
            engine: AVPlaybackEngine(), resolver: PlaybackStreamResolver(cache: playbackCache, offline: offlineDownloads),
            audioSession: SystemPlaybackAudioSession(), remote: SystemPlaybackRemoteControls(),
            store: PlaybackStateStore(), networkMonitor: SystemPlaybackNetworkMonitor(),
            cache: playbackCache, reporting: PlaybackReporting(verifySession: verifyPlaybackSession),
            verifySession: verifyPlaybackSession
        )
        playback = controller
        Task { @MainActor in
            for await state in catalogPresentation.$policyState.values {
                guard state == .ready, let only = catalogPresentation.isLibraryOnly else { continue }
                controller.applyLibraryOnlyPolicy(only, tracks: presentation.tracks)
            }
        }
        librarySync = LibrarySyncCoordinator(
            repository: repository, events: LibraryWebSocket(api: api),
            sessionUpdates: sessionUpdates,
            verifySession: { try await connection.verifySession(expected: $0) },
            didUpdate: { await presentation.syncDidUpdate(for: $0) },
            didFail: { presentation.syncDidFail(for: $0, message: $1) },
            didChangeCollections: { await collections.refresh(for: $0) },
            didChangeMusicPolicy: { [weak catalogPresentation] session in
                await catalogPresentation?.refreshPolicy(for: session)
                guard catalogPresentation?.policyState == .ready,
                      let only = catalogPresentation?.isLibraryOnly else { return }
                controller.applyLibraryOnlyPolicy(only, tracks: presentation.tracks)
            },
            didChangeDownloadQueue: { [weak serverDownloads] session in
                guard serverDownloads?.session == session else { return }
                await serverDownloads?.queueDidChange()
            }
        )

    }
}
